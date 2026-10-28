import Foundation
import OSSClient

let usage = """
    oss — OS Server: lend macOS, Linux and Windows VMs, iOS simulators, Android emulators and Linux containers.

    Machines (a VM, a simulator, an emulator or a container of your own until you release it or its time runs out):
      oss machine lease <macos|ios|android|linux|windows> [--config=NAME] [--minutes=N] [--wait] [--json | --exports]
      oss machine lease container --image=REF [--cpus=N] [--memory=GB] [--disk=GB] [--mount=/mac/path:/path[:ro]]…
                                  [--volume=NAME:/path:GB[:keep]]… [--rosetta] [--env=NAME=VALUE]… [--workdir=DIR]
                                  [--command="…"] [--minutes=0]
                                                            a container on the server's Mac, for a client on that Mac
                                                            (--minutes=0: held until released); it outlives the server's
                                                            restarts, and after the Mac's starts again from its own disk
      oss machine renew <id | platform> [--minutes=N]       its time set to N minutes from now (default 60, at most 480)
      oss machine release <id | platform>                   given back: the clone is deleted
      oss machine list
      oss machine ssh <id> [-- command…]                    macOS, Linux, Windows
      oss machine vnc <id> [--open]                         macOS, Linux, Windows: its VNC address and password
      oss machine exec <id | --socket=PATH> [--tty] [--env=NAME=VALUE]… [--env-file=F] [--workdir=DIR] -- command…
                                                            a container: the command run in it, streamed, signals passed on
                                                            (--socket: the lease's execSocket, no server or token needed)
      oss volume list | delete <name>                       containers' volumes, kept ones too
    Storage (files kept on the server by their SHA-256 while a lease of yours holds them, 24h unless --ttl, at most 7d):
      oss storage put <file> [--name=N] [--ttl=24h] [--json]
                                                            kept once however often it's put; its bytes go only if the
                                                            server hasn't got them; a name of yours moves to it
      oss storage get <sha256 | name> [out]                 to out (else its name, or its sha256)
      oss storage ls [--json]                               your leases: object, size, name, until when
      oss storage renew <id | name> [--ttl=24h]             its time set again
      oss storage rm <id | name>                            released; the object goes once no lease holds it
      oss storage put <file> --url=GRANT                    with a storage.put grant, no token (its name and TTL)
      oss storage get --url=GRANT [out]                     with a storage.get grant, no token
    Grants (a URL that does one thing, on a lease or object of yours, for 5 minutes unless --ttl, at most 15):
      oss grant storage.put [--name=N] [--object-ttl=24h] [--ttl=5m] [--json]
      oss grant storage.get <sha256 | name> [--ttl=5m] [--json]
      oss grant machine.install <id | ios> [--ttl=5m] [--json]
    What this Mac lends (on the server's Mac; the app's Settings › Components):
      oss component list                                    each component: installed, or not, or why not here
      oss component install <id> [--file=PATH]              macos, linux, windows (--file= its ISO), android, ios
      oss component remove <id>                             what it installed deleted (refused while a lease uses it)
      oss machine simctl <id> <simctl arguments…>          iOS: install ./My.app, launch <bundle id>, openurl …
      oss machine install <id> <sha256 | name>              iOS: an .ipa or zipped .app of yours from storage installed
      oss machine install --url=GRANT <sha256 | name>       the same with a machine.install grant, no token
      oss machine adb <id> <adb arguments…>                 Android: install ./app.apk, shell …, logcat -d …
      oss machine screenshot <id> <file.png>                any lease
      oss machine tap <id> <x> <y>                          any lease, in its screenshot's pixels
      oss machine swipe <id> <x> <y> <to x> <to y> [--ms=300]
      oss machine type <id> <text…>                         typed into what has focus
      oss machine key <id> <key>                            return, tab, escape, backspace, delete, space, up, down,
                                                            left, right, pageup, pagedown, home, back; on a VM cmd+a…
      oss machine upload <id> <local> <remote>              macOS, Linux, Windows (scp; a directory too)
      oss machine download <id> <remote> <local>
      oss machine run <platform> [--config=NAME] [--minutes=N] -- command…   (a 5-minute lease renewed while it runs;
                                                            SIGTERM releases it at once)
      oss machine run container --image=REF [lease options…] --inside [--cache=HOST] [--netrc=HOST]… [--env=…] -- command…
                                                            the command in the container, in this folder (mount it
                                                            at its own path), the lease released after (CI); --cache:
                                                            its Bazel reads this server's cache at HOST (~/.bazelrc,
                                                            the read token in ~/.netrc); --netrc: the token for HOST
                                                            lease, run the command with OSS_* set, release
    The server and its bases (on the server's Mac):
      oss serve | status | capabilities | doctor
      oss usage [--json]                                    the server's CPU and memory, and each lease's
      oss setup android [--api=35] [--tag=google_apis]     the Android SDK (emulator, platform-tools, a system image)
      oss image build <macos|linux|windows> <config> --from=<base config> [--script=PATH] [--copy=HOST:GUEST]
      oss image build ios <config> [--device="iPhone 17 Pro"] [--runtime=ID] [--script=PATH]
      oss image build android <config> [--api=35] [--tag=google_apis] [--script=PATH]
      oss image install macos [config] [--ipsw=PATH] [--cpus=6] [--memory=16] [--disk=128]
                                                            OS Server's own macOS base (Virtualization's), installed
                                                            and runner made with no one at its screen (macOS 27)
      oss image install linux [config] [--image=PATH] [--cpus=6] [--memory=8] [--disk=128]
                                                            OS Server's own Ubuntu base (its QEMU's), from Ubuntu's
                                                            cloud image (downloaded and checked), GNOME and runner
                                                            set up by cloud-init
      oss image install windows [config] --iso=PATH [--edition="Windows 11 Pro"] [--cpus=6] [--memory=8] [--disk=128]
                                                            OS Server's own Windows base (its QEMU's) from Windows 11
                                                            on Arm's ISO, installed by an answer file
      oss image import-utm <UTM VM name>… [--as=CONFIG]     UTM's macOS VMs as OS Server's own bases (APFS clones)
      oss image provision-macos --vm=NAME [--install]       a UTM VM's (before OS Server ran its own)
    OS Monitor (OS Server's client: reads what the server is doing, nothing else):
      oss monitor code [--new]                              its connection code (piped, never shown; --new: a new token)
    The Bazel cache (a server's with "cache" in its server.json; its populate job writes, everyone else reads):
      oss cache status                                      its size, and how many lookups it answered
      oss cache use [--remove]                              this computer's Bazel reads it (~/.bazelrc, the token in ~/.netrc)
      oss cache token --write | <what keeps it>             a token (the server's Mac only; piped, never shown)
      oss cache serve                                       the cache alone (to try one, with an OSS_HOME of its own)
    Files served by their SHA-256 on the cache's port (pinned Bazel dependencies; the cache's read token):
      oss files add <path>                                  hashed and kept (never evicted); prints its URL
      oss files list                                        what this server serves
      oss files remove <sha256>
    Tools for programs that speak the Model Context Protocol:
      oss mcp                                               an MCP server on stdio: lease, use and release machines

    Configs: what the server has bases for (oss status lists them); oss makes vanilla ones. Settings:
    ~/.config/oss/client.json {"servers": [...]} (or OSS_SERVERS), tried in order; the token in ~/.config/oss/token
    (or OSS_TOKEN). Holder: OSS_HOLDER, else user@host.
    """

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var rest: [String] = []
    /// Every value an option was given, where it may be given more than once (`--mount`, `--env`).
    var all: [String: [String]] = [:]

    init(_ arguments: [String], valued: Set<String>) {
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a == "--" { rest = Array(arguments[(i + 1)...]); break }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    options[String(body[..<equals])] = String(body[body.index(after: equals)...])
                    all[String(body[..<equals]), default: []].append(String(body[body.index(after: equals)...]))
                } else if valued.contains(body), i + 1 < arguments.count {
                    options[body] = arguments[i + 1]; i += 1
                    all[body, default: []].append(arguments[i])
                } else {
                    flags.insert(body)
                }
            } else {
                positional.append(a)
                // `machine simctl|adb <id> …`: the rest is the device
                // command's, its own options too (`am start --es key value`).
                if positional.count == 3, positional[0] == "machine", ["simctl", "adb"].contains(positional[1]) {
                    rest = Array(arguments[(i + 1)...])
                    if rest.first == "--" { rest.removeFirst() }
                    break
                }
            }
            i += 1
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("oss: \(message)\n".utf8))
    exit(1)
}

