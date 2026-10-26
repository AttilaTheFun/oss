import Foundation
import OSSClient

#if canImport(Virtualization)
import Virtualization

/// macOS VMs run by OS Server itself, through Apple's Virtualization
/// framework: no UTM. A machine is a folder (`<name>.vm`) of three files:
/// its disk (`Disk.img`, sparse), its auxiliary storage and `machine.json`
/// (the hardware model and machine identifier it was installed with, its
/// CPUs, memory, display and network address). Bases are
/// `Machines/macos/<config>.vm`; a lease's clone is
/// `Machines/leases/<lease name>.vm`, an APFS clone of its base (clonefile:
/// no space until it writes), deleted with the lease.
///
/// The VMs run in the process that made them (OS Server's, or the command
/// line's while it builds a base): quitting it stops them. Each runs
/// headless; the app shows any of them live (`MacVMs.running`).
enum MacVMStore {
    static var bases: String { "\(Paths.machines)/macos" }
    static var leases: String { "\(Paths.machines)/leases" }

    static func basePath(_ config: String) -> String { "\(bases)/\(config).vm" }
    static func leasePath(_ name: String) -> String { "\(leases)/\(name).vm" }

    /// The configs there are bases for.
    static func configs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bases)) ?? []
        return names.filter { $0.hasSuffix(".vm") && FileManager.default.fileExists(atPath: "\(bases)/\($0)/machine.json") }
            .map { String($0.dropLast(3)) }.sorted()
    }

    static func hasBase(_ config: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(basePath(config))/machine.json")
    }

    /// A copy of a machine that shares its blocks until either writes:
    /// clonefile(2) clones a directory whole.
    static func clone(_ source: String, to destination: String) throws {
        Paths.ensure((destination as NSString).deletingLastPathComponent)
        if FileManager.default.fileExists(atPath: destination) { try FileManager.default.removeItem(atPath: destination) }
        guard clonefile(source, destination, 0) == 0 else {
            throw ShellError(description: "cloning \(source): \(String(cString: strerror(errno)))")
        }
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// What `machine.json` holds.
struct MacMachineSpec: Codable, Sendable {
    var hardwareModel: Data
    var machineIdentifier: Data
    var cpus: Int
    var memoryBytes: UInt64
    var diskBytes: UInt64
    var displayWidth: Int = 1920
    var displayHeight: Int = 1200
    var displayPPI: Int = 80
    /// The network card's address: a clone gets its own, so the NAT's DHCP
    /// server gives it an address of its own.
    var mac: String
    /// What it was installed from, or the base it was built on.
    var origin: String?

    static func load(_ machine: String) throws -> MacMachineSpec {
        guard let data = FileManager.default.contents(atPath: "\(machine)/machine.json") else {
            throw ShellError(description: "no machine.json in \(machine)")
        }
        return try JSONDecoder().decode(MacMachineSpec.self, from: data)
    }

    func save(_ machine: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: "\(machine)/machine.json"))
    }
}

/// One macOS VM running in this process. Everything Virtualization's is
/// done on the main actor (its VMs' queue, and where the app's live view
/// shows them).
@MainActor
final class MacVM: NSObject, VZVirtualMachineDelegate {
    let name: String
    let path: String
    let spec: MacMachineSpec
    let machine: VZVirtualMachine
    private(set) var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(name: String, path: String) throws {
        self.name = name
        self.path = path
        spec = try MacMachineSpec.load(path)
        machine = VZVirtualMachine(configuration: try Self.configuration(path: path, spec: spec))
        super.init()
        machine.delegate = self
    }

