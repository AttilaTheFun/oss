import CryptoKit
import Foundation
import OSSClient

#if canImport(Network)

/// What the API's routes reach: the machines, the store, the Bazel cache,
/// the API's token and the grants' key.
struct API: Sendable {
    let machines: MachineManager
    let token: String
    let cache: CacheServer?
    let storage: StorageStore
    let grants: GrantKey
}

/// Who a request comes from: the API's token (anything, for any holder it
/// names), OS Monitor's (reads only), or a grant's URL (its one route, in
/// its holder's name); or refused, with the answer.
enum Access: Sendable {
    case token
    case monitor
    case grant(GrantClaims)
    case refused(HTTPResponse)
}

/// A request's body as it arrives.
protocol RequestBody: Sendable {
    /// Before the body is read: a client that waits for it is told to go on
    /// (100 Continue). False when the client has gone.
    func proceed() async -> Bool
    /// The bytes handed to `sink` as they come: whether the whole body came.
    func read(_ sink: (Data) throws -> Void) async throws -> Bool
}

/// A body read from its connection, by its length or in chunks.
struct PeerBody: RequestBody {
    let peer: CachePeer
    let request: HTTPRequest

    func proceed() async -> Bool {
        request.header("expect")?.lowercased() == "100-continue" ? await peer.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) : true
    }

    func read(_ sink: (Data) throws -> Void) async throws -> Bool {
        if request.header("transfer-encoding")?.lowercased().contains("chunked") == true { return try await peer.chunkedBody(sink) }
        return try await peer.body(Int64(request.header("content-length") ?? "0") ?? 0, sink)
    }
}

/// A streamed request's answer: a response, or an object's bytes (open
/// for reading, kept from the sweep, until they're sent).
enum StreamAnswer: Sendable {
    case response(HTTPResponse)
    case object(hash: String, path: String, size: Int64)
}

extension Server {
    /// The answer to a refusal, by its code.
    static func response(for error: APIError) -> HTTPResponse {
        let status: Int
        switch error.code {
        case "busy", "notReady": status = 409
        case "notLocal", "forbidden": status = 403
        case "notFound", "noObject", "noFile": status = 404
        case "quota": status = 413
        case "length": status = 411
        case "upgrade": status = 426
        default: status = error.error.hasPrefix("busy") ? 409 : 400
        }
        return HTTPResponse(status: status, body: (try? JSONEncoder.oss.encode(error)) ?? Data())
    }

    /// Who's asking. A request with no token and a `grant` is taken on the
    /// one route its verb and resource name, unexpired, signed by this
    /// server; any other is 403, the same 403 whatever is wrong.
    static func access(_ request: HTTPRequest, _ parts: [String], api: API) -> Access {
        let authorization = request.header("authorization")
        if authorization == nil, let grant = request.query["grant"] {
            guard let use = GrantKey.use(request.method, parts),
                  let claims = api.grants.verify(grant, verb: use.verb, resource: use.resource) else {
                return .refused(.error("this grant doesn't allow that", status: 403))
            }
            return .grant(claims)
        }
        let given = authorization?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        if constantTimeEqual(given, api.token) { return .token }
        // The monitor token (OS Monitor's) reads and does nothing else.
        guard constantTimeEqual(given, MonitorAccess.token()) else { return .refused(.error("unauthorized", status: 401)) }
        guard MonitorAccess.allows(request.method, parts) else { return .refused(.error("OS Monitor's token only reads", status: 403)) }
        return .monitor
    }

    /// The holder a storage request is for: a grant's, or the one it names.
    static func holder(_ access: Access, _ request: HTTPRequest) throws -> String {
        if case .grant(let claims) = access { return claims.holder }
        return try StorageStore.holder(request.header(OSSHeaders.holder))
    }

