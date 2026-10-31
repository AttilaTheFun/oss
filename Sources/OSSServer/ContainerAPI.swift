import Foundation
import OSSClient

#if canImport(Network)
import Network

/// A container lease from any computer (API 9): its commands and its files
/// through the server, which reaches the container over its exec socket
/// on this Mac, as a client here does. With the API's token, for the
/// holder the request names (`OSS-Holder`), whose lease it must be; or
/// with a grant's URL for that lease (`machine.exec`, `machine.upload`,
/// `machine.download`).
///
/// - `POST /v1/machines/<id>/exec`, `Connection: Upgrade`, `Upgrade:
///   oss-exec`, the body an `ExecRequest` (JSON, with its length): 101
///   Switching Protocols, then the exec socket's frames both ways (stdin,
///   its end, a terminal's size and signals in; stdout, stderr and last
///   the exit status out). The server starts the command with the request
///   and relays the rest as it comes; the connection closing before the
///   command ends ends it (TERM, then KILL ten seconds on).
/// - `PUT /v1/machines/<id>/files?path=…[&mode=755]`, the body streamed:
///   the file at `path` (relative to the container's working directory,
///   `~/` its home), its folders made, written beside it and moved into
///   place only once all of it has come. 201 `MachineFile`.
/// - `GET /v1/machines/<id>/files?path=…`: the file's bytes, streamed.
///
/// Files go through the container's `/bin/sh` (`cat`, `wc`, `mv`, `chmod`,
/// `mkdir`), as every image with a shell has them.
enum ContainerAPI {
    /// The routes whose connection is handed over once their head has come.
    static func streams(_ method: String, _ parts: [String]) -> Bool {
        parts.count == 4 && parts[0] == "v1" && parts[1] == "machines"
            && ((method == "POST" && parts[3] == "exec") || ((method == "PUT" || method == "GET") && parts[3] == "files"))
    }

    static func serve(_ request: HTTPRequest, _ peer: CachePeer, api: API) async {
        let parts = (request.path.split(separator: "?").first ?? "").split(separator: "/").map(String.init)
        let access = Server.access(request, parts, api: api)
        if case .refused(let response) = access {
            _ = await peer.send(response)
            return
        }
        do {
            let lease = try await self.lease(parts[2], access: access, request: request, api: api)
            switch (request.method, parts[3]) {
            case ("POST", "exec"): try await exec(request, peer, lease: lease)
            case ("PUT", "files"): try await upload(request, peer, lease: lease)
            default: try await download(request, peer, lease: lease)
            }
        } catch let error as APIError {
            _ = await peer.send(Server.response(for: error))
        } catch {
            _ = await peer.send(.error("\(error)", status: 500))
        }
    }

    /// The container lease a request may use: its holder's
    /// (`Server.holdersLease`), ready.
    static func lease(_ id: String, access: Access, request: HTTPRequest, api: API) async throws -> Lease {
        let lease = try await Server.holdersLease(id, access: access, request: request, api: api,
                                                  what: "a container's exec and files are")
        guard lease.platform == .container else {
            throw APIError(error: "exec and files through the server are a container lease's: a VM takes SSH (oss machine ssh, upload, "
                                + "download), a simulator simctl, an emulator adb")
        }
        guard lease.state == .ready, lease.execSocket != nil else { throw APIError(error: "lease \(id) isn't ready yet", code: "notReady") }
        return lease
    }

    // MARK: exec

