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
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
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

    init(config: ServerConfig, bazelCache: (port: Int, readToken: String)? = nil) {
        self.config = config
        self.bazelCache = bazelCache
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
        let all = knownVMBases + (await Simulators.bases()) + Emulators.bases(config)
        knownBases = all.filter { $0.config != "base" }.sorted { ($0.platform.rawValue, $0.config) < ($1.platform.rawValue, $1.config) }
    }

    private func findBase(_ platform: Platform, _ config: String) async -> Base? {
        switch platform {
        case .ios: return await Simulators.bases().first { $0.config == config }
        case .android: return Emulators.bases(self.config).first { $0.config == config }
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

    func lease(_ request: LeaseRequest) async throws -> Lease {
        let config = request.config ?? self.config.defaultConfig(request.platform)
        guard let base = await findBase(request.platform, config) else {
            let offered = knownBases.filter { $0.platform == request.platform }.map(\.config)
            throw APIError(error: "no \(request.platform.rawValue) base \(config) (there are: \(offered.joined(separator: ", ")))")
        }
        let held = leases.values.filter { $0.platform == request.platform && $0.state != .failed }.count
        guard held < self.config.limit(request.platform) else {
            throw APIError(error: "busy: \(held) of \(self.config.limit(request.platform)) \(request.platform.rawValue) machines are leased")
        }
        let id = Random.hex(4)
        let minutes = min(max(request.minutes ?? self.config.defaultMinutes, 1), self.config.maxMinutes)
        var lease = Lease(id: id, platform: request.platform, config: config, name: "oss-lease-\(request.platform.rawValue)-\(id)",
                          holder: request.holder ?? "unknown", state: .creating, created: Date(),
                          expires: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        if request.platform.isVM { lease.sshUser = self.config.guestUser }
        leases[id] = lease
        save()
        log("lease \(id): \(base.name) for \(lease.holder), \(minutes) min")
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
        leases[id]?.state = .ready
        save()
        log("lease \(id): simulator \(udid) booted")
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
        // adb from anywhere: `adb connect <server>:<adbPort>` reaches the emulator's own adb port.
        let adb = try forward(id, to: "127.0.0.1", port: port + 1)
        leases[id]?.adbPort = adb
        leases[id]?.state = .ready
        save()
        log("lease \(id): emulator-\(port) booted, adb :\(adb)")
    }

    private func createVM(_ id: String, lease: Lease, base: Base, holderKey: String?) async throws {
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
        let guest = Guest(platform: lease.platform, address: address, user: config.guestUser, key: config.managementKey)
        guard await guest.waitUntilReachable(seconds: 300) else { throw APIError(error: "\(lease.name) at \(address): no SSH") }
        let password = Random.vncPassword()
        try await guest.prepare(holderKey: holderKey, vncPassword: password)
        await guest.setTimeZone(TimeZone.current.identifier)
        if let allotted = try? await UTM.allotment(lease.name) {
            leases[id]?.cpus = allotted.cpus
            leases[id]?.memoryLimitBytes = allotted.memoryBytes
        }
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
        let minutes = min(max(minutes ?? config.defaultMinutes, 1), config.maxMinutes)
        lease.expires = Date().addingTimeInterval(TimeInterval(minutes * 60))
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
        }
    }

    private var lastUsage: Usage?

    /// What the server's Mac and the leases use: sampled at most every
    /// three seconds (`ps` and `lsof` cost a moment).
    func usage() async -> Usage {
        if let lastUsage, Date().timeIntervalSince(lastUsage.sampledAt) < 3 { return lastUsage }
        let sampled = await UsageProbe.usage(of: leases.values.filter { $0.state == .ready }.sorted { $0.created < $1.created })
        lastUsage = sampled
        return sampled
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
        default: throw APIError(error: "\(lease.platform.rawValue) leases take SSH, not device commands")
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
        let simulators = (try? await Simulators.devices()) ?? []
        // Simulators and emulators first (quick); VMs last, as UTM can be slow to answer.
        let ordered = saved.filter { !$0.platform.isVM } + saved.filter { $0.platform.isVM }
        let vms = saved.contains(where: { $0.platform.isVM }) ? ((try? await UTM.list()) ?? []) : []
        for var lease in ordered where lease.state == .ready && lease.expires > Date() {
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
        for device in simulators where device.name.hasPrefix("oss-lease-") && !leases.values.contains(where: { $0.udid == device.udid }) {
            log("deleting simulator \(device.name): no lease holds it")
            await Simulators.release(udid: device.udid)
        }
        for lease in saved where lease.platform == .android && leases[lease.id] == nil {
            await Emulators.release(name: lease.name, port: lease.consolePort, pid: lease.emulatorPID)
        }
        save()
    }
}

/// `oss serve`: the API on the configured port, every interface.
enum Server {
    static func serve() async throws -> Never {
        let config = ServerConfig.load()
        let token = Token.ensure()
        let cache = config.cache.flatMap(startCache)
        let machines = MachineManager(config: config, bazelCache: cache.map { ($0.config.port, $0.readToken) })
        let server = try HTTPServer(port: config.port) { request in
            await route(request, machines: machines, token: token, cache: cache)
        }
        server.start()
        // Recovery and listings ask UTM, which can be slow to answer (or
        // waiting on a permission prompt): the API serves meanwhile.
        Task {
            await machines.recover()
            while true {
                try? await machines.refreshBases()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        log("oss serving on :\(config.port); capacity \(config.capacity)")
        while true {
            try await Task.sleep(for: .seconds(15))
            await machines.expire()
        }
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
        if parts == ["v1", "capabilities"] {
            let platforms = ((try? await machines.bases()) ?? []).map(\.platform)
            return .json(Capabilities(version: OSS.version, api: OSS.apiLevel, features: OSS.features + (cache == nil ? [] : ["cache"]),
                                      platforms: Platform.allCases.filter { platforms.contains($0) }))
        }
        if parts == ["v1", "hello"] {
            return .json(["server": "oss", "host": localHostName])
        }
        let given = request.header("authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        guard constantTimeEqual(given, token) else { return .error("unauthorized", status: 401) }
        do {
            let method = request.method
            switch (method, parts.count) {
            case ("GET", 2) where parts[1] == "status":
                return .json(Status(server: localHostName, bases: try await machines.bases(),
                                    capacity: await machines.capacity(), leases: await machines.all()))
            case ("GET", 2) where parts[1] == "usage":
                return .json(await machines.usage())
            case ("POST", 4) where parts[1] == "machines" && parts[3] == "input":
                try await machines.input(parts[2], try JSONDecoder.oss.decode(InputRequest.self, from: request.body))
                return .json(["done": "input"])
            case ("GET", 2) where parts[1] == "cache":
                guard let cache else { return .error("this server keeps no Bazel cache", status: 404) }
                return .json(await cache.store.info(port: cache.config.port, readToken: cache.readToken))
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
                return .json(try await machines.lease(try JSONDecoder.oss.decode(LeaseRequest.self, from: request.body)), status: 201)
            case ("GET", 2) where parts[1] == "machines":
                return .json(await machines.all())
            case ("GET", 3) where parts[1] == "machines":
                guard let lease = await machines.lease(parts[2]) else { return .error("no lease \(parts[2])", status: 404) }
                return .json(lease)
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
            return .error(error.error, status: error.error.hasPrefix("busy") ? 409 : 400)
        } catch {
            return .error("\(error)", status: 500)
        }
    }
}

#endif
