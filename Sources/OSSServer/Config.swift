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
    /// A client's API key (API 12): an application's, in place of the token.
    static let clientKey = "\(clientDirectory)/key"
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
    /// The API keys' digests (APIKeys).
    static let keys = "\(config)/keys.json"
    static let serverConfig = "\(config)/server.json"
    static let leases = "\(state)/leases.json"
    /// UTM's VM bases as last listed.
    static let vmBases = "\(state)/vm-bases.json"
    static let uploads = "\(state)/uploads"
    /// The last day of usage, a sample a minute.
    static let usageHistory = "\(state)/usage-history.json"
    /// The macOS VMs' bases (OS Server's own, run by Apple's
    /// Virtualization framework) and their leases' clones.
    static let machines = "\(share)/Machines"
    /// The iOS bases' setup scripts, by path (`<config>.json`): what a
    /// lease of another device type is set up with.
    static let simulators = "\(share)/Simulators"
    /// The containers' kernel, images and root filesystems
    /// (Containerization's store).
    static let containers = "\(share)/Containers"
    /// Files served by their SHA-256 (ServedFiles: `oss files add`), and
    /// the store's objects beside them (StorageStore), in `sha256/`.
    static let files = "\(share)/Files"
    /// The holders' leases on the store's objects.
    static let storageLeases = "\(state)/storage-leases.json"
    /// The key grants are signed with (Grants), made the first time.
    static let grantKey = "\(config)/grant-key"
    /// What CI's jobs are run with (CIRunnerKit): GitHub's runner, as
    /// downloaded, and the Linux command line, as built.
    static let ci = "\(share)/CI"

    /// OS Server's own SSH key, which its bases trust (made the first time
    /// it's needed). A server set up before 0.9 keeps using the user's
    /// (`managementKey` in server.json, written by `migrate`).
    static let ownKey = "\(support)/ssh/id_ed25519"

    /// What comes inside OS Server.app (`Contents/<path>`): its provisioning
    /// scripts, AXe. Found from the running program, the app's or the
    /// command line's inside it (Contents/MacOS, Contents/Helpers); nil when
    /// it doesn't run from the app.
    static func bundled(_ path: String) -> String? {
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                let found = url.appendingPathComponent("Contents").appendingPathComponent(path).path
                return FileManager.default.fileExists(atPath: found) ? found : nil
            }
        }
        return nil
    }

    /// The layers' scripts (`provision/<platform>/<layer>`): the app's, or
    /// a checkout's (`OSS_REPO`, ~/Developer/oss) when run from one.
    static var provisioning: String {
        if let repo = ProcessInfo.processInfo.environment["OSS_REPO"] { return "\(repo)/provision" }
        return bundled("Resources/provision") ?? "\(home)/Developer/oss/provision"
    }

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
        if settings["managementKey"] == nil, manager.fileExists(atPath: "\(home)/.ssh/id_ed25519") {
            settings["managementKey"] = "\(home)/.ssh/id_ed25519"
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
    /// The MCP server's port (API 12), on every interface: oss's tools for
    /// agents over Streamable HTTP, each call made with its caller's key.
    /// 0 for none.
    var mcpPort: Int = 7481
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
    /// The key the server reaches its VM guests with (the bases trust its
    /// public half): OS Server's own (Paths.ownKey), or the one a server
    /// set up before 0.9 used.
    var managementKey: String = Paths.ownKey
    var guestUser: String = "runner"
    /// The config a lease gets when it names none, by platform.
    var defaultConfig: [String: String] = ["macos": "vanilla", "windows": "vanilla", "linux": "vanilla", "ios": "iphone", "android": "phone",
                                           "container": "linux"]
    /// The Android SDK oss sets up (`oss setup android`), and its AVDs.
    var androidSDK: String = "\(Paths.share)/android-sdk"
    var androidAVDHome: String = "\(Paths.share)/avd"
    /// A Bazel cache (Cache.swift), when set.
    var cache: CacheConfig?
    /// The store's caps (Storage.swift); the store is kept without it too.
    var storage: StorageConfig?
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
    /// Whether to use UTM (its Linux and Windows bases, and macOS bases OS
    /// Server hasn't got of its own): by default, where UTM is installed (a
    /// server set up before 0.9). OS Server makes its own bases without it.
    var useUTM: Bool = FileManager.default.fileExists(atPath: "/Applications/UTM.app")
    /// CI's jobs in containers (CISettings): the repositories it runs them
    /// for. Off without it, or without the GitHub App's files.
    var ci: CISettings?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServerConfig()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        mcpPort = try c.decodeIfPresent(Int.self, forKey: .mcpPort) ?? d.mcpPort
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
        storage = try c.decodeIfPresent(StorageConfig.self, forKey: .storage)
        axePath = try c.decodeIfPresent(String.self, forKey: .axePath)
        headlessVMs = try c.decodeIfPresent(Bool.self, forKey: .headlessVMs) ?? d.headlessVMs
        lends = try c.decodeIfPresent([Platform].self, forKey: .lends)
        useUTM = try c.decodeIfPresent(Bool.self, forKey: .useUTM) ?? d.useUTM
        ci = try c.decodeIfPresent(CISettings.self, forKey: .ci)
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

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClientConfig {
        if let env = environment["OSS_SERVERS"] {
            return ClientConfig(servers: env.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        // A CI job's grant names its server.
        if let server = JobGrantEnvironment.server(environment) { return ClientConfig(servers: [server]) }
        guard let data = FileManager.default.contents(atPath: Paths.clientConfig),
              let config = try? JSONDecoder().decode(ClientConfig.self, from: data) else { return ClientConfig() }
        return config
    }
}

enum Token {
    /// What a client shows the API, as it finds it: a CI job's grant
    /// (`OSS_GRANT`, API 13: what a job's container has, and nothing
    /// else), else an API key (`OSS_API_KEY`, else `~/.config/oss/key`),
    /// else the shared token (`OSS_TOKEN`, else `~/.config/oss/token`, else
    /// on the server's own computer the server's), which stands for the
    /// `user` application through 0.14.
    static func read() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let grant = JobGrantEnvironment.token(environment) { return grant }
        if let key = environment["OSS_API_KEY"], !key.isEmpty { return key }
        if let key = file(Paths.clientKey) { return key }
        if let env = environment["OSS_TOKEN"], !env.isEmpty { return env }
        return file(Paths.clientToken) ?? file(Paths.token)
    }

    /// Who the client acts for within its application (`OSS_CLIENT_ID`): a
    /// CI job, a session; what it leases is `<CLIENT_ID>@<application>`'s.
    static func clientID() -> String? {
        guard let id = ProcessInfo.processInfo.environment["OSS_CLIENT_ID"]?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        return id
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

/// A CI job's grant (API 13) as its container's environment carries it:
/// `OSS_GRANT`, a URL on the job's server
/// (`http://<host>:7480/v1/machines?grant=…`). The client sends the grant
/// as its bearer to that server (unless OSS_SERVERS names others), and acts
/// for the grant's holder, the job (`<job>-<run>@ci`): the server holds it
/// to that holder whatever the client says.
enum JobGrantEnvironment {
    static func url(_ environment: [String: String]) -> URLComponents? {
        guard let text = environment["OSS_GRANT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let components = URLComponents(string: text), components.host?.isEmpty == false else { return nil }
        return components
    }

    /// The grant itself: its URL's `grant`.
    static func token(_ environment: [String: String]) -> String? {
        guard let value = url(environment)?.queryItems?.first(where: { $0.name == "grant" })?.value, !value.isEmpty else { return nil }
        return value
    }

    /// Its server: the URL's scheme, host and port.
    static func server(_ environment: [String: String]) -> String? {
        guard let url = url(environment), token(environment) != nil, let host = url.host else { return nil }
        return "\(url.scheme ?? "http")://\(host.contains(":") ? "[\(host)]" : host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// Whom it acts for, as its claims say (read, not checked: the server
    /// checks them).
    static func holder(_ environment: [String: String]) -> String? {
        guard let token = token(environment), let payload = token.split(separator: ".").first,
              let data = Data(base64URL: String(payload)), let claims = try? JSONDecoder().decode(GrantClaims.self, from: data) else { return nil }
        return claims.holder
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

/// The key OS Server reaches its VMs with. A new server makes its own
/// (Paths.ownKey: in its folder, gone with it); one set up before 0.9,
/// whose bases trust the user's ~/.ssh/id_ed25519, keeps that (written into
/// its server.json once).
enum ManagementKey {
    static func settle() {
        let manager = FileManager.default
        let userKey = "\(Paths.home)/.ssh/id_ed25519"
        var settings = (manager.contents(atPath: Paths.serverConfig)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        // Bases or leases from before (UTM's are listed in vm-bases.json): they trust the user's key.
        let setUpBefore = manager.fileExists(atPath: Paths.machines) || manager.fileExists(atPath: Paths.leases)
            || manager.fileExists(atPath: Paths.vmBases)
        if settings["managementKey"] == nil, setUpBefore, !manager.fileExists(atPath: Paths.ownKey),
           manager.fileExists(atPath: userKey) {
            settings["managementKey"] = userKey
            if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
                Paths.ensure(Paths.config)
                manager.createFile(atPath: Paths.serverConfig, contents: data, attributes: [.posixPermissions: 0o600])
            }
            log("its bases trust \(userKey): kept as the management key")
        }
        let key = ServerConfig.load().managementKey
        guard key == Paths.ownKey, !manager.fileExists(atPath: key) else { return }
        Paths.ensure((key as NSString).deletingLastPathComponent)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "OS Server on \(localHostName)", "-f", key]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            log("made OS Server's own SSH key")
        } catch {
            log("couldn't make an SSH key: \(error)")
        }
    }
}