func defaultKey() -> String? {
    ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"].map { "\(Paths.home)/.ssh/\($0)" }
        .first { FileManager.default.fileExists(atPath: $0) }
}

func holderName() -> String {
    ProcessInfo.processInfo.environment["OSS_HOLDER"]
        ?? "\(NSUserName())@\(localHostName.components(separatedBy: ".")[0])"
}

func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

func minutesLeft(_ date: Date) -> Int { max(0, Int(date.timeIntervalSinceNow / 60)) }

func printJSON(_ value: some Encodable) throws { print(String(decoding: try JSONEncoder.oss.encode(value), as: UTF8.self)) }

/// How to reach a lease, for whoever holds it.
func describe(_ lease: Lease, _ client: OSSClient) -> String {
    let env = client.environment(lease)
    var lines = ["lease \(lease.id): \(lease.platform.rawValue) (\(lease.config)), valid until \(iso(lease.expires)) (\(minutesLeft(lease.expires)) min)"]
    switch lease.platform {
    case .macos, .linux, .windows:
        lines.append("  ssh:  \(env["OSS_SSH"]!)")
        lines.append("  vnc:  \(env["OSS_VNC"]!)  password \(lease.vncPassword ?? "")")
    case .ios:
        lines.append("  simulator \(lease.udid ?? "") on \(client.host)")
        lines.append("  oss machine simctl \(lease.id) install ./My.app | launch <bundle id> | openurl <url> | ...")
        if client.host == "127.0.0.1" { lines.append("  (on this Mac: xcrun simctl … \(lease.udid ?? ""))") }
    case .android:
        lines.append("  adb connect \(env["OSS_ADB"]!)   (then adb -s \(env["OSS_ADB"]!) …)")
        lines.append("  or: oss machine adb \(lease.id) install ./app.apk | shell … | logcat -d")
    case .container:
        lines.append("  \(lease.container?.image ?? "a container") on \(client.host)")
        lines.append("  oss machine exec \(lease.id) [--tty] -- <command>")
    }
    lines.append("  screenshot: oss machine screenshot \(lease.id) screen.png")
    lines.append("  renew: oss machine renew \(lease.id)    release: oss machine release \(lease.id)")
    return lines.joined(separator: "\n")
}

func printInstalled(_ result: InstallResult) {
    print("installed \(result.app)" + (result.bundleIdentifier.map { " (\($0))" } ?? "") + " from \(result.object)")
}

