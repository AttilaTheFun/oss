import Foundation
import OSSClient
#if canImport(Network)
import Network

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

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder.oss.encode(value)) ?? Data())
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(APIError(error: message), status: status)
    }
}

/// A small HTTP/1.1 server: one request a connection, bodies by
/// Content-Length, on every interface.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    private let listener: NWListener
    private let queue = DispatchQueue(label: "oss.http")
    private let handler: Handler

    init(port: Int, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [queue, handler] connection in
            connection.start(queue: queue)
            HTTPServer.read(connection, buffer: Data(), handler: handler)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("oss: the API's listener failed: \(error)\n".utf8))
                exit(1)
            }
        }
        listener.start(queue: queue)
    }

    private static func read(_ connection: NWConnection, buffer: Data, handler: @escaping Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) {
                var request = request
                if case .hostPort(let host, _) = connection.endpoint { request.remoteAddress = "\(host)".components(separatedBy: "%")[0] }
                Task {
                    let response = await handler(request)
                    send(response, on: connection)
                }
            } else if complete || error != nil || buffer.count > 1 << 30 {
                connection.cancel()
            } else {
                read(connection, buffer: buffer, handler: handler)
            }
        }
    }

    /// The request, once its head and its whole body have arrived.
    private static func parse(_ buffer: Data) -> HTTPRequest? {
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
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private static func send(_ response: HTTPResponse, on connection: NWConnection) {
        let reason = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      409: "Conflict", 500: "Internal Server Error", 503: "Service Unavailable"][response.status] ?? "Status"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

#endif
