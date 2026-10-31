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
    /// The same, with a file's bytes as the body, read as they're sent, and
    /// (with `responseFile`) a 2xx answer's body written to that file, not
    /// held: a stored object can be gigabytes. The default reads and writes
    /// them whole, through `send(_:)`.
    func send(_ request: OSSHTTPRequest, bodyFile: URL?, responseFile: URL?) async throws -> OSSHTTPResponse
    /// A connection of its own to the server, both ways, for a request the
    /// server upgrades (a container's exec, API 9). The default is a TCP
    /// socket of this process's.
    func connect(host: String, port: Int) async throws -> any OSSByteStream
}

extension OSSTransport {
    public func send(_ request: OSSHTTPRequest, bodyFile: URL?, responseFile: URL?) async throws -> OSSHTTPResponse {
        var request = request
        if let bodyFile { request.body = try Data(contentsOf: bodyFile, options: .mappedIfSafe) }
        var answer = try await send(request)
        if let responseFile, (200..<300).contains(answer.status) {
            try answer.body.write(to: responseFile)
            answer.body = Data()
        }
        return answer
    }

    public func connect(host: String, port: Int) async throws -> any OSSByteStream {
        try await OSSSocketStream.connect(host: host, port: port)
    }
}

public struct URLSessionTransport: OSSTransport {
    public init() {}

    private func urlRequest(_ request: OSSHTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    private func answer(_ data: Data, _ response: URLResponse) throws -> OSSHTTPResponse {
        guard let http = response as? HTTPURLResponse else { throw OSSError(status: 0, message: "not an HTTP answer") }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return OSSHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    public func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: urlRequest(request))
        return try answer(data, response)
    }

    #if !canImport(FoundationNetworking)
    public func send(_ request: OSSHTTPRequest, bodyFile: URL?, responseFile: URL?) async throws -> OSSHTTPResponse {
        if let bodyFile {
            var upload = urlRequest(request)
            upload.httpBody = nil
            let (data, response) = try await URLSession.shared.upload(for: upload, fromFile: bodyFile)
            return try answer(data, response)
        }
        guard let responseFile else { return try await send(request) }
        let (location, response) = try await URLSession.shared.download(for: urlRequest(request))
        defer { try? FileManager.default.removeItem(at: location) }
        var answer = try answer(Data(), response)
        if (200..<300).contains(answer.status) {
            try? FileManager.default.removeItem(at: responseFile)
            try FileManager.default.moveItem(at: location, to: responseFile)
        } else {
            answer.body = (try? Data(contentsOf: location)) ?? Data()
        }
        return answer
    }
    #endif
}

/// A request the server refused or couldn't answer: its message, and the
/// HTTP status (0: no answer).
public struct OSSError: Error, Sendable, CustomStringConvertible {
    public var status: Int
    public var message: String
    /// The server's kind of refusal (`APIError.code`): `busy`, `notLocal`,
    /// `noContainers`, `volumeInUse`, `notFound`, `noObject`, `quota`,
    /// `notReady`, `noFile`.
    public var code: String?
    public var description: String { message }

    public init(status: Int, message: String, code: String? = nil) {
        self.status = status
        self.message = message
        self.code = code
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
    /// Who the client acts for within its key's application (API 12, the
    /// `CLIENT_ID` header): a CI job, a Visor session. What it leases and
    /// stores is then `<clientID>@<application>`'s.
    public var clientID: String?

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
        OSSClient(server: try await firstAnswering(servers, transport: transport), token: token, transport: transport)
    }

    /// The first of `servers` that answers as an oss server, in order
    /// (`GET /v1/hello`, which needs no token: a grant's client asks it too).
    public static func firstAnswering(_ servers: [URL], transport: any OSSTransport = URLSessionTransport()) async throws -> URL {
        for server in servers {
            let probe = OSSHTTPRequest(method: "GET", url: server.appendingPathComponent("v1/hello"), timeout: 4)
            if let answer = try? await transport.send(probe), answer.status == 200,
               String(decoding: answer.body, as: UTF8.self).contains("\"oss\"") {
                return server
            }
        }
        throw OSSError(status: 0, message: "no oss server answered (tried \(servers.map(\.absoluteString).joined(separator: ", ")))")
    }

