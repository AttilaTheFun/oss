#if canImport(Network)
import Foundation
import Network
import Testing
import OSSClient
@testable import OSSServer

// A forwarded port (the relay VMs' SSH and VNC and containers' ports go
// through, by Apple's nc), its guest a real TCP server on this computer's
// loopback: what the guest sends before it closes arrives whole, and a
// client's end of input reaches the guest without cutting off its answer.

/// A TCP server on this computer's loopback, answering each connection as
/// its mode says, then ending its side (the end of the stream after all it
/// sent) and closing once the other side has closed too.
final class RelayGuest: @unchecked Sendable {
    enum Mode: Sendable {
        /// Reads a line, a count of bytes: answers that many (`pattern`).
        case countOnALine
        /// Reads to the client's end of input: answers what it read, then `payload`.
        case afterTheEnd(payload: Data)
        /// Sends back what it's sent, until the client's end of input.
        case echo
    }

    let listener: NWListener
    let port: Int

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start(_ mode: Mode) async throws -> RelayGuest {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "oss.test.guest")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            GuestConnection(connection, mode).next()
        }
        let port: Int = await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: Int(listener.port?.rawValue ?? 0))
                case .failed, .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: 0)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard port != 0 else { throw APIError(error: "the guest didn't start") }
        return RelayGuest(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}

/// One of the guest's connections (its events on the guest's queue, one at a time).
private final class GuestConnection: @unchecked Sendable {
    let connection: NWConnection
    let mode: RelayGuest.Mode
    var request = Data()

    init(_ connection: NWConnection, _ mode: RelayGuest.Mode) {
        self.connection = connection
        self.mode = mode
    }

    func next() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { request.append(data) }
            guard error == nil else { connection.cancel(); return }
            switch mode {
            case .countOnALine:
                if let newline = request.firstIndex(of: 0x0A) {
                    return answer(pattern(Int(String(decoding: request[..<newline], as: UTF8.self)) ?? 0))
                }
            case .afterTheEnd(let payload):
                if complete { return answer(request + payload) }
            case .echo:
                if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
                if complete { return answer(Data()) }
            }
            if complete { connection.cancel() } else { next() }
        }
    }

    /// All of it, then the end of the stream; closed once the other side has closed.
    private func answer(_ reply: Data) {
        if !reply.isEmpty { connection.send(content: reply, completion: .contentProcessed { _ in }) }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in drain() })
    }

    private func drain() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] _, _, complete, error in
            if complete || error != nil { connection.cancel() } else { drain() }
        }
    }
}

/// `count` bytes no two runs of which look alike, so a piece lost, doubled or
/// out of order shows.
func pattern(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for i in 0..<count { bytes[i] = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> 13) }
    }
    return data
}

/// A forwarder from a port of the system's choosing to the guest's, once it listens.
func forwarding(to guest: RelayGuest) async throws -> (Forwarder, Int) {
    // A write to an nc that has exited fails (EPIPE), as in the server, rather than ending the tests.
    signal(SIGPIPE, SIG_IGN)
    let forwarder = try Forwarder(port: 0, target: "127.0.0.1", targetPort: guest.port)
    forwarder.start()
    for _ in 0..<250 {
        if let port = forwarder.boundPort { return (forwarder, port) }
        try await Task.sleep(for: .milliseconds(20))
    }
    forwarder.stop()
    throw APIError(error: "the forwarder didn't listen in 5 s")
}

