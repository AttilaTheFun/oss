import Foundation
import OSSClient

/// Where oss keeps its files: `~/.config/oss` (settings, the token),
/// `~/.local/state/oss` (leases, containers and their archives, each
/// lease's known_hosts on a client) and `~/.local/share/oss` (the Android
/// SDK and AVDs it sets up).
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let config = "\(home)/.config/oss"
    static let state = "\(home)/.local/state/oss"
    static let share = "\(home)/.local/share/oss"
    static let token = "\(config)/token"
    static let serverConfig = "\(config)/server.json"
    static let clientConfig = "\(config)/client.json"
    /// Variables every container process gets (KEY=VALUE lines).
    static let containerEnvironment = "\(config)/container.env"
    /// Files copied into every container's home when it is made, where the
    /// home lacks them (settings, sign-ins); never archived.
    static let containerHomeTemplate = "\(config)/container-home"
    /// An image's own: `<image>.env` (variables) and `<image>.home/` (home
    /// files), over the server's for containers of that image.
    static let imageSettings = "\(config)/images"
    static let leases = "\(state)/leases.json"
    static let containers = "\(state)/containers.json"
    /// Each container's own folder, shared into it at /oss (its home is not).
    static let containerFolders = "\(state)/containers"
    static let archives = "\(state)/archives"
    /// UTM's VM bases as last listed.
    static let vmBases = "\(state)/vm-bases.json"
    static let uploads = "\(state)/uploads"

    static func ensure(_ directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

/// The server's settings (`~/.config/oss/server.json`; every field optional).
struct ServerConfig: Codable, Sendable {
    /// The API's port, on every interface.
    var port: Int = 7480
    /// How many leases of each platform may exist at once.
    var capacity: [String: Int] = ["macos": 2, "windows": 2, "linux": 2, "ios": 4, "android": 2]
    /// How many containers may run at once.
    var containerLimit: Int = 8
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
    var defaultConfig: [String: String] = ["macos": "vanilla", "windows": "vanilla", "linux": "vanilla", "ios": "iphone", "android": "phone"]
    /// The Android SDK oss sets up (`oss setup android`), and its AVDs.
    var androidSDK: String = "\(Paths.share)/android-sdk"
    var androidAVDHome: String = "\(Paths.share)/avd"
    /// The image a container runs when it names none: Ubuntu as it comes.
    var containerImage: String = "docker.io/library/ubuntu:24.04"
    /// A container's size when it names none: the VMs' (6 cores, 16 GB).
    var containerCPUs: Int = 6
    var containerMemory: String = "16g"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServerConfig()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        capacity = d.capacity.merging(try c.decodeIfPresent([String: Int].self, forKey: .capacity) ?? [:]) { $1 }
        containerLimit = try c.decodeIfPresent(Int.self, forKey: .containerLimit) ?? d.containerLimit
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
        containerImage = try c.decodeIfPresent(String.self, forKey: .containerImage) ?? d.containerImage
        containerCPUs = try c.decodeIfPresent(Int.self, forKey: .containerCPUs) ?? d.containerCPUs
        containerMemory = try c.decodeIfPresent(String.self, forKey: .containerMemory) ?? d.containerMemory
    }

    static func load() -> ServerConfig {
        guard let data = FileManager.default.contents(atPath: Paths.serverConfig) else { return ServerConfig() }
        return (try? JSONDecoder().decode(ServerConfig.self, from: data)) ?? ServerConfig()
    }

    func limit(_ platform: Platform) -> Int { capacity[platform.rawValue] ?? 0 }
    func defaultConfig(_ platform: Platform) -> String { defaultConfig[platform.rawValue] ?? "vanilla" }
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
    /// The API's shared secret: `OSS_TOKEN`, else `~/.config/oss/token`.
    static func read() -> String? {
        if let env = ProcessInfo.processInfo.environment["OSS_TOKEN"], !env.isEmpty { return env }
        guard let data = FileManager.default.contents(atPath: Paths.token) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The server's token, made on its first start (readable by its owner only).
    static func ensure() -> String {
        if let token = read() { return token }
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