    static func configuration(path: String, spec: MacMachineSpec) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        let platform = VZMacPlatformConfiguration()
        guard let model = VZMacHardwareModel(dataRepresentation: spec.hardwareModel), model.isSupported else {
            throw ShellError(description: "\(path): this Mac can't run its hardware model")
        }
        guard let identifier = VZMacMachineIdentifier(dataRepresentation: spec.machineIdentifier) else {
            throw ShellError(description: "\(path): its machine identifier can't be read")
        }
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: URL(fileURLWithPath: "\(path)/AuxiliaryStorage"))
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = spec.cpus
        configuration.memorySize = spec.memoryBytes
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: spec.displayWidth, heightInPixels: spec.displayHeight,
                                                              pixelsPerInch: spec.displayPPI)]
        configuration.graphicsDevices = [graphics]
        let disk = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: "\(path)/Disk.img"), readOnly: false,
                                                          cachingMode: .automatic, synchronizationMode: .fsync)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        guard let mac = VZMACAddress(string: spec.mac) else { throw ShellError(description: "\(path): bad MAC \(spec.mac)") }
        network.macAddress = mac
        configuration.networkDevices = [network]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        // The trackpad for a person at the live view; the screen-coordinate
        // pointer for Screen Sharing's absolute clicks.
        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        try configuration.validate()
        return configuration
    }

    func start() async throws {
        try await machine.start(options: VZMacOSVirtualMachineStartOptions())
        MacVMs.running[name] = self
    }

    /// Its first boot after an install: `provisioning` sets up its account
    /// (macOS 27 guests).
    @available(macOS 27, *)
    func start(provisioning: VZMacGuestProvisioningOptions) async throws {
        let options = VZMacOSVirtualMachineStartOptions()
        try options.setGuestProvisioning(provisioning)
        try await machine.start(options: options)
        MacVMs.running[name] = self
    }

    /// Powered off at once: a lease's clone is thrown away, so nothing in it
    /// needs to be saved.
    func stop() async {
        guard !stopped else { return }
        if machine.canStop { try? await machine.stop() }
        ended()
    }

    /// Until the guest shuts itself down (a sealed base), or `seconds` pass.
    func waitUntilStopped(seconds: TimeInterval) async -> Bool {
        if stopped { return true }
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            self.resumeWaiters()
        }
        await withCheckedContinuation { stopWaiters.append($0) }
        deadline.cancel()
        return stopped
    }

    private func ended() {
        stopped = true
        if MacVMs.running[name] === self { MacVMs.running[name] = nil }
        resumeWaiters()
    }

    private func resumeWaiters() {
        let waiters = stopWaiters
        stopWaiters = []
        waiters.forEach { $0.resume() }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.ended() }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Task { @MainActor in
            log("\(self.name) stopped: \(error.localizedDescription)")
            self.ended()
        }
    }
}

/// The macOS VMs running in this process, by name (a lease's clone, or a
/// base being built): what the app shows live.
@MainActor
public enum MacVMs {
    static var running: [String: MacVM] = [:]

    /// The VM a machine of that name runs, for a live view (`VZVirtualMachineView`).
    public static func virtualMachine(named name: String) -> VZVirtualMachine? { running[name]?.machine }

    public static var names: [String] { running.keys.sorted() }
}

