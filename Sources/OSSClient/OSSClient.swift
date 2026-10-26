import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP exchange, as a transport carries it.
public struct OSSHTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Seconds before it gives up (a long poll asks for its wait and more).
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 120) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct OSSHTTPResponse: Sendable {
    public var status: Int
    /// By lowercased name.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// How a client's requests travel. URLSession by default; another where
/// that can't reach the server (macOS lets only Apple's own tools reach the
/// LAN without the user's leave: the CLI goes through curl).
public protocol OSSTransport: Sendable {
    func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse
}

public struct URLSessionTransport: OSSTransport {
    public init() {}

    public func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw OSSError(status: 0, message: "not an HTTP answer") }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return OSSHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// A request the server refused or couldn't answer: its message, and the
/// HTTP status (0: no answer).
public struct OSSError: Error, Sendable, CustomStringConvertible {
    public var status: Int
    public var message: String
    public var description: String { message }

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}

/// An oss server's API: machines leased and used. Every call is one
/// request and throws `OSSError` with the server's message.
public struct OSSClient: Sendable {
    /// The server's address in use (`http://host:7480`).
    public let server: URL
    /// The token, asked for on every request (so a changed one takes effect at once).
    let token: @Sendable () async throws -> String
    let transport: any OSSTransport
    /// Seconds a request may take, but a long poll's (its wait and a minute more).
    public var timeout: TimeInterval

    /// The server's host: SSH, VNC and adb to a lease go to it too.
    public var host: String { server.host ?? "127.0.0.1" }

    public init(server: URL, token: String, transport: any OSSTransport = URLSessionTransport(), timeout: TimeInterval = 120) {
        self.init(server: server, token: { token }, transport: transport, timeout: timeout)
    }

    /// A client whose token comes from `token` on every request (a secret store, say).
    public init(server: URL, token: @escaping @Sendable () async throws -> String, transport: any OSSTransport = URLSessionTransport(),
                timeout: TimeInterval = 120) {
        self.server = server
        self.token = token
        self.transport = transport
        self.timeout = timeout
    }

    /// The first of `servers` that answers as an oss server (nearest first:
    /// this computer, the LAN, a VPN).
    public static func connect(servers: [URL], token: String, transport: any OSSTransport = URLSessionTransport()) async throws -> OSSClient {
        for server in servers {
            let probe = OSSHTTPRequest(method: "GET", url: server.appendingPathComponent("v1/hello"), timeout: 4)
            if let answer = try? await transport.send(probe), answer.status == 200,
               String(decoding: answer.body, as: UTF8.self).contains("\"oss\"") {
                return OSSClient(server: server, token: token, transport: transport)
            }
        }
        throw OSSError(status: 0, message: "no oss server answered (tried \(servers.map(\.absoluteString).joined(separator: ", ")))")
    }

    // MARK: Requests

    /// A request with this client's token; a status but 2xx thrown with the
    /// server's message. `timeout`: this one's, else the client's.
    public func send(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                     contentType: String = "application/json", timeout: TimeInterval? = nil) async throws -> OSSHTTPResponse {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = (components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath)
            + path
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        // The API level this client speaks: a server shows an older one only
        // what it knows (no containers below 6).
        var headers = ["Authorization": "Bearer \(try await token())", "OSS-API": "\(OSS.apiLevel)"]
        if body != nil { headers["Content-Type"] = contentType }
        let answer = try await transport.send(OSSHTTPRequest(method: method, url: components.url!, headers: headers, body: body,
                                                             timeout: timeout ?? self.timeout))
        guard (200..<300).contains(answer.status) else {
            let message = (try? JSONDecoder.oss.decode(APIError.self, from: answer.body))?.error ?? String(decoding: answer.body, as: UTF8.self)
            throw OSSError(status: answer.status, message: message)
        }
        return answer
    }

    func json<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:]) async throws -> T {
        try JSONDecoder.oss.decode(T.self, from: try await send(method, path, query: query).body)
    }

    func json<T: Decodable, Body: Encodable>(_ method: String, _ path: String, query: [String: String] = [:], body: Body) async throws -> T {
        try JSONDecoder.oss.decode(T.self, from: try await send(method, path, query: query, body: try JSONEncoder.oss.encode(body)).body)
    }

    /// A path segment, percent-encoded (a file's path keeps its slashes).
    static func encode(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "?", "#"])) ?? String($0) }
            .joined(separator: "/")
    }

    // MARK: The server

    public func capabilities() async throws -> Capabilities { try await json("GET", "/v1/capabilities") }
    public func status() async throws -> Status { try await json("GET", "/v1/status") }
    /// The server's Bazel cache, where it keeps one (the `cache` feature).
    public func cache() async throws -> CacheInfo { try await json("GET", "/v1/cache") }

    // MARK: Machines

    public func leases() async throws -> [Lease] { try await json("GET", "/v1/machines") }
    public func lease(_ id: String) async throws -> Lease { try await json("GET", "/v1/machines/\(id)") }

    /// A lease asked for (its state `creating` until it is ready; see `lease(_:waitForCapacity:progress:)`).
    public func requestLease(_ request: LeaseRequest) async throws -> Lease { try await json("POST", "/v1/machines", body: request) }

    /// A lease asked for and waited on until it is ready, or (with
    /// `waitForCapacity`) first until the platform has room. `progress` hears
    /// what it's waiting for.
    public func lease(_ request: LeaseRequest, waitForCapacity: Bool = false,
                      progress: @Sendable (String) -> Void = { _ in }) async throws -> Lease {
        var lease: Lease
        while true {
            do {
                lease = try await requestLease(request)
                break
            } catch let error as OSSError where waitForCapacity && error.message.hasPrefix("busy") {
                progress("\(error.message); waiting")
                try await Task.sleep(for: .seconds(15))
            }
        }
        progress("lease \(lease.id): making \(lease.name)")
        while lease.state == .creating {
            try await Task.sleep(for: .seconds(3))
            lease = try await self.lease(lease.id)
        }
        if let error = lease.error { throw OSSError(status: 0, message: "lease \(lease.id) failed: \(error)") }
        guard lease.state == .ready else { throw OSSError(status: 0, message: "lease \(lease.id) is \(lease.state.rawValue)") }
        return lease
    }

    public func renew(_ id: String, minutes: Int? = nil) async throws -> Lease {
        try await json("POST", "/v1/machines/\(id)/renew", body: RenewRequest(minutes: minutes))
    }

    public func release(_ id: String) async throws {
        _ = try await send("DELETE", "/v1/machines/\(id)")
    }

    /// A file for a lease's simctl or adb commands, named `@<name>` there
    /// (a `.zip` is unpacked: an `.app`).
    public func upload(_ id: String, name: String, data: Data) async throws {
        _ = try await send("PUT", "/v1/machines/\(id)/files/\(Self.encode(name))", body: data, contentType: "application/octet-stream")
    }

    /// `simctl` (an iOS lease) or `adb` (an Android one) on the server, against that device only.
    public func deviceCommand(_ lease: Lease, _ arguments: [String]) async throws -> DeviceCommandResult {
        let tool = lease.platform == .ios ? "simctl" : "adb"
        return try await json("POST", "/v1/machines/\(lease.id)/\(tool)", body: DeviceCommand(arguments: arguments))
    }

    /// A PNG of a lease's screen.
    public func screenshot(_ id: String) async throws -> Data {
        try await send("GET", "/v1/machines/\(id)/screenshot").body
    }

    /// A tap, swipe, text or key on a lease's screen, in its screenshot's pixels.
    public func input(_ id: String, _ request: InputRequest) async throws {
        _ = try await send("POST", "/v1/machines/\(id)/input", body: try JSONEncoder.oss.encode(request))
    }

    /// What the server's Mac and each lease use now.
    public func usage() async throws -> Usage { try await json("GET", "/v1/usage") }

    // MARK: Containers' volumes

    /// The volumes containers made on the server's Mac, kept ones too.
    public func volumes() async throws -> [VolumeInfo] { try await json("GET", "/v1/volumes") }

    /// A kept volume deleted (one no lease is using).
    public func deleteVolume(_ name: String) async throws {
        _ = try await send("DELETE", "/v1/volumes/\(Self.encode(name))")
    }
}
