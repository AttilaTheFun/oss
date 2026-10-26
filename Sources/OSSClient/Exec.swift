#if canImport(Network)
import Foundation
import Network

extension OSSClient {
    /// A command run in a container lease: `input` sent as it comes (stdin,
    /// its end, a terminal's new size, signals), what the command writes
    /// handed to `output` (`.stdout`, `.stderr`); returns its exit status.
    /// Straight to the container over its Unix socket on the server's Mac
    /// (`Lease.execSocket`), not through the server: a command outlives the
    /// server's restarts. Ending the task (or the process) ends the command.
    public func exec(_ lease: Lease, _ request: ExecRequest, input: AsyncStream<ExecFrame>,
                     output: @escaping @Sendable (ExecFrame) -> Void) async throws -> Int32 {
        guard let socket = lease.execSocket else {
            throw OSSError(status: 0, message: "lease \(lease.id) takes no commands (a container's, once it is ready)")
        }
        return try await Self.exec(socket: socket, request, input: input, output: output)
    }

    /// The same, given the container's socket alone (`Lease.execSocket`,
    /// kept by whoever leased it): no server, no token. What a process that
    /// runs a long command in a container (an agent's host) uses.
    public static func exec(socket: String, _ request: ExecRequest, input: AsyncStream<ExecFrame>,
                            output: @escaping @Sendable (ExecFrame) -> Void) async throws -> Int32 {
        let connection = ExecConnection(NWConnection(to: .unix(path: socket), using: .tcp))
        try await connection.open()
        defer { connection.close() }
        try await connection.send(ExecFrame.start(request).encoded)
        let pump = Task {
            for await frame in input { try? await connection.send(frame.encoded) }
        }
        defer { pump.cancel() }
        var buffer = Data()
        while true {
            for frame in ExecFrame.decode(&buffer) {
                if case .exit(let code) = frame { return code }
                output(frame)
            }
            guard let more = try await connection.receive() else {
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
