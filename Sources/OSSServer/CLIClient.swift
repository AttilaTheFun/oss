import Foundation
import OSSClient

/// The CLI's transport: Apple's own `curl` on a Mac, which macOS's local
/// network privacy lets reach the LAN (a binary of our own would need the
/// user's leave). The token goes to curl in a file of the caller's own,
/// never on its command line.
struct CurlTransport: OSSTransport {
    static let curl: String = FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") ? "/usr/bin/curl" : "curl"

    func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse {
        try await send(request, bodyFile: nil, responseFile: nil)
    }

    /// A file's body goes by `-T` (read as it's sent), an answer to a file
    /// by `-o`: a stored object needn't fit in memory.
    func send(_ request: OSSHTTPRequest, bodyFile: URL?, responseFile: URL?) async throws -> OSSHTTPResponse {
        let configFile = NSTemporaryDirectory() + "oss-curl-\(Random.hex(6))"
        let headerFile = configFile + "-headers"
        defer {
            try? FileManager.default.removeItem(atPath: configFile)
            try? FileManager.default.removeItem(atPath: headerFile)
        }
        let headers = request.headers.sorted { $0.key < $1.key }.map { "header = \"\($0.key): \($0.value)\"\n" }.joined()
        FileManager.default.createFile(atPath: configFile, contents: Data(headers.utf8), attributes: [.posixPermissions: 0o600])
        var arguments = ["-sS", "-K", configFile, "--connect-timeout", "5",
                         "--max-time", String(Int(request.timeout.rounded(.up))), "-w", "\n%{http_code}", "-D", headerFile]
        // HEAD by its own option: told `-X HEAD`, curl waits for a body that never comes.
        arguments += request.method == "HEAD" ? ["-I", "-o", "/dev/null"] : ["-X", request.method]
        if let bodyFile {
            arguments += ["-T", bodyFile.path]
        } else if request.body != nil {
            arguments += ["--data-binary", "@-"]
        }
        if let responseFile { arguments += ["-o", responseFile.path] }
        let result = try await Shell.run(Self.curl, arguments + [request.url.absoluteString], input: bodyFile == nil ? request.body : nil)
        guard result.ok else {
            throw OSSError(status: 0, message: "\(request.url.host ?? ""): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // `-w` puts a line with the status after the body; output without it
        // (curl ended with nothing written) is no answer, not a crash.
        guard let newline = result.data.lastIndex(of: 0x0A) else {
            throw OSSError(status: 0, message: "\(request.url.host ?? ""): no answer")
        }
        let status = Int(String(decoding: result.data[result.data.index(after: newline)...], as: UTF8.self)) ?? 0
        var responseHeaders: [String: String] = [:]
        let head = FileManager.default.contents(atPath: headerFile).map { String(decoding: $0, as: UTF8.self) } ?? ""
        // A 100 Continue before the answer (a put's): the answer's fields are the last block's.
        for line in head.components(separatedBy: "\r\n\r\n").last(where: { !$0.isEmpty })?.components(separatedBy: "\r\n") ?? [] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            responseHeaders[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(result.data[..<newline])
        if let responseFile, !(200..<300).contains(status) {
            // A refusal's message, not the object.
            body = FileManager.default.contents(atPath: responseFile.path) ?? Data()
            try? FileManager.default.removeItem(at: responseFile)
        }
        return OSSHTTPResponse(status: status, headers: responseHeaders, body: body)
    }

    /// An upgraded request's connection (a container's exec): on a Mac,
    /// to another computer through Apple's own `nc`, as curl for the rest;
    /// to this one, and off a Mac, a socket of this process's.
    func connect(host: String, port: Int) async throws -> any OSSByteStream {
        #if os(macOS)
        let loopback = host == "localhost" || host == "::1" || host.hasPrefix("127.")
        if !loopback { return try NetcatStream(host: host, port: port) }
        #endif
        return try await OSSSocketStream.connect(host: host, port: port)
    }
}

#if os(macOS)
/// A TCP connection carried by Apple's `/usr/bin/nc`, which macOS's local
/// network privacy lets reach the LAN: this process writes to its stdin and
/// reads its stdout, each on a queue of its own (both block).
final class NetcatStream: OSSByteStream, @unchecked Sendable {
    private let process = Process()
    private let toServer = Pipe()
    private let fromServer = Pipe()
    private let writes = DispatchQueue(label: "oss.nc.write")
    private let reads = DispatchQueue(label: "oss.nc.read")

    init(host: String, port: Int) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-G", "10", host, String(port)]
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async { [self] in
                do {
                    try toServer.fileHandleForWriting.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: OSSError(status: 0, message: "the connection (nc) closed"))
                }
            }
        }
    }

    func read() async throws -> Data? {
        await withCheckedContinuation { continuation in
            reads.async { [self] in
                let data = fromServer.fileHandleForReading.availableData
                continuation.resume(returning: data.isEmpty ? nil : data)
            }
        }
    }

    func close() {
        try? toServer.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
#endif

/// The CLI's transport: curl, or with OSS_TRANSPORT=urlsession the
/// library's own (where macOS lets this binary reach the server).
func cliTransport() -> any OSSTransport {
    ProcessInfo.processInfo.environment["OSS_TRANSPORT"] == "urlsession" ? URLSessionTransport() : CurlTransport()
}

extension OSSGrantClient {
    /// `--url`: a grant's URL, or its path alone (`oss grant --json`'s
    /// `path`) on the first of this computer's servers that answers
    /// (`~/.config/oss/client.json`'s, or OSS_SERVERS), as the commands with
    /// the token find theirs.
    static func cli(_ grant: String, environment: [String: String] = ProcessInfo.processInfo.environment) async throws
        -> OSSGrantClient {
        try await resolving(grant, servers: ClientConfig.load(environment: environment).servers.compactMap(URL.init(string:)),
                            transport: cliTransport())
    }
}

extension OSSClient {
    /// The server this computer uses: the first of `~/.config/oss/client.json`'s
    /// servers (or OSS_SERVERS) that answers, with an API key or the token
    /// (Token.read), acting for OSS_CLIENT_ID when it is set.
    static func connect() async throws -> OSSClient {
        guard let token = Token.read() else {
            throw OSSError(status: 0, message: "no key or token: put an API key in \(Paths.clientKey) (or OSS_API_KEY), or the server's token in \(Paths.clientToken) (or OSS_TOKEN)")
        }
        let servers = ClientConfig.load().servers.compactMap(URL.init(string:))
        var client = try await connect(servers: servers, token: token, transport: cliTransport())
        client.clientID = Token.clientID()
        return client
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
        Paths.ensure(Paths.clientState)
        return "\(Paths.clientState)/known_hosts-\(id)"
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
        if lease.platform == .ios {
            env["OSS_UDID"] = lease.udid ?? ""
            if let device = lease.device { env["OSS_DEVICE"] = device }
        }
        if lease.platform == .android {
            env["OSS_ADB"] = "\(host):\(lease.adbPort ?? 0)"
            env["OSS_ADB_PORT"] = String(lease.adbPort ?? 0)
        }
        // A container's forwarded ports: OSS_PORT_8080=<host>:<port>.
        for port in lease.ports ?? [] { env["OSS_PORT_\(port.port)"] = "\(port.host ?? host):\(port.hostPort)" }
        return env
    }
}
