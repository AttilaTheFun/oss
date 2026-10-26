import Foundation
import OSSClient

#if os(macOS)
import Virtualization

/// What OS Server lends, a piece at a time: each installed on its own (the
/// app's onboarding, Settings › Components) from a download or an image
/// you give it, and removed on its own, leaving the others. Everything a
/// component installs is in OS Server's folder, so removing OS Server
/// removes them all.
public struct ComponentInfo: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case absent
        /// Its last log line while it installs.
        case installing(String)
        case installed
        /// It can't be installed here (why).
        case unavailable(String)
        case failed(String)
    }

    public var id: String
    public var name: String
    public var detail: String
    public var symbol: String
    public var state: State
    /// What it can be installed from besides a download (a file to pick).
    public var accepts: [String]
    /// It installs only from a file you give it (there's no download).
    public var needsFile: Bool = false

    public init(id: String, name: String, detail: String, symbol: String, state: State, accepts: [String], needsFile: Bool = false) {
        self.needsFile = needsFile
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.state = state
        self.accepts = accepts
    }
}

/// The components, and what each takes to install and remove.
public actor Components {
    public static let shared = Components()

    /// The containers' backend (OS Server's app has one).
    var containers: ContainerBackend?
    /// How many leases of a platform are held (a component in use isn't removed).
    var held: (@Sendable (Platform) async -> Int)?
    private var running: [String: Task<Void, Never>] = [:]
    private var failures: [String: String] = [:]

    func attach(containers: ContainerBackend?, held: @escaping @Sendable (Platform) async -> Int) {
        self.containers = containers
        self.held = held
    }

    public func list() async -> [ComponentInfo] {
        var list: [ComponentInfo] = []
        func state(_ id: String, installed: Bool, unavailable: String? = nil) -> ComponentInfo.State {
            if running[id] != nil { return .installing(ServerLog.lastLine ?? "starting") }
            if let failure = failures[id] { return .failed(failure) }
            if installed { return .installed }
            if let unavailable { return .unavailable(unavailable) }
            return .absent
        }
        let containersReady = await containers?.isPrepared() ?? false
        let noContainers: String
        if #available(macOS 26, *) { noContainers = "OS Server's app runs them" } else { noContainers = "needs macOS 26" }
        list.append(ComponentInfo(id: "containers", name: "Linux containers",
                                  detail: "Containers from any registry's images, on Apple's Containerization: its Linux kernel and init.",
                                  symbol: "shippingbox",
                                  state: state("containers", installed: containersReady,
                                               unavailable: containers == nil ? noContainers : nil),
                                  accepts: []))
        let macOS27: Bool
        if #available(macOS 27, *) { macOS27 = true } else { macOS27 = false }
        list.append(ComponentInfo(id: "macos", name: "macOS VMs",
                                  detail: "The newest macOS this Mac runs, installed from Apple's restore image with no one at its screen.",
                                  symbol: "laptopcomputer",
                                  state: state("macos", installed: MacVMStore.hasBase("vanilla"),
                                               unavailable: macOS27 ? nil : "needs macOS 27 here"),
                                  accepts: ["ipsw"]))
        list.append(ComponentInfo(id: "linux", name: "Ubuntu VMs",
                                  detail: "Ubuntu \(LinuxInstaller.release) with GNOME, from Ubuntu's cloud image, on OS Server's QEMU.",
                                  symbol: "server.rack",
                                  state: state("linux", installed: QEMUStore.hasBase(.linux, "vanilla"),
                                               unavailable: QEMU.system == nil ? "this OS Server has no QEMU" : nil),
                                  accepts: ["img"]))
        list.append(ComponentInfo(id: "windows", name: "Windows VMs",
                                  detail: "Windows 11 on Arm from Microsoft's ISO (downloaded from Microsoft, about 6 GB), installed by an answer file on OS Server's QEMU, with Fedora's virtio drivers.",
                                  symbol: "pc",
                                  state: state("windows", installed: QEMUStore.hasBase(.windows, "vanilla"),
                                               unavailable: QEMU.system == nil ? "this OS Server has no QEMU" : nil),
                                  accepts: ["iso"]))
        list.append(ComponentInfo(id: "android", name: "Android emulators",
                                  detail: "Google's emulator and an Android 15 phone image, from Google's repository.",
                                  symbol: "candybarphone",
                                  state: state("android", installed: Emulators.bases(ServerConfig.load()).contains { $0.config == "phone" }),
                                  accepts: []))
        let xcode = FileManager.default.fileExists(atPath: "/Applications/Xcode.app") || ProcessInfo.processInfo.environment["DEVELOPER_DIR"] != nil
        let iphone = await Simulators.bases().contains { $0.config == "iphone" }
        list.append(ComponentInfo(id: "ios", name: "iOS simulators",
                                  detail: "An iPhone simulator of the newest runtime Xcode has.",
                                  symbol: "iphone",
                                  state: state("ios", installed: iphone, unavailable: xcode ? nil : "needs Xcode"),
                                  accepts: []))
        return list
    }

    /// Installed in the background (`list()` says how it goes); `file` an
    /// image to install from instead of a download.
    public func install(_ id: String, file: String? = nil) {
        guard running[id] == nil else { return }
        failures[id] = nil
        running[id] = Task {
            do {
                try await self.perform(id, file: file)
            } catch {
                log("installing \(id) failed: \(error)")
                self.failed(id, "\(error)")
            }
            self.finished(id)
        }
    }

    private func failed(_ id: String, _ message: String) { failures[id] = message }
    private func finished(_ id: String) { running[id] = nil }

    private func perform(_ id: String, file: String?) async throws {
        log("installing \(id)")
        switch id {
        case "containers":
            guard let containers else { throw ShellError(description: "containers need macOS 26") }
            try await containers.prepare()
            if VZLinuxRosettaDirectoryShare.availability == .notInstalled {
                // The system's own prompt: x86_64 Linux programs in containers.
                try? await VZLinuxRosettaDirectoryShare.installRosetta()
            }
        case "macos":
            guard #available(macOS 27, *) else { throw ShellError(description: "needs macOS 27 here") }
            GuestPasswords.ensure(.macos)
            try await MacInstaller.install(config: "base", ipsw: file, cpus: 6, memoryGB: 16, diskGB: 128)
            try await Images.build(platform: .macos, layer: "vanilla", from: "base", script: nil, copies: [])
        case "linux":
            GuestPasswords.ensure(.linux)
            try await LinuxInstaller.install(config: "base", image: file, cpus: 6, memoryGB: 8, diskGB: 128)
            try await Images.build(platform: .linux, layer: "vanilla", from: "base", script: nil, copies: [])
        case "windows":
            GuestPasswords.ensure(.windows)
            var iso = file
            if iso == nil { iso = try await WindowsISO.download().path }
            try await WindowsInstaller.install(config: "base", iso: iso ?? "", cpus: 6, memoryGB: 8, diskGB: 128)
            try await Images.build(platform: .windows, layer: "vanilla", from: "base", script: nil, copies: [])
        case "android":
            try await Emulators.setup(api: 35, tag: "google_apis")
            try await Emulators.build(config: "phone", api: 35, tag: "google_apis", script: nil)
        case "ios":
            try await Simulators.build(config: "iphone", deviceType: "iPhone 17 Pro", runtime: nil, script: nil)
        default:
            throw ShellError(description: "no component \(id)")
        }
        log("\(id) is installed")
    }

    /// Removed, with everything it put in OS Server's folder; refused while
    /// a lease uses it.
    public func remove(_ id: String) async throws {
        let platform: Platform? = ["containers": .container, "macos": .macos, "linux": .linux, "windows": .windows,
                                   "android": .android, "ios": .ios][id]
        if let platform, let held, await held(platform) > 0 {
            throw ShellError(description: "a lease uses it: release it first")
        }
        failures[id] = nil
        let config = ServerConfig.load()
        switch id {
        case "containers":
            await containers?.removeEverything()
        case "macos":
            try? FileManager.default.removeItem(atPath: MacVMStore.bases)
            try? FileManager.default.removeItem(atPath: "\(Paths.machines)/restore-images")
        case "linux":
            try? FileManager.default.removeItem(atPath: QEMUStore.bases(.linux))
            try? FileManager.default.removeItem(atPath: "\(Paths.machines)/images/\(LinuxInstaller.imageName)")
        case "windows":
            try? FileManager.default.removeItem(atPath: QEMUStore.bases(.windows))
            // The ISO it downloaded, and the virtio drivers.
            let images = "\(Paths.machines)/images"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: images)) ?? []
            where name.hasPrefix("Windows11_") || name.hasPrefix("virtio-win-") {
                try? FileManager.default.removeItem(atPath: "\(images)/\(name)")
            }
        case "android":
            await Emulators.stopADB()
            try? FileManager.default.removeItem(atPath: config.androidAVDHome)
            try? FileManager.default.removeItem(atPath: config.androidSDK)
        case "ios":
            for base in await Simulators.bases() { _ = try? await Simulators.simctl(["delete", base.name]) }
        default:
            throw ShellError(description: "no component \(id)")
        }
        log("removed \(id)")
    }
}

extension GuestPasswords {
    /// A password for a platform's runner, made and kept (mode 600) when
    /// there's none: a self-contained install needs no one to choose one.
    static func ensure(_ platform: Platform) {
        var passwords = (FileManager.default.contents(atPath: path)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
        guard passwords[platform.rawValue] == nil else { return }
        passwords[platform.rawValue] = Random.vncPassword() + Random.hex(4)
        Paths.ensure(Paths.config)
        if let data = try? JSONEncoder().encode(passwords) {
            FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
#endif