/// A storage lease of the holder's, by its id or its name (the newest with it).
func resolveStorageLease(_ argument: String?, _ client: OSSClient, holder: String) async throws -> StorageLease {
    guard let argument else { fail("which lease? its id or its name (oss storage ls)") }
    let mine = try await client.storageLeases(holder: holder)
    guard let lease = mine.first(where: { $0.id == argument }) ?? mine.last(where: { $0.name == argument }) else {
        fail("\(holder) holds no storage lease \(argument) (oss storage ls)")
    }
    return lease
}

func describe(_ lease: StorageLease) -> String {
    "\(lease.id)  \(lease.sha256)  \(ByteCountFormatter.string(fromByteCount: lease.size, countStyle: .file))  \(lease.name ?? "-")  until \(iso(lease.expires))"
}

/// A secret goes to a file or a pipe, never to the screen.
func refuseTerminal(_ message: String) {
    if isatty(STDOUT_FILENO) != 0 { fail(message) }
}

func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func leaseRequest(_ args: Arguments, platformArgument: String?) -> LeaseRequest {
    guard let name = platformArgument, let platform = Platform(rawValue: name) else {
        fail("which platform? macos, ios, android, linux, windows or container")
    }
    let keyPath = args.options["key"] ?? defaultKey()
    let key = keyPath.flatMap { FileManager.default.contents(atPath: $0) }
        .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    return LeaseRequest(platform: platform, config: args.options["config"], minutes: args.options["minutes"].flatMap(Int.init),
                        holder: args.options["holder"] ?? holderName(), sshPublicKey: platform == .container ? nil : key,
                        container: platform == .container ? containerSpec(args) : nil)
}

/// A container lease's spec from its options; GB as 2³⁰ bytes.
func containerSpec(_ args: Arguments) -> ContainerSpec {
    guard let image = args.options["image"] else { fail("a container lease names its image: --image=REF") }
    func gigabytes(_ option: String) -> Int64? {
        args.options[option].map { value in
            guard let number = Double(value) else { fail("--\(option)=GB") }
            return Int64(number * Double(1 << 30))
        }
    }
    let volumes = (args.all["volume"] ?? []).map { value -> ContainerVolume in
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count == 3 || (parts.count == 4 && parts[3] == "keep"), let size = Double(parts[2]) else {
            fail("--volume=NAME:/path:GB[:keep]")
        }
        return ContainerVolume(name: parts[0], destination: parts[1], sizeBytes: Int64(size * Double(1 << 30)), keep: parts.count == 4)
    }
    let mounts = (args.all["mount"] ?? []).map { value -> ContainerMount in
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count == 2 || (parts.count == 3 && parts[2] == "ro") else { fail("--mount=/mac/path:/path[:ro]") }
        let source = URL(fileURLWithPath: parts[0]).standardizedFileURL.path
        return ContainerMount(source: source, destination: parts[1], readOnly: parts.count == 3)
    }
    var environment: [String: String] = [:]
    for pair in args.all["env"] ?? [] {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("--env=NAME=VALUE") }
        environment[parts[0]] = parts[1]
    }
    return ContainerSpec(image: image, cpus: args.options["cpus"].flatMap(Int.init), memoryBytes: gigabytes("memory"),
                         diskBytes: gigabytes("disk"), mounts: mounts, volumes: volumes, rosetta: args.flags.contains("rosetta"),
                         environment: environment,
                         workingDirectory: args.options["workdir"],
                         command: args.options["command"].map { $0.split(separator: " ").map(String.init) })
}

/// A lease named by its id, or by its platform when the caller holds just one of it.
func resolveLease(_ argument: String?, _ client: OSSClient) async throws -> Lease {
    guard let argument else { fail("which lease? its id, or a platform you hold one lease of") }
    if let platform = Platform(rawValue: argument) {
        let mine = try await client.leases()
            .filter { $0.platform == platform && $0.holder == holderName() && $0.state != .returning && $0.state != .failed }
        guard mine.count == 1 else { fail("you hold \(mine.count) \(platform.rawValue) leases: name one by its id") }
        return mine[0]
    }
    return try await client.lease(argument)
}

/// The `oss` command line: everything it does, client and server alike
/// (`oss serve` runs the server in this process). The `oss` executable is
/// this and nothing else; the OS Server app hosts the server itself
/// (`ServerHost`) and ships this beside it as its command line.
public enum OSSCommand {
    #if canImport(Network)
    /// A container's home made ready for this server's cache, through its
    /// exec socket: the read token in ~/.netrc, a line for each host its
    /// builds name the server by (Bazel's downloader and HTTP cache read
    /// credentials there; never on a command line), and with `cacheHost`,
    /// ~/.bazelrc reading the cache there read-only, as a VM lease's has.
    static func prepareHome(socket: String, netrcHosts: [String], cacheHost: String?, client: OSSClient) async throws {
        let cache = try await client.cache()
        guard !cache.readToken.isEmpty else { throw OSSError(status: 0, message: "this server keeps no cache: no token for --netrc or --cache") }
        func append(_ text: String, to file: String) async throws {
            let (input, continuation) = AsyncStream<ExecFrame>.makeStream()
            continuation.yield(.stdin(Data(text.utf8)))
            continuation.yield(.closeStdin)
            continuation.finish()
            let request = ExecRequest(arguments: ["sh", "-c", "umask 077 && cat >> \"$HOME/\(file)\""])
            let status = try await OSSClient.exec(socket: socket, request, input: input) { _ in }
            guard status == 0 else { throw OSSError(status: 0, message: "couldn't write the container's ~/\(file) (\(status))") }
        }
        try await append(netrcHosts.map { CacheClientFiles.netrcEntry(host: $0, token: cache.readToken) + "\n" }.joined(), to: ".netrc")
        if let cacheHost {
            try await append("build --remote_cache=http://\(cacheHost):\(cache.port) --noremote_upload_local_results\n", to: ".bazelrc")
        }
    }
    #endif

