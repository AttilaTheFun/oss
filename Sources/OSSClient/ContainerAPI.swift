import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// A container lease from any computer (API 9): its commands through the
// server (`POST /v1/machines/<id>/exec`, the request upgraded to the exec
// socket's frames), its files (`PUT` and `GET /v1/machines/<id>/files?path=…`),
// with the API's token in its holder's name or a grant's URL.

/// Bytes both ways over a connection of the client's own: an upgraded
/// request's (`OSSTransport.connect`).
public protocol OSSByteStream: Sendable {
    func write(_ data: Data) async throws
    /// What came next; nil once the other side has closed.
    func read() async throws -> Data?
    /// Closed both ways; a read waiting returns nil.
    func close()
}

/// The protocol an exec's request is upgraded to: its connection then
/// carries `ExecFrame`s both ways, as a container's exec socket does.
public enum OSSExecProtocol {
    public static let name = "oss-exec"
}

extension OSSClient {
    /// A command run in a container lease: over its Unix socket where that
    /// is on this computer (the server's Mac: the command outlives the
    /// server's restarts), through the server from anywhere else (API 9).
    /// `input` is sent as it comes (stdin, its end, a terminal's new size,
    /// signals), what the command writes handed to `output` (`.stdout`,
    /// `.stderr`); returns its exit status. Ending the task (or the
    /// process) ends the command.
    public func exec(_ lease: Lease, _ request: ExecRequest, input: AsyncStream<ExecFrame>,
                     output: @escaping @Sendable (ExecFrame) -> Void) async throws -> Int32 {
        #if canImport(Network)
        if let socket = lease.execSocket, FileManager.default.fileExists(atPath: socket) {
            return try await Self.exec(socket: socket, request, input: input, output: output)
        }
        #endif
        guard lease.platform == .container else {
            throw OSSError(status: 0, message: "lease \(lease.id) takes no commands (a container's, once it is ready)")
        }
        return try await exec(lease.id, holder: lease.holder, request, input: input, output: output)
    }

    /// The same through the server, from any computer (API 9), for a
    /// container lease of `holder`'s: `POST /v1/machines/<id>/exec`, its
    /// connection upgraded to `oss-exec` and carrying the exec socket's
    /// frames. While its container starts again (the Mac restarted), the
    /// server waits for it.
    public func exec(_ id: String, holder: String, _ request: ExecRequest, input: AsyncStream<ExecFrame>,
                     output: @escaping @Sendable (ExecFrame) -> Void) async throws -> Int32 {
        let target = url("/v1/machines/\(Self.encode(id))/exec")
        let stream = try await transport.connect(host: server.host ?? "127.0.0.1", port: server.port ?? 80)
        let headers = try await authorization().merging([OSSHeaders.holder: holder]) { $1 }
        return try await OSSExecUpgrade.run(over: stream, url: target, headers: headers, request, input: input, output: output)
    }

    /// A file put in a container lease of `holder`'s at `path` (API 9):
    /// relative to its working directory, `~/` its home; folders made as
    /// needed; the file replaced whole once all of it has come. `mode`:
    /// octal (`755`), else the container's umask's.
    public func uploadFile(_ id: String, holder: String, file: URL, to path: String, mode: String? = nil) async throws -> MachineFile {
        var query = ["path": path]
        if let mode { query["mode"] = mode }
        let answer = try await send("PUT", "/v1/machines/\(Self.encode(id))/files", query: query, contentType: "application/octet-stream",
                                    headers: [OSSHeaders.holder: holder], bodyFile: file, timeout: Self.transferTimeout)
        return try JSONDecoder.oss.decode(MachineFile.self, from: answer.body)
    }

    public func uploadFile(_ id: String, holder: String, data: Data, to path: String, mode: String? = nil) async throws -> MachineFile {
        var query = ["path": path]
        if let mode { query["mode"] = mode }
        let answer = try await send("PUT", "/v1/machines/\(Self.encode(id))/files", query: query, body: data,
                                    contentType: "application/octet-stream", headers: [OSSHeaders.holder: holder],
                                    timeout: Self.transferTimeout)
        return try JSONDecoder.oss.decode(MachineFile.self, from: answer.body)
    }

