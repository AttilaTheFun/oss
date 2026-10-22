import Foundation
import OSSClient

/// The CLI's transport: Apple's own `curl` on a Mac, which macOS's local
/// network privacy lets reach the LAN (a binary of our own would need the
/// user's leave). The token goes to curl in a file of the caller's own,
/// never on its command line.
struct CurlTransport: OSSTransport {
    static let curl: String = FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") ? "/usr/bin/curl" : "curl"

    func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse {
        let configFile = NSTemporaryDirectory() + "oss-curl-\(Random.hex(6))"
        let headerFile = configFile + "-headers"
        defer {
            try? FileManager.default.removeItem(atPath: configFile)
            try? FileManager.default.removeItem(atPath: headerFile)
        }
        let headers = request.headers.sorted { $0.key < $1.key }.map { "header = \"\($0.key): \($0.value)\"\n" }.joined()
        FileManager.default.createFile(atPath: configFile, contents: Data(headers.utf8), attributes: [.posixPermissions: 0o600])
        var arguments = ["-sS", "-K", configFile, "-X", request.method, "--connect-timeout", "5",
                         "--max-time", String(Int(request.timeout.rounded(.up))), "-w", "\n%{http_code}", "-D", headerFile]
        if request.body != nil { arguments += ["--data-binary", "@-"] }
        let result = try await Shell.run(Self.curl, arguments + [request.url.absoluteString], input: request.body)
        guard result.ok else {
            throw OSSError(status: 0, message: "\(request.url.host ?? ""): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let newline = result.data.lastIndex(of: 0x0A) ?? result.data.startIndex
        let status = Int(String(decoding: result.data[result.data.index(after: newline)...], as: UTF8.self)) ?? 0
        var responseHeaders: [String: String] = [:]
        let head = FileManager.default.contents(atPath: headerFile).map { String(decoding: $0, as: UTF8.self) } ?? ""
        for line in head.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            responseHeaders[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return OSSHTTPResponse(status: status, headers: responseHeaders, body: Data(result.data[..<newline]))
    }
}

extension OSSClient {
    /// The server this computer uses: the first of `~/.config/oss/client.json`'s
    /// servers (or OSS_SERVERS) that answers, with `~/.config/oss/token` (or OSS_TOKEN).
    static func connect() async throws -> OSSClient {
        guard let token = Token.read() else {
            throw OSSError(status: 0, message: "no token: put the server's in \(Paths.token) (or OSS_TOKEN)")
        }
        let servers = ClientConfig.load().servers.compactMap(URL.init(string:))
        // OSS_TRANSPORT=urlsession: the library's own transport (where macOS lets this binary reach the server).
        let transport: any OSSTransport = ProcessInfo.processInfo.environment["OSS_TRANSPORT"] == "urlsession"
            ? URLSessionTransport() : CurlTransport()
        return try await connect(servers: servers, token: token, transport: transport)
    }

    /// A lease waited on, telling the terminal how it goes.
    func leaseForTerminal(_ request: LeaseRequest, waitForCapacity: Bool) async throws -> Lease {
        defer { FileHandle.standardError.write(Data("\n".utf8)) }
        return try await lease(request, waitForCapacity: waitForCapacity) { FileHandle.standardError.write(Data("oss: \($0)".utf8)) }
    }

    /// simctl (iOS) or adb (Android) on the server, for this lease's device.
    /// Local paths among the arguments are uploaded first (a directory, such
    /// as an .app, zipped) and named `@<file>`.
    func deviceCommandUploading(_ lease: Lease, _ arguments: [String]) async throws -> DeviceCommandResult {
        var sent: [String] = []
        for argument in arguments {
            var isDirectory: ObjCBool = false
            guard argument.contains("/") || argument.hasSuffix(".app") || argument.hasSuffix(".apk") || argument.hasSuffix(".ipa"),
                  FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory) else { sent.append(argument); continue }
            let name = URL(fileURLWithPath: argument).lastPathComponent
            if isDirectory.boolValue {
                let zip = NSTemporaryDirectory() + "oss-\(Random.hex(4))-\(name).zip"
                defer { try? FileManager.default.removeItem(atPath: zip) }
                let ditto = try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", argument, zip], timeout: 600)
                guard ditto.ok else { throw OSSError(status: 0, message: "zipping \(argument): \(ditto.error)") }
                try await upload(lease.id, name: "\(name).zip", data: FileManager.default.contents(atPath: zip) ?? Data())
            } else {
                try await upload(lease.id, name: name, data: FileManager.default.contents(atPath: argument) ?? Data())
            }
            sent.append("@\(name)")
        }
        return try await deviceCommand(lease, sent)
    }

    /// Where a lease's SSH host keys are kept (each guest's are new).
    static func knownHosts(_ id: String) -> String {
        Paths.ensure(Paths.state)
        return "\(Paths.state)/known_hosts-\(id)"
    }

    func sshArguments(_ lease: Lease, identity: String?) -> [String] {
        var arguments = ["-p", String(lease.sshPort ?? 22), "-o", "UserKnownHostsFile=\(Self.knownHosts(lease.id))",
                         "-o", "StrictHostKeyChecking=accept-new"]
        if let identity { arguments += ["-i", identity] }
        return arguments + ["\(lease.sshUser ?? "runner")@\(host)"]
    }

    /// What a holder needs, as shell exports (`oss machine lease --exports`, `oss machine run`).
    func environment(_ lease: Lease) -> [String: String] {
        var env = [
            "OSS_ID": lease.id,
            "OSS_PLATFORM": lease.platform.rawValue,
            "OSS_CONFIG": lease.config,
            "OSS_HOST": host,
            "OSS_EXPIRES": ISO8601DateFormatter().string(from: lease.expires),
        ]
        if lease.platform.isVM {
            env["OSS_SSH_PORT"] = String(lease.sshPort ?? 0)
            env["OSS_SSH_USER"] = lease.sshUser ?? "runner"
            env["OSS_SSH"] = "ssh -p \(lease.sshPort ?? 0) -o UserKnownHostsFile=\(Self.knownHosts(lease.id)) -o StrictHostKeyChecking=accept-new \(lease.sshUser ?? "runner")@\(host)"
            env["OSS_VNC_PORT"] = String(lease.vncPort ?? 0)
            env["OSS_VNC_PASSWORD"] = lease.vncPassword ?? ""
            env["OSS_VNC"] = "vnc://\(host):\(lease.vncPort ?? 0)"
        }
        if lease.platform == .ios { env["OSS_UDID"] = lease.udid ?? "" }
        if lease.platform == .android {
            env["OSS_ADB"] = "\(host):\(lease.adbPort ?? 0)"
            env["OSS_ADB_PORT"] = String(lease.adbPort ?? 0)
        }
        return env
    }
}
