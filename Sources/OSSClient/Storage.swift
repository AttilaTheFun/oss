import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// Storage (API 7): files kept on the server by their content's SHA-256, for
// a while. A holder (a user@host, Visor's `visor:<session>`) puts a file and
// gets a lease on it; the bytes are kept once however many leases hold them,
// and deleted once no lease does. A lease lasts 24 hours unless asked
// otherwise (at most 7 days), and is renewed or released like a machine's.
// Requests say their holder in the `OSS-Holder` header; a holder sees and
// changes only its own leases.

/// An object in the store: its content's SHA-256 and its size.
public struct StorageObject: Codable, Sendable, Hashable {
    public var sha256: String
    public var size: Int64

    public init(sha256: String, size: Int64) {
        self.sha256 = sha256
        self.size = size
    }
}

/// A holder's lease on an object, which keeps it until the lease is
/// released or expires. A name, if it has one, is unique among the holder's
/// leases: a put with a name already used releases the lease that had it.
public struct StorageLease: Codable, Sendable, Identifiable {
    public var id: String
    public var holder: String
    public var sha256: String
    public var size: Int64
    public var name: String?
    public var created: Date
    public var expires: Date

    public init(id: String, holder: String, sha256: String, size: Int64, name: String? = nil, created: Date, expires: Date) {
        self.id = id
        self.holder = holder
        self.sha256 = sha256
        self.size = size
        self.name = name
        self.created = created
        self.expires = expires
    }
}

/// What a put answers: the object, the lease it got, and whether the store
/// had the bytes already (they're kept once).
public struct StoragePut: Codable, Sendable {
    public var object: StorageObject
    public var lease: StorageLease
    public var existed: Bool

    public init(object: StorageObject, lease: StorageLease, existed: Bool) {
        self.object = object
        self.lease = lease
        self.existed = existed
    }
}

/// The store's use (`Status.storage`): the objects holders' leases keep
/// and their bytes, against the store's cap and each holder's; and the
/// files the server serves by their SHA-256 (`oss files add`), held by the
/// server itself and counted apart.
public struct StorageInfo: Codable, Sendable {
    public var objects: Int
    public var bytes: Int64
    public var maxBytes: Int64
    public var maxBytesPerHolder: Int64
    public var leases: Int
    public var servedFiles: Int
    public var servedBytes: Int64

    public init(objects: Int, bytes: Int64, maxBytes: Int64, maxBytesPerHolder: Int64, leases: Int, servedFiles: Int, servedBytes: Int64) {
        self.objects = objects
        self.bytes = bytes
        self.maxBytes = maxBytes
        self.maxBytesPerHolder = maxBytesPerHolder
        self.leases = leases
        self.servedFiles = servedFiles
        self.servedBytes = servedBytes
    }
}

/// A grant asked for (`POST /v1/grants`): a URL that does one thing, on one
/// lease or object, for a few minutes, with no token. Whoever holds the
/// token (Visor) asks for one in a holder's name, and hands the URL to
/// what may do only that (an agent in a container).
public struct GrantRequest: Codable, Sendable {
    /// What it allows: `storage.put`, `storage.get` or `machine.install`;
    /// from API 9 `machine.exec`, `machine.upload` and `machine.download`
    /// (a container lease's commands, and its files either way); from API
    /// 10 `machine.xctest` (tests run on an iOS lease's simulator, and
    /// their results read).
    public var verb: String
    /// `machine.install`, `machine.xctest`: the iOS lease (the holder's
    /// own); `machine.exec`, `machine.upload`, `machine.download`: the
    /// container lease (the holder's own).
    public var lease: String?
    /// `storage.get`: the object, by its SHA-256 or a name of the holder's.
    public var object: String?
    /// How long the URL works: `5m` unless asked otherwise, at most `15m`.
    public var ttl: String?
    /// `storage.put`: the name and the TTL the object's lease will get.
    public var name: String?
    public var objectTTL: String?