    public static func run(_ commandLine: [String]) async -> Never {
        // A closed pipe or socket is an error to handle, not the end of `oss`.
        signal(SIGPIPE, SIG_IGN)
        let arguments = Arguments(Array(commandLine.dropFirst()),
                                  valued: ["config", "minutes", "key", "holder", "identity", "from", "script", "vm", "device", "runtime",
                                           "api", "tag", "copy", "image", "cpus", "memory", "disk", "mount", "volume", "env", "env-file", "workdir",
                                           "command", "socket", "iso", "edition", "file", "netrc", "cache", "name", "ttl", "url",
                                           "object-ttl"])
        let command = arguments.positional.first ?? "help"
        let sub = arguments.positional.count > 1 ? arguments.positional[1] : nil
        let target = arguments.positional.count > 2 ? arguments.positional[2] : nil

        // `--help` or `-h` anywhere: the usage, and nothing done (a subcommand's
        // `--help` once started a container).
        if arguments.flags.contains("help") || arguments.positional.contains("-h") {
            print(usage)
            exit(0)
        }

        do {
            switch command {
            case "machine":
                #if canImport(Network)
                // A container's socket given: straight to it, no server (nor token) needed.
                if sub == "exec", let socket = arguments.options["socket"] {
                    exit(try await ExecCommand.run(socket: socket, arguments))
                }
                #endif
                // A grant's URL given: it is the credential (and names the lease).
                if sub == "install", let url = arguments.options["url"] {
                    guard let grant = URL(string: url), let object = target else { fail("oss machine install --url=GRANT <sha256 | name>") }
                    printInstalled(try await OSSGrantClient(url: grant, transport: cliTransport()).install(object: object))
                    exit(0)
                }
                let client = try await OSSClient.connect()
                switch sub {
                case "install":
                    guard arguments.positional.count >= 4 else { fail("oss machine install <id> <sha256 | name>") }
                    let lease = try await resolveLease(target, client)
                    printInstalled(try await client.install(lease.id, object: arguments.positional[3]))
                case "lease":
                    let lease = try await client.leaseForTerminal(leaseRequest(arguments, platformArgument: target),
                                                                 waitForCapacity: arguments.flags.contains("wait"))
                    if arguments.flags.contains("json") {
                        try printJSON(lease)
                    } else if arguments.flags.contains("exports") {
                        for (key, value) in client.environment(lease).sorted(by: { $0.key < $1.key }) { print("export \(key)=\(shellQuote(value))") }
                    } else {
                        print(describe(lease, client))
                    }
                case "renew":
                    let lease = try await client.renew(try await resolveLease(target, client).id, minutes: arguments.options["minutes"].flatMap(Int.init))
                    print("lease \(lease.id): valid until \(iso(lease.expires)) (\(minutesLeft(lease.expires)) min)")
                case "release":
                    let lease = try await resolveLease(target, client)
                    try await client.release(lease.id)
                    try? FileManager.default.removeItem(atPath: OSSClient.knownHosts(lease.id))
                    print("lease \(lease.id) released: \(lease.name) is being deleted")
                case "list":
                    for lease in try await client.leases() {
                        print("\(lease.id)  \(lease.platform.rawValue)/\(lease.config)  \(lease.state.rawValue)  \(lease.holder)  until \(iso(lease.expires))")
                    }
                case "ssh":
                    let lease = try await resolveLease(target, client)
                    exit(try Shell.passthrough("/usr/bin/ssh", client.sshArguments(lease, identity: arguments.options["identity"]) + arguments.rest))
                case "exec":
                    #if canImport(Network)
                    let lease = try await resolveLease(target, client)
                    guard lease.platform == .container, let socket = lease.execSocket else {
                        fail("exec is for a ready container lease: a VM takes ssh, a simulator simctl, an emulator adb")
                    }
                    exit(try await ExecCommand.run(socket: socket, arguments))
                    #else
                    fail("exec runs on the container's Mac")
                    #endif
                case "vnc":
                    let lease = try await resolveLease(target, client)
                    let url = "vnc://\(client.host):\(lease.vncPort ?? 0)"
                    print("\(url)  password \(lease.vncPassword ?? "")")
                    if arguments.flags.contains("open") { _ = try Shell.passthrough("/usr/bin/open", [url]) }
                case "simctl", "adb":
                    let lease = try await resolveLease(target, client)
                    let result = try await client.deviceCommandUploading(lease, Array(arguments.positional.dropFirst(3)) + arguments.rest)
                    print(result.output, terminator: "")
                    FileHandle.standardError.write(Data(result.error.utf8))
                    exit(result.status)
                case "tap", "swipe", "type", "key":
                    let lease = try await resolveLease(target, client)
                    let values = Array(arguments.positional.dropFirst(3))
                    func number(_ i: Int) -> Double {
                        guard i < values.count, let value = Double(values[i]) else { fail("oss machine \(sub!) <id> …: see oss --help") }
                        return value
                    }
                    let request: InputRequest
                    switch sub {
                    case "tap": request = InputRequest(action: .tap, x: number(0), y: number(1))
                    case "swipe":
                        request = InputRequest(action: .swipe, x: number(0), y: number(1), toX: number(2), toY: number(3),
                                               milliseconds: arguments.options["ms"].flatMap(Int.init))
                    case "type":
                        let text = (values + arguments.rest).joined(separator: " ")
                        guard !text.isEmpty else { fail("oss machine type <id> <text…>") }
                        request = InputRequest(action: .type, text: text)
                    default:
                        guard let key = values.first else { fail("oss machine key <id> <key>") }
                        request = InputRequest(action: .key, key: key)
                    }
                    try await client.input(lease.id, request)
                case "upload", "download":
                    guard arguments.positional.count >= 5 else { fail("oss machine \(sub!) <id> <from> <to>") }
                    let lease = try await resolveLease(target, client)
                    guard lease.platform.isVM else { fail("upload and download are for VMs: a simulator takes simctl, an emulator adb push") }
                    let remote = "\(lease.sshUser ?? "runner")@\(client.host):"
                    let (from, to) = sub == "upload"
                        ? (arguments.positional[3], remote + arguments.positional[4])
                        : (remote + arguments.positional[3], arguments.positional[4])
                    var scp = ["-q", "-r", "-P", String(lease.sshPort ?? 22), "-o", "UserKnownHostsFile=\(OSSClient.knownHosts(lease.id))",
                               "-o", "StrictHostKeyChecking=accept-new"]
                    if let identity = arguments.options["identity"] { scp += ["-i", identity] }
                    exit(try Shell.passthrough("/usr/bin/scp", scp + [from, to]))
                case "screenshot":
                    guard arguments.positional.count >= 4 else { fail("oss machine screenshot <id> <file.png>") }
                    let lease = try await resolveLease(target, client)
                    try await client.screenshot(lease.id).write(to: URL(fileURLWithPath: arguments.positional[3]))
                    print(arguments.positional[3])
                case "run":
                    guard !arguments.rest.isEmpty else { fail("oss machine run <platform> [options] -- command…") }
                    // A short lease, renewed while the command runs: when this
                    // process is killed outright (a CI runner's SIGKILL, after its
                    // SIGINT and SIGTERM), the lease ends within minutes, and its
                    // volumes are free again, not at the hour.
                    var request = leaseRequest(arguments, platformArgument: target)
                    let minutes = request.minutes ?? 5
                    request.minutes = minutes
                    let lease = try await client.leaseForTerminal(request, waitForCapacity: true)
                    let renewing = Task {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(min(600, max(30, minutes * 12))))
                            _ = try? await client.renew(lease.id, minutes: minutes)
                        }
                    }
                    // SIGTERM releases the lease and exits at once, the container's
                    // command with it: a runner cancelling a job sends SIGINT
                    // (forwarded into the container), then SIGTERM, then SIGKILL
                    // within seconds, before Bazel has stopped.
                    signal(SIGTERM, SIG_IGN)
                    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
                    terminate.setEventHandler {
                        Task {
                            renewing.cancel()
                            try? await client.release(lease.id)
                            FileHandle.standardError.write(Data("oss: lease \(lease.id) released (SIGTERM)\n".utf8))
                            exit(143)
                        }
                    }
                    terminate.resume()
                    let status: Int32
                    if arguments.flags.contains("inside") {
                        // In the container, in this folder (mounted at its own path), as `exec` runs it.
                        #if canImport(Network)
                        guard lease.platform == .container, let socket = lease.execSocket else {
                            renewing.cancel()
                            try? await client.release(lease.id)
                            fail("--inside is for a container lease")
                        }
                        do {
                            let cacheHost = arguments.options["cache"]
                            let hosts = (cacheHost.map { [$0] } ?? []) + (arguments.all["netrc"] ?? [])
                            if !hosts.isEmpty {
                                try await Self.prepareHome(socket: socket, netrcHosts: hosts, cacheHost: cacheHost, client: client)
                            }
                            var inside = arguments
                            inside.options["workdir"] = arguments.options["workdir"] ?? FileManager.default.currentDirectoryPath
                            status = try await ExecCommand.run(socket: socket, inside)
                        } catch {
                            status = 127
                            FileHandle.standardError.write(Data("oss: \(error)\n".utf8))
                        }
                        #else
                        fail("--inside runs on the container's Mac")
                        #endif
                    } else {
                        let environment = ProcessInfo.processInfo.environment.merging(client.environment(lease)) { $1 }
                        do { status = try Shell.passthrough("/usr/bin/env", arguments.rest, environment: environment) } catch {
                            status = 127
                            FileHandle.standardError.write(Data("oss: \(error)\n".utf8))
                        }
                    }
                    renewing.cancel()
                    try await client.release(lease.id)
                    try? FileManager.default.removeItem(atPath: OSSClient.knownHosts(lease.id))
                    exit(status)
                default:
                    print(usage)
                }

            case "component":
                #if os(macOS)
                // What this Mac lends, a component at a time (the app's Settings › Components).
                func show(_ list: [ComponentInfo]) {
                    for component in list {
                        let state: String
                        switch component.state {
                        case .absent: state = component.needsFile ? "not installed (from a file: --file=)" : "not installed"
                        case .installing(let line): state = "installing: \(line)"
                        case .installed: state = "installed"
                        case .unavailable(let why): state = "unavailable: \(why)"
                        case .failed(let why): state = "failed: \(why)"
                        }
                        print("\(component.id)\t\(component.name): \(state)")
                    }
                }
                switch sub {
                case "list", nil:
                    show(await Components.shared.list())
                case "install":
                    guard let target else { fail("oss component install <id> [--file=PATH]") }
                    await Components.shared.install(target, file: arguments.options["file"])
                    // Here, in this process: waited on until it's done.
                    while case .installing = await Components.shared.list().first(where: { $0.id == target })?.state {
                        try await Task.sleep(for: .seconds(5))
                    }
                    let done = await Components.shared.list().first { $0.id == target }
                    show(done.map { [$0] } ?? [])
                    if case .failed = done?.state { exit(1) }
                case "remove":
                    guard let target else { fail("oss component remove <id>") }
                    try await Components.shared.remove(target)
                    print("removed \(target)")
                default:
                    print(usage)
                }
                #else
                fail("components are OS Server's on a Mac")
                #endif

            case "files":
                // On the server's Mac, in its folder: nothing writes them over the network.
                let port = ServerConfig.load().cache?.port
                func url(_ hash: String) -> String { "http://\(localHostName):\(port ?? 7490)/files/sha256/\(hash)" }
                switch sub {
                case "add":
                    guard let target else { fail("oss files add <path>") }
                    let entry = try ServedFiles.add(target)
                    print("\(entry.name), \(gigabytes(entry.bytes)): sha256 \(entry.sha256)")
                    print("  \(url(entry.sha256))  (by this Mac's tailnet name too; the cache's read token)")
                    if port == nil { print("  this server keeps no cache: files are served on the cache's port once it has one") }
                case "list":
                    for entry in ServedFiles.list() {
                        print("\(entry.sha256)  \(gigabytes(entry.bytes))  \(entry.name)")
                    }
                case "remove":
                    guard let target else { fail("oss files remove <sha256>") }
                    try ServedFiles.remove(target)
                    print("\(target) is no longer served; the server's sweep deletes it unless a storage lease holds it")
                default:
                    print(usage)
                }

            case "storage":
                let holder = arguments.options["holder"] ?? holderName()
                // A grant's URL given: it is the credential, and says the holder, the object, the name and the TTL.
                if let url = arguments.options["url"] {
                    guard let grantURL = URL(string: url) else { fail("--url=<a grant's URL>") }
                    let grant = OSSGrantClient(url: grantURL, transport: cliTransport())
                    switch sub {
                    case "put":
                        guard let file = target, FileManager.default.fileExists(atPath: file) else { fail("oss storage put <file> --url=GRANT") }
                        let put = try await grant.put(file: URL(fileURLWithPath: file))
                        if arguments.flags.contains("json") { try printJSON(put) } else { print(describe(put.lease)) }
                    case "get":
                        let out = target ?? grantURL.lastPathComponent
                        try await grant.get(to: URL(fileURLWithPath: out))
                        print(out)
                    default:
                        fail("with --url: oss storage put <file> | get [out]")
                    }
                    exit(0)
                }
                let client = try await OSSClient.connect()
                switch sub {
                case "put":
                    var isDirectory: ObjCBool = false
                    guard let file = target, FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue else {
                        fail("oss storage put <file> [--name=N] [--ttl=24h] (a directory: zip it first)")
                    }
                    let put = try await client.putObject(file: URL(fileURLWithPath: file), holder: holder, name: arguments.options["name"],
                                                         ttl: arguments.options["ttl"])
                    if arguments.flags.contains("json") {
                        try printJSON(put)
                    } else {
                        print(describe(put.lease) + (put.existed ? "  (the server had it)" : ""))
                    }
                case "get":
                    guard let target else { fail("oss storage get <sha256 | name> [out]") }
                    let mine = try await client.storageLeases(holder: holder)
                    let lease = mine.first { $0.sha256 == target.lowercased() } ?? mine.last { $0.name == target }
                    let hash = lease?.sha256 ?? target.lowercased()
                    let out = arguments.positional.count > 3 ? arguments.positional[3]
                        : lease?.name.map { URL(fileURLWithPath: $0).lastPathComponent } ?? hash
                    try await client.downloadObject(hash, holder: holder, to: URL(fileURLWithPath: out))
                    print(out)
                case "ls", "list":
                    let mine = try await client.storageLeases(holder: holder)
                    if arguments.flags.contains("json") {
                        try printJSON(mine)
                    } else {
                        for lease in mine { print(describe(lease)) }
                    }
                case "renew":
                    let lease = try await resolveStorageLease(target, client, holder: holder)
                    print(describe(try await client.renewStorageLease(lease.id, holder: holder, ttl: arguments.options["ttl"])))
                case "rm", "release":
                    let lease = try await resolveStorageLease(target, client, holder: holder)
                    try await client.releaseStorageLease(lease.id, holder: holder)
                    print("lease \(lease.id) released: \(lease.sha256) goes once no lease holds it")
                default:
                    print(usage)
                }

            case "grant":
                // oss grant <verb> [<lease | object>]: a URL that does it, in this holder's name, without the token.
                let client = try await OSSClient.connect()
                let holder = arguments.options["holder"] ?? holderName()
                let ttl = arguments.options["ttl"]
                let request: GrantRequest
                switch sub {
                case "storage.put":
                    request = GrantRequest(verb: "storage.put", ttl: ttl, name: arguments.options["name"], objectTTL: arguments.options["object-ttl"])
                case "storage.get":
                    guard let target else { fail("oss grant storage.get <sha256 | name>") }
                    request = GrantRequest(verb: "storage.get", object: target, ttl: ttl)
                case "machine.install":
                    let lease = try await resolveLease(target, client)
                    request = GrantRequest(verb: "machine.install", lease: lease.id, ttl: ttl)
                default:
                    fail("oss grant storage.put | storage.get <sha256 | name> | machine.install <id>")
                }
                let grant = try await client.grant(request, holder: holder)
                if arguments.flags.contains("json") { try printJSON(grant) } else { print(grant.url.absoluteString) }

            case "volume":
                let client = try await OSSClient.connect()
                switch sub {
                case "list":
                    for volume in try await client.volumes() {
                        print("\(volume.name)  \(gigabytes(volume.sizeBytes)) (\(gigabytes(volume.allocatedBytes)) used)  \(volume.lease.map { "lease \($0)" } ?? "kept")")
                    }
                case "delete":
                    guard let target else { fail("oss volume delete <name>") }
                    try await client.deleteVolume(target)
                    print("volume \(target) deleted")
                default:
                    print(usage)
                }

            case "mcp":
                await MCPServer.run()
                exit(0)

            case "status":
                let client = try await OSSClient.connect()
                let status = try await client.status()
                if arguments.flags.contains("json") {
                    try printJSON(status)
                } else {
                    print("server \(status.server) (\(client.server.absoluteString))")
                    for platform in Platform.allCases {
                        let configs = status.bases.filter { $0.platform == platform }.map(\.config)
                        let capacity = status.capacity.first { $0.platform == platform }
                        print("  \(platform.rawValue): \(capacity?.leased ?? 0)/\(capacity?.limit ?? 0) leased; configs: \(configs.isEmpty ? "none" : configs.joined(separator: ", "))")
                    }
                    for lease in status.leases {
                        print("    \(lease.id)  \(lease.platform.rawValue)/\(lease.config)  \(lease.state.rawValue)  \(lease.holder)  until \(iso(lease.expires))")
                    }
                    if let storage = status.storage {
                        print("  storage: \(storage.objects) objects, \(gigabytes(storage.bytes)) of \(gigabytes(storage.maxBytes)) "
                              + "(\(gigabytes(storage.maxBytesPerHolder)) a holder), \(storage.leases) leases; "
                              + "\(storage.servedFiles) served files, \(gigabytes(storage.servedBytes))")
                    }
                }

            case "capabilities":
                try printJSON(try await OSSClient.connect().capabilities())

            case "usage":
                let client = try await OSSClient.connect()
                let usage = try await client.usage()
                if arguments.flags.contains("json") {
                    try printJSON(usage)
                } else {
                    let h = usage.host
                    print("\(h.name): CPU \(String(format: "%.0f", h.cpuPercent))% of \(h.cpus * 100)%, memory \(gigabytes(h.memoryUsedBytes)) of \(gigabytes(h.memoryBytes))")
                    for m in usage.machines {
                        let cpu = m.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "?"
                        let cpus = m.cpus.map { " of \($0 * 100)%" } ?? ""
                        let memory = m.memoryBytes.map(gigabytes) ?? "?"
                        let limit = m.memoryLimitBytes.map { " of \(gigabytes($0))" } ?? ""
                        print("  \(m.id)  \(m.platform.rawValue)/\(m.config)  CPU \(cpu)\(cpus), memory \(memory)\(limit)  \(m.holder)")
                    }
                }

            case "cache":
                switch sub {
                case "status":
                    let client = try await OSSClient.connect()
                    let cache = try await client.cache()
                    let lookups = cache.hits + cache.misses
                    print("Bazel cache at \(client.host):\(cache.port): \(gigabytes(cache.bytes)) of \(gigabytes(cache.maxBytes)), "
                          + "\(gigabytes(cache.freeBytes)) free on the server's disk")
                    print("  since the server started: \(cache.hits) of \(lookups) action lookups answered"
                          + (lookups > 0 ? " (\(cache.hits * 100 / lookups)%)" : "") + ", \(cache.writes) entries written, \(cache.evicted) evicted")
                case "use":
                    let client = try await OSSClient.connect()
                    let cache = try await client.cache()
                    let remove = arguments.flags.contains("remove")
                    try CacheClientFiles.use(host: client.host, port: cache.port, token: remove ? nil : cache.readToken)
                    print(remove ? "Bazel here no longer reads the cache (~/.bazelrc and ~/.netrc)"
                                 : "Bazel here reads the cache at http://\(client.host):\(cache.port) (~/.bazelrc; the token in ~/.netrc)")
                case "token":
                    let write = arguments.flags.contains("write")
                    guard write || arguments.flags.contains("read") else { fail("oss cache token --write | --read") }
                    guard let token = CacheTokens.read(write ? CacheTokens.writePath : CacheTokens.readPath) else {
                        fail("no cache token here: the server's Mac makes them when it first keeps a cache")
                    }
                    refuseTerminal("a token is a secret: pipe it into what keeps it (oss cache token --write | gh secret set …)")
                    print(token)
                #if canImport(Network)
                case "serve":
                    try await Server.serveCache()
                #endif
                default:
                    fail("oss cache status | use [--remove] | token --write|--read | serve")
                }

            case "monitor":
            // oss monitor code [--new]: OS Monitor's connection code for this
            // server (its link), piped, never shown; --new makes a new token.
            guard sub == "code" else { fail("oss monitor code [--new]") }
            refuseTerminal("the code holds the monitor token: pipe it (oss monitor code | pbcopy)")
            print(MonitorAccess.connection(newToken: arguments.flags.contains("new")).link.absoluteString)

        case "doctor":
                let client = try await OSSClient.connect()
                let report = try JSONDecoder.oss.decode([String: String].self, from: try await client.send("GET", "/v1/doctor").body)
                for (check, result) in report.sorted(by: { $0.key < $1.key }) { print("\(check): \(result)") }

            #if canImport(Network)
            case "serve":
                try await Server.serve()

            case "forward":
                // oss forward <local port> <host> <port> [vnc password]: a port of this Mac relayed (through nc).
                guard arguments.positional.count >= 4, let local = Int(arguments.positional[1]), let port = Int(arguments.positional[3]) else {
                    fail("oss forward <local port> <host> <port> [vnc password]")
                }
                let forwarder = try Forwarder(port: local, target: arguments.positional[2], targetPort: port,
                                              vncPassword: arguments.positional.count >= 5 ? arguments.positional[4] : nil)
                forwarder.start()
                log("forwarding :\(local) to \(arguments.positional[2]):\(port)")
                while true { try await Task.sleep(for: .seconds(3600)) }
            #endif

            #if canImport(CommonCrypto)
            case "vnc-shot":
                guard arguments.positional.count >= 5, let port = Int(arguments.positional[2]) else {
                    fail("oss vnc-shot <host> <port> <password> <file.png>")
                }
                try RFBScreenshot(host: arguments.positional[1], port: port, password: arguments.positional[3]).capture(to: arguments.positional[4])
                print(arguments.positional[4])
            #endif

            case "setup":
                switch sub {
                case "android":
                    try await Emulators.setup(api: Int(arguments.options["api"] ?? "") ?? 35, tag: arguments.options["tag"] ?? "google_apis")
                default:
                    fail("oss setup android")
                }

            case "image":
                ManagementKey.settle()
                #if canImport(Virtualization)
            if sub == "install", target == "linux" {
                // oss image install linux [config] [--image=PATH] [--cpus=N] [--memory=GB] [--disk=GB]
                try await LinuxInstaller.install(config: arguments.positional.count >= 4 ? arguments.positional[3] : "base",
                                                 image: arguments.options["image"],
                                                 cpus: Int(arguments.options["cpus"] ?? "") ?? 6,
                                                 memoryGB: Int(arguments.options["memory"] ?? "") ?? 8,
                                                 diskGB: Int(arguments.options["disk"] ?? "") ?? 128)
                exit(0)
            }
            if sub == "install", target == "windows" {
                // oss image install windows [config] --iso=PATH [--edition="Windows 11 Pro"] [--cpus=N] [--memory=GB] [--disk=GB]
                guard let iso = arguments.options["iso"] else { fail("oss image install windows [config] --iso=<Windows 11 on Arm's ISO>") }
                try await WindowsInstaller.install(config: arguments.positional.count >= 4 ? arguments.positional[3] : "base", iso: iso,
                                                   edition: arguments.options["edition"] ?? "Windows 11 Pro",
                                                   cpus: Int(arguments.options["cpus"] ?? "") ?? 6,
                                                   memoryGB: Int(arguments.options["memory"] ?? "") ?? 8,
                                                   diskGB: Int(arguments.options["disk"] ?? "") ?? 128)
                exit(0)
            }
            if sub == "install" {
                // oss image install macos [config] [--ipsw=PATH] [--cpus=N] [--memory=GB] [--disk=GB]
                guard target == "macos" else { fail("oss image install macos|linux [config] … (see oss --help)") }
                guard #available(macOS 27, *) else { fail("installing macOS with no one at its screen needs macOS 27 here") }
                try await MacInstaller.install(config: arguments.positional.count >= 4 ? arguments.positional[3] : "base",
                                               ipsw: arguments.options["ipsw"],
                                               cpus: Int(arguments.options["cpus"] ?? "") ?? 6,
                                               memoryGB: Int(arguments.options["memory"] ?? "") ?? 16,
                                               diskGB: Int(arguments.options["disk"] ?? "") ?? 128)
                exit(0)
            }
            #endif
            #if canImport(Virtualization)
            if sub == "import-utm" {
                // oss image import-utm <UTM VM name>… [--as=<config>]
                let names = Array(arguments.positional.dropFirst(2))
                guard !names.isEmpty else { fail("oss image import-utm <UTM VM name>… [--as=<config>]") }
                for name in names { try await MacImport.fromUTM(name, as: names.count == 1 ? arguments.options["as"] : nil) }
                exit(0)
            }
            #endif
            if sub == "provision-macos" {
                    guard let name = arguments.options["vm"] else { fail("oss image provision-macos --vm=<name> [--install]") }
                    if arguments.flags.contains("install") { setenv("OSS_INSTALL", "1", 1) }
                    try await Images.provisionMacOS(name: name)
                    exit(0)
                }
                guard sub == "build", let name = target, let platform = Platform(rawValue: name), arguments.positional.count >= 4 else { print(usage); exit(1) }
                let config = arguments.positional[3]
                switch platform {
                case .container:
                    fail("a container's image comes from a registry: nothing to build here")
                case .ios:
                    try await Simulators.build(config: config, deviceType: arguments.options["device"] ?? "iPhone 17 Pro",
                                               runtime: arguments.options["runtime"], script: arguments.options["script"])
                case .android:
                    try await Emulators.build(config: config, api: Int(arguments.options["api"] ?? "") ?? 35,
                                              tag: arguments.options["tag"] ?? "google_apis", script: arguments.options["script"])
                case .macos, .linux, .windows:
                    guard let base = arguments.options["from"] else { fail("oss image build \(name) <config> --from=<base config>") }
                    // --copy=HOST:GUEST[,HOST:GUEST…]: copied into the clone before its script runs.
                    let copies = (arguments.options["copy"] ?? "").split(separator: ",").compactMap { pair -> (String, String)? in
                        let halves = pair.split(separator: ":", maxSplits: 1).map(String.init)
                        return halves.count == 2 ? (halves[0], halves[1]) : nil
                    }
                    try await Images.build(platform: platform, layer: config, from: base, script: arguments.options["script"],
                                           copies: copies)
                }

            default:
                print(usage)
            }
        } catch {
            fail("\(error)")
        }
        exit(0)
    }
}
