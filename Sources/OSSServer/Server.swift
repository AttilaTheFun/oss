import Foundation
import OSSClient

/// One UTM change at a time: clones, settings, starts and deletes are
/// serialised so two leases never trip over each other in UTM.
actor UTMQueue {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return try await work()
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)"
    FileHandle.standardError.write(Data((line + "\n").utf8))
    ServerLog.sink?(line)
}

/// Where the server's log lines go besides standard error: the OS Server
/// app shows them and keeps them in a file.
public enum ServerLog {
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?

    /// A line in the server's log, from what runs beside it (the app's containers).
    public static func write(_ message: String) { log(message) }
}

#if canImport(Network)

/// The leases: each a clone of a base (a UTM VM, a simulator, an AVD),
/// made when asked for, handed to its holder (SSH and VNC, or simctl, or
/// adb, through this Mac), and deleted when released or when its time runs out.
actor MachineManager {
    let config: ServerConfig
    private var leases: [String: Lease] = [:]
    /// The bases, as last listed (refreshed in the background: UTM can take
    /// minutes to answer while it's busy).
    private var knownBases: [Base] = []
    private var forwarders: [String: [Forwarder]] = [:]
    private let utm = UTMQueue()
    /// The server's Bazel cache, which every VM lease reads.
    private let bazelCache: (port: Int, readToken: String)?
    /// What runs containers, where this process can (OS Server's app).
    let containers: ContainerBackend?

    init(config: ServerConfig, bazelCache: (port: Int, readToken: String)? = nil, containers: ContainerBackend? = nil) {
        self.config = config
        self.bazelCache = bazelCache
        self.containers = containers
    }

    // MARK: Status

    /// What can be leased, without waiting on UTM: its VMs as last listed
    /// (kept across restarts), simulators and emulators as they are now.
    func bases() async throws -> [Base] {
        await combineBases()
        return knownBases
    }

    /// VM bases as UTM last listed them (UTM can be slow, or hold every
    /// request while a permission prompt waits: a failed listing keeps the
    /// last one).
    private lazy var knownVMBases: [Base] = FileManager.default.contents(atPath: Paths.vmBases)
        .flatMap { try? JSONDecoder.oss.decode([Base].self, from: $0) } ?? []
    /// The one UTM listing in flight, shared by whoever asks meanwhile.
    private var listing: Task<[Base]?, Never>?

    func refreshBases() async throws {
        guard config.useUTM else { return await combineBases() }
        let task = listing ?? Task {
            (try? await UTM.list()).map { $0.compactMap { Base(name: $0.name) }.filter { $0.platform.isVM } }
        }
        listing = task
        let vms = await task.value
        listing = nil
        if let vms {
            knownVMBases = vms
            if let data = try? JSONEncoder.oss.encode(vms) { FileManager.default.createFile(atPath: Paths.vmBases, contents: data) }
        }
        await combineBases()
    }

    private func combineBases() async {
        // OS Server's own macOS bases (Virtualization's) before UTM's of the same config.
        #if canImport(Virtualization)
        let own = MacVMStore.configs().map { Base(platform: .macos, config: $0) }
        #else
        let own: [Base] = []
        #endif
        let utm = !config.useUTM ? [] : knownVMBases.filter { base in !own.contains { $0.platform == base.platform && $0.config == base.config } }
        let simulators = config.lends(.ios) ? await Simulators.bases() : []
        let emulators = config.lends(.android) ? Emulators.bases(config) : []
        let all = own + utm + simulators + emulators + containerBases
        knownBases = all.filter { $0.config != "base" && config.lends($0.platform) }
            .sorted { ($0.platform.rawValue, $0.config) < ($1.platform.rawValue, $1.config) }
    }

    /// Containers have one base, Linux on this Mac's CPU: what they run is
    /// the image each lease names.
    private var containerBases: [Base] {
        containers != nil && config.lends(.container) ? [Base(platform: .container, config: "linux")] : []
    }

    private func findBase(_ platform: Platform, _ config: String) async -> Base? {
        switch platform {
        case .ios: return await Simulators.bases().first { $0.config == config }
        case .android: return Emulators.bases(self.config).first { $0.config == config }
        case .container: return containerBases.first { $0.config == config }
        default:
            if let base = knownBases.first(where: { $0.platform == platform && $0.config == config }) { return base }
            try? await refreshBases()
            return knownBases.first(where: { $0.platform == platform && $0.config == config })
        }
    }

    func capacity() -> [Capacity] {
        Platform.allCases.map { platform in
            Capacity(platform: platform, limit: config.limit(platform),
                     leased: leases.values.filter { $0.platform == platform && $0.state != .failed }.count)
        }
    }

    func all() -> [Lease] { leases.values.sorted { $0.created < $1.created } }
    func lease(_ id: String) -> Lease? { leases[id] }

    // MARK: Leasing

    /// `local`: whether the client is on this Mac (a container is lent to
    /// no other: it shares this Mac's folders).
    func lease(_ request: LeaseRequest, local: Bool) async throws -> Lease {
        guard self.config.lends(request.platform) else { throw APIError(error: "this server lends no \(request.platform.rawValue) machines") }
        if request.platform == .container {
            guard containers != nil else { throw APIError(error: "this server runs no containers (OS Server's app does)", code: "noContainers") }
            guard local else { throw APIError(error: "a container is lent only to a client on its server's Mac", code: "notLocal") }
            guard let spec = request.container, !spec.image.isEmpty else { throw APIError(error: "a container lease names its image") }
            for mount in spec.mounts where !mount.source.hasPrefix("/") || !FileManager.default.fileExists(atPath: mount.source) {
                throw APIError(error: "no folder \(mount.source) to share")
            }
            for volume in spec.volumes {
                guard !volume.name.isEmpty, volume.name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }),
                      !volume.name.hasPrefix(".") else { throw APIError(error: "a volume's name is letters, digits, - _ and .") }
                if let user = leases.values.first(where: { $0.state != .failed && $0.container?.volumes.contains { $0.name == volume.name } == true }) {
                    throw APIError(error: "volume \(volume.name) is in use by lease \(user.id)", code: "volumeInUse")
                }
            }
        } else if request.minutes == 0 {
            throw APIError(error: "only a container is held until it is released (minutes: 0)")
        }
        let config = request.config ?? self.config.defaultConfig(request.platform)
        guard let base = await findBase(request.platform, config) else {
            let offered = knownBases.filter { $0.platform == request.platform }.map(\.config)
            throw APIError(error: "no \(request.platform.rawValue) base \(config) (there are: \(offered.joined(separator: ", ")))")
        }
        let held = leases.values.filter { $0.platform == request.platform && $0.state != .failed }.count
        guard held < self.config.limit(request.platform) else {
            throw APIError(error: "busy: \(held) of \(self.config.limit(request.platform)) \(request.platform.rawValue) machines are leased", code: "busy")
        }
        let id = Random.hex(4)
        // A container may be held until it is released (an agent's, for days).
        let untilReleased = request.platform == .container && request.minutes == 0
        let minutes = min(max(request.minutes ?? self.config.defaultMinutes, 1), self.config.maxMinutes)
        var lease = Lease(id: id, platform: request.platform, config: config, name: "oss-lease-\(request.platform.rawValue)-\(id)",
                          holder: request.holder ?? "unknown", state: .creating, created: Date(),
                          expires: untilReleased ? .distantFuture : Date().addingTimeInterval(TimeInterval(minutes * 60)))
        if request.platform.isVM { lease.sshUser = self.config.guestUser }
        lease.container = request.container
        leases[id] = lease
        save()
        log("lease \(id): \(base.name) for \(lease.holder), \(untilReleased ? "until released" : "\(minutes) min")")
        Task { await self.create(id, from: base, holderKey: request.sshPublicKey) }
        return lease
    }

    private func create(_ id: String, from base: Base, holderKey: String?) async {
        guard let lease = leases[id] else { return }
        do {
            switch lease.platform {
            case .macos, .linux, .windows: try await createVM(id, lease: lease, base: base, holderKey: holderKey)
            case .ios: try await createSimulator(id, lease: lease, base: base)
            case .android: try await createEmulator(id, lease: lease, base: base)
            case .container: try await createContainer(id, lease: lease)
            }
        } catch {
            log("lease \(id): failed: \(error)")
            leases[id]?.error = "\(error)"
            await release(id, reason: "failed")
        }
    }

    private func createSimulator(_ id: String, lease: Lease, base: Base) async throws {
        let udid = try await Simulators.lease(base: base, name: lease.name)
        leases[id]?.udid = udid
        guard leases[id]?.state == .creating else { await Simulators.release(udid: udid); return }
        await Simulators.holdStatusBarStill(udid: udid)
        leases[id]?.state = .ready
        save()
        log("lease \(id): simulator \(udid) booted")
    }

    private func createContainer(_ id: String, lease: Lease) async throws {
        guard let containers, let spec = lease.container else { throw APIError(error: "no container backend") }
        let socket = try await containers.start(name: lease.name, spec: spec)
        guard leases[id]?.state == .creating else { await containers.stop(name: lease.name, spec: spec); return }
        leases[id]?.cpus = spec.cpus ?? ContainerDefaults.cpus
        leases[id]?.memoryLimitBytes = spec.memoryBytes ?? ContainerDefaults.memoryBytes
        leases[id]?.execSocket = socket
        leases[id]?.state = .ready
        save()
        log("lease \(id): container \(lease.name) running \(spec.image)")
    }

    /// Containers whose helper has stopped (it crashed, or its command
    /// ended) are started again from their disks.
    func reviveContainers() async {
        guard let containers else { return }
        for lease in leases.values where lease.platform == .container && lease.state == .ready {
            guard let spec = lease.container, !(await containers.isRunning(name: lease.name)) else { continue }
            log("lease \(lease.id): \(lease.name) stopped; starting it again")
            if let socket = await containers.reattach(name: lease.name, spec: spec) {
                leases[lease.id]?.execSocket = socket
            } else {
                leases[lease.id]?.error = "its container stopped and couldn't be started again"
                await release(lease.id, reason: "its container is gone")
            }
        }
    }

    func volumes() async -> [VolumeInfo] {
        guard let containers else { return [] }
        return await containers.volumes().map { volume in
            var volume = volume
            volume.lease = leases.values.first { $0.state != .failed && $0.container?.volumes.contains { $0.name == volume.name } == true }?.id
            return volume
        }
    }

    func deleteVolume(_ name: String) async throws {
        guard let containers else { throw APIError(error: "this server runs no containers") }
        if let user = leases.values.first(where: { $0.state != .failed && $0.container?.volumes.contains { $0.name == name } == true }) {
            throw APIError(error: "volume \(name) is in use by lease \(user.id)", code: "volumeInUse")
        }
        try await containers.deleteVolume(name: name)
    }

    private func createEmulator(_ id: String, lease: Lease, base: Base) async throws {
        let used = Set(leases.values.compactMap(\.consolePort))
        guard let port = stride(from: config.firstEmulatorPort, through: config.lastEmulatorPort, by: 2).first(where: { !used.contains($0) }) else {
            throw APIError(error: "no free emulator port")
        }
        leases[id]?.consolePort = port
        let pid = try await Emulators.lease(base: base, name: lease.name, port: port)
        leases[id]?.emulatorPID = pid
        let allotted = Emulators.allotment(config, avd: lease.name)
        leases[id]?.cpus = allotted.cpus
        leases[id]?.memoryLimitBytes = allotted.memoryBytes
        guard leases[id]?.state == .creating else { return }
        await Emulators.holdStatusBarStill(port: port)
        // adb from anywhere: `adb connect <server>:<adbPort>` reaches the emulator's own adb port.
        let adb = try forward(id, to: "127.0.0.1", port: port + 1)
        leases[id]?.adbPort = adb
        leases[id]?.state = .ready
        save()
        log("lease \(id): emulator-\(port) booted, adb :\(adb)")
    }

    private func createVM(_ id: String, lease: Lease, base: Base, holderKey: String?) async throws {
        #if canImport(Virtualization)
        if lease.platform == .macos, MacVMStore.hasBase(base.config) {
            return try await createMacVM(id, lease: lease, base: base, holderKey: holderKey)
        }
        #endif
        // Windows and Linux show their screens through QEMU's VNC, on a loopback port of their own.
        let qemuVNC = lease.platform == .macos ? nil : freeQEMUVNCPort()
        leases[id]?.qemuVNCPort = qemuVNC
        // A clone that doesn't come up (a guest hung at boot, seldom) is
        // thrown away and made again, once.
        var address: String?
        // Windows' first boot of a clone can take minutes; the others come up in seconds.
        let bootAllowance: TimeInterval = lease.platform == .windows ? 360 : 150
        for attempt in 1...2 where address == nil {
            let mac = Random.mac()
            leases[id]?.mac = mac
            try await utm.run {
                try await UTM.clone(base.name, as: lease.name)
                try await UTM.setMAC(lease.name, mac)
                if let qemuVNC { try await UTM.setQEMUVNC(lease.name, port: qemuVNC) }
                if self.config.headlessVMs { try await UTM.makeHeadless(lease.name, qemuVNCPort: qemuVNC) }
                try await UTM.start(lease.name)
            }
            let deadline = Date().addingTimeInterval(bootAllowance)
            while address == nil && Date() < deadline {
                address = UTM.addressFromDHCP(mac)
                if address == nil { address = try? await UTM.ipAddress(lease.name) }
                if address == nil { try await Task.sleep(for: .seconds(3)) }
            }
            if address == nil {
                let state = (try? await UTM.vm(named: lease.name))?.status ?? "gone"
                log("lease \(id): \(lease.name) (\(state)) reported no address after \(Int(bootAllowance)) s (try \(attempt) of 2)")
                try await utm.run {
                    if try await UTM.vm(named: lease.name) != nil {
                        try await UTM.stop(lease.name)
                        try await UTM.delete(lease.name)
                    }
                }
                guard leases[id]?.state == .creating else { return }
            }
        }
        guard let address else { throw APIError(error: "\(lease.name) reported no address, twice") }
        if let qemuVNC {
            // VNC's pointer absolute: the tablet alone (QMPConnection.removeRelativeMice).
            do {
                let removed = try await Task.detached { try QMPConnection(port: UTM.qmpPort(vncPort: qemuVNC)).removeRelativeMice() }.value
                if removed == 0 { log("lease \(id): no USB mouse to take out; VNC's pointer may be relative") }
            } catch {
                log("lease \(id): taking out the USB mouse failed (\(error)); VNC's pointer may be relative")
            }
        }
        if let allotted = try? await UTM.allotment(lease.name) {
            leases[id]?.cpus = allotted.cpus
            leases[id]?.memoryLimitBytes = allotted.memoryBytes
        }
        try await handOver(id, lease: lease, address: address, qemuVNC: qemuVNC, holderKey: holderKey)
    }

    #if canImport(Virtualization)
    /// A macOS lease on OS Server's own VM: its base cloned and started in
    /// this process, with a network card of its own. A clone that gets no
    /// address is made again, once.
    private func createMacVM(_ id: String, lease: Lease, base: Base, holderKey: String?) async throws {
        let path = MacVMStore.leasePath(lease.name)
        var address: String?
        for attempt in 1...2 where address == nil {
            let vm = try await MacVMs.startClone(of: base.config, as: lease.name, at: path)
            leases[id]?.mac = vm.spec.mac
            leases[id]?.cpus = vm.spec.cpus
            leases[id]?.memoryLimitBytes = Int64(vm.spec.memoryBytes)
            address = try? await MacVMs.address(of: vm.spec.mac, seconds: 150)
            if address == nil {
                log("lease \(id): \(lease.name) got no address after 150 s (try \(attempt) of 2)")
                await vm.stop()
                MacVMStore.remove(path)
                guard leases[id]?.state == .creating else { return }
            }
        }
        guard let address else { throw APIError(error: "\(lease.name) got no address, twice") }
        try await handOver(id, lease: lease, address: address, qemuVNC: nil, holderKey: holderKey)
    }
    #endif

    /// A VM with an address made the holder's: their key let in, its
    /// screen's password set, the cache wired, SSH and VNC forwarded.
    private func handOver(_ id: String, lease: Lease, address: String, qemuVNC: Int?, holderKey: String?) async throws {
        let guest = Guest(platform: lease.platform, address: address, user: config.guestUser, key: config.managementKey)
        guard await guest.waitUntilReachable(seconds: 300) else { throw APIError(error: "\(lease.name) at \(address): no SSH") }
        let password = Random.vncPassword()
        try await guest.prepare(holderKey: holderKey, vncPassword: password)
        await guest.setTimeZone(TimeZone.current.identifier)
        leases[id]?.guestPassword = GuestPasswords.password(for: lease.platform, config: lease.config)
        if let bazelCache, let host = LocalNetworks.hostAddress(facing: address) {
            await guest.useBazelCache(host: host, port: bazelCache.port, token: bazelCache.readToken)
        }
        if !(await guest.waitForDesktop(seconds: 240)) { log("lease \(id): no desktop after 240 s; handing it over anyway") }
        guard leases[id]?.state == .creating else { return }   // released meanwhile
        let ssh = try forward(id, to: address, port: 22)
        let vnc = try qemuVNC.map { try forward(id, to: "127.0.0.1", port: $0, vncPassword: password) }
            ?? forward(id, to: address, port: 5900)
        leases[id]?.guestAddress = address
        leases[id]?.sshPort = ssh
        leases[id]?.vncPort = vnc
        leases[id]?.vncPassword = password
        leases[id]?.state = .ready
        save()
        log("lease \(id): ready at \(address), ssh :\(ssh), vnc :\(vnc)")
    }

    private func freeQEMUVNCPort() -> Int? {
        let used = Set(leases.values.compactMap(\.qemuVNCPort))
        return (config.firstQEMUVNCPort...config.lastQEMUVNCPort).first { !used.contains($0) }
    }

    private func forward(_ id: String, to address: String, port: Int, vncPassword: String? = nil) throws -> Int {
        let used = Set(forwarders.values.flatMap { $0.map(\.port) })
        for candidate in config.firstPort...config.lastPort where !used.contains(candidate) {
            guard let forwarder = try? Forwarder(port: candidate, target: address, targetPort: port, vncPassword: vncPassword) else { continue }
            forwarder.start()
            forwarders[id, default: []].append(forwarder)
            return candidate
        }
        throw APIError(error: "no free port for forwarding")
    }

    func renew(_ id: String, minutes: Int?) throws -> Lease {
        guard var lease = leases[id], lease.state != .returning, lease.state != .failed else { throw APIError(error: "no lease \(id)") }
        // A container held until it is released stays so; one asked for 0 is from now on.
        if lease.platform == .container && (minutes == 0 || (minutes == nil && lease.expires == .distantFuture)) {
            lease.expires = .distantFuture
        } else {
            let minutes = min(max(minutes ?? config.defaultMinutes, 1), config.maxMinutes)
            lease.expires = Date().addingTimeInterval(TimeInterval(minutes * 60))
        }
        leases[id] = lease
        save()
        return lease
    }

    /// The lease ends: its forwards close, its clone is stopped and deleted,
    /// and the platform's place is free again.
    func release(_ id: String, reason: String) async {
        guard let lease = leases[id], lease.state != .returning, lease.state != .failed else { return }
        leases[id]?.state = .returning
        save()   // a restart from here on deletes the clone instead of bringing the lease back
        forwarders.removeValue(forKey: id)?.forEach { $0.stop() }
        log("lease \(id): \(reason); deleting \(lease.name)")
        switch lease.platform {
        case .macos, .linux, .windows:
            #if canImport(Virtualization)
            if lease.platform == .macos, FileManager.default.fileExists(atPath: MacVMStore.leasePath(lease.name)) {
                await MainActor.run { MacVMs.running[lease.name] }?.stop()
                MacVMStore.remove(MacVMStore.leasePath(lease.name))
                break
            }
            #endif
            do {
                try await utm.run {
                    if try await UTM.vm(named: lease.name) != nil {
                        try await UTM.stop(lease.name)
                        try await UTM.delete(lease.name)
                    }
                }
            } catch {
                log("lease \(id): deleting \(lease.name) failed: \(error)")
            }
        case .ios:
            if let udid = lease.udid { await Simulators.release(udid: udid) }
        case .android:
            await Emulators.release(name: lease.name, port: lease.consolePort, pid: lease.emulatorPID)
            // The last emulator gone: oss's adb server too (the next lease starts it again).
            if !leases.values.contains(where: { $0.platform == .android && $0.id != id }) { await Emulators.stopADB() }
        case .container:
            await containers?.stop(name: lease.name, spec: lease.container)
        }
        try? FileManager.default.removeItem(atPath: "\(Paths.uploads)/\(id)")
        if leases[id]?.error != nil {
            // A failed lease stays a while so its holder can read why, holding no place.
            leases[id]?.state = .failed
            save()
            try? await Task.sleep(for: .seconds(600))
        }
        leases[id] = nil
        save()
    }

    /// Every lease ended now (OS Server removing itself).
    func releaseAll() async {
        for lease in leases.values where lease.state != .returning {
            leases[lease.id]?.error = nil
            await release(lease.id, reason: "OS Server removed")
        }
    }

    /// Leases whose time ran out are released.
    func expire() async {
        let now = Date()
        for lease in leases.values where lease.expires < now && lease.state != .returning && lease.state != .failed {
            await release(lease.id, reason: "expired")
        }
    }

    // MARK: A lease's device

    func ready(_ id: String) throws -> Lease {
        guard let lease = leases[id], lease.state == .ready else { throw APIError(error: "no ready lease \(id)") }
        return lease
    }

    /// A tap, swipe, text or key on a lease's screen.
    func input(_ id: String, _ request: InputRequest) async throws {
        let lease = try ready(id)
        try MachineInput.check(request)
        switch lease.platform {
        case .android: try await MachineInput.android(request, port: lease.consolePort ?? 0)
        case .ios: try await MachineInput.simulator(request, udid: lease.udid ?? "")
        case .macos, .linux, .windows:
            #if canImport(CommonCrypto)
            // The guest's VNC directly, as screenshots: macOS's Screen Sharing, or QEMU's on loopback.
            // Off the actor: its reads block, and nothing else may wait for them.
            let (host, port, password) = lease.qemuVNCPort.map { ("127.0.0.1", $0, "") }
                ?? (lease.guestAddress ?? "", 5900, lease.vncPassword ?? "")
            try await Task.detached { try MachineInput.vnc(request, host: host, port: port, password: password) }.value
            #else
            throw APIError(error: "VM input needs a Mac server")
            #endif
        case .container: throw APIError(error: "a container has no screen: run commands in it with exec")
        }
    }

    private var lastUsage: Usage?
    private lazy var history: [UsageSample] = FileManager.default.contents(atPath: Paths.usageHistory)
        .flatMap { try? JSONDecoder.oss.decode([UsageSample].self, from: $0) } ?? []

    /// A sample of the Mac for the day's history (every minute), kept
    /// across restarts.
    func recordHistory() async {
        let sample = UsageSample(await usage())
        history.append(sample)
        history.removeAll { sample.date.timeIntervalSince($0.date) > 86400 }
        if let data = try? JSONEncoder.oss.encode(history) {
            Paths.ensure(Paths.state)
            FileManager.default.createFile(atPath: Paths.usageHistory, contents: data)
        }
    }

    func usageHistory() -> [UsageSample] { history }

    /// What the server's Mac and the leases use: sampled at most every
    /// three seconds (`ps` and `lsof` cost a moment).
    func usage() async -> Usage {
        if let lastUsage, Date().timeIntervalSince(lastUsage.sampledAt) < 3 { return lastUsage }
        let ready = leases.values.filter { $0.state == .ready }.sorted { $0.created < $1.created }
        let sampled = await UsageProbe.usage(of: ready, folders: Dictionary(uniqueKeysWithValues: ready.map { ($0.id, folder(of: $0)) }))
        lastUsage = sampled
        return sampled
    }

    /// Where a lease's disk goes: its clone, its simulator's or emulator's
    /// data, its container's root filesystem.
    private func folder(of lease: Lease) -> String? {
        switch lease.platform {
        case .macos, .linux, .windows:
            #if canImport(Virtualization)
            if lease.platform == .macos, FileManager.default.fileExists(atPath: MacVMStore.leasePath(lease.name)) {
                return MacVMStore.leasePath(lease.name)
            }
            #endif
            return "\(NSHomeDirectory())/Library/Containers/com.utmapp.UTM/Data/Documents/\(lease.name).utm"
        case .ios: return lease.udid.map { "\(NSHomeDirectory())/Library/Developer/CoreSimulator/Devices/\($0)" }
        case .android: return "\(config.androidAVDHome)/\(lease.name).avd"
        case .container: return containers?.directory(name: lease.name)
        }
    }

    /// `simctl` for a simulator, `adb` for an emulator, with `@name`
    /// arguments the lease's uploaded files.
    func command(_ id: String, _ arguments: [String]) async throws -> DeviceCommandResult {
        let lease = try ready(id)
        let resolved = arguments.map { argument -> String in
            guard argument.hasPrefix("@") else { return argument }
            return "\(Paths.uploads)/\(id)/\(argument.dropFirst())"
        }
        let result: ProcessResult
        switch lease.platform {
        case .ios: result = try await Simulators.run(resolved, udid: lease.udid ?? "")
        case .android: result = try await Emulators.run(resolved, port: lease.consolePort ?? 0)
        default: throw APIError(error: "\(lease.platform.rawValue) leases take \(lease.platform == .container ? "exec" : "SSH"), not device commands")
        }
        return DeviceCommandResult(status: result.status, output: result.output, error: result.error)
    }

    /// A file for the lease's commands (`@name`); a .zip is unpacked beside it
    /// (an app bundle, which is a directory, travels zipped).
    func upload(_ id: String, name: String, data: Data) async throws -> [String: String] {
        _ = try ready(id)
        guard !name.contains("/"), !name.hasPrefix(".") else { throw APIError(error: "bad file name \(name)") }
        let directory = "\(Paths.uploads)/\(id)"
        Paths.ensure(directory)
        let path = "\(directory)/\(name)"
        FileManager.default.createFile(atPath: path, contents: data)
        if name.hasSuffix(".zip") {
            let unzip = try await Shell.run("/usr/bin/ditto", ["-x", "-k", path, directory], timeout: 600)
            guard unzip.ok else { throw APIError(error: "unzipping \(name): \(unzip.error)") }
        }
        return ["stored": name]
    }

    func screenshot(_ id: String) async throws -> Data {
        let lease = try ready(id)
        switch lease.platform {
        case .ios: return try await Simulators.screenshot(udid: lease.udid ?? "")
        case .android: return try await Emulators.screenshot(port: lease.consolePort ?? 0)
        case .macos, .linux, .windows:
            let path = NSTemporaryDirectory() + "oss-vnc-\(Random.hex(4)).png"
            defer { try? FileManager.default.removeItem(atPath: path) }
            // The guest's VNC directly (no relay): macOS's Screen Sharing, or QEMU's on loopback.
            // Off the actor, as input is.
            let (host, port, password) = lease.qemuVNCPort.map { ("127.0.0.1", $0, "") }
                ?? (lease.guestAddress ?? "", 5900, lease.vncPassword ?? "")
            try await Task.detached { try RFBScreenshot(host: host, port: port, password: password).capture(to: path) }.value
            guard let data = FileManager.default.contents(atPath: path) else { throw APIError(error: "no screenshot") }
            return data
        case .container: throw APIError(error: "a container has no screen")
        }
    }

    // MARK: Persistence

    private func save() {
        Paths.ensure(Paths.state)
        if let data = try? JSONEncoder.oss.encode(Array(leases.values)) {
            FileManager.default.createFile(atPath: Paths.leases, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// After a restart: leases still running get their forwards back; clones
    /// nobody holds any more are deleted.
    func recover() async {
        let saved = (FileManager.default.contents(atPath: Paths.leases))
            .flatMap { try? JSONDecoder.oss.decode([Lease].self, from: $0) } ?? []
        // What this server doesn't lend, it leaves alone (a second server's
        // machines, named like its own).
        let simulators = config.lends(.ios) ? ((try? await Simulators.devices()) ?? []) : []
        // Simulators and emulators first (quick); VMs last, as UTM can be slow to answer.
        let ordered = saved.filter { !$0.platform.isVM } + saved.filter { $0.platform.isVM }
        let vms = config.useUTM && config.lends.map({ $0.contains(where: \.isVM) }) ?? true ? ((try? await UTM.list()) ?? []) : []
        for var lease in ordered where lease.state == .ready && lease.expires > Date() {
            #if canImport(Virtualization)
            // OS Server's own macOS VMs ran in the process that ended: theirs went with it.
            if lease.platform == .macos, FileManager.default.fileExists(atPath: MacVMStore.leasePath(lease.name)) { continue }
            #endif
            switch lease.platform {
            case .macos, .linux, .windows:
                guard vms.contains(where: { $0.name == lease.name && $0.status == "started" }) else { continue }
                var found = lease.mac.flatMap(UTM.addressFromDHCP)
                if found == nil { found = try? await UTM.ipAddress(lease.name) }
                guard let address = found else { continue }
                forwarders[lease.id] = []
                let vncTarget = lease.qemuVNCPort.map { ("127.0.0.1", $0, lease.vncPassword) } ?? (address, 5900, nil)
                for (port, host, target, password) in [(lease.sshPort, address, 22, nil as String?), (lease.vncPort, vncTarget.0, vncTarget.1, vncTarget.2)] {
                    guard let port, let forwarder = try? Forwarder(port: port, target: host, targetPort: target, vncPassword: password) else { continue }
                    forwarder.start()
                    forwarders[lease.id]?.append(forwarder)
                }
                lease.guestAddress = address
            case .ios:
                guard simulators.contains(where: { $0.udid == lease.udid && $0.state == "Booted" }) else { continue }
            case .android:
                guard let pid = lease.emulatorPID, kill(pid, 0) == 0, let console = lease.consolePort, let adb = lease.adbPort,
                      let forwarder = try? Forwarder(port: adb, target: "127.0.0.1", targetPort: console + 1) else { continue }
                forwarder.start()
                forwarders[lease.id] = [forwarder]
            case .container:
                // Each in a process of its own: still running, or started again from its disk.
                guard let containers, config.lends(.container), let spec = lease.container,
                      let socket = await containers.reattach(name: lease.name, spec: spec) else { continue }
                lease.execSocket = socket
            }
            leases[lease.id] = lease
            log("lease \(lease.id): recovered")
        }
        // Clones nobody holds: deleted.
        for vm in vms where vm.name.hasPrefix("oss-lease-") && !leases.values.contains(where: { $0.name == vm.name }) {
            log("deleting \(vm.name): no lease holds it")
            try? await utm.run {
                if vm.status != "stopped" { try await UTM.stop(vm.name) }
                try await UTM.delete(vm.name)
            }
        }
        #if canImport(Virtualization)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: MacVMStore.leases)) ?? []
        where name.hasSuffix(".vm") && !leases.values.contains(where: { "\($0.name).vm" == name }) {
            log("deleting \(name): no lease holds it")
            MacVMStore.remove("\(MacVMStore.leases)/\(name)")
        }
        #endif
        for device in simulators where device.name.hasPrefix("oss-lease-") && !leases.values.contains(where: { $0.udid == device.udid }) {
            log("deleting simulator \(device.name): no lease holds it")
            await Simulators.release(udid: device.udid)
        }
        for lease in saved where lease.platform == .android && leases[lease.id] == nil && config.lends(.android) {
            await Emulators.release(name: lease.name, port: lease.consolePort, pid: lease.emulatorPID)
        }
        if let containers, config.lends(.container) {
            await containers.prune(keeping: Set(leases.values.filter { $0.platform == .container }.map(\.name)))
        }
        save()
    }
}

/// The server running in this process (OS Server's, or `oss serve`'s):
/// the API on the configured port, every interface; the machines it lends;
/// its Bazel cache.
public final class ServerHost: Sendable {
    public let port: Int
    let machines: MachineManager
    private let http: HTTPServer
    private let cache: CacheServer?

    /// Starts it: listening once this returns; recovery (leases a restart
    /// left), base listings and expiry go on in the background. With
    /// `containers` it lends containers too.
    public static func start(containers: ContainerBackend? = nil) throws -> ServerHost {
        Paths.migrate()
        let config = ServerConfig.load()
        let token = Token.ensure()
        let cache = config.cache.flatMap(Server.startCache)
        let machines = MachineManager(config: config, bazelCache: cache.map { ($0.config.port, $0.readToken) }, containers: containers)
        let http = try HTTPServer(port: config.port) { request in
            await Server.route(request, machines: machines, token: token, cache: cache)
        }
        http.start()
        // Recovery and listings ask UTM, which can be slow to answer (or
        // waiting on a permission prompt): the API serves meanwhile.
        Task {
            await machines.recover()
            #if canImport(Virtualization)
            // UTM's macOS bases become OS Server's own (0.7's first start takes them all).
            if config.useUTM && config.lends(.macos) { await MacImport.fromUTMWhereMissing() }
            #endif
            while true {
                try? await machines.refreshBases()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(15))
                await machines.expire()
                await machines.reviveContainers()
            }
        }
        Task {
            while true {
                await machines.recordHistory()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        log("oss serving on :\(config.port); capacity \(config.capacity)")
        return ServerHost(port: config.port, machines: machines, http: http, cache: cache)
    }

    /// Every lease ended and everything the server keeps on this Mac
    /// deleted: its folder (settings, token, state, the macOS bases), and
    /// what an oss before 0.7 kept in ~/.config, ~/.local/state and
    /// ~/.local/share; UTM's `oss-` VMs too when asked.
    public func removeEverything(includingUTMMachines: Bool) async {
        await machines.releaseAll()
        if includingUTMMachines, let vms = try? await UTM.list() {
            for vm in vms where vm.name.hasPrefix("oss-") {
                log("deleting UTM's \(vm.name)")
                if vm.status != "stopped" { try? await UTM.stop(vm.name) }
                try? await UTM.delete(vm.name)
            }
        }
        for path in [Paths.support, Paths.config, Paths.state, Paths.share, Paths.clientDirectory, Paths.clientState,
                     "\(Paths.home)/.local/share/oss"] {
            try? FileManager.default.removeItem(atPath: path)
        }
        log("removed everything OS Server kept")
    }

    /// Where containers keep their kernel, images and root filesystems.
    public static var containersDirectory: String { Paths.containers }

    private init(port: Int, machines: MachineManager, http: HTTPServer, cache: CacheServer?) {
        self.port = port
        self.machines = machines
        self.http = http
        self.cache = cache
    }
}

/// `oss serve`: the API on the configured port, every interface.
enum Server {
    static func serve() async throws -> Never {
        _ = try ServerHost.start()
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    /// The Bazel cache, with its tokens (made the first time); nil when its
    /// port can't be had (the machines go on without it).
    static func startCache(_ config: CacheConfig) -> CacheServer? {
        do {
            let cache = try CacheServer(config: config, store: CacheStore(config: config),
                                        readToken: CacheTokens.ensure(CacheTokens.readPath),
                                        writeToken: CacheTokens.ensure(CacheTokens.writePath))
            cache.start()
            log("oss Bazel cache on :\(config.port), at most \(config.maxGigabytes) GB, \(config.minFreeGigabytes) GB kept free on the disk")
            return cache
        } catch {
            log("oss Bazel cache off: \(error)")
            return nil
        }
    }

    /// `oss cache serve`: the cache alone (to try one beside a running
    /// server, with an `OSS_HOME` of its own).
    static func serveCache() async throws -> Never {
        guard startCache(ServerConfig.load().cache ?? CacheConfig()) != nil else { exit(1) }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    static func route(_ request: HTTPRequest, machines: MachineManager, token: String, cache: CacheServer?) async -> HTTPResponse {
        let parts = request.path.split(separator: "?")[0].split(separator: "/").map(String.init)
        // A client below API 6 (an OSSClient before 0.9 sends no OSS-API)
        // can't read a container's platform: it is shown none.
        let seesContainers = (Int(request.header("oss-api") ?? "") ?? 0) >= 6
        func visible(_ platform: Platform) -> Bool { seesContainers || platform != .container }
        if parts == ["v1", "capabilities"] {
            let platforms = ((try? await machines.bases()) ?? []).map(\.platform)
            return .json(Capabilities(version: OSS.version, api: OSS.apiLevel, features: OSS.features + (cache == nil ? [] : ["cache"]),
                                      platforms: Platform.allCases.filter { platforms.contains($0) && visible($0) }))
        }
        if parts == ["v1", "hello"] {
            return .json(["server": "oss", "host": localHostName])
        }
        let given = request.header("authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        // The monitor token (OS Monitor's) reads and does nothing else.
        let monitor = !constantTimeEqual(given, token)
        if monitor {
            guard constantTimeEqual(given, MonitorAccess.token()) else { return .error("unauthorized", status: 401) }
            guard MonitorAccess.allows(request.method, parts) else { return .error("OS Monitor's token only reads", status: 403) }
        }
        do {
            let method = request.method
            switch (method, parts.count) {
            case ("GET", 2) where parts[1] == "status":
                return .json(Status(server: localHostName, bases: try await machines.bases().filter { visible($0.platform) },
                                    capacity: await machines.capacity().filter { visible($0.platform) },
                                    leases: await machines.all().filter { visible($0.platform) }))
            case ("GET", 2) where parts[1] == "usage":
                var usage = await machines.usage()
                usage.machines = usage.machines.filter { visible($0.platform) }
                return .json(usage)
            case ("GET", 3) where parts[1] == "usage" && parts[2] == "history":
                return .json(await machines.usageHistory())
            case ("POST", 4) where parts[1] == "machines" && parts[3] == "input":
                try await machines.input(parts[2], try JSONDecoder.oss.decode(InputRequest.self, from: request.body))
                return .json(["done": "input"])
            case ("GET", 2) where parts[1] == "cache":
                guard let cache else { return .error("this server keeps no Bazel cache", status: 404) }
                return .json(await cache.store.info(port: cache.config.port, readToken: monitor ? "" : cache.readToken))
            case ("GET", 2) where parts[1] == "doctor":
                // Whether this server can drive UTM (its CLI and AppleScript), simulators and emulators.
                let list = try? await Shell.run(UTM.utmctl, ["list"], timeout: 120)
                var appleScript = "ok"
                do { _ = try await UTM.script("tell application \"UTM\" to get name of every virtual machine") } catch { appleScript = "\(error)" }
                let simctl = (try? await Shell.run("/usr/bin/xcrun", ["simctl", "help"], timeout: 60))?.ok == true
                let emulator = FileManager.default.isExecutableFile(atPath: Emulators.emulator(machines.config))
                return .json(["utmctl": list?.ok == true ? "ok" : "failed: \(list?.error ?? "")", "appleScript": appleScript,
                              "simctl": simctl ? "ok" : "no Xcode (iOS simulators off)",
                              "emulator": emulator ? "ok" : "no Android SDK: oss setup android"])
            case ("POST", 2) where parts[1] == "machines":
                return .json(try await machines.lease(try JSONDecoder.oss.decode(LeaseRequest.self, from: request.body),
                                                      local: LocalNetworks.isThisMac(request.remoteAddress)), status: 201)
            case ("GET", 2) where parts[1] == "machines":
                return .json(await machines.all().filter { visible($0.platform) })
            case ("GET", 3) where parts[1] == "machines":
                guard let lease = await machines.lease(parts[2]), visible(lease.platform) else { return .error("no lease \(parts[2])", status: 404) }
                return .json(lease)
            case ("GET", 2) where parts[1] == "volumes":
                return .json(await machines.volumes())
            case ("DELETE", 3) where parts[1] == "volumes":
                guard LocalNetworks.isThisMac(request.remoteAddress) else {
                    return .json(APIError(error: "a volume is deleted only from its server's Mac", code: "notLocal"), status: 403)
                }
                try await machines.deleteVolume(parts[2].removingPercentEncoding ?? parts[2])
                return .json(["deleted": parts[2]])
            case ("DELETE", 3) where parts[1] == "machines":
                guard await machines.lease(parts[2]) != nil else { return .error("no lease \(parts[2])", status: 404) }
                let id = parts[2]
                Task { await machines.release(id, reason: "released") }
                return .json(["released": id])
            case ("POST", 4) where parts[1] == "machines" && parts[3] == "renew":
                let body = (try? JSONDecoder.oss.decode(RenewRequest.self, from: request.body)) ?? RenewRequest()
                return .json(try await machines.renew(parts[2], minutes: body.minutes))
            case ("POST", 4) where parts[1] == "machines" && (parts[3] == "simctl" || parts[3] == "adb"):
                let body = try JSONDecoder.oss.decode(DeviceCommand.self, from: request.body)
                return .json(try await machines.command(parts[2], body.arguments))
            case ("GET", 4) where parts[1] == "machines" && parts[3] == "screenshot":
                return HTTPResponse(status: 200, body: try await machines.screenshot(parts[2]), contentType: "image/png")
            case ("PUT", 5) where parts[1] == "machines" && parts[3] == "files":
                return .json(try await machines.upload(parts[2], name: parts[4], data: request.body))
            default:
                break
            }
            return .error("no such endpoint: \(method) \(request.path)", status: 404)
        } catch let error as APIError {
            let status = error.code == "busy" || error.error.hasPrefix("busy") ? 409 : error.code == "notLocal" ? 403 : 400
            return HTTPResponse(status: status, body: (try? JSONEncoder.oss.encode(error)) ?? Data())
        } catch {
            return .error("\(error)", status: 500)
        }
    }
}

#endif