/// Installing macOS into a new base, and its first boot, which makes
/// `runner` with no one at the screen (macOS 27's guest provisioning).
@available(macOS 27, *)
@MainActor
enum MacInstaller {
    /// A base made from a restore image (an .ipsw, or the newest this Mac
    /// supports, downloaded): installed, provisioned, then shut down. What
    /// makes it a lab machine (sudo, keys, no sleep, Screen Sharing) is
    /// the vanilla layer's, built on it (`oss image build macos vanilla
    /// --from=base`).
    static func install(config: String, ipsw: String?, cpus: Int, memoryGB: Int, diskGB: Int) async throws {
        guard let password = ProcessInfo.processInfo.environment["OSS_GUEST_PASSWORD"]
                ?? GuestPasswords.password(for: .macos, config: config), !password.isEmpty else {
            throw ShellError(description: "set OSS_GUEST_PASSWORD (or guest-passwords.json's \"macos\") to the password runner gets")
        }
        let server = ServerConfig.load()
        let imageURL: URL
        if let ipsw {
            imageURL = URL(fileURLWithPath: ipsw)
        } else {
            imageURL = try await downloadLatest()
        }
        log("reading \(imageURL.lastPathComponent)")
        let image = try await VZMacOSRestoreImage.image(from: imageURL)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw ShellError(description: "this Mac can't run macOS \(image.operatingSystemVersion.majorVersion) from \(imageURL.lastPathComponent)")
        }
        let path = MacVMStore.basePath(config)
        let work = path + ".installing"
        MacVMStore.remove(work)
        Paths.ensure(work)
        let disk = "\(work)/Disk.img"
        guard FileManager.default.createFile(atPath: disk, contents: nil),
              let handle = FileHandle(forWritingAtPath: disk) else { throw ShellError(description: "can't make \(disk)") }
        try handle.truncate(atOffset: UInt64(diskGB) * 1_000_000_000)
        try handle.close()
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: URL(fileURLWithPath: "\(work)/AuxiliaryStorage"),
                                      hardwareModel: requirements.hardwareModel, options: [])
        let spec = MacMachineSpec(hardwareModel: requirements.hardwareModel.dataRepresentation,
                                  machineIdentifier: VZMacMachineIdentifier().dataRepresentation,
                                  cpus: max(cpus, requirements.minimumSupportedCPUCount),
                                  memoryBytes: max(UInt64(memoryGB) << 30, requirements.minimumSupportedMemorySize),
                                  diskBytes: UInt64(diskGB) * 1_000_000_000, mac: Random.mac(),
                                  origin: imageURL.lastPathComponent)
        try spec.save(work)

        let name = "build-macos-\(config)"
        let vm = try MacVM(name: name, path: work)
        log("installing macOS \(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion) (\(image.buildVersion)) into \(config)")
        let installer = VZMacOSInstaller(virtualMachine: vm.machine, restoringFromImageAt: imageURL)
        let progress = installer.progress
        let reporter = Task { @MainActor in
            var last = -10
            while !Task.isCancelled {
                let percent = Int(progress.fractionCompleted * 100)
                if percent / 10 != last / 10 { log("installing: \(percent)%"); last = percent }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        do {
            try await installer.install()
        } catch {
            reporter.cancel()
            throw ShellError(description: "installing macOS: \(error.localizedDescription)")
        }
        reporter.cancel()
        _ = await vm.waitUntilStopped(seconds: 120)
        if !vm.stopped { await vm.stop() }

        // The first boot: runner made, logged in at startup, Remote Login on.
        log("first boot: provisioning \(server.guestUser)")
        let first = try MacVM(name: name, path: work)
        let options = VZMacGuestProvisioningOptions()
        options.fullName = server.guestUser
        options.username = server.guestUser
        options.password = password
        options.logsInAutomatically = true
        options.enablesRemoteLogin = true
        try await first.start(provisioning: options)
        let address = try await MacVMs.address(of: spec.mac, seconds: 900)
        try await MacVMs.letKeyIn(address: address, password: password, config: server)
        let guest = Guest(platform: .macos, address: address, user: server.guestUser, key: server.managementKey)
        guard await guest.waitUntilReachable(seconds: 300) else { throw ShellError(description: "\(config) at \(address): no SSH") }
        try await MacVMs.seal(first, guest: guest)
        MacVMStore.remove(path)
        try FileManager.default.moveItem(atPath: work, toPath: path)
        log("macOS base \(config) is ready: installed, \(server.guestUser) made, the server's key let in")
    }

    /// The newest macOS this Mac's Virtualization framework supports,
    /// downloaded beside the bases (kept: the next install reads it again).
    static func downloadLatest() async throws -> URL {
        let image = try await VZMacOSRestoreImage.latestSupported
        let directory = "\(Paths.machines)/restore-images"
        Paths.ensure(directory)
        let destination = URL(fileURLWithPath: "\(directory)/\(image.url.lastPathComponent)")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        log("downloading \(image.url.absoluteString)")
        let (temporary, response) = try await URLSession.shared.download(from: image.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ShellError(description: "downloading \(image.url): \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// UTM's macOS VMs (an Apple-backend `.utm`) taken in as OS Server's own
/// bases: UTM exports the VM (an APFS clone: no space, a moment), and its
/// disk, auxiliary storage, hardware model and machine identifier become a
/// `.vm` folder. The VM in UTM is left as it was.
enum MacImport {
    /// `oss-macos-<config>` (or any name, `as` its config).
    static func fromUTM(_ name: String, as config: String? = nil) async throws {
        guard let config = config ?? Base(name: name).map(\.config) else { throw ShellError(description: "\(name): give its config (--as)") }
        Paths.ensure(MacVMStore.bases)
        let exported = "\(MacVMStore.bases)/\(config).import.utm"
        let work = MacVMStore.basePath(config) + ".importing"
        MacVMStore.remove(exported)
        MacVMStore.remove(work)
        defer { MacVMStore.remove(exported) }
        log("importing UTM's \(name) as macOS \(config)")
        _ = try await UTM.script("""
            on run argv
              tell application "UTM" to export (virtual machine named (item 1 of argv)) to (POSIX file (item 2 of argv))
            end run
            """, [name, exported], timeout: 1800)
        guard let data = FileManager.default.contents(atPath: "\(exported)/config.plist"),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ShellError(description: "\(name): UTM exported no config.plist")
        }
        guard plist["Backend"] as? String == "Apple", let system = plist["System"] as? [String: Any],
              let platform = system["MacPlatform"] as? [String: Any],
              let model = platform["HardwareModel"] as? Data, let identifier = platform["MachineIdentifier"] as? Data,
              let image = (plist["Drive"] as? [[String: Any]])?.first?["ImageName"] as? String else {
            throw ShellError(description: "\(name) isn't a macOS VM of Apple's Virtualization")
        }
        let display = (plist["Display"] as? [[String: Any]])?.first ?? [:]
        let mac = (plist["Network"] as? [[String: Any]])?.first?["MacAddress"] as? String ?? Random.mac()
        Paths.ensure(work)
        let disk = "\(work)/Disk.img"
        try FileManager.default.moveItem(atPath: "\(exported)/Data/\(image)", toPath: disk)
        try FileManager.default.moveItem(atPath: "\(exported)/Data/\(platform["AuxiliaryStoragePath"] as? String ?? "AuxiliaryStorage")",
                                         toPath: "\(work)/AuxiliaryStorage")
        let size = (try? FileManager.default.attributesOfItem(atPath: disk)[.size] as? NSNumber)?.uint64Value ?? 0
        let spec = MacMachineSpec(hardwareModel: model, machineIdentifier: identifier,
                                  cpus: system["CPUCount"] as? Int ?? 6,
                                  memoryBytes: UInt64(system["MemorySize"] as? Int ?? 16384) << 20, diskBytes: size,
                                  displayWidth: display["WidthPixels"] as? Int ?? 1920, displayHeight: display["HeightPixels"] as? Int ?? 1200,
                                  displayPPI: display["PixelsPerInch"] as? Int ?? 80, mac: mac, origin: "UTM's \(name)")
        try spec.save(work)
        MacVMStore.remove(MacVMStore.basePath(config))
        try FileManager.default.moveItem(atPath: work, toPath: MacVMStore.basePath(config))
        log("macOS \(config) is OS Server's own now (from UTM's \(name))")
    }

    /// Each `oss-macos-` VM UTM has whose config OS Server hasn't got of
    /// its own: the first start of 0.7 takes them all in, and a base made
    /// in UTM later comes in at the next start.
    static func fromUTMWhereMissing() async {
        guard let vms = try? await UTM.list() else { return }
        let own = Set(MacVMStore.configs())
        for vm in vms where vm.status == "stopped" {
            guard let base = Base(name: vm.name), base.platform == .macos, !own.contains(base.config) else { continue }
            do { try await fromUTM(vm.name) } catch { log("importing \(vm.name): \(error)") }
        }
    }
}

extension MacVMs {
    /// The address the NAT's DHCP server gave this network card.
    static func address(of mac: String, seconds: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let address = UTM.addressFromDHCP(mac) { return address }
            try await Task.sleep(for: .seconds(3))
        }
        throw ShellError(description: "no address for \(mac) after \(Int(seconds)) s")
    }

    /// The server's key let into a newly provisioned guest with runner's
    /// password (ssh-copy-id, the password from an askpass of ours), and
    /// runner's sudo made to ask nothing.
    static func letKeyIn(address: String, password: String, config: ServerConfig) async throws {
        let askpass = NSTemporaryDirectory() + "oss-askpass-\(Random.hex(4))"
        FileManager.default.createFile(atPath: askpass, contents: Data("#!/bin/sh\nprintf '%s\\n' \"$OSS_GUEST_PASSWORD\"\n".utf8),
                                       attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: askpass) }
        var environment = ProcessInfo.processInfo.environment
        environment["OSS_GUEST_PASSWORD"] = password
        environment["SSH_ASKPASS"] = askpass
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "none"
        var copied = false
        for _ in 0..<120 where !copied {
            let result = try await Shell.run("/usr/bin/ssh-copy-id", ["-i", config.managementKey + ".pub", "-o", "ConnectTimeout=5",
                                                                      "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                                                                      "-o", "PubkeyAuthentication=no", "\(config.guestUser)@\(address)"],
                                             environment: environment, timeout: 60)
            copied = result.ok
            if !copied { try await Task.sleep(for: .seconds(5)) }
        }
        guard copied else { throw ShellError(description: "could not let the server's key into \(address)") }
        let sudoers = try await Shell.run("/usr/bin/ssh", Images.sshOptions(config) + ["\(config.guestUser)@\(address)",
            "IFS= read -r pw; printf '%s\\n' \"$pw\" | sudo -S -p '' sh -c 'echo \"\(config.guestUser) ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/\(config.guestUser) && chmod 440 /etc/sudoers.d/\(config.guestUser)' && sudo -n true && echo sudo-ok"],
            input: Data((password + "\n").utf8), timeout: 60)
        guard sudoers.output.contains("sudo-ok") else { throw ShellError(description: "could not set up sudo at \(address): \(sudoers.error)") }
    }

    /// Cleared of what a build leaves and shut down from inside (its disk
    /// whole for the clones made from it).
    static func seal(_ vm: MacVM, guest: Guest) async throws {
        _ = try? await guest.run("rm -f ~/layer.sh ~/.zsh_history ~/.bash_history; rm -rf ~/.zsh_sessions; find ~/Library/Caches -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; sudo shutdown -h now", timeout: 60)
        guard await vm.waitUntilStopped(seconds: 300) else {
            await vm.stop()
            throw ShellError(description: "\(vm.name) did not shut down")
        }
    }

    /// A clone of a base, running with a network card of its own: a
    /// lease's machine, or a layer being built.
    static func startClone(of config: String, as name: String, at path: String) async throws -> MacVM {
        try MacVMStore.clone(MacVMStore.basePath(config), to: path)
        var spec = try MacMachineSpec.load(path)
        spec.mac = Random.mac()
        spec.origin = config
        try spec.save(path)
        let vm = try MacVM(name: name, path: path)
        try await vm.start()
        return vm
    }
}

#endif
