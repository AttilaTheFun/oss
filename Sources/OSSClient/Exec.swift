#if canImport(Network)
import Foundation
import Network

extension OSSClient {
    /// A command run in a container lease, given its socket alone
    /// (`Lease.execSocket`, kept by whoever leased it, on the server's Mac):
    /// straight to the container, not through the server, so it outlives
    /// the server's restarts; no server, no token. What a process that runs
    /// a long command in a container (an agent's host) uses.
    /// `exec(_:_:input:output:)` takes it where it can, and the server's
    /// route where it can't.
    ///
    /// A container that isn't running (the Mac restarted, its helper
    /// ended) is started again by its server within seconds: until
    /// `waiting` passes, the socket is tried again every two seconds. Any
    /// number of commands may run in one container at once. Its output
    /// comes as fast as `output` takes it: while `output` hasn't returned,
    /// the command's writes wait (nothing is dropped).
    public static func exec(socket: String, _ request: ExecRequest, input: AsyncStream<ExecFrame>, waiting: Duration = .seconds(180),
                            output: @escaping @Sendable (ExecFrame) -> Void) async throws -> Int32 {
        let deadline = ContinuousClock.now + waiting
        var connection = ExecConnection(NWConnection(to: .unix(path: socket), using: .tcp))
        while true {
            do {
                try await connection.open()
                break
            } catch {
                connection.close()
                guard ContinuousClock.now < deadline else {
                    throw OSSError(status: 0, message: "the container isn't running (its server starts it again): \(error)", code: "notRunning")
                }
                try await Task.sleep(for: .seconds(2))
                connection = ExecConnection(NWConnection(to: .unix(path: socket), using: .tcp))
            }
        }
        let opened = connection
        defer { opened.close() }
        try await opened.send(ExecFrame.start(request).encoded)
        let pump = Task {
            for await frame in input { try? await opened.send(frame.encoded) }
        }
        defer { pump.cancel() }
        var buffer = Data()
        while true {
            for frame in ExecFrame.decode(&buffer) {
                if case .exit(let code) = frame { return code }
                output(frame)
            }
            guard let more = try await opened.receive() else {
                throw OSSError(status: 0, message: "the container closed the connection before the command ended")
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
                    continuation.resume(throwing: OSSError(status: 0, message: "the container's socket: \(error)"))
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
