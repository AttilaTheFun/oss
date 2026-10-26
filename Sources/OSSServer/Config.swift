import Foundation
import OSSClient

/// Where oss keeps its files.
///
/// A client's (any computer that leases): `~/.config/oss` (client.json, the
/// server's token) and `~/.local/state/oss` (each lease's known_hosts).
///
/// The server's: on a Mac everything under `~/Library/Application
/// Support/OS Server` (its settings and token, the leases, the machines'
/// bases), so removing that folder removes OS Server; on Linux
/// `~/.config/oss`, `~/.local/state/oss` and `~/.local/share/oss`, as before
/// 0.7 on a Mac too (`migrate()` moves those).
enum Paths {
    /// The user's home, or `OSS_HOME`: a second oss with files of its own
    /// (its settings, token and state), to test one beside a running server.
    static let home = ProcessInfo.processInfo.environment["OSS_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path

    // A client's.
    static let clientDirectory = "\(home)/.config/oss"
    static let clientConfig = "\(clientDirectory)/client.json"
    static let clientToken = "\(clientDirectory)/token"
    static let clientState = "\(home)/.local/state/oss"

    // The server's.
    #if os(macOS)
    static let support = "\(home)/Library/Application Support/OS Server"
    static let config = support
    static let state = "\(support)/State"
    static let share = support
    #else
    static let support = "\(home)/.local/share/oss"
    static let config = "\(home)/.config/oss"
    static let state = "\(home)/.local/state/oss"
    static let share = support
    #endif
    static let token = "\(config)/token"
    static let serverConfig = "\(config)/server.json"
    static let leases = "\(state)/leases.json"
    /// UTM's VM bases as last listed.
    static let vmBases = "\(state)/vm-bases.json"
    static let uploads = "\(state)/uploads"
    /// The macOS VMs' bases (OS Server's own, run by Apple's
    /// Virtualization framework) and their leases' clones.
    static let machines = "\(share)/Machines"
    /// The containers' kernel, images and root filesystems
    /// (Containerization's store).
    static let containers = "\(share)/Containers"

    static func ensure(_ directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Before 0.7 a Mac's server kept its files where Linux's does: moved
    /// into Application Support the first time 0.7 starts (the token
    /// copied, as local clients read it from ~/.config/oss too). What the
    /// old settings left to a default that now lies elsewhere (the Android
    /// SDK, the Bazel cache) is written into them, so nothing moves under
    /// a running emulator or a cache's clients.
    static func migrate() {
        #if os(macOS)
        let manager = FileManager.default
        let oldConfig = "\(home)/.config/oss", oldState = "\(home)/.local/state/oss", oldShare = "\(home)/.local/share/oss"
        guard !manager.fileExists(atPath: serverConfig),
              manager.fileExists(atPath: "\(oldConfig)/server.json") || manager.fileExists(atPath: "\(oldConfig)/token")
                || manager.fileExists(atPath: "\(oldState)/leases.json") else { return }
        ensure(support)
        ensure(state)
        var settings = (manager.contents(atPath: "\(oldConfig)/server.json")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        if settings["androidSDK"] == nil, manager.fileExists(atPath: "\(oldShare)/android-sdk") {
            settings["androidSDK"] = "\(oldShare)/android-sdk"
        }
        if settings["androidAVDHome"] == nil, manager.fileExists(atPath: "\(oldShare)/avd") {
            settings["androidAVDHome"] = "\(oldShare)/avd"
        }
        if var cache = settings["cache"] as? [String: Any], cache["directory"] == nil {
            cache["directory"] = "\(oldState)/bazel-cache"
            settings["cache"] = cache
        }
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            manager.createFile(atPath: serverConfig, contents: data, attributes: [.posixPermissions: 0o600])
        }
        for name in ["token", "cache-read-token", "cache-write-token"] where manager.fileExists(atPath: "\(oldConfig)/\(name)") {
            try? manager.copyItem(atPath: "\(oldConfig)/\(name)", toPath: "\(config)/\(name)")
        }
        if manager.fileExists(atPath: "\(oldConfig)/guest-passwords.json") {
            try? manager.moveItem(atPath: "\(oldConfig)/guest-passwords.json", toPath: "\(config)/guest-passwords.json")
        }
        try? manager.removeItem(atPath: "\(oldConfig)/server.json")
        for name in ["leases.json", "vm-bases.json", "uploads"] where manager.fileExists(atPath: "\(oldState)/\(name)") {
            try? manager.moveItem(atPath: "\(oldState)/\(name)", toPath: "\(state)/\(name)")
        }
        log("moved the server's files from ~/.config/oss and ~/.local/state/oss to \(support)")
        #endif
    }
}

/// The server's settings (`server.json` in its folder, Paths.config;
/// every field optional).
struct ServerConfig: Codable, Sendable {
    /// The API's port, on every interface.
    var port: Int = 7480
    /// How many leases of each platform may exist at once.
    var capacity: [String: Int] = ["macos": 2, "windows": 2, "linux": 2, "ios": 4, "android": 2, "container": 4]
    var defaultMinutes: Int = 60
    var maxMinutes: Int = 8 * 60
    /// The range forwarded ports are taken from.
    var firstPort: Int = 47500
    var lastPort: Int = 47999
    /// Loopback ports for QEMU's own VNC servers (Windows, Linux), behind
    /// the forwarder's password check.
    var firstQEMUVNCPort: Int = 46500
    var lastQEMUVNCPort: Int = 46999
    /// Console ports for Android emulators (even; each one's adb is the next).
    var firstEmulatorPort: Int = 5700
    var lastEmulatorPort: Int = 5798
    /// The key the server reaches its VM guests with (the bases trust its public half).
    var managementKey: String = "\(Paths.home)/.ssh/id_ed25519"
    var guestUser: String = "runner"
    /// The config a lease gets when it names none, by platform.
    var defaultConfig: [String: String] = ["macos": "vanilla", "windows": "vanilla", "linux": "vanilla", "ios": "iphone", "android": "phone",
                                           "container": "linux"]
    /// The Android SDK oss sets up (`oss setup android`), and its AVDs.
    var androidSDK: String = "\(Paths.share)/android-sdk"
    var androidAVDHome: String = "\(Paths.share)/avd"
    /// A Bazel cache (Cache.swift), when set.
    var cache: CacheConfig?
    /// AXe, for a simulator's input, where it isn't Homebrew's.
    var axePath: String?
    /// VMs run without UTM's windows (UTM.makeHeadless): their screens are
    /// VNC's alone.
    var headlessVMs: Bool = false
    /// The platforms this server lends (nil: all of them). A server that
    /// lends none of a platform leaves its machines alone, even those named
    /// like its own: a second server (to try a change beside a running one)
    /// lends only what it's trying.
    var lends: [Platform]?
    /// Whether to use UTM (Linux and Windows VMs, and macOS bases OS Server
    /// hasn't got of its own).
    var useUTM: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServerConfig()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        capacity = d.capacity.merging(try c.decodeIfPresent([String: Int].self, forKey: .capacity) ?? [:]) { $1 }
        defaultMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultMinutes) ?? d.defaultMinutes
        maxMinutes = try c.decodeIfPresent(Int.self, forKey: .maxMinutes) ?? d.maxMinutes
        firstPort = try c.decodeIfPresent(Int.self, forKey: .firstPort) ?? d.firstPort
        lastPort = try c.decodeIfPresent(Int.self, forKey: .lastPort) ?? d.lastPort
        firstQEMUVNCPort = try c.decodeIfPresent(Int.self, forKey: .firstQEMUVNCPort) ?? d.firstQEMUVNCPort
        lastQEMUVNCPort = try c.decodeIfPresent(Int.self, forKey: .lastQEMUVNCPort) ?? d.lastQEMUVNCPort
        firstEmulatorPort = try c.decodeIfPresent(Int.self, forKey: .firstEmulatorPort) ?? d.firstEmulatorPort
        lastEmulatorPort = try c.decodeIfPresent(Int.self, forKey: .lastEmulatorPort) ?? d.lastEmulatorPort
        managementKey = try c.decodeIfPresent(String.self, forKey: .managementKey) ?? d.managementKey
        guestUser = try c.decodeIfPresent(String.self, forKey: .guestUser) ?? d.guestUser
        defaultConfig = d.defaultConfig.merging(try c.decodeIfPresent([String: String].self, forKey: .defaultConfig) ?? [:]) { $1 }
        androidSDK = try c.decodeIfPresent(String.self, forKey: .androidSDK) ?? d.androidSDK
        androidAVDHome = try c.decodeIfPresent(String.self, forKey: .androidAVDHome) ?? d.androidAVDHome
        cache = try c.decodeIfPresent(CacheConfig.self, forKey: .cache)
        axePath = try c.decodeIfPresent(String.self, forKey: .axePath)
        headlessVMs = try c.decodeIfPresent(Bool.self, forKey: .headlessVMs) ?? d.headlessVMs
        lends = try c.decodeIfPresent([Platform].self, forKey: .lends)
        useUTM = try c.decodeIfPresent(Bool.self, forKey: .useUTM) ?? d.useUTM
    }