    /// The request's command started in the container, then its frames
    /// relayed both ways as they come until the container closes (after the
    /// exit frame) or the client goes (which ends the command).
    static func exec(_ request: HTTPRequest, _ peer: CachePeer, lease: Lease) async throws {
        guard request.header("upgrade")?.lowercased() == OSSExecProtocol.name else {
            throw APIError(error: "an exec's connection is upgraded: Connection: Upgrade, Upgrade: \(OSSExecProtocol.name)", code: "upgrade")
        }
        guard let length = Int(request.header("content-length") ?? ""), length > 0, length <= 1 << 20 else {
            throw APIError(error: "an exec's body is its ExecRequest (JSON), with its length", code: "length")
        }
        var body = Data()
        guard try await peer.body(Int64(length), { body.append($0) }) else { return }   // the client went away
        guard let exec = try? JSONDecoder().decode(ExecRequest.self, from: body), !exec.arguments.isEmpty else {
            throw APIError(error: "an exec's body is an ExecRequest: {\"arguments\": [...], \"tty\"?, \"columns\"?, \"rows\"?, "
                                + "\"environment\"?, \"workingDirectory\"?}")
        }
        // Its container, waited for while it starts again (the Mac restarted, its helper ended).
        let container: UnixStream
        do {
            container = try await UnixStream.open(lease.execSocket ?? "", waiting: .seconds(180))
        } catch {
            throw APIError(error: "lease \(lease.id)'s container isn't running (its server starts it again): \(error)", code: "notReady")
        }
        defer { container.close() }
        let upgraded = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: \(OSSExecProtocol.name)\r\n\r\n"
        guard await peer.send(Data(upgraded.utf8)), (try? await container.write(ExecFrame.start(exec).encoded)) != nil else { return }
        log("lease \(lease.id): exec \(exec.arguments[0]) through the API")
        // The client's frames to the container; when it goes, the container's
        // side closes, which ends the command.
        let upstream = Task {
            while let data = await peer.next() {
                guard (try? await container.write(data)) != nil else { break }
            }
            container.close()
        }
        // The container's to the client, each sent before the next is read:
        // a slow client holds the command's writes back, as on the socket.
        while let data = await container.read() {
            guard await peer.send(data) else { break }
        }
        upstream.cancel()
        peer.close()
    }

    // MARK: Files

    /// The script every file operation runs in the container
    /// (`sh -c <script> oss-files <what> <path> [<id> <mode>]`): `~/` is the
    /// container's home; an upload is received into `.oss-upload-<id>`
    /// beside its path and moved into place only when the server says it
    /// all came (`commit`), or removed (`discard`).
    static let script = """
        p=$2
        case $p in "~") p=$HOME;; "~/"*) p=$HOME/${p#"~/"};; esac
        case $1 in
        size)
          [ -e "$p" ] || { echo "no file $2" >&2; exit 2; }
          [ -f "$p" ] || { echo "$2 isn't a file" >&2; exit 4; }
          [ -r "$p" ] || { echo "$2 can't be read" >&2; exit 3; }
          wc -c < "$p";;
        read)
          exec cat "$p";;
        receive)
          if [ -d "$p" ]; then echo "$2 is a folder" >&2; exit 4; fi
          d=$(dirname "$p")
          mkdir -p "$d" || exit 1
          t="$d/.oss-upload-$3"
          trap 'rm -f "$t"; exit 143' TERM INT HUP
          cat > "$t" || { rm -f "$t"; exit 1; }
          wc -c < "$t";;
        commit)
          t="$(dirname "$p")/.oss-upload-$3"
          if [ -n "$4" ]; then chmod "$4" "$t" || { rm -f "$t"; exit 1; }; fi
          mv -f "$t" "$p" || { rm -f "$t"; exit 1; }
          case $p in /*) printf '%s' "$p";; *) printf '%s/%s' "$(pwd)" "$p";; esac;;
        discard)
          rm -f "$(dirname "$p")/.oss-upload-$3";;
        esac
        """

    static func files(_ arguments: String...) -> [String] { ["/bin/sh", "-c", script, "oss-files"] + arguments }

    /// The request's `path`.
    static func path(_ request: HTTPRequest) throws -> String {
        guard let path = request.query["path"], !path.isEmpty, path.count <= 4096, !path.contains("\0") else {
            throw APIError(error: "which file? ?path=… (relative to the container's working directory, ~/ its home)")
        }
        return path
    }

