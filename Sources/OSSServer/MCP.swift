import Foundation
import OSSClient

/// oss's machine commands as Model Context Protocol tools: `oss mcp` on
/// stdio (JSON-RPC, a message a line), with the client's settings as for
/// the CLI; and the server's own MCP port (API 12, `Server.mcpRoute`), each
/// call made with its caller's key and CLIENT_ID.
enum MCPServer {
    struct Failure: Error, CustomStringConvertible { var description: String }

    /// What a call works with: its client, whom its leases and objects are
    /// for, how a VM is reached, and where files are.
    struct Context: Sendable {
        var client: OSSClient
        /// The holder named in requests that name one (the server makes a
        /// keyed caller's `<CLIENT_ID>@<application>` of it).
        var holder: String
        /// The public key a VM lease lets in (nil: none asked for).
        var sshPublicKey: String?
        /// The identity ssh uses (nil: ssh's own).
        var sshIdentity: String?
        /// Whether paths are the caller's own (stdio): uploaded first. Over
        /// HTTP the caller's files are elsewhere: they come by storage.
        var localFiles: Bool

        /// `oss mcp`'s: this computer's client and key.
        static func local() async throws -> Context {
            let key = defaultKey().flatMap { FileManager.default.contents(atPath: $0) }
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            return Context(client: try await OSSClient.connect(), holder: holderName(), sshPublicKey: key, sshIdentity: nil, localFiles: true)
        }
    }

    static func run() async {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let answer = await answer(message, context: { try await Context.local() }),
                  var data = try? JSONSerialization.data(withJSONObject: answer) else { continue }
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
    }