    /// Whether a request may read the served files through the API: by
    /// `/files/sha256/…`'s rules (the server keeps a cache, whose port serves
    /// them; the client is this Mac, its VMs or containers, the tailnet
    /// where the cache allows it, or the LAN where it allows that).
    static func readsServedFiles(_ request: HTTPRequest, api: API) -> Bool {
        guard let cache = api.cache, let remote = request.remoteAddress,
              let address = LocalNetworks.value(remote.hasPrefix("::ffff:") ? String(remote.dropFirst(7)) : remote) else { return false }
        return cache.config.lanReads || LocalNetworks.isInternal(address) || (cache.config.tailnetReads && address & 0xFFC0_0000 == 0x6440_0000)
    }

    /// The server's address as the asker reached it (for a grant's URL).
    static func base(_ request: HTTPRequest) -> String {
        if let host = request.header("host"), !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:[]".contains($0) }) {
            return "http://\(host)"
        }
        return "http://\(localHostName):\(ServerConfig.load().port)"
    }

    // MARK: Streamed

    /// The requests whose bodies or answers are streamed, not held: an
    /// object's put and its get; a container's exec (its connection
    /// upgraded) and its files' puts and gets; an iOS lease's xctest (its
    /// connection upgraded) and its results.
    static func streams(_ method: String, _ path: String) -> Bool {
        let parts = (path.split(separator: "?").first ?? "").split(separator: "/").map(String.init)
        return (method == "PUT" && parts == ["v1", "storage", "objects"])
            || (method == "GET" && parts.count == 4 && Array(parts[0...2]) == ["v1", "storage", "objects"])
            || ContainerAPI.streams(method, parts) || XCTestAPI.streams(method, parts)
    }

    /// A streamed request, on its connection.
    static func stream(_ request: HTTPRequest, _ peer: CachePeer, api: API) async {
        let parts = (request.path.split(separator: "?").first ?? "").split(separator: "/").map(String.init)
        if ContainerAPI.streams(request.method, parts) { return await ContainerAPI.serve(request, peer, api: api) }
        if XCTestAPI.streams(request.method, parts) { return await XCTestAPI.serve(request, peer, api: api) }
        switch await streamed(request, body: PeerBody(peer: peer, request: request), api: api) {
        case .response(let response):
            _ = await peer.send(response)
        case .object(let hash, let path, let size):
            if let file = FileHandle(forReadingAtPath: path) {
                let head = HTTPResponse(status: 200, body: Data(), contentType: "application/octet-stream", length: size)
                if await peer.send(head.head(headOnly: true)) {
                    while let chunk = try? file.read(upToCount: 1 << 20), !chunk.isEmpty {
                        guard await peer.send(chunk) else { break }
                    }
                }
                try? file.close()
            } else {
                _ = await peer.send(.error("the object can't be read", status: 500))
            }
            await api.storage.close(hash)
        }
    }

    /// An object's put or get: its body read through `body` as it comes, or
    /// its bytes to be sent.
    static func streamed(_ request: HTTPRequest, body: some RequestBody, api: API) async -> StreamAnswer {
        let parts = (request.path.split(separator: "?").first ?? "").split(separator: "/").map(String.init)
        let access = Self.access(request, parts, api: api)
        if case .refused(let response) = access { return .response(response) }
        do {
            if request.method == "PUT", parts == ["v1", "storage", "objects"] {
                return .response(try await put(request, access: access, body: body, api: api))
            }
            guard request.method == "GET", parts.count == 4, parts[1] == "storage", parts[2] == "objects" else {
                return .response(.error("no such endpoint: \(request.method) \(request.path)", status: 404))
            }
            return try await get(parts[3], request, access: access, api: api)
        } catch let error as APIError {
            return .response(response(for: error))
        } catch {
            return .response(.error("\(error)", status: 500))
        }
    }

    /// `PUT /v1/storage/objects`: the body written to a file of its own,
    /// hashed as it comes, checked against `OSS-SHA256` if given, and moved
    /// into place (or dropped, if the store has it); then the holder's lease.
    private static func put(_ request: HTTPRequest, access: Access, body: some RequestBody, api: API) async throws -> HTTPResponse {
        let holder = try Self.holder(access, request)
        let name: String?, ttl: TimeInterval
        if case .grant(let claims) = access {
            // What the grant gives: its URL's own query can't change it.
            name = claims.name
            ttl = claims.objectTTL ?? StorageStore.defaultTTL
        } else {
            name = try StorageStore.name(request.query["name"])
            ttl = try Durations.clamped(request.query["ttl"], default: StorageStore.defaultTTL, most: StorageStore.maxTTL)
        }
        let expected = request.header(OSSHeaders.sha256)?.lowercased()
        if let expected, !ServedFiles.isHash(expected) { throw APIError(error: "\(OSSHeaders.sha256) is 64 hex digits") }
        let chunked = request.header("transfer-encoding")?.lowercased().contains("chunked") == true
        let length = request.header("content-length").flatMap { Int64($0) }
        // Its hash and no bytes: a lease on what the store has (else noObject).
        if let expected, !chunked, (length ?? 0) == 0, expected != StorageStore.emptyHash {
            return .json(try await api.storage.store(temporary: nil, hash: expected, holder: holder, name: name, ttl: ttl), status: 201)
        }
        guard chunked || length != nil else { throw APIError(error: "a put's body has a length (or comes in chunks)", code: "length") }
        try await api.storage.admit(holder: holder, name: name, hash: expected, length: chunked ? nil : length)
        guard await body.proceed() else { throw APIError(error: "the client went away") }
        let temporary = api.storage.incoming()
        // Removed however this ends (moved into place, it's gone already).
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        FileManager.default.createFile(atPath: temporary, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let out = FileHandle(forWritingAtPath: temporary) else { throw ShellError(description: "the store can't write") }
        var hasher = SHA256()
        let complete: Bool
        do {
            complete = try await body.read { data in
                try out.write(contentsOf: data)
                hasher.update(data: data)
            }
            try out.close()
        } catch {
            try? out.close()
            throw APIError(error: "the upload failed: \(error)")
        }
        guard complete else { throw APIError(error: "the upload was cut short") }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected, expected != hash { throw APIError(error: "its content's SHA-256 is \(hash), not \(expected)") }
        return .json(try await api.storage.store(temporary: temporary, hash: hash, holder: holder, name: name, ttl: ttl), status: 201)
    }

    /// `GET /v1/storage/objects/<sha256>`: an object the holder has a lease
    /// on, or a served file under the served files' rules.
    private static func get(_ name: String, _ request: HTTPRequest, access: Access, api: API) async throws -> StreamAnswer {
        let hash = name.lowercased()
        let holder = try? Self.holder(access, request)
        var allowed = false
        if let holder, await api.storage.holds(holder, hash) {
            allowed = true
        } else if case .grant = access {
            // Issued for a served file only to an asker who could read it.
            allowed = api.storage.isServed(hash)
        } else {
            allowed = api.storage.isServed(hash) && readsServedFiles(request, api: api)
        }
        guard allowed, ServedFiles.isHash(hash), let (path, size) = await api.storage.open(hash) else {
            throw APIError(error: "no object \(name)" + (holder.map { " of \($0)'s" } ?? ""), code: "notFound")
        }
        return .object(hash: hash, path: path, size: size)
    }

    // MARK: Buffered

    /// The storage, grant and install routes whose bodies are small: nil
    /// for any other route.
    static func storageRoute(_ request: HTTPRequest, _ parts: [String], access: Access, api: API) async throws -> HTTPResponse? {
        switch (request.method, parts.count) {
        case ("HEAD", 4) where parts[1] == "storage" && parts[2] == "objects":
            // Whether the store has it: what a put by its hash alone needs.
            guard let size = api.storage.size(parts[3].lowercased()) else { return .error("no object \(parts[3])", status: 404) }
            return HTTPResponse(status: 200, body: Data(), contentType: "application/octet-stream", length: size)
        case ("GET", 3) where parts[1] == "storage" && parts[2] == "leases":
            return .json(await api.storage.leases(of: try holder(access, request)))
        case ("POST", 5) where parts[1] == "storage" && parts[2] == "leases" && parts[4] == "renew":
            let ttl = try Durations.clamped(request.query["ttl"], default: StorageStore.defaultTTL, most: StorageStore.maxTTL)
            return .json(try await api.storage.renew(parts[3], holder: try holder(access, request), ttl: ttl))
        case ("DELETE", 4) where parts[1] == "storage" && parts[2] == "leases":
            try await api.storage.release(parts[3], holder: try holder(access, request))
            return .json(["released": parts[3]])
        case ("POST", 2) where parts[1] == "grants":
            guard case .token = access else { return .error("a grant is asked for with the API's token", status: 403) }
            let body = try JSONDecoder.oss.decode(GrantRequest.self, from: request.body)
            var lease: Lease?
            if let id = body.lease { lease = await api.machines.lease(id) }
            return .json(try await api.grants.issue(body, holder: try holder(access, request), lease: lease, storage: api.storage,
                                                    readsServedFiles: readsServedFiles(request, api: api), base: base(request)), status: 201)
        case ("POST", 4) where parts[1] == "machines" && parts[3] == "install":
            let body = try JSONDecoder.oss.decode(InstallRequest.self, from: request.body)
            var asker: String?
            if case .grant(let claims) = access { asker = claims.holder }
            return .json(try await Installs.install(on: try await api.machines.ready(parts[2]), object: body.object, holder: asker,
                                                    storage: api.storage))
        default:
            return nil
        }
    }
}

