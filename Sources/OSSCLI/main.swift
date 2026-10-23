import Foundation
import OSSClient

let usage = """
    oss — OS Server: lend macOS, Linux and Windows VMs, iOS simulators and Android emulators, and run Linux containers.

    Machines (a VM, a simulator or an emulator of your own until you release it or its time runs out):
      oss machine lease <macos|ios|android|linux|windows> [--config=NAME] [--minutes=N] [--wait] [--json | --exports]
      oss machine renew <id | platform> [--minutes=N]       its time set to N minutes from now (default 60, at most 480)
      oss machine release <id | platform>                   given back: the clone is deleted
      oss machine list
      oss machine ssh <id> [-- command…]                    macOS, Linux, Windows
      oss machine vnc <id> [--open]                         macOS, Linux, Windows: its VNC address and password
      oss machine simctl <id> <simctl arguments…>          iOS: install ./My.app, launch <bundle id>, openurl …
      oss machine adb <id> <adb arguments…>                 Android: install ./app.apk, shell …, logcat -d …
      oss machine screenshot <id> <file.png>                any lease
      oss machine run <platform> [--config=NAME] [--minutes=N] -- command…
                                                            lease, run the command with OSS_* set, release
    Containers (Linux, any image: Apple's container on a Mac, Podman or Docker on Linux):
      oss container start [--image=NAME] [--from=ARCHIVE] [--env-file=F] [--label=KEY=VALUE] [--cpus=N] [--memory=4g]
      oss container stop | archive | remove <id>
      oss container restart <id> [--env-file=F]             an archived one restored into a new container
      oss container exec <id> [--input] [--env-file=F] [--cwd=DIR] -- command…
                                                            a process in it, its output followed (--input: ours is its input)
      oss container cp <local> <id>:<path> | <id>:<path> <local>   files in and out of its home (/root)
      oss container list | shell <id> | logs <id>
    The server and its bases (on the server's Mac):
      oss serve | status | capabilities | doctor
      oss setup android [--api=35] [--tag=google_apis]     the Android SDK (emulator, platform-tools, a system image)
      oss setup containers                                  the default container image, pulled
      oss image build <macos|linux|windows> <config> --from=<base config> [--script=PATH] [--copy=HOST:GUEST]
      oss image build ios <config> [--device="iPhone 17 Pro"] [--runtime=ID] [--script=PATH]
      oss image build android <config> [--api=35] [--tag=google_apis] [--script=PATH]
      oss image build container <name> --dockerfile=PATH [--context=DIR]
      oss image provision-macos --vm=NAME [--install]
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

    init(_ arguments: [String], valued: Set<String>) {
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a == "--" { rest = Array(arguments[(i + 1)...]); break }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    options[String(body[..<equals])] = String(body[body.index(after: equals)...])
                } else if valued.contains(body), i + 1 < arguments.count {
                    options[body] = arguments[i + 1]; i += 1
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
    }
    lines.append("  screenshot: oss machine screenshot \(lease.id) screen.png")
    lines.append("  renew: oss machine renew \(lease.id)    release: oss machine release \(lease.id)")
    return lines.joined(separator: "\n")
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func leaseRequest(_ args: Arguments, platformArgument: String?) -> LeaseRequest {
    guard let name = platformArgument, let platform = Platform(rawValue: name) else {
        fail("which platform? macos, ios, android, linux or windows")
    }
    let keyPath = args.options["key"] ?? defaultKey()
    let key = keyPath.flatMap { FileManager.default.contents(atPath: $0) }
        .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    return LeaseRequest(platform: platform, config: args.options["config"], minutes: args.options["minutes"].flatMap(Int.init),
                        holder: args.options["holder"] ?? holderName(), sshPublicKey: key)
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

func describe(_ container: Container) -> String {
    var lines = ["container \(container.id): \(container.state.rawValue) (\(container.image ?? "the default image"), \(container.name))"]
    if container.state != .archived { lines.append("  home: /root, on its own disk; oss's folder at /oss") }
    if let labels = container.labels, !labels.isEmpty {
        lines.append("  labels: " + labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
    if let archive = container.archive, container.state == .archived {
        lines.append("  archived to: \(archive)")
        lines.append("  restore: oss container restart \(container.id)    copy it elsewhere: cp \(archive) …")
    }
    if container.state == .running {
        lines.append("  run something: oss container exec \(container.id) -- command…")
        if let host = container.hostAddress { lines.append("  this computer, from the container: \(host)") }
    }
    if let error = container.error { lines.append("  error: \(error)") }
    return lines.joined(separator: "\n")
}

/// Containers through the server, or right here when this computer has no
/// server to reach (Linux: Podman or Docker).
enum ContainerFront {
    case server(OSSClient)
    case local(ContainerManager)

    static func connect(_ args: Arguments) async -> ContainerFront {
        if !args.flags.contains("local"), let client = try? await OSSClient.connect() { return .server(client) }
        return .local(ContainerManager(config: ServerConfig.load()))
    }

    func list() async throws -> [Container] {
        switch self {
        case .server(let client): return try await client.containers()
        case .local(let manager): return await manager.list()
        }
    }

    func resolve(_ argument: String?) async throws -> Container {
        guard let argument else { fail("which container? its id") }
        guard let container = try await list().first(where: { $0.id == argument }) else { fail("no container \(argument)") }
        return container
    }

    func start(_ request: ContainerRequest) async throws -> Container {
        switch self {
        case .server(let client): return try await client.startContainer(request)
        case .local(let manager): return try await manager.start(request, archive: request.archive)
        }
    }

    func stop(_ id: String) async throws -> Container {
        switch self {
        case .server(let client): return try await client.stop(container: id)
        case .local(let manager): return try await manager.stop(id)
        }
    }

    func restart(_ id: String, environment: [String: String]?) async throws -> Container {
        switch self {
        case .server(let client): return try await client.restart(container: id, environment: environment)
        case .local(let manager): return try await manager.restart(id, environment: environment)
        }
    }

    func archive(_ id: String) async throws -> Container {
        switch self {
        case .server(let client): return try await client.archive(container: id)
        case .local(let manager): return try await manager.archive(id)
        }
    }

    func remove(_ id: String) async throws {
        switch self {
        case .server(let client): try await client.remove(container: id)
        case .local(let manager): try await manager.remove(id)
        }
    }

    func startProcess(_ id: String, _ request: ProcessRequest) async throws -> ContainerProcess {
        switch self {
        case .server(let client): return try await client.startProcess(id, request)
        case .local(let manager): return try await manager.startProcess(id, request)
        }
    }

    func process(_ id: String, _ process: String) async throws -> ContainerProcess {
        switch self {
        case .server(let client): return try await client.process(id, process)
        case .local(let manager): return try await manager.process(id, process)
        }
    }

    func output(_ id: String, _ process: String, stream: OSSClient.Stream, from offset: Int, wait: Int) async throws -> Data {
        switch self {
        case .server(let client): return try await client.output(id, process, stream: stream, from: offset, wait: wait).data
        case .local(let manager):
            return try await manager.output(id, process, stream: stream.rawValue, from: offset, limit: 4 << 20, wait: Double(wait)).0
        }
    }

    func input(_ id: String, _ process: String, _ data: Data, close: Bool) async throws {
        switch self {
        case .server(let client): try await client.input(id, process, data, close: close)
        case .local(let manager): try await manager.input(id, process, data: data, close: close)
        }
    }

    func readFile(_ id: String, _ path: String) async throws -> (data: Data, isDirectory: Bool) {
        switch self {
        case .server(let client): return try await client.readFile(id, path)
        case .local(let manager): return try await manager.readFile(id, path)
        }
    }

    func writeFile(_ id: String, _ path: String, _ data: Data, unpack: Bool) async throws {
        switch self {
        case .server(let client): try await client.writeFile(id, path, data, unpack: unpack)
        case .local(let manager): try await manager.writeFile(id, path, data: data, unpack: unpack)
        }
    }
}

/// KEY=VALUE lines (blank lines and # comments skipped): a container's or a process's variables.
func readEnvironmentFile(_ path: String?) -> [String: String]? {
    guard let path else { return nil }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
    var variables: [String: String] = [:]
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
        variables[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
    }
    return variables
}

/// `<container>:<path>`, or nil for a local path.
func containerPath(_ argument: String) -> (String, String)? {
    guard let colon = argument.firstIndex(of: ":"), !argument.hasPrefix("/"), !argument.hasPrefix(".") else { return nil }
    return (String(argument[..<colon]), String(argument[argument.index(after: colon)...]))
}

/// This computer's architecture, as container images name it.
var hostArchitecture: String {
    #if arch(arm64)
    "arm64"
    #else
    "amd64"
    #endif
}

func noContainerTool() -> Never { fail("no container tool: Apple's container (brew install container) or Podman/Docker") }

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()),
                          valued: ["config", "minutes", "key", "holder", "identity", "from", "script", "vm", "device", "runtime",
                                   "api", "tag", "env-file", "cwd", "label", "cpus", "memory", "image", "dockerfile", "context", "copy"])
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
        let client = try await OSSClient.connect()
        switch sub {
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
        case "screenshot":
            guard arguments.positional.count >= 4 else { fail("oss machine screenshot <id> <file.png>") }
            let lease = try await resolveLease(target, client)
            try await client.screenshot(lease.id).write(to: URL(fileURLWithPath: arguments.positional[3]))
            print(arguments.positional[3])
        case "run":
            guard !arguments.rest.isEmpty else { fail("oss machine run <platform> [options] -- command…") }
            let lease = try await client.leaseForTerminal(leaseRequest(arguments, platformArgument: target), waitForCapacity: true)
            let minutes = arguments.options["minutes"].flatMap(Int.init)
            let renewing = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(600))
                    _ = try? await client.renew(lease.id, minutes: minutes)
                }
            }
            let environment = ProcessInfo.processInfo.environment.merging(client.environment(lease)) { $1 }
            let status: Int32
            do { status = try Shell.passthrough("/usr/bin/env", arguments.rest, environment: environment) } catch {
                status = 127
                FileHandle.standardError.write(Data("oss: \(error)\n".utf8))
            }
            renewing.cancel()
            try await client.release(lease.id)
            try? FileManager.default.removeItem(atPath: OSSClient.knownHosts(lease.id))
            exit(status)
        default:
            print(usage)
        }

    case "container":
        let front = await ContainerFront.connect(arguments)
        switch sub {
        case "start":
            let labels = arguments.options["label"].flatMap { label in
                label.firstIndex(of: "=").map { [String(label[..<$0]): String(label[label.index(after: $0)...])] }
            }
            let container = try await front.start(ContainerRequest(holder: arguments.options["holder"] ?? holderName(),
                                                                   image: arguments.options["image"], archive: arguments.options["from"],
                                                                   environment: readEnvironmentFile(arguments.options["env-file"]),
                                                                   labels: labels, cpus: arguments.options["cpus"].flatMap(Int.init),
                                                                   memory: arguments.options["memory"]))
            if arguments.flags.contains("json") { try printJSON(container) } else { print(describe(container)) }
        case "restart":
            let container = try await front.restart(try await front.resolve(target).id,
                                                    environment: readEnvironmentFile(arguments.options["env-file"]))
            if arguments.flags.contains("json") { try printJSON(container) } else { print(describe(container)) }
        case "stop", "archive":
            let id = try await front.resolve(target).id
            let container = sub == "stop" ? try await front.stop(id) : try await front.archive(id)
            if arguments.flags.contains("json") { try printJSON(container) } else { print(describe(container)) }
        case "remove":
            let id = try await front.resolve(target).id
            try await front.remove(id)
            print("container \(id) removed: its container, home and archive are deleted")
        case "exec":
            // A process in the container, its output followed here until it
            // ends; with --input, our input (to its end) is its input.
            guard !arguments.rest.isEmpty else { fail("oss container exec <id> [--input] [--env-file=F] [--cwd=DIR] -- command…") }
            let container = try await front.resolve(target)
            let process = try await front.startProcess(container.id, ProcessRequest(command: arguments.rest,
                                                                                    environment: readEnvironmentFile(arguments.options["env-file"]),
                                                                                    directory: arguments.options["cwd"]))
            let input = arguments.flags.contains("input") ? FileHandle.standardInput.readDataToEndOfFile() : Data()
            do {
                try await front.input(container.id, process.id, input, close: true)
            } catch {
                // A command that ended without reading it all: as a shell's pipe.
                guard try await front.process(container.id, process.id).state != .running else { throw error }
            }
            var offsets: [OSSClient.Stream: Int] = [.output: 0, .errors: 0]
            while true {
                var quiet = true
                for (stream, handle) in [(OSSClient.Stream.output, FileHandle.standardOutput), (.errors, FileHandle.standardError)] {
                    let data = try await front.output(container.id, process.id, stream: stream, from: offsets[stream]!,
                                                      wait: stream == .output ? 2 : 0)
                    if !data.isEmpty { handle.write(data); offsets[stream]! += data.count; quiet = false }
                }
                if quiet {
                    let info = try await front.process(container.id, process.id)
                    if info.state != .running, offsets[.output]! >= info.outputSize, offsets[.errors]! >= info.errorSize {
                        if info.state == .lost { FileHandle.standardError.write(Data("oss: the container stopped under it\n".utf8)) }
                        exit(info.status ?? 1)
                    }
                }
            }
        case "cp":
            // <local> <id>:<path>, or <id>:<path> <local>; directories as tarballs.
            guard arguments.positional.count == 4 else { fail("oss container cp <local> <id>:<path> | <id>:<path> <local>") }
            let source = arguments.positional[2], destination = arguments.positional[3]
            if let (id, path) = containerPath(destination), containerPath(source) == nil {
                let container = try await front.resolve(id)
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: source, isDirectory: &directory) else { fail("no \(source)") }
                if directory.boolValue {
                    // COPYFILE_DISABLE: no macOS AppleDouble files (._name) for extended attributes.
                    let tar = try await Shell.run("/usr/bin/tar", ["-czf", "-", "-C", source, "."],
                                                  environment: ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { $1 },
                                                  timeout: 3600)
                    guard tar.ok else { fail("packing \(source): \(tar.error)") }
                    try await front.writeFile(container.id, path, tar.data, unpack: true)
                } else {
                    try await front.writeFile(container.id, path, try Data(contentsOf: URL(fileURLWithPath: source)), unpack: false)
                }
            } else if let (id, path) = containerPath(source), containerPath(destination) == nil {
                let container = try await front.resolve(id)
                let (data, isDirectory) = try await front.readFile(container.id, path)
                if isDirectory {
                    Paths.ensure(destination)
                    let tar = try await Shell.run("/usr/bin/tar", ["-xzf", "-", "-C", destination], input: data, timeout: 3600)
                    guard tar.ok else { fail("unpacking into \(destination): \(tar.error)") }
                } else {
                    var directory: ObjCBool = false
                    let file = FileManager.default.fileExists(atPath: destination, isDirectory: &directory) && directory.boolValue
                        ? "\(destination)/\((path as NSString).lastPathComponent)" : destination
                    try data.write(to: URL(fileURLWithPath: file))
                }
            } else {
                fail("one side is <id>:<path>, the other a local path")
            }
        case "list":
            // `--label key=value`: only the containers with that label.
            let wanted = arguments.options["label"].flatMap { label in
                label.firstIndex(of: "=").map { (String(label[..<$0]), String(label[label.index(after: $0)...])) }
            }
            for container in try await front.list() {
                if let (key, value) = wanted, container.labels?[key] != value { continue }
                let labels = (container.labels ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                print("\(container.id)  \(container.state.rawValue)  \(container.image ?? "-")  \(container.holder)  \(container.archive ?? "")"
                      + (labels.isEmpty ? "" : "  \(labels)"))
            }
        case "shell", "logs":
            let container = try await front.resolve(target)
            guard let runtime = ContainerRuntime.detect() else { fail("shell and logs need the container tool on this computer (the server's)") }
            exit(sub == "shell"
                 ? try runtime.interactive(["exec", "-it", container.name, "/bin/sh"])
                 : try runtime.interactive(["logs", container.name]))
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
            print("  containers: \(status.containers.filter { $0.state == .running }.count)/\(status.containerLimit) running")
            for lease in status.leases {
                print("    \(lease.id)  \(lease.platform.rawValue)/\(lease.config)  \(lease.state.rawValue)  \(lease.holder)  until \(iso(lease.expires))")
            }
            for container in status.containers {
                print("    \(container.id)  container  \(container.state.rawValue)  \(container.holder)")
            }
        }

    case "capabilities":
        try printJSON(try await OSSClient.connect().capabilities())

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
        case "containers":
            guard let runtime = ContainerRuntime.detect() else { noContainerTool() }
            let image = ServerConfig.load().containerImage
            // This computer's architecture only (a multi-platform image would bring every one).
            exit(try runtime.interactive(runtime.name == "container" ? ["image", "pull", "--os", "linux", "--arch", hostArchitecture, image]
                                                                     : ["pull", image]))
        default:
            fail("oss setup android | containers")
        }

    case "image":
        let repo = ProcessInfo.processInfo.environment["OSS_REPO"] ?? "\(Paths.home)/Developer/oss"
        if sub == "provision-macos" {
            guard let name = arguments.options["vm"] else { fail("oss image provision-macos --vm=<name> [--install]") }
            if arguments.flags.contains("install") { setenv("OSS_INSTALL", "1", 1) }
            try await Images.provisionMacOS(name: name)
            exit(0)
        }
        if sub == "build", target == "container" {
            // A container image of your own: a Dockerfile (FROM whatever you like).
            guard arguments.positional.count >= 4, let file = arguments.options["dockerfile"] else {
                fail("oss image build container <name> --dockerfile=PATH [--context=DIR]")
            }
            guard let runtime = ContainerRuntime.detect() else { noContainerTool() }
            let context = arguments.options["context"] ?? (file as NSString).deletingLastPathComponent
            exit(try await runtime.build(tag: arguments.positional[3], file: file, context: context.isEmpty ? "." : context))
        }
        guard sub == "build", let name = target, let platform = Platform(rawValue: name), arguments.positional.count >= 4 else { print(usage); exit(1) }
        let config = arguments.positional[3]
        switch platform {
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
                                   copies: copies, repo: repo)
        }

    default:
        print(usage)
    }
} catch {
    fail("\(error)")
}
