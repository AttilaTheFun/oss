import Foundation
import OSSClient
#if canImport(Network)
import Network
#endif

/// Linux containers, for a server that can run them: OS Server's app gives
/// one (on Apple's Containerization, in its own process), `oss serve` on
/// its own has none and lends no containers. The server keeps the leases;
/// the backend keeps the containers, each named by its lease
/// (`oss-lease-container-<id>`).
public protocol ContainerBackend: Sendable {
    /// Started from `spec` (its image pulled if this Mac hasn't it); returns
    /// once its main process runs.
    func start(name: String, spec: ContainerSpec) async throws
    /// A command run in it, its standard streams through `session`; its
    /// exit status.
    func exec(name: String, request: ExecRequest, session: ExecSession) async throws -> Int32
    /// Stopped and deleted, its root filesystem with it.
    func stop(name: String) async
    /// Every container deleted (at the server's start: none outlives the
    /// process that ran it).
    func removeAll() async
    /// The folder its root filesystem is in, for the disk it takes.
    func directory(name: String) -> String?
}

/// What a container gets where its lease asks for nothing.
public enum ContainerDefaults {
    public static let cpus = 4
    public static let memoryBytes: Int64 = 8 << 30
    public static let diskBytes: Int64 = 64 << 30
}

/// An exec's two directions: what the client sends (stdin, its end, a
/// terminal's new size) and a way to send it stdout and stderr.
public final class ExecSession: Sendable {
    public let input: AsyncStream<ExecFrame>
    private let output: @Sendable (ExecFrame) -> Void

    init(input: AsyncStream<ExecFrame>, output: @escaping @Sendable (ExecFrame) -> Void) {
        self.input = input
        self.output = output
    }

    public func stdout(_ data: Data) { output(.stdout(data)) }
    public func stderr(_ data: Data) { output(.stderr(data)) }
}

#if canImport(Network)
/// The connection an exec runs over, once upgraded: frames in (decoded into
/// the session's input), frames out; the exit status last, then closed.
enum ExecBridge {
    static func run(_ connection: NWConnection, rest: Data, lease: String, request: ExecRequest,
                    backend: ContainerBackend) {
        let (input, continuation) = AsyncStream<ExecFrame>.makeStream()
        let session = ExecSession(input: input) { frame in
            connection.send(content: frame.encoded, completion: .idempotent)
        }
        var buffer = rest
        for frame in ExecFrame.decode(&buffer) { continuation.yield(frame) }
        receive(connection, buffer: buffer, continuation: continuation)
        Task {
            let status: Int32
            do {
                status = try await backend.exec(name: lease, request: request, session: session)
            } catch {
                session.stderr(Data("oss: \(error)\n".utf8))
                status = 126
            }
            continuation.finish()
            connection.send(content: ExecFrame.exit(status).encoded, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func receive(_ connection: NWConnection, buffer: Data, continuation: AsyncStream<ExecFrame>.Continuation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            for frame in ExecFrame.decode(&buffer) { continuation.yield(frame) }
            if complete || error != nil {
                continuation.yield(.closeStdin)
                return
            }
            receive(connection, buffer: buffer, continuation: continuation)
        }
    }
}
#endif

extension LocalNetworks {
    /// Whether an address is this Mac's own (loopback, or one of its
    /// interfaces'): a container is lent only to a client on its Mac.
    static func isThisMac(_ address: String?) -> Bool {
        // An IPv4 client on the dual-stack listener comes as ::ffff:a.b.c.d.
        guard let address = address.map({ $0.hasPrefix("::ffff:") ? String($0.dropFirst(7)) : $0 }) else { return false }
        if address == "::1" || address.hasPrefix("127.") { return true }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let socketAddress = pointer.pointee.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(socketAddress.pointee.sa_family == sa_family_t(AF_INET6) ? MemoryLayout<sockaddr_in6>.size
                                                                                            : MemoryLayout<sockaddr_in>.size)
            guard getnameinfo(socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if text.components(separatedBy: "%")[0] == address { return true }
        }
        return false
    }
}