    /// A container lease's file written to `file` as it comes (API 9).
    public func downloadFile(_ id: String, holder: String, path: String, to file: URL) async throws {
        _ = try await send("GET", "/v1/machines/\(Self.encode(id))/files", query: ["path": path], headers: [OSSHeaders.holder: holder],
                           responseFile: file, timeout: Self.transferTimeout)
    }

    public func downloadFile(_ id: String, holder: String, path: String) async throws -> Data {
        try await send("GET", "/v1/machines/\(Self.encode(id))/files", query: ["path": path], headers: [OSSHeaders.holder: holder],
                       timeout: Self.transferTimeout).body
    }
}

extension OSSGrantClient {
    /// `machine.exec`: a command in the grant's container lease, through
    /// the server, with no token.
    public func exec(_ request: ExecRequest, input: AsyncStream<ExecFrame>,
                     output: @escaping @Sendable (ExecFrame) -> Void) async throws -> Int32 {
        let stream = try await transport.connect(host: url.host ?? "127.0.0.1", port: url.port ?? 80)
        return try await OSSExecUpgrade.run(over: stream, url: url, headers: ["OSS-API": "\(OSS.apiLevel)"], request, input: input,
                                            output: output)
    }

    /// `machine.upload`: a file put in the grant's container lease at `path`.
    public func uploadFile(_ file: URL, to path: String, mode: String? = nil) async throws -> MachineFile {
        var query = ["path": path]
        if let mode { query["mode"] = mode }
        return try JSONDecoder.oss.decode(MachineFile.self, from: try await send("PUT", query: query, bodyFile: file).body)
    }

    public func uploadFile(_ data: Data, to path: String, mode: String? = nil) async throws -> MachineFile {
        var query = ["path": path]
        if let mode { query["mode"] = mode }
        return try JSONDecoder.oss.decode(MachineFile.self, from: try await send("PUT", query: query, body: data).body)
    }

    /// `machine.download`: the grant's container lease's file at `path`,
    /// written to `file` as it comes.
    public func downloadFile(_ path: String, to file: URL) async throws {
        _ = try await send("GET", query: ["path": path], responseFile: file)
    }

    public func downloadFile(_ path: String) async throws -> Data {
        try await send("GET", query: ["path": path]).body
    }
}

/// An exec through the server: the request (its `ExecRequest` the body)
/// and the server's answer, then, upgraded, the exec socket's frames.
enum OSSExecUpgrade {
    static func run(over stream: any OSSByteStream, url: URL, headers: [String: String], _ request: ExecRequest,
                    input: AsyncStream<ExecFrame>, output: @escaping @Sendable (ExecFrame) -> Void) async throws -> Int32 {
        defer { stream.close() }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.percentEncodedPath).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        let target = path + (components?.percentEncodedQuery.map { "?\($0)" } ?? "")
        let host = (url.host ?? "127.0.0.1") + (url.port.map { ":\($0)" } ?? "")
        let body = try JSONEncoder().encode(request)
        var head = "POST \(target) HTTP/1.1\r\nHost: \(host)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Connection: Upgrade\r\nUpgrade: \(OSSExecProtocol.name)\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n\r\n"
        try await stream.write(Data(head.utf8) + body)

        // The answer's head: 101, or a refusal with its message.
        var buffer = Data()
        let blank = Data("\r\n\r\n".utf8)
        while buffer.range(of: blank) == nil {
            guard buffer.count < 64 << 10, let more = try await stream.read() else {
                throw OSSError(status: 0, message: "\(url.host ?? ""): no answer to the exec")
            }
            buffer.append(more)
        }
        let end = buffer.range(of: blank)!
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        buffer = Data(buffer[end.upperBound...])
        let status = lines.first.flatMap { line in line.split(separator: " ").dropFirst().first.flatMap { Int($0) } } ?? 0
        if status != 101 {
            var length: Int?
            for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
            while buffer.count < (length ?? Int.max), let more = try await stream.read() { buffer.append(more) }
            let refusal = try? JSONDecoder.oss.decode(APIError.self, from: buffer)
            throw OSSError(status: status, message: refusal?.error ?? String(decoding: buffer, as: UTF8.self), code: refusal?.code)
        }