    func lends(_ platform: Platform) -> Bool { lends?.contains(platform) ?? true }

    static func load() -> ServerConfig {
        guard let data = FileManager.default.contents(atPath: Paths.serverConfig) else { return ServerConfig() }
        return (try? JSONDecoder().decode(ServerConfig.self, from: data)) ?? ServerConfig()
    }

    func limit(_ platform: Platform) -> Int { capacity[platform.rawValue] ?? 0 }
    func defaultConfig(_ platform: Platform) -> String { defaultConfig[platform.rawValue] ?? "vanilla" }
}

/// The VM bases' `runner` passwords, where the server's owner keeps them
/// (`guest-passwords.json` in its folder, mode 600): `{"macos": "…"}`, or
/// `"macos/xcode-27.0"` for one config. A VM lease carries its own, for
/// its holder to log in at its screen or unlock it.
enum GuestPasswords {
    static let path = "\(Paths.config)/guest-passwords.json"

    static func password(for platform: Platform, config: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let passwords = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return passwords["\(platform.rawValue)/\(config)"] ?? passwords[platform.rawValue]
    }
}

/// A client's settings (`~/.config/oss/client.json`): the server's
/// addresses in the order to try them, nearest first (this computer, the
/// LAN, a VPN such as a tailnet). The first that answers is used for the
/// API, SSH, VNC and adb.
struct ClientConfig: Codable, Sendable {
    var servers: [String] = ["http://127.0.0.1:7480"]