    /// `PUT …/files?path=…[&mode=…]`: the body to the container as it comes,
    /// into a file beside the path's, moved into place once it has all come
    /// and the container has all of it.
    static func upload(_ request: HTTPRequest, _ peer: CachePeer, lease: Lease) async throws {
        let path = try path(request)
        let mode = request.query["mode"].flatMap { $0.isEmpty ? nil : $0 }
        if let mode, !(3...4).contains(mode.count) || !mode.allSatisfy({ ("0"..."7").contains($0) }) {
            throw APIError(error: "a file's mode is octal: 644, 755, 0600")
        }
        let chunked = request.header("transfer-encoding")?.lowercased().contains("chunked") == true
        let length = request.header("content-length").flatMap { Int64($0) }
        guard chunked || length != nil else { throw APIError(error: "a put's body has a length (or comes in chunks)", code: "length") }
        let socket = lease.execSocket ?? ""
        let id = Random.hex(6)
        let receiving = try await ContainerCommand.start(socket, files("receive", path, id))
        if request.header("expect")?.lowercased() == "100-continue" {
            guard await peer.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) else {
                receiving.close()
                await discard(socket, path, id)
                return
            }
        }
        let counted = Counter()
        let complete: Bool
        do {
            let sink: (Data) async throws -> Void = { chunk in
                counted.add(Int64(chunk.count))
                try await receiving.write(.stdin(chunk))
            }
            complete = chunked ? try await peer.chunkedBody(sink) : try await peer.body(length ?? 0, sink)
        } catch {
            complete = false
        }
        guard complete else {
            // Cut short (the client went), or the container refused it (a
            // folder there): the receiving command is ended, its file removed.
            receiving.close()
            let ended = await receiving.finish()
            await discard(socket, path, id)
            let message = ended.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError(error: ended.status > 0 && !message.isEmpty ? message : "the upload was cut short")
        }
        try await receiving.write(.closeStdin)
        let received = await receiving.finish()
        let size = Int64(String(decoding: received.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        guard received.status == 0, size == counted.value else {
            await discard(socket, path, id)
            let message = received.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError(error: received.status != 0 && !message.isEmpty ? message
                           : "the container took \(size.map(String.init) ?? "none") of its \(counted.value) bytes")
        }
        let committed = try await ContainerCommand.run(socket, files("commit", path, id, mode ?? ""))
        guard committed.status == 0 else {
            await discard(socket, path, id)
            throw APIError(error: "putting \(path) in place: \(committed.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let file = MachineFile(path: String(decoding: committed.output, as: UTF8.self), size: counted.value)
        log("lease \(lease.id): \(file.path), \(file.size) bytes, put through the API")
        _ = await peer.send(.json(file, status: 201))
    }

    private static func discard(_ socket: String, _ path: String, _ id: String) async {
        _ = try? await ContainerCommand.run(socket, files("discard", path, id))
    }

    /// `GET …/files?path=…`: its size first (its answer's length), then its
    /// bytes as the container reads them.
    static func download(_ request: HTTPRequest, _ peer: CachePeer, lease: Lease) async throws {
        let path = try path(request)
        let socket = lease.execSocket ?? ""
        let sized = try await ContainerCommand.run(socket, files("size", path))
        let message = sized.error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sized.status == 0, let size = Int64(String(decoding: sized.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw APIError(error: message.isEmpty ? "\(path) can't be read (\(sized.status))" : message, code: sized.status == 2 ? "noFile" : nil)
        }
        let head = HTTPResponse(status: 200, body: Data(), contentType: "application/octet-stream", length: size)
        guard await peer.send(head.head(headOnly: true)) else { return }
        // Past its head, a failure can only close the connection short of its
        // length; a file that grew meanwhile is sent as long as it was.
        let sent = Counter()
        let reading = try? await ContainerCommand.start(socket, files("read", path), stdout: { data in
            let room = size - sent.value
            guard room > 0 else { return false }
            let part = data.count > room ? data.prefix(Int(room)) : data
            sent.add(Int64(part.count))
            return await peer.send(part)
        })
        guard let reading else { return }
        try? await reading.write(.closeStdin)
        _ = await reading.finish()
    }
}

extension Server {
    /// The lease a request may use as its holder: a grant's holder's (the
    /// grant names the lease), or with the token the holder `OSS-Holder`
    /// names (`what`: what is the holder's, for the refusal without one).
    /// Another holder's is 404, as storage's are.
    static func holdersLease(_ id: String, access: Access, request: HTTPRequest, api: API, what: String) async throws -> Lease {
        let holder: String
        switch access {
        case .grant(let claims):
            holder = claims.holder
        case .token, .key:
            guard let acting = actingHolder(access, request, named: request.header(OSSHeaders.holder)), !acting.isEmpty else {
                throw APIError(error: "\(what) its holder's: name the holder in \(OSSHeaders.holder)")
            }
            holder = acting
        default:
            throw APIError(error: "OS Monitor's token only reads", code: "forbidden")
        }
        guard let lease = await api.machines.lease(id), lease.holder == holder, lease.state == .creating || lease.state == .ready else {
            throw APIError(error: "no lease \(id) of \(holder)'s", code: "notFound")
        }
        return lease
    }
}

/// A count kept across a body's chunks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ count: Int64) { lock.withLock { total += count } }
    var value: Int64 { lock.withLock { total } }
}

/// A command in a container, run by the server over its exec socket: its
/// stdout kept (up to a megabyte) or handed to `stdout` as it comes, its
/// stderr kept (up to 64 KB), its exit status.
final class ContainerCommand: Sendable {
    struct Result: Sendable {
        var status: Int32
        var output: Data
        var error: String
    }

    private let stream: UnixStream
    private let result: Task<Result, Never>

    private init(stream: UnixStream, result: Task<Result, Never>) {
        self.stream = stream
        self.result = result
    }

    /// Started; `stdout` (when given) is handed its output as it comes,
    /// and ends the command by answering false (its client has gone).
    static func start(_ socket: String, _ arguments: [String],
                      stdout: (@Sendable (Data) async -> Bool)? = nil) async throws -> ContainerCommand {
        try await start(socket, ExecRequest(arguments: arguments), stdout: stdout)
    }

    /// The same with the request's environment and working directory (a CI
    /// job's runner's).
    static func start(_ socket: String, _ request: ExecRequest,
                      stdout: (@Sendable (Data) async -> Bool)? = nil) async throws -> ContainerCommand {
        let stream: UnixStream
        do {
            stream = try await UnixStream.open(socket, waiting: .seconds(60))
        } catch {
            throw APIError(error: "the container isn't running (its server starts it again): \(error)", code: "notReady")
        }
        do {
            try await stream.write(ExecFrame.start(request).encoded)
        } catch {
            stream.close()
            throw APIError(error: "the container's exec socket: \(error)", code: "notReady")
        }
        let result = Task {
            var buffer = Data(), output = Data(), error = Data()
            while let more = await stream.read() {
                buffer.append(more)
                for frame in ExecFrame.decode(&buffer) {
                    switch frame {
                    case .stdout(let data):
                        if let stdout {
                            if !(await stdout(data)) {
                                stream.close()
                                return Result(status: 141, output: output, error: String(decoding: error, as: UTF8.self))
                            }
                        } else if output.count < 1 << 20 {
                            output.append(data)
                        }
                    case .stderr(let data):
                        if error.count < 64 << 10 { error.append(data) }
                    case .exit(let status):
                        return Result(status: status, output: output, error: String(decoding: error, as: UTF8.self))
                    default:
                        break
                    }
                }
            }
            return Result(status: -1, output: output,
                          error: String(decoding: error, as: UTF8.self) + "the container closed the connection before the command ended")
        }
        return ContainerCommand(stream: stream, result: result)
    }

    /// Run with no input, to its end.
    static func run(_ socket: String, _ arguments: [String]) async throws -> Result {
        let command = try await start(socket, arguments)
        try? await command.write(.closeStdin)
        return await command.finish()
    }

    func write(_ frame: ExecFrame) async throws { try await stream.write(frame.encoded) }

    /// Its status and what it wrote, once it has ended.
    func finish() async -> Result {
        let done = await result.value
        stream.close()
        return done
    }

    /// Its connection closed: the command ends (TERM, then KILL ten seconds on).
    func close() { stream.close() }
}

/// A connection to a Unix socket (a container's exec socket), its calls awaited.
final class UnixStream: Sendable {
    private let connection: NWConnection

    private init(_ connection: NWConnection) { self.connection = connection }

    /// Connected, tried again every two seconds until `waiting` passes (a
    /// container started again takes a few).
    static func open(_ path: String, waiting: Duration) async throws -> UnixStream {
        let deadline = ContinuousClock.now + waiting
        while true {
            let stream = UnixStream(NWConnection(to: .unix(path: path), using: .tcp))
            do {
                try await stream.start()
                return stream
            } catch {
                stream.close()
                guard ContinuousClock.now < deadline else { throw error }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Handlers run one at a time on the queue: the first that resumes
            // takes the handler away from the rest.
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "oss.container.exec"))
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// What came next; nil once it has closed (or failed).
    func read() async -> Data? {
        while true {
            let (data, ended): (Data?, Bool) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    continuation.resume(returning: (data, complete || error != nil))
                }
            }
            if let data, !data.isEmpty { return data }
            if ended { return nil }
        }
    }

    func close() { connection.cancel() }
}

#endif
