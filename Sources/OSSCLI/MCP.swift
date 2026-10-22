import Foundation
import OSSClient

/// `oss mcp`: oss's machine commands as Model Context Protocol tools, on
/// stdio (JSON-RPC, a message a line), for programs that speak it. In an
/// oss container it uses the container's own token and server (its
/// ~/.config/oss), so what it leases is the container's; anywhere else, the
/// client's settings as for the CLI.
enum MCPServer {
    struct Failure: Error, CustomStringConvertible { var description: String }

    static func run() async {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Notifications (no id) need no answer.
            guard let id = message["id"] else { continue }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                reply(id, result: ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                                   "capabilities": ["tools": [String: Any]()],
                                   "serverInfo": ["name": "oss", "version": OSS.version]])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                reply(id, result: await call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
            default:
                reply(id, error: ["code": -32601, "message": "no method \(method)"])
            }
        }
    }

    private static func reply(_ id: Any, result: [String: Any]? = nil, error: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { message["result"] = result }
        if let error { message["error"] = error }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    private static var leaseID: [String: Any] { ["type": "string", "description": "the lease's id (from oss_lease or oss_status)"] }

    static var tools: [[String: Any]] { [
        tool("oss_status", "What the oss server lends (each platform's configs and free places) and the machines you hold.", [:]),
        tool("oss_lease", """
            Lease a machine of your own: a macOS, Linux or Windows VM, an iOS simulator or an Android emulator, a clone \
            made for you and deleted when you release it. Waits until it is ready (a VM takes up to a minute or so) and \
            says how to reach it. Release it as soon as you're done: places are shared.
            """,
             ["platform": ["type": "string", "enum": Platform.allCases.map { $0.rawValue }],
              "config": ["type": "string", "description": "its base: VMs vanilla, dev (the default), xcode-<version> (macOS); oss_status lists them"],
              "minutes": ["type": "integer", "description": "how long it is yours (default 60, at most 480); renew to keep it longer"]],
             required: ["platform"]),
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
        tool("oss_simctl", "Run simctl against a leased iOS simulator: install <path to a .app>, launch <bundle id>, openurl <url>, terminate, listapps, privacy, status_bar, … (local paths are uploaded first).",
             ["id": leaseID, "arguments": ["type": "array", "items": ["type": "string"]]], required: ["id", "arguments"]),
        tool("oss_adb", "Run adb against a leased Android emulator: install <path to an .apk>, shell …, logcat -d, … (local paths are uploaded first).",
             ["id": leaseID, "arguments": ["type": "array", "items": ["type": "string"]]], required: ["id", "arguments"]),
        tool("oss_screenshot", "A picture of a leased machine's screen.", ["id": leaseID], required: ["id"]),
    ] }

    private static func text(_ string: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": string]], "isError": error]
    }

    static func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        do {
            let client = try await OSSClient.connect()
            func lease() async throws -> Lease {
                guard let id = arguments["id"] as? String, !id.isEmpty else { throw Failure(description: "which lease? its id") }
                return try await client.lease(id)
            }
            switch name {
            case "oss_status":
                let status = try await client.status()
                var lines: [String] = []
                for capacity in status.capacity {
                    let configs = status.bases.filter { $0.platform == capacity.platform }.map(\.config)
                    lines.append("\(capacity.platform.rawValue): \(capacity.limit - capacity.leased) of \(capacity.limit) free; configs: \(configs.isEmpty ? "none" : configs.joined(separator: ", "))")
                }
                let held = status.leases.filter { $0.holder == holderName() }
                lines.append(held.isEmpty ? "you hold no machines" : "you hold:")
                for lease in held { lines.append("  \(lease.id)  \(lease.platform.rawValue)/\(lease.config)  \(lease.state.rawValue)  until \(iso(lease.expires))") }
                return text(lines.joined(separator: "\n"))
            case "oss_lease":
                guard let name = arguments["platform"] as? String, let platform = Platform(rawValue: name) else {
                    throw Failure(description: "platform is one of \(Platform.allCases.map { $0.rawValue }.joined(separator: ", "))")
                }
                let key = defaultKey().flatMap { FileManager.default.contents(atPath: $0) }
                    .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                let lease = try await client.lease(LeaseRequest(platform: platform, config: arguments["config"] as? String,
                                                                minutes: (arguments["minutes"] as? NSNumber)?.intValue,
                                                                holder: holderName(), sshPublicKey: key))
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
                guard held.platform.isVM else { throw Failure(description: "\(held.id) is a \(held.platform.rawValue) lease: use oss_simctl or oss_adb") }
                guard let command = arguments["command"] as? String else { throw Failure(description: "which command?") }
                let timeout = (arguments["timeout"] as? NSNumber)?.doubleValue ?? 600
                let result = try await Shell.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "LogLevel=ERROR"]
                                                 + client.sshArguments(held, identity: nil) + [command], timeout: timeout)
                var out = "exit status \(result.status)\n\(result.output)"
                if !result.error.isEmpty { out += "\n[stderr]\n\(result.error)" }
                return text(out, error: result.status != 0)
            case "oss_simctl", "oss_adb":
                let held = try await lease()
                guard held.platform == (name == "oss_simctl" ? .ios : .android) else {
                    throw Failure(description: "\(held.id) is a \(held.platform.rawValue) lease")
                }
                let result = try await client.deviceCommandUploading(held, arguments["arguments"] as? [String] ?? [])
                var out = "exit status \(result.status)\n\(result.output)"
                if !result.error.isEmpty { out += "\n[stderr]\n\(result.error)" }
                return text(out, error: result.status != 0)
            case "oss_screenshot":
                let held = try await lease()
                let data = try await client.screenshot(held.id)
                return ["content": [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]], "isError": false]
            default:
                throw Failure(description: "no tool \(name)")
            }
        } catch {
            return text("\(error)", error: true)
        }
    }
}