    /// The answer to a JSON-RPC message; nil for a notification, which
    /// needs none.
    static func answer(_ message: [String: Any], context: () async throws -> Context) async -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        func reply(result: [String: Any]? = nil, error: [String: Any]? = nil) -> [String: Any] {
            var answer: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if let result { answer["result"] = result }
            if let error { answer["error"] = error }
            return answer
        }
        switch method {
        case "initialize":
            return reply(result: ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                                  "capabilities": ["tools": [String: Any]()],
                                  "serverInfo": ["name": "oss", "version": OSS.version]])
        case "ping":
            return reply(result: [:])
        case "tools/list":
            return reply(result: ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return reply(result: await call(name, arguments, context: try await context()))
            } catch {
                return reply(result: text("\(error)", error: true))
            }
        default:
            return reply(error: ["code": -32601, "message": "no method \(method)"])
        }
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    private static var leaseID: [String: Any] { ["type": "string", "description": "the lease's id (from oss_lease or oss_status)"] }

    static var tools: [[String: Any]] { [
        tool("oss_status", "What the oss server lends (its memory budget and what the leases take of it, each platform's configs, cap and room, the leases waiting) and the machines you hold.", [:]),
        tool("oss_lease", """
            Lease a machine of your own: a macOS, Linux or Windows VM, an iOS simulator or an Android emulator, a clone \
            made for you and deleted when you release it. Waits until it is ready (a VM takes up to a minute or so) and \
            says how to reach it. Release it as soon as you're done: places are shared.
            """,
             ["platform": ["type": "string", "enum": Platform.allCases.filter { $0 != .container }.map { $0.rawValue }],
              "config": ["type": "string", "description": "its base: VMs vanilla, dev (the default), xcode-<version> (macOS); oss_status lists them"],
              "minutes": ["type": "integer", "description": "how long it is yours (default 60, at most 480); renew to keep it longer"],
              "device": ["type": "string", "description": "iOS: a device type, by name or identifier (\"iPad Pro 13-inch (M5)\", \"iPhone 18 Pro\"); the config's otherwise"],
              "label": ["type": "string", "description": "what it is for, shown beside it to everyone watching the server"]],
             required: ["platform"]),
        tool("oss_container_lease", """
            Lease a Linux container of your own from an image: headless Linux work (builds, servers under test) without a VM. \
            Waits until it is ready. Run commands with oss_exec, move files with oss_upload and oss_download or a grant. \
            Release it when done.
            """,
             ["image": ["type": "string", "description": "the image (e.g. ghcr.io/owner/name:tag)"],
              "cpus": ["type": "integer"], "memory_gb": ["type": "number"], "disk_gb": ["type": "number"],
              "volumes": ["type": "array", "description": "kept disks: each {name, path, gb, keep?}",
                          "items": ["type": "object", "properties": ["name": ["type": "string"], "path": ["type": "string"],
                                                                     "gb": ["type": "number"], "keep": ["type": "boolean"]]]],
              "ports": ["type": "array", "items": ["type": "integer"], "description": "the container's ports to forward to the server's"],
              "environment": ["type": "object", "description": "variables for its commands"],
              "minutes": ["type": "integer", "description": "how long it is yours (default 60); renew to keep it longer"],
              "label": ["type": "string"]],
             required: ["image"]),
        tool("oss_renew", "Keep a lease: its time set to `minutes` from now.",
             ["id": leaseID, "minutes": ["type": "integer", "description": "default 60, at most 480"]], required: ["id"]),
        tool("oss_release", "Give a machine back: it is deleted, with everything on it.", ["id": leaseID], required: ["id"]),
        tool("oss_ssh", """
            Run a command on a leased VM over SSH, as its user `runner` (sudo asks nothing). macOS: zsh (use zsh -lc \
            for Homebrew's tools); Linux: bash; Windows: PowerShell. Answers its output and exit status.
            """,
             ["id": leaseID, "command": ["type": "string"],
              "timeout": ["type": "integer", "description": "seconds before it is stopped (default 600)"]],
             required: ["id", "command"]),
        tool("oss_exec", "Run a command in a leased container (sh -c), to its end: its output, errors and exit status.",
             ["id": leaseID, "command": ["type": "string"], "input": ["type": "string", "description": "its standard input"],
              "directory": ["type": "string"], "timeout": ["type": "integer", "description": "seconds before it is stopped (default 600)"]],
             required: ["id", "command"]),
        tool("oss_upload", "Write a small text file into a leased container (a big one: oss_grant machine.upload, then PUT it to the URL).",
             ["id": leaseID, "path": ["type": "string"], "content": ["type": "string"], "mode": ["type": "string", "description": "e.g. 755"]],
             required: ["id", "path", "content"]),
        tool("oss_download", "Read a small text file from a leased container (a big one: oss_grant machine.download, then GET the URL).",
             ["id": leaseID, "path": ["type": "string"]], required: ["id", "path"]),
        tool("oss_simctl", "Run simctl against a leased iOS simulator: install @<an uploaded .app>, launch <bundle id>, openurl <url>, terminate, listapps, privacy, status_bar, … (an app from storage: oss_install).",
             ["id": leaseID, "arguments": ["type": "array", "items": ["type": "string"]]], required: ["id", "arguments"]),
        tool("oss_adb", "Run adb against a leased Android emulator: install @<an uploaded .apk>, shell …, logcat -d, ….",
             ["id": leaseID, "arguments": ["type": "array", "items": ["type": "string"]]], required: ["id", "arguments"]),
        tool("oss_install", "Install an .ipa or a zipped .app from storage (yours, by its SHA-256 or name) on a leased iOS simulator.",
             ["id": leaseID, "object": ["type": "string"]], required: ["id", "object"]),
        tool("oss_storage", "Your objects in the server's storage: each lease on one (id, SHA-256, size, name, until when).", [:]),
        tool("oss_grant", """
            A URL that does one thing for a few minutes, for files too big for a tool call: storage.put (PUT the file's bytes; \
            name it with `name`), storage.get (GET an object of yours), machine.upload / machine.download (a container's \
            file: add ?path=…), machine.install, machine.exec. A grant is a secret: don't put it anywhere else.
            """,
             ["verb": ["type": "string", "enum": ["storage.put", "storage.get", "machine.upload", "machine.download", "machine.install", "machine.exec", "machine.xctest"]],
              "lease": leaseID, "object": ["type": "string"], "name": ["type": "string"], "ttl": ["type": "string", "description": "how long the URL works: 5m unless asked, at most 15m"]],
             required: ["verb"]),
        tool("oss_screenshot", "A picture of a leased machine's screen.", ["id": leaseID], required: ["id"]),
        tool("oss_tap", "Tap (click) a leased machine's screen at x, y: its screenshot's pixels.",
             ["id": leaseID, "x": ["type": "number"], "y": ["type": "number"]], required: ["id", "x", "y"]),
        tool("oss_swipe", "Swipe (drag) on a leased machine's screen from x, y to toX, toY, in its screenshot's pixels.",
             ["id": leaseID, "x": ["type": "number"], "y": ["type": "number"], "toX": ["type": "number"], "toY": ["type": "number"],
              "milliseconds": ["type": "integer", "description": "how long the swipe takes (default 300)"]],
             required: ["id", "x", "y", "toX", "toY"]),
        tool("oss_type", "Type text into what has focus on a leased machine.", ["id": leaseID, "text": ["type": "string"]],
             required: ["id", "text"]),
        tool("oss_key", "Press a key on a leased machine: return, tab, escape, backspace, delete, space, up, down, left, right, pageup, pagedown, home, back (Android); on a VM with modifiers too (cmd+a, ctrl+shift+t); or the platform's own code.",
             ["id": leaseID, "key": ["type": "string"]], required: ["id", "key"]),
        tool("oss_usage", "The oss server's CPU and memory, and each lease's (100% CPU is one core).", [:]),
    ] }

    private static func text(_ string: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": string]], "isError": error]
    }

    /// The most a file read or written through a call holds; beyond it, a grant.
    static let inlineBytes = 1_000_000

    static func call(_ name: String, _ arguments: [String: Any], context: Context) async -> [String: Any] {
        let client = context.client
        do {
            func lease() async throws -> Lease {
                guard let id = arguments["id"] as? String, !id.isEmpty else { throw Failure(description: "which lease? its id") }
                return try await client.lease(id)
            }
            func number(_ key: String) -> Double? { (arguments[key] as? NSNumber)?.doubleValue }
            switch name {
            case "oss_status":
                let status = try await client.status()
                // The budget, each type's room and who waits, as `oss status` says them.
                var lines = (capacityLines(status) + (status.host.map(hostLines) ?? [])).map { $0.trimmingCharacters(in: .whitespaces) }
                let held = status.leases.filter { Self.isMine($0.holder, context: context) }
                lines.append(held.isEmpty ? "you hold no machines" : "you hold:")
                for lease in held { lines.append("  \(leaseLine(lease))") }
                return text(lines.joined(separator: "\n"))
            case "oss_lease":
                guard let name = arguments["platform"] as? String, let platform = Platform(rawValue: name), platform != .container else {
                    throw Failure(description: "platform is one of \(Platform.allCases.filter { $0 != .container }.map { $0.rawValue }.joined(separator: ", ")) (a container: oss_container_lease)")
                }
                // A program that speaks MCP to lease a machine is an agent at work.
                let lease = try await client.lease(LeaseRequest(platform: platform, config: arguments["config"] as? String,
                                                                minutes: (arguments["minutes"] as? NSNumber)?.intValue,
                                                                holder: context.holder, sshPublicKey: context.sshPublicKey, kind: .agent,
                                                                label: arguments["label"] as? String,
                                                                device: platform == .ios ? arguments["device"] as? String : nil))
                return text(describe(lease, client))
            case "oss_container_lease":
                guard let image = arguments["image"] as? String, !image.isEmpty else { throw Failure(description: "which image?") }
                let gigabyte = 1_073_741_824.0
                let volumes = (arguments["volumes"] as? [[String: Any]] ?? []).compactMap { volume -> ContainerVolume? in
                    guard let name = volume["name"] as? String, let path = volume["path"] as? String else { return nil }
                    return ContainerVolume(name: name, destination: path, sizeBytes: Int64((((volume["gb"] as? NSNumber)?.doubleValue) ?? 16) * gigabyte),
                                           keep: volume["keep"] as? Bool ?? false)
                }
                var spec = ContainerSpec(image: image, cpus: (arguments["cpus"] as? NSNumber)?.intValue,
                                         memoryBytes: number("memory_gb").map { Int64($0 * gigabyte) },
                                         diskBytes: number("disk_gb").map { Int64($0 * gigabyte) }, volumes: volumes)
                spec.environment = (arguments["environment"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
                spec.ports = (arguments["ports"] as? [NSNumber] ?? []).map(\.intValue)
                let lease = try await client.lease(LeaseRequest(platform: .container, minutes: (arguments["minutes"] as? NSNumber)?.intValue,
                                                                holder: context.holder, container: spec, kind: .agent,
                                                                label: arguments["label"] as? String))
                return text(describe(lease, client))
            case "oss_renew":
                let renewed = try await client.renew(try await lease().id, minutes: (arguments["minutes"] as? NSNumber)?.intValue)
                return text("lease \(renewed.id): yours until \(iso(renewed.expires)) (\(minutesLeft(renewed.expires)) min)")
            case "oss_release":
                let held = try await lease()
                try await client.release(held.id)
                try? FileManager.default.removeItem(atPath: OSSClient.knownHosts(held.id))
                return text("lease \(held.id) released: \(held.name) is being deleted")
            case "oss_ssh":
                let held = try await lease()
                guard held.platform.isVM else { throw Failure(description: "\(held.id) is a \(held.platform.rawValue) lease: use oss_simctl, oss_adb or oss_exec") }
                guard let command = arguments["command"] as? String else { throw Failure(description: "which command?") }
                let result = try await Shell.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "LogLevel=ERROR"]
                                                 + client.sshArguments(held, identity: context.sshIdentity) + [command], timeout: number("timeout") ?? 600)
                var out = "exit status \(result.status)\n\(result.output)"
                if !result.error.isEmpty { out += "\n[stderr]\n\(result.error)" }
                return text(out, error: result.status != 0)
            case "oss_exec":
                let held = try await lease()
                guard held.platform == .container else { throw Failure(description: "\(held.id) is a \(held.platform.rawValue) lease: oss_exec runs in containers (a VM: oss_ssh)") }
                guard let command = arguments["command"] as? String else { throw Failure(description: "which command?") }
                let (frames, feed) = AsyncStream<ExecFrame>.makeStream()
                if let input = arguments["input"] as? String { feed.yield(.stdin(Data(input.utf8))) }
                feed.yield(.closeStdin)
                let collected = Collected()
                let request = ExecRequest(arguments: ["/bin/sh", "-c", command], workingDirectory: arguments["directory"] as? String)
                let status = try await withTimeout(number("timeout") ?? 600) {
                    try await client.exec(held.id, holder: context.holder, request, input: frames) { frame in
                        switch frame {
                        case .stdout(let data): collected.add(data, error: false)
                        case .stderr(let data): collected.add(data, error: true)
                        default: break
                        }
                    }
                }
                feed.finish()
                var out = "exit status \(status)\n\(collected.output)"
                if !collected.errors.isEmpty { out += "\n[stderr]\n\(collected.errors)" }
                return text(out, error: status != 0)
            case "oss_upload":
                let held = try await lease()
                guard let path = arguments["path"] as? String, let content = arguments["content"] as? String else { throw Failure(description: "which path, and what in it?") }
                guard content.utf8.count <= inlineBytes else { throw Failure(description: "too big for a call: oss_grant machine.upload, then PUT it") }
                let written = try await client.uploadFile(held.id, holder: context.holder, data: Data(content.utf8), to: path, mode: arguments["mode"] as? String)
                return text("written: \(written.path) (\(written.size) bytes)")
            case "oss_download":
                let held = try await lease()
                guard let path = arguments["path"] as? String else { throw Failure(description: "which path?") }
                let data = try await client.downloadFile(held.id, holder: context.holder, path: path)
                guard data.count <= inlineBytes else { throw Failure(description: "\(data.count) bytes: too big for a call; oss_grant machine.download, then GET it") }
                return text(String(decoding: data, as: UTF8.self))
            case "oss_simctl", "oss_adb":
                let held = try await lease()
                guard held.platform == (name == "oss_simctl" ? .ios : .android) else {
                    throw Failure(description: "\(held.id) is a \(held.platform.rawValue) lease")
                }
                let given = arguments["arguments"] as? [String] ?? []
                let result = context.localFiles ? try await client.deviceCommandUploading(held, given) : try await client.deviceCommand(held, given)
                var out = "exit status \(result.status)\n\(result.output)"
                if !result.error.isEmpty { out += "\n[stderr]\n\(result.error)" }
                return text(out, error: result.status != 0)
            case "oss_install":
                let held = try await lease()
                guard let object = arguments["object"] as? String else { throw Failure(description: "which object? its SHA-256 or name") }
                let installed = try await client.install(held.id, object: object)
                return text("installed \(installed.app)" + (installed.bundleIdentifier.map { " (\($0))" } ?? ""))
            case "oss_storage":
                let leases = try await client.storageLeases(holder: context.holder)
                return text(leases.isEmpty ? "you keep nothing in storage" : leases.map(describe).joined(separator: "\n"))
            case "oss_grant":
                guard let verb = arguments["verb"] as? String else { throw Failure(description: "which verb?") }
                let grant = try await client.grant(GrantRequest(verb: verb, lease: arguments["lease"] as? String, object: arguments["object"] as? String,
                                                                ttl: arguments["ttl"] as? String, name: arguments["name"] as? String),
                                                   holder: context.holder)
                return text("\(grant.verb): \(grant.url.absoluteString)\nuntil \(iso(grant.expires))")
            case "oss_screenshot":
                let held = try await lease()
                let data = try await client.screenshot(held.id)
                return ["content": [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]], "isError": false]
            case "oss_tap", "oss_swipe", "oss_type", "oss_key":
                let held = try await lease()
                let action: InputRequest.Action = ["oss_tap": .tap, "oss_swipe": .swipe, "oss_type": .type, "oss_key": .key][name]!
                try await client.input(held.id, InputRequest(action: action, x: number("x"), y: number("y"), toX: number("toX"),
                                                             toY: number("toY"), milliseconds: (arguments["milliseconds"] as? NSNumber)?.intValue,
                                                             text: arguments["text"] as? String, key: arguments["key"] as? String))
                return text("done: take a screenshot to see what it did")
            case "oss_usage":
                let usage = try await client.usage()
                let h = usage.host
                var lines = ["\(h.name): CPU \(Int(h.cpuPercent))% of \(h.cpus * 100)%, memory \(gigabytes(h.memoryUsedBytes)) of \(gigabytes(h.memoryBytes))"]
                for m in usage.machines {
                    let cpu = m.cpuPercent.map { "\(Int($0))%" } ?? "?"
                    lines.append("  \(m.id) \(m.platform.rawValue)/\(m.config): CPU \(cpu), memory \(m.memoryBytes.map(gigabytes) ?? "?") (\(m.holder)\(m.kind.map { ", \($0.rawValue)" } ?? ""))")
                }
                return text(lines.joined(separator: "\n"))
            default:
                throw Failure(description: "no tool \(name)")
            }
        } catch {
            return text("\(error)", error: true)
        }
    }

    /// Whether a lease is the caller's: its holder, or (keyed) its holder
    /// within the caller's application.
    static func isMine(_ holder: String, context: Context) -> Bool {
        holder == context.holder || holder.hasPrefix(context.holder + "@")
    }

    /// A command's output as it comes, kept for its answer.
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func add(_ data: Data, error: Bool) {
            lock.withLock { error ? err.append(data) : out.append(data) }
        }

        var output: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
        var errors: String { lock.withLock { String(decoding: err, as: UTF8.self) } }
    }

    /// `work`, stopped after `seconds`.
    static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Failure(description: "stopped after \(Int(seconds)) s")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