    public init(verb: String, lease: String? = nil, object: String? = nil, ttl: String? = nil, name: String? = nil, objectTTL: String? = nil) {
        self.verb = verb
        self.lease = lease
        self.object = object
        self.ttl = ttl
        self.name = name
        self.objectTTL = objectTTL
    }
}

/// A grant: its URL (the server's address as the asker reached it), the
/// same as a path for a client that reaches the server by another address,
/// and when it stops working. It may be used any number of times until then.
public struct Grant: Codable, Sendable {
    public var verb: String
    public var url: URL
    public var path: String
    public var expires: Date

    public init(verb: String, url: URL, path: String, expires: Date) {
        self.verb = verb
        self.url = url
        self.path = path
        self.expires = expires
    }
}

/// An app installed on an iOS lease's simulator from the store
/// (`POST /v1/machines/<id>/install`): an .ipa or a zipped .app the lease's
/// holder has a lease on, by its SHA-256 or name.
public struct InstallRequest: Codable, Sendable {
    public var object: String
    public init(object: String) { self.object = object }
}

public struct InstallResult: Codable, Sendable {
    /// The object's SHA-256, the app's bundle name and its identifier (to launch it).
    public var object: String
    public var app: String
    public var bundleIdentifier: String?

    public init(object: String, app: String, bundleIdentifier: String?) {
        self.object = object
        self.app = app
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum OSSHeaders {
    /// Who a storage request is for: its leases are this holder's.
    public static let holder = "OSS-Holder"
    /// A put's SHA-256 as the client counted it: checked, and with an empty
    /// body, enough when the store has the object already.
    public static let sha256 = "OSS-SHA256"
    /// An xctest's run (API 10), in its `101 Switching Protocols`: the id
    /// its JUnit and result bundle are read by.
    public static let xctestRun = "OSS-XCTest-Run"
    /// An application's API key (API 12), in place of the bearer token.
    public static let apiKey = "API_KEY"
    /// Who a keyed request acts for within its application (API 12).
    public static let clientID = "CLIENT_ID"
}

extension OSSClient {
    /// A file's SHA-256, read a few megabytes at a time; nil where there's no
    /// CryptoKit (Linux), and a put sends its bytes without it.
    public static func sha256(ofFile url: URL) throws -> String? {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    /// Seconds an object's transfer may take.
    static let transferTimeout: TimeInterval = 6 * 3600

    /// The holder's leases on objects.
    public func storageLeases(holder: String) async throws -> [StorageLease] {
        try JSONDecoder.oss.decode([StorageLease].self,
                                   from: try await send("GET", "/v1/storage/leases", headers: [OSSHeaders.holder: holder]).body)
    }

    /// Whether the store has an object: its size, or nil.
    public func objectSize(_ sha256: String) async throws -> Int64? {
        do {
            let answer = try await send("HEAD", "/v1/storage/objects/\(sha256)")
            return answer.headers["content-length"].flatMap { Int64($0) } ?? 0
        } catch let error as OSSError where error.status == 404 {
            return nil
        }
    }

    /// A file put in the store for `holder`: its bytes sent only if the
    /// store hasn't got them (a HEAD by its SHA-256 first).
    public func putObject(file: URL, holder: String, name: String? = nil, ttl: String? = nil) async throws -> StoragePut {
        var headers = [OSSHeaders.holder: holder]
        var query: [String: String] = [:]
        if let name { query["name"] = name }
        if let ttl { query["ttl"] = ttl }
        if let hash = try OSSClient.sha256(ofFile: file) {
            headers[OSSHeaders.sha256] = hash
            if try await objectSize(hash) != nil {
                do {
                    return try JSONDecoder.oss.decode(StoragePut.self, from: try await send("PUT", "/v1/storage/objects", query: query,
                                                                                             body: Data(), contentType: "application/octet-stream",
                                                                                             headers: headers).body)
                } catch let error as OSSError where error.code == "noObject" {
                    // Swept since the HEAD: its bytes after all.
                }
            }
        }
        return try JSONDecoder.oss.decode(StoragePut.self, from: try await send("PUT", "/v1/storage/objects", query: query,
                                                                                 contentType: "application/octet-stream", headers: headers,
                                                                                 bodyFile: file, timeout: Self.transferTimeout).body)
    }

    /// Bytes put in the store for `holder`.
    public func putObject(_ data: Data, holder: String, name: String? = nil, ttl: String? = nil) async throws -> StoragePut {
        var query: [String: String] = [:]
        if let name { query["name"] = name }
        if let ttl { query["ttl"] = ttl }
        return try JSONDecoder.oss.decode(StoragePut.self, from: try await send("PUT", "/v1/storage/objects", query: query, body: data,
                                                                                 contentType: "application/octet-stream",
                                                                                 headers: [OSSHeaders.holder: holder],
                                                                                 timeout: Self.transferTimeout).body)
    }

    /// An object's bytes, for a holder with a lease on it.
    public func object(_ sha256: String, holder: String) async throws -> Data {
        try await send("GET", "/v1/storage/objects/\(sha256)", headers: [OSSHeaders.holder: holder], timeout: Self.transferTimeout).body
    }

    /// An object's bytes written to `file` as they come.
    public func downloadObject(_ sha256: String, holder: String, to file: URL) async throws {
        _ = try await send("GET", "/v1/storage/objects/\(sha256)", headers: [OSSHeaders.holder: holder], responseFile: file,
                           timeout: Self.transferTimeout)
    }

    /// A lease's time set again: `ttl` from now (24 hours unless asked otherwise, at most 7 days).
    public func renewStorageLease(_ id: String, holder: String, ttl: String? = nil) async throws -> StorageLease {
        try JSONDecoder.oss.decode(StorageLease.self, from: try await send("POST", "/v1/storage/leases/\(Self.encode(id))/renew",
                                                                            query: ttl.map { ["ttl": $0] } ?? [:],
                                                                            headers: [OSSHeaders.holder: holder]).body)
    }

    /// A lease released: its object goes once no lease holds it.
    public func releaseStorageLease(_ id: String, holder: String) async throws {
        _ = try await send("DELETE", "/v1/storage/leases/\(Self.encode(id))", headers: [OSSHeaders.holder: holder])
    }

    /// A grant in `holder`'s name: a URL that does `request.verb`, on that
    /// lease or object only, without the token.
    public func grant(_ request: GrantRequest, holder: String) async throws -> Grant {
        try JSONDecoder.oss.decode(Grant.self, from: try await send("POST", "/v1/grants", body: try JSONEncoder.oss.encode(request),
                                                                     headers: [OSSHeaders.holder: holder]).body)
    }

    /// An .ipa or a zipped .app from the store installed on an iOS lease's
    /// simulator: an object its holder has a lease on, by SHA-256 or name.
    public func install(_ leaseID: String, object: String) async throws -> InstallResult {
        // Unpacking an .ipa and installing it can take minutes.
        try JSONDecoder.oss.decode(InstallResult.self, from: try await send("POST", "/v1/machines/\(leaseID)/install",
                                                                             body: try JSONEncoder.oss.encode(InstallRequest(object: object)),
                                                                             timeout: 900).body)
    }
}

/// What a grant's URL does, for a client that has it and no token: the
/// URL is its own credential (`?grant=…`), good for its one verb on its
/// one lease or object until it expires.
public struct OSSGrantClient: Sendable {
    public let url: URL
    let transport: any OSSTransport

    public init(url: URL, transport: any OSSTransport = URLSessionTransport()) {
        self.url = url
        self.transport = transport
    }

    /// A grant given as its URL, or as its path alone (`Grant.path`,
    /// `/v1/…?grant=…`, the same grant at any of the server's addresses) on
    /// the first of `servers` that answers, as a client with the token finds
    /// its server: a grant asked for on the server's Mac names it as that Mac
    /// reached it (`127.0.0.1`), which a container or another computer
    /// reaches by another address.
    public static func resolving(_ grant: String, servers: [URL], transport: any OSSTransport = URLSessionTransport()) async throws
        -> OSSGrantClient {
        if let url = URL(string: grant), url.scheme != nil, url.host != nil { return OSSGrantClient(url: url, transport: transport) }
        guard grant.hasPrefix("/") else { throw OSSError(status: 0, message: "a grant is its URL (http://…) or its path (/v1/…?grant=…)") }
        var base = try await OSSClient.firstAnswering(servers, transport: transport).absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + grant) else { throw OSSError(status: 0, message: "no URL from \(base) and the grant's path") }
        return OSSGrantClient(url: url, transport: transport)
    }

    /// A request to the grant's URL, with `query` beside its own (a file's
    /// path), or to a path below its own (`below`: an xctest run's
    /// `<run>/junit`), its grant kept.
    func send(_ method: String, below: String? = nil, query: [String: String] = [:], body: Data? = nil, headers: [String: String] = [:],
              bodyFile: URL? = nil, responseFile: URL? = nil, timeout: TimeInterval = OSSClient.transferTimeout) async throws -> OSSHTTPResponse {
        var headers = headers.merging(["OSS-API": "\(OSS.apiLevel)"]) { $1 }
        if body != nil || bodyFile != nil { headers["Content-Type"] = method == "POST" ? "application/json" : "application/octet-stream" }
        var target = url
        if !query.isEmpty || below != nil, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let below { components.percentEncodedPath += "/" + OSSClient.encode(below) }
            if !query.isEmpty {
                components.queryItems = (components.queryItems ?? [])
                    + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            target = components.url ?? url
        }
        let request = OSSHTTPRequest(method: method, url: target, headers: headers, body: body, timeout: timeout)
        return try OSSClient.checked(bodyFile == nil && responseFile == nil
            ? await transport.send(request)
            : await transport.send(request, bodyFile: bodyFile, responseFile: responseFile))
    }

    /// `storage.put`: a file put in the store, in the grant's holder's name
    /// (with the name and TTL the grant gives). With its SHA-256 sent first
    /// and no body, the bytes go only if the store hasn't got them.
    public func put(file: URL) async throws -> StoragePut {
        if let hash = try OSSClient.sha256(ofFile: file) {
            do {
                return try JSONDecoder.oss.decode(StoragePut.self, from: try await send("PUT", body: Data(), headers: [OSSHeaders.sha256: hash]).body)
            } catch let error as OSSError where error.code == "noObject" {
                return try JSONDecoder.oss.decode(StoragePut.self, from: try await send("PUT", headers: [OSSHeaders.sha256: hash], bodyFile: file).body)
            }
        }
        return try JSONDecoder.oss.decode(StoragePut.self, from: try await send("PUT", bodyFile: file).body)
    }

    public func put(_ data: Data) async throws -> StoragePut {
        try JSONDecoder.oss.decode(StoragePut.self, from: try await send("PUT", body: data).body)
    }

    /// `storage.get`: the object's bytes.
    public func get() async throws -> Data { try await send("GET").body }

    /// `storage.get`: the object's bytes written to `file` as they come.
    public func get(to file: URL) async throws { _ = try await send("GET", responseFile: file) }

    /// `machine.install`: an object the lease's holder has a lease on
    /// installed on its simulator.
    public func install(object: String) async throws -> InstallResult {
        try JSONDecoder.oss.decode(InstallResult.self, from: try await send("POST", body: try JSONEncoder.oss.encode(InstallRequest(object: object)),
                                                                             timeout: 900).body)
    }
}