    // MARK: Requests

    /// A request with this client's token; a status but 2xx thrown with the
    /// server's message. `timeout`: this one's, else the client's.
    /// `bodyFile` and `responseFile`: the body read from a file as it's sent,
    /// the answer's written to one (OSSTransport's).
    public func send(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                     contentType: String = "application/json", headers extra: [String: String] = [:],
                     bodyFile: URL? = nil, responseFile: URL? = nil, timeout: TimeInterval? = nil) async throws -> OSSHTTPResponse {
        var headers = extra.merging(try await authorization()) { $1 }
        if body != nil || bodyFile != nil { headers["Content-Type"] = contentType }
        let request = OSSHTTPRequest(method: method, url: url(path, query: query), headers: headers, body: body, timeout: timeout ?? self.timeout)
        return try Self.checked(bodyFile == nil && responseFile == nil
            ? await transport.send(request)
            : await transport.send(request, bodyFile: bodyFile, responseFile: responseFile))
    }

    /// An API path on this client's server, with its query.
    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = (components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath)
            + path
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }

    /// The token, and the API level this client speaks: a server shows an
    /// older one only what it knows (no containers below 6).
    func authorization() async throws -> [String: String] {
        var headers = ["Authorization": "Bearer \(try await token())", "OSS-API": "\(OSS.apiLevel)"]
        if let clientID, !clientID.isEmpty { headers[OSSHeaders.clientID] = clientID }
        return headers
    }

    /// The answer, or a status but 2xx thrown with the server's message.
    static func checked(_ answer: OSSHTTPResponse) throws -> OSSHTTPResponse {
        guard (200..<300).contains(answer.status) else {
            let refusal = try? JSONDecoder.oss.decode(APIError.self, from: answer.body)
            throw OSSError(status: answer.status, message: refusal?.error ?? String(decoding: answer.body, as: UTF8.self), code: refusal?.code)
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
    /// A device type or runtime asked of a server before API 11, which
    /// would make its base's instead, is refused here.
    public func requestLease(_ request: LeaseRequest) async throws -> Lease {
        if request.device != nil || request.runtime != nil {
            let api = try await capabilities().api
            guard api >= 11 else {
                throw OSSError(status: 0, message: "this server (API \(api)) makes no simulator of another device type or runtime: "
                                                 + "that's OS Server 0.13.0's (API 11)")
            }
        }
        return try await json("POST", "/v1/machines", body: request)
    }

    /// A lease asked for and waited on until it is ready, or (with
    /// `waitForCapacity`) first until the platform has room. `progress` hears
    /// what it's waiting for. Waiting, it asks with a ticket of its own
    /// (API 14: a server before ignores it), so the server keeps its place in
    /// line; a lease bigger than the server's whole budget (`tooBig`) isn't
    /// waited for.
    public func lease(_ request: LeaseRequest, waitForCapacity: Bool = false,
                      progress: @Sendable (String) -> Void = { _ in }) async throws -> Lease {
        var request = request
        if waitForCapacity, request.waitTicket == nil { request.waitTicket = UUID().uuidString }
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

    /// The last day of the server's Mac, a sample a minute.
    public func usageHistory() async throws -> [UsageSample] { try await json("GET", "/v1/usage/history") }

    // MARK: Containers' volumes

    /// The volumes containers made on the server's Mac, kept ones too.
    public func volumes() async throws -> [VolumeInfo] { try await json("GET", "/v1/volumes") }

    /// A kept volume deleted (one no lease is using).
    public func deleteVolume(_ name: String) async throws {
        _ = try await send("DELETE", "/v1/volumes/\(Self.encode(name))")
    }
}