/// A client of the forwarded port: a connection, what it sends, its end of
/// input, and everything that comes until the other side's end.
final class RelayClient: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "oss.test.client")
    /// Times the connection waited and was started again, on `queue`.
    private var waits = 0
    /// The other side's end, once a read has carried it (alone or with the
    /// last bytes): no more is read, as a read past it fails (ENODATA).
    private var ended = false
    /// A failure that came with bytes: thrown by the read after them.
    private var failure: Error?

    private init(_ connection: NWConnection) { self.connection = connection }

    static func connect(port: Int) async throws -> RelayClient {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let client = RelayClient(connection)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .waiting(let error):
                    // A loopback connect can find its 4-tuple still closing from an
                    // earlier connection (EADDRINUSE): Network waits; try again soon.
                    client.waits += 1
                    guard client.waits <= 50 else { once.run { continuation.resume(throwing: error) }; return }
                    client.queue.asyncAfter(deadline: .now() + .milliseconds(20)) { connection.restart() }
                case .cancelled: once.run { continuation.resume(throwing: APIError(error: "cancelled")) }
                default: break
                }
            }
            connection.start(queue: client.queue)
        }
        return client
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Its side shut for writing (`shutdown(SHUT_WR)`, as `printf … | nc` does): its reads go on.
    func endInput() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// What comes next: nil at the other side's end. Network may hand over
    /// the last bytes and the end together; the end is kept for the next read.
    func receive() async throws -> Data? {
        if let failure { throw failure }
        if ended { return nil }
        let (data, complete, error) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(Data?, Bool, NWError?), Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                continuation.resume(returning: (data, complete, error))
            }
        }
        if complete { ended = true }
        guard let data, !data.isEmpty else {
            if let error { throw error }
            return complete ? nil : Data()
        }
        failure = error
        return data
    }

    /// Everything until the other side's end.
    func receiveAll() async throws -> Data {
        var all = Data()
        while let data = try await receive() { all.append(data) }
        return all
    }

    func close() { connection.cancel() }
}

/// A continuation resumed once, whichever state comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

@Test func whatTheGuestSendsBeforeItClosesArrivesWhole() async throws {
    // A request, then 1 to 5 MB and the guest's close, as a web server's
    // download: nc exits as soon as the guest has closed, while the last of
    // it is still on its way to the client. The client starts reading a
    // moment after the guest has sent it all, as one slower than the guest
    // (over the LAN) does. Then small pages, which came back empty.
    let guest = try await RelayGuest.start(.countOnALine)
    defer { guest.stop() }
    let (forwarder, port) = try await forwarding(to: guest)
    defer { forwarder.stop() }
    let sizes = (0..<24).map { 1_000_000 + $0 * 4_000_000 / 23 } + (0..<60).map { 1 + $0 * 97 }
    for size in sizes {
        let client = try await RelayClient.connect(port: port)
        try await client.send(Data("\(size)\n".utf8))
        if size >= 1_000_000 { try await Task.sleep(for: .milliseconds(200)) }
        let reply = try await client.receiveAll()
        client.close()
        #expect(reply.count == size)
        #expect(reply == pattern(size))
    }
}

@Test func aClientThatEndsItsInputStillGetsTheWholeAnswer() async throws {
    // `printf 'GET / …' | nc host port`: the request, then the client's side
    // shut for writing. The guest answers only once that end has reached it.
    let payload = pattern(3_000_000)
    let guest = try await RelayGuest.start(.afterTheEnd(payload: payload))
    defer { guest.stop() }
    let (forwarder, port) = try await forwarding(to: guest)
    defer { forwarder.stop() }
    for attempt in 0..<12 {
        let request = Data("GET /\(attempt) HTTP/1.0\r\nHost: guest\r\n\r\n".utf8)
        let client = try await RelayClient.connect(port: port)
        try await client.send(request)
        try await client.endInput()
        let reply = try await client.receiveAll()
        client.close()
        #expect(reply.count == request.count + payload.count)
        #expect(reply == request + payload)
    }
}

@Test func aConversationGoesBothWaysUntilTheClientEndsIt() async throws {
    // As SSH and VNC are: turn by turn, each answer before the next request;
    // the client's end then ends the guest's side, and the relay.
    let guest = try await RelayGuest.start(.echo)
    defer { guest.stop() }
    let (forwarder, port) = try await forwarding(to: guest)
    defer { forwarder.stop() }
    let client = try await RelayClient.connect(port: port)
    for turn in 0..<20 {
        let message = Data("turn \(turn): ".utf8) + pattern(1 + turn * 5_000)
        try await client.send(message)
        var echoed = Data()
        while echoed.count < message.count, let data = try await client.receive() { echoed.append(data) }
        #expect(echoed == message)
    }
    try await client.endInput()
    #expect(try await client.receiveAll().isEmpty)
    client.close()
}
#endif