/// An app installed on an iOS lease's simulator from the store: an .ipa
/// (its `Payload/<name>.app`) or a zipped .app (`ditto -c -k --keepParent`),
/// one the lease's holder has a lease on, unpacked beside the lease's
/// uploads and installed with simctl.
enum Installs {
    /// `holder`: a grant's, which installs on its own lease only.
    static func install(on lease: Lease, object: String, holder: String?, storage: StorageStore) async throws -> InstallResult {
        if let holder, holder != lease.holder { throw APIError(error: "no lease \(lease.id) of \(holder)'s", code: "notFound") }
        guard lease.platform == .ios else { throw APIError(error: "install is for an iOS lease (a simulator); an emulator takes adb install") }
        let hash = try await storage.resolve(object, holder: lease.holder)
        guard let udid = lease.udid, let (archive, _) = await storage.open(hash) else {
            throw APIError(error: "no simulator or no object \(object) for lease \(lease.id)", code: "notFound")
        }
        let directory = "\(Paths.uploads)/\(lease.id)/install-\(Random.hex(4))"
        do {
            let (app, bundleIdentifier) = try await installApp(from: archive, in: directory, udid: udid)
            try? FileManager.default.removeItem(atPath: directory)
            await storage.close(hash)
            log("lease \(lease.id): installed \(app) from the store (\(hash.prefix(12))…)")
            return InstallResult(object: hash, app: app, bundleIdentifier: bundleIdentifier)
        } catch {
            try? FileManager.default.removeItem(atPath: directory)
            await storage.close(hash)
            throw error
        }
    }

    private static func installApp(from archive: String, in directory: String, udid: String) async throws -> (String, String?) {
        // Both are zips: "PK\3\4".
        let handle = FileHandle(forReadingAtPath: archive)
        let magic = try? handle?.read(upToCount: 4)
        try? handle?.close()
        guard magic == Data([0x50, 0x4B, 0x03, 0x04]) else { throw APIError(error: "not an .ipa or a zipped .app (it isn't a zip)") }
        Paths.ensure(directory)
        let unzip = try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive, directory], timeout: 600)
        guard unzip.ok else { throw APIError(error: "unpacking it: \(unzip.error)") }
        let apps = ["\(directory)/Payload", directory].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }.map { "\(folder)/\($0)" }
        }
        guard apps.count == 1, let app = apps.first else {
            throw APIError(error: apps.isEmpty ? "no .app in it (an .ipa's Payload/, or a zipped .app)" : "more than one .app in it")
        }
        let result = try await Simulators.simctl(["install", udid, app], timeout: 600)
        guard result.ok else { throw APIError(error: "simctl install: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let info = NSDictionary(contentsOfFile: "\(app)/Info.plist")
        return ((app as NSString).lastPathComponent, info?["CFBundleIdentifier"] as? String)
    }
}

#endif
