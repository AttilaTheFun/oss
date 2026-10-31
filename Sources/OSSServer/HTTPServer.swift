import Foundation
import OSSClient
#if canImport(Network)
import Network

extension NWParameters {
    /// TCP over IPv4, for OS Server's listeners (the API, the cache, a
    /// lease's forwarded ports). Network.framework's default listener, one
    /// IPv6 socket taking IPv4 too, never sees a connection that comes in over
    /// a tailnet (Tailscale's tunnel), though it sees the LAN's and loopback's;
    /// an IPv4 one sees them all. (Two listeners, one each, can't share the
    /// port.) Nothing reaches OS Server over IPv6.
    static var listening: NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        return parameters
    }
}

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    /// The client's address, as the connection came from it.
    var remoteAddress: String? = nil

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The query's values, percent-decoded.
    var query: [String: String] {
        guard let components = URLComponents(string: path) else { return [:] }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
        return values
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var body: Data
    var contentType = "application/json"
    var headers: [String: String] = [:]
    /// A HEAD's answer: the length the GET's body would have (it has none).
    var length: Int64? = nil

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder.oss.encode(value)) ?? Data())
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(APIError(error: message), status: status)
    }

    static let reasons = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                          405: "Method Not Allowed", 409: "Conflict", 411: "Length Required", 413: "Content Too Large", 426: "Upgrade Required",
                          500: "Internal Server Error", 503: "Service Unavailable"]

    /// Its status line and fields, the connection closed after it; without
    /// the body when `headOnly` (a HEAD's answer, or a streamed one's, whose
    /// body follows).
    func head(headOnly: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(length ?? Int64(body.count))\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + (headOnly ? Data() : body)
    }
}

/// A small HTTP/1.1 server: one request a connection, bodies by
/// Content-Length, on every interface. A request `streams` picks (a stored
/// object's put or get, which can be gigabytes) is handed its connection
/// once its head has come, its body read and its answer written as they go.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    typealias Streamer = @Sendable (HTTPRequest, CachePeer) async -> Void
    /// An answer made at once, on the listener's queue, without waiting for
    /// a task to run it: `/v1/hello`, which says the server is up, must not
    /// wait behind work that holds Swift's threads (a client gives up on a
    /// hello in seconds). Nil: the handler's, in a task.
    typealias Immediate = @Sendable (HTTPRequest) -> HTTPResponse?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "oss.http")
    private let handler: Handler
    private let streams: @Sendable (_ method: String, _ path: String) -> Bool
    private let streamer: Streamer
    private let immediate: Immediate

    init(port: Int, streams: @escaping @Sendable (_ method: String, _ path: String) -> Bool = { _, _ in false },
         streamer: @escaping Streamer = { _, _ in }, immediate: @escaping Immediate = { _ in nil },
         handler: @escaping Handler) throws {
        let parameters = NWParameters.listening
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        self.handler = handler
        self.streams = streams
        self.streamer = streamer
        self.immediate = immediate
    }

    /// The port it listens on once it does: the one asked for, or (asked
    /// for 0, as a test's is) the one the system gave.
    var boundPort: Int? { listener.port.map { Int($0.rawValue) }.flatMap { $0 == 0 ? nil : $0 } }

    /// No longer listening (a test's server; OS Server's lasts as long as it does).
    func stop() {
        listener.stateUpdateHandler = nil
        listener.cancel()
    }

    func start() {
        listener.newConnectionHandler = { [queue, handler, streams, streamer, immediate] connection in
            connection.start(queue: queue)
            HTTPServer.read(connection, buffer: Data(), handler: handler, streams: streams, streamer: streamer, immediate: immediate)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("oss: the API's listener failed: \(error)\n".utf8))
                exit(1)
            }
        }
        listener.start(queue: queue)
    }

    private static func read(_ connection: NWConnection, buffer: Data, handler: @escaping Handler,
                             streams: @escaping @Sendable (String, String) -> Bool, streamer: @escaping Streamer,
                             immediate: @escaping Immediate) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            func remoteAddress() -> String? {
                guard case .hostPort(let host, _) = connection.endpoint else { return nil }
                return "\(host)".components(separatedBy: "%")[0]
            }
            if let (head, bodyStart) = parseHead(buffer), streams(head.method, head.path) {
                // Its body (or its answer) too big to hold: the connection is the streamer's.
                var request = head
                request.remoteAddress = remoteAddress()
                let peer = CachePeer(connection, buffered: Data(buffer[bodyStart...]))
                Task {
                    await streamer(request, peer)
                    connection.cancel()
                }
            } else if let request = parse(buffer) {
                var request = request
                request.remoteAddress = remoteAddress()
                if let response = immediate(request) {
                    send(response, headOnly: request.method == "HEAD", on: connection)
                    return
                }
                let arrived = ContinuousClock.now
                Task {
                    // A request that waited for a thread says so: something
                    // is holding Swift's threads (blocking work in a task).
                    let waited = ContinuousClock.now - arrived
                    if waited > .seconds(2) {
                        FileHandle.standardError.write(Data("oss: \(request.method) \(request.path.split(separator: "?")[0]) waited \(waited) for a thread\n".utf8))
                    }
                    let response = await handler(request)
                    send(response, headOnly: request.method == "HEAD", on: connection)
                }
            } else if complete || error != nil || buffer.count > 1 << 30 {
                connection.cancel()
            } else {
                read(connection, buffer: buffer, handler: handler, streams: streams, streamer: streamer, immediate: immediate)
            }
        }
    }

    /// The request's head once it has arrived (its body empty), and where
    /// its body starts.
    private static func parseHead(_ buffer: Data) -> (HTTPRequest, Data.Index)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data()), end.upperBound)
    }

    /// The request, once its head and its whole body have arrived.
    private static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let (head, bodyStart) = parseHead(buffer) else { return nil }
        var request = head
        let length = Int(request.header("content-length") ?? "0") ?? 0
        let body = buffer[bodyStart...]
        guard body.count >= length else { return nil }
        request.body = Data(body.prefix(length))
        return request
    }

    private static func send(_ response: HTTPResponse, headOnly: Bool, on connection: NWConnection) {
        connection.send(content: response.head(headOnly: headOnly), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

extension CachePeer {
    /// An API answer, whole (the connection closes after it).
    func send(_ response: HTTPResponse) async -> Bool { await send(response.head()) }
}

#endif