        // Upgraded: the client's frames as they come, the container's until its exit.
        let pump = Task {
            for await frame in input {
                if case .start = frame { continue }
                do { try await stream.write(frame.encoded) } catch { return }
            }
        }
        defer { pump.cancel() }
        while true {
            for frame in ExecFrame.decode(&buffer) {
                if case .exit(let code) = frame { return code }
                output(frame)
            }
            guard let more = try await stream.read() else {
                throw OSSError(status: 0, message: "the server closed the connection before the command ended")
            }
            buffer.append(more)
        }
    }
}

// MARK: A socket of the process's own

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

#if canImport(Darwin)
private let streamSocketType = SOCK_STREAM
private let sendFlags: Int32 = 0
#elseif canImport(Glibc)
private let streamSocketType = Int32(SOCK_STREAM.rawValue)
private let sendFlags = Int32(MSG_NOSIGNAL)
#else
private let streamSocketType = Int32(SOCK_STREAM)
private let sendFlags = Int32(MSG_NOSIGNAL)
#endif

/// A TCP connection to `host`'s `port`: its descriptor, connected within
/// ten seconds.
private func openSocket(_ host: String, _ port: Int) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = streamSocketType
    var found: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &found)
    guard status == 0, let first = found else {
        throw OSSError(status: 0, message: "\(host): \(String(cString: gai_strerror(status)))")
    }
    defer { freeaddrinfo(found) }
    var failure = "no address"
    for info in sequence(first: first, next: { $0.pointee.ai_next }) {
        let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard descriptor >= 0 else { failure = String(cString: strerror(errno)); continue }
        #if canImport(Darwin)
        // A write to a closed connection fails (EPIPE) instead of ending the process.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var connected = connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
        if !connected && errno == EINPROGRESS {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            if poll(&waiting, 1, 10_000) == 1 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
                connected = error == 0
                if !connected { failure = String(cString: strerror(error)) }
            } else {
                failure = "no answer in 10 s"
            }
        } else if !connected {
            failure = String(cString: strerror(errno))
        }
        if connected {
            _ = fcntl(descriptor, F_SETFL, flags)
            return descriptor
        }
        _ = close(descriptor)
    }
    throw OSSError(status: 0, message: "\(host):\(port): \(failure)")
}

private func sendAll(_ descriptor: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < bytes.count {
            let sent = send(descriptor, bytes.baseAddress! + offset, bytes.count - offset, sendFlags)
            if sent < 0 {
                if errno == EINTR { continue }
                throw OSSError(status: 0, message: "the connection: \(String(cString: strerror(errno)))")
            }
            offset += sent
        }
    }
}

private func receiveSome(_ descriptor: Int32) -> (Data?, Int32) {
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count > 0 { return (Data(buffer[0..<count]), 0) }
        if count == 0 { return (nil, 0) }
        if errno != EINTR { return (nil, errno) }
    }
}

private func shutDown(_ descriptor: Int32) { _ = shutdown(descriptor, Int32(SHUT_RDWR)) }
private func closeDescriptor(_ descriptor: Int32) { _ = close(descriptor) }

/// A TCP connection of this process's own, its reads and its writes each on
/// a queue of their own (both block): what `OSSTransport.connect` gives by
/// default.
public final class OSSSocketStream: OSSByteStream, @unchecked Sendable {
    private let descriptor: Int32
    private let reads = DispatchQueue(label: "oss.stream.read")
    private let writes = DispatchQueue(label: "oss.stream.write")
    private let lock = NSLock()
    private var closed = false

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { closeDescriptor(descriptor) }

    public static func connect(host: String, port: Int) async throws -> OSSSocketStream {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { continuation.resume(returning: OSSSocketStream(descriptor: try openSocket(host, port))) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async { [self] in
                do {
                    try sendAll(descriptor, data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            reads.async { [self] in
                let (data, failure) = receiveSome(descriptor)
                if failure != 0 && !isClosed {
                    continuation.resume(throwing: OSSError(status: 0, message: "the connection: \(String(cString: strerror(failure)))"))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    public func close() {
        // (NSLock's withLock is newer than this library's floor.)
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        if first { shutDown(descriptor) }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

#else

/// No sockets here: a transport of the platform's own must connect.
public enum OSSSocketStream {
    public static func connect(host: String, port: Int) async throws -> any OSSByteStream {
        throw OSSError(status: 0, message: "no sockets on this platform: give the client a transport that connects")
    }
}

#endif
