#if canImport(Network)
import Foundation
import Network

extension OSSClient {
    /// A command run in a container lease: `input` sent as it comes (stdin,
    /// its end, a terminal's new size), what the command writes handed to
    /// `output` (`.stdout`, `.stderr`); returns its exit status. Over the
    /// server's port on loopback, upgraded to a stream of `ExecFrame`s: a
    /// container is lent only on its server's Mac.
    public func exec(_ id: String, _ request: ExecRequest, input: AsyncStream<ExecFrame>,
                     output: @escaping @Sendable (ExecFrame) -> Void) async throws -> Int32 {
        let port = server.port ?? 7480
        let connection = ExecConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp))
        try await connection.open()
        defer { connection.close() }
        let body = try JSONEncoder.oss.encode(request)
        var head = "POST /v1/machines/\(Self.encode(id))/exec HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        head += "Authorization: Bearer \(try await token())\r\nOSS-API: \(OSS.apiLevel)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: Upgrade\r\nUpgrade: oss-exec\r\n\r\n"
        try await connection.send(Data(head.utf8) + body)

        // The answer's head: 101, or an error with the server's message.
        var buffer = Data()
        var end: Range<Data.Index>?
        while true {
            end = buffer.range(of: Data("\r\n\r\n".utf8))
            if end != nil { break }
            guard let more = try await connection.receive() else { throw OSSError(status: 0, message: "the server closed the connection") }
            buffer.append(more)
        }
        let lines = String(decoding: buffer[..<end!.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
        buffer = Data(buffer[end!.upperBound...])
        guard status == 101 else {
            let length = lines.dropFirst().compactMap { line -> Int? in
                let pair = line.split(separator: ":", maxSplits: 1)
                return pair.count == 2 && pair[0].lowercased() == "content-length" ? Int(pair[1].trimmingCharacters(in: .whitespaces)) : nil
            }.first ?? 0
            while buffer.count < length, let more = try await connection.receive() { buffer.append(more) }
            let message = (try? JSONDecoder.oss.decode(APIError.self, from: buffer))?.error ?? String(decoding: buffer, as: UTF8.self)
            throw OSSError(status: status, message: message)
        }

        let pump = Task {
            for await frame in input { try? await connection.send(frame.encoded) }
        }
        defer { pump.cancel() }
        while true {
            for frame in ExecFrame.decode(&buffer) {
                if case .exit(let code) = frame { return code }
                output(frame)
            }
            guard let more = try await connection.receive() else {
                throw OSSError(status: 0, message: "the connection closed before the command ended")
            }
            buffer.append(more)
        }
    }
}

/// An NWConnection's calls, awaited.
private final class ExecConnection: Sendable {
    private let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    func open() async throws {
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
                    continuation.resume(throwing: OSSError(status: 0, message: "127.0.0.1: \(error)"))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "oss.exec"))
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// What came next; nil once the server has closed its side.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: complete ? nil : Data()) }
            }
        }
    }

    func close() { connection.cancel() }
}
#endif