    static func load() -> ClientConfig {
        if let env = ProcessInfo.processInfo.environment["OSS_SERVERS"] {
            return ClientConfig(servers: env.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        guard let data = FileManager.default.contents(atPath: Paths.clientConfig),
              let config = try? JSONDecoder().decode(ClientConfig.self, from: data) else { return ClientConfig() }
        return config
    }
}

enum Token {
    /// The API's shared secret, as a client finds it: `OSS_TOKEN`, else
    /// `~/.config/oss/token`, else (on the server's own computer) the
    /// server's.
    static func read() -> String? {
        if let env = ProcessInfo.processInfo.environment["OSS_TOKEN"], !env.isEmpty { return env }
        return file(Paths.clientToken) ?? file(Paths.token)
    }

    private static func file(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The server's token, made on its first start (readable by its owner only).
    static func ensure() -> String {
        if let env = ProcessInfo.processInfo.environment["OSS_TOKEN"], !env.isEmpty { return env }
        if let token = file(Paths.token) { return token }
        Paths.ensure(Paths.config)
        let token = Random.hex(32)
        FileManager.default.createFile(atPath: Paths.token, contents: Data((token + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }
}

enum Random {
    static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    static func hex(_ count: Int) -> String {
        bytes(count).map { String(format: "%02x", $0) }.joined()
    }

    /// A VNC password: VNC uses only its first eight characters.
    static func vncPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String(bytes(8).map { alphabet[Int($0) % alphabet.count] })
    }

    /// A locally administered unicast MAC address, for a clone of its own.
    static func mac() -> String {
        var b = bytes(6)
        b[0] = (b[0] & 0xFC) | 0x02
        return b.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// This computer's own name (a Mac's is its .local name), not what reverse
/// DNS calls its address.
let localHostName: String = {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return ProcessInfo.processInfo.hostName }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}()

/// Two secrets compared without leaking where they differ.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}
