#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import OSSClient

/// What a grant says, signed: what it allows (its verb), where (the API
/// path below `/v1/` it opens), in whose name, until when (seconds since
/// 1970); and for a put, the name and TTL its object's lease will get.
struct GrantClaims: Codable, Sendable, Equatable {
    var verb: String
    var resource: String
    var holder: String
    var expires: Int
    var name: String?
    var objectTTL: TimeInterval?
}

/// The CI jobs' grants that work now (API 13), by their runner's lease: a
/// job's grant works while its runner's lease lasts, and not once CI has
/// taken it back (its runner ended) or the server started again.
final class JobGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var live: Set<String> = []

    func open(_ lease: String) { lock.withLock { _ = live.insert(lease) } }
    func close(_ lease: String) { lock.withLock { _ = live.remove(lease) } }
    func isOpen(_ lease: String) -> Bool { lock.withLock { live.contains(lease) } }
}

/// What a CI job's grant opens (API 13): what a job's scripts do with
/// `oss` — machines leased, used and released, objects stored and read,
/// the Bazel cache's read token — in its holder's name; the leases it names
/// must be the holder's (Server.route). Never keys, grants of its own,
/// volumes, usage or the server's status.
enum JobGrantRoutes {
    static func allows(_ method: String, _ parts: [String]) -> Bool {
        guard parts.first == "v1", parts.count >= 2 else { return false }
        switch (method, parts[1], parts.count) {
        case ("GET", "machines", 2), ("POST", "machines", 2): return true
        case ("GET", "machines", 3), ("DELETE", "machines", 3): return true
        case ("POST", "machines", 4): return ["renew", "simctl", "adb", "input", "install", "exec", "xctest"].contains(parts[3])
        case ("GET", "machines", 4): return ["screenshot", "files"].contains(parts[3])
        case ("PUT", "machines", 4): return parts[3] == "files"
        case ("PUT", "machines", 5): return parts[3] == "files"
        case ("GET", "machines", 6): return parts[3] == "xctest" && ["junit", "result"].contains(parts[5])
        case ("PUT", "storage", 3): return parts[2] == "objects"
        case ("GET", "storage", 4), ("HEAD", "storage", 4): return parts[2] == "objects"
        case ("GET", "storage", 3): return parts[2] == "leases"
        case ("POST", "storage", 5): return parts[2] == "leases" && parts[4] == "renew"
        case ("DELETE", "storage", 4): return parts[2] == "leases"
        case ("GET", "cache", 2): return true
        default: return false
        }
    }
}

#if canImport(CryptoKit)
/// Grants (`POST /v1/grants`): a URL that does one thing without the API's
/// token, for a client that has only it (an agent in a container, its
/// session's Visor holding the token). Its `grant` query parameter is the
/// claims and an HMAC-SHA256 of them, under a key only the server has
/// (`grant-key` in its folder: made the first time, never logged, nor are
/// grants). The server takes one only on the route its verb and resource
/// name, until it expires, as often as it's used until then; anything else
/// is the same 403, whatever was wrong.
struct GrantKey: Sendable {
    let key: Data

    /// Grants last this long unless asked otherwise, and at most so long.
    static let defaultTTL: TimeInterval = 5 * 60
    static let maxTTL: TimeInterval = 15 * 60
    /// The verbs there are grants for. A container lease's files go each
    /// way by a verb of their own, as the store's do: a grant that puts
    /// files in reads none out. `machine.xctest` runs an iOS lease's tests
    /// and reads their results (a run's results are no use without it).
    static let verbs = ["storage.put", "storage.get", "machine.install", "machine.exec", "machine.upload", "machine.download",
                        "machine.xctest"]
    /// The verbs whose lease is an iOS lease's.
    static let iosVerbs = ["machine.install", "machine.xctest"]
    /// The verbs whose lease is a container's.
    static let containerVerbs = ["machine.exec", "machine.upload", "machine.download"]

    /// The server's key: read, or made (32 random bytes, readable by its owner only).
    static func ensure(_ path: String = Paths.grantKey) -> GrantKey {
        if let data = FileManager.default.contents(atPath: path),
           let key = Data(hex: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), key.count >= 32 {
            return GrantKey(key: key)
        }
        Paths.ensure((path as NSString).deletingLastPathComponent)
        let hex = Random.hex(32)
        FileManager.default.createFile(atPath: path, contents: Data((hex + "\n").utf8), attributes: [.posixPermissions: 0o600])
        return GrantKey(key: Data(hex: hex)!)
    }

    /// The `grant` parameter for these claims: base64url(JSON).base64url(HMAC).
    func token(_ claims: GrantClaims) -> String {
        let payload = (try? JSONEncoder().encode(claims)) ?? Data()
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))
        return payload.base64URL + "." + Data(mac).base64URL
    }

    /// The claims, if `token` is this server's, for this verb on this
    /// resource, and unexpired; nil otherwise, whatever is wrong.
    func verify(_ token: String, verb: String, resource: String, now: Date = Date()) -> GrantClaims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Data(base64URL: String(parts[0])), let mac = Data(base64URL: String(parts[1])),
              HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: payload, using: SymmetricKey(data: key)),
              let claims = try? JSONDecoder().decode(GrantClaims.self, from: payload),
              claims.verb == verb, claims.resource == resource, TimeInterval(claims.expires) > now.timeIntervalSince1970 else { return nil }
        return claims
    }

    /// A CI job's grant's verb (API 13): its resource is its runner's lease
    /// (`machines/<id>`), its holder the job's.
    static let jobVerb = "ci.job"
    /// A job's grant expires after this whatever happens, though it stops
    /// working sooner, when its runner's lease ends (JobGrants).
    static let jobTTL: TimeInterval = 3 * 24 * 60 * 60

    /// A CI job's grant: what its scripts lease, use and store in `holder`'s
    /// name (JobGrantRoutes), while `runner` (its runner's lease) is open in
    /// `live`. Its URL is on `base`, the server as the job's container
    /// reaches it. Opened here; CI closes it when the runner ends.
    func issueJob(holder: String, runner: String, base: String, live: JobGrants, now: Date = Date()) throws -> URL {
        let claims = GrantClaims(verb: Self.jobVerb, resource: "machines/\(runner)", holder: holder,
                                 expires: Int(now.addingTimeInterval(Self.jobTTL).timeIntervalSince1970))
        guard let url = URL(string: "\(base)/v1/machines?grant=\(token(claims))") else { throw APIError(error: "no URL from \(base)") }
        live.open(runner)
        log("grant: \(Self.jobVerb) for \(holder), while lease \(runner) lasts")
        return url
    }

    /// The cache's write, for CI's populate job alone (`ci.populate`): a
    /// password good while its runner's lease lasts, in place of the write
    /// token, which never leaves the server's Mac.
    static let cacheWriteVerb = "ci.cache-write"

    func issueCacheWrite(holder: String, runner: String, live: JobGrants, now: Date = Date()) -> String {
        live.open(runner)
        log("grant: \(Self.cacheWriteVerb) for \(holder), while lease \(runner) lasts")
        return token(GrantClaims(verb: Self.cacheWriteVerb, resource: "machines/\(runner)", holder: holder,
                                 expires: Int(now.addingTimeInterval(Self.jobTTL).timeIntervalSince1970)))
    }

    /// Whether `token` is a populate job's cache write whose runner's lease
    /// is still open.
    func verifyCacheWrite(_ token: String, live: JobGrants, now: Date = Date()) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Data(base64URL: String(parts[0])),
              let claims = try? JSONDecoder().decode(GrantClaims.self, from: payload), claims.verb == Self.cacheWriteVerb,
              claims.resource.hasPrefix("machines/"), live.isOpen(String(claims.resource.dropFirst("machines/".count))) else { return false }
        return verify(token, verb: Self.cacheWriteVerb, resource: claims.resource, now: now) != nil
    }

    /// The claims, if `token` is a CI job's grant of this server's whose
    /// runner's lease is still open; nil otherwise.
    func verifyJob(_ token: String, live: JobGrants, now: Date = Date()) -> GrantClaims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Data(base64URL: String(parts[0])),
              let claims = try? JSONDecoder().decode(GrantClaims.self, from: payload), claims.verb == Self.jobVerb,
              claims.resource.hasPrefix("machines/"), live.isOpen(String(claims.resource.dropFirst("machines/".count))) else { return nil }
        return verify(token, verb: Self.jobVerb, resource: claims.resource, now: now)
    }

    /// The verb and resource a request would take a grant for: nil on a
    /// route no grant opens.
    static func use(_ method: String, _ parts: [String]) -> (verb: String, resource: String)? {
        guard parts.first == "v1" else { return nil }
        if method == "PUT", parts == ["v1", "storage", "objects"] { return ("storage.put", "storage/objects") }
        if method == "GET" || method == "HEAD", parts.count == 4, parts[1] == "storage", parts[2] == "objects" {
            return ("storage.get", "storage/objects/\(parts[3])")
        }
        if method == "POST", parts.count == 4, parts[1] == "machines", parts[3] == "install" { return ("machine.install", "machines/\(parts[2])") }
        if method == "POST", parts.count == 4, parts[1] == "machines", parts[3] == "exec" { return ("machine.exec", "machines/\(parts[2])") }
        if method == "PUT", parts.count == 4, parts[1] == "machines", parts[3] == "files" { return ("machine.upload", "machines/\(parts[2])") }
        if method == "GET", parts.count == 4, parts[1] == "machines", parts[3] == "files" { return ("machine.download", "machines/\(parts[2])") }
        if method == "POST", parts.count == 4, parts[1] == "machines", parts[3] == "xctest" { return ("machine.xctest", "machines/\(parts[2])") }
        if method == "GET", parts.count == 6, parts[1] == "machines", parts[3] == "xctest", ["junit", "result"].contains(parts[5]) {
            return ("machine.xctest", "machines/\(parts[2])")
        }
        return nil
    }

    /// A grant in `holder`'s name, where the plain API would let the holder
    /// do the same: a put; a get of an object it has a lease on (or a
    /// served file, where `readsServedFiles`); an install on, or tests run
    /// on, an iOS lease it holds; a command in, or files to or from, a
    /// container lease it holds (`lease`: the one the request names, as the
    /// server has it).
    /// `base`: the server's address as the asker reached it.
    func issue(_ request: GrantRequest, holder: String, lease: Lease?, storage: StorageStore, readsServedFiles: Bool,
               base: String, now: Date = Date()) async throws -> Grant {
        let ttl = try Durations.clamped(request.ttl, default: Self.defaultTTL, most: Self.maxTTL)
        var claims = GrantClaims(verb: request.verb, resource: "", holder: holder, expires: Int(now.addingTimeInterval(ttl).timeIntervalSince1970))
        let path: String
        switch request.verb {
        case "storage.put":
            claims.resource = "storage/objects"
            claims.name = try StorageStore.name(request.name)
            claims.objectTTL = try Durations.clamped(request.objectTTL, default: StorageStore.defaultTTL, most: StorageStore.maxTTL)
            path = "/v1/storage/objects"
        case "storage.get":
            guard let object = request.object, !object.isEmpty else { throw APIError(error: "a storage.get grant names its object") }
            let hash: String
            if let held = try? await storage.resolve(object, holder: holder) {
                hash = held
            } else if readsServedFiles, storage.isServed(object.lowercased()) {
                hash = object.lowercased()
            } else {
                throw APIError(error: "\(holder) holds no object \(object)", code: "notFound")
            }
            claims.resource = "storage/objects/\(hash)"
            path = "/v1/storage/objects/\(hash)"
        case let verb where Self.iosVerbs.contains(verb):
            guard let id = request.lease, !id.isEmpty else { throw APIError(error: "a \(verb) grant names its lease") }
            guard let lease, lease.id == id, lease.holder == holder, lease.state == .creating || lease.state == .ready else {
                throw APIError(error: "no lease \(id) of \(holder)'s", code: "notFound")
            }
            guard lease.platform == .ios else {
                throw APIError(error: "\(verb == "machine.install" ? "install" : "xctest") is for an iOS lease (a simulator)")
            }
            claims.resource = "machines/\(id)"
            path = "/v1/machines/\(id)/" + (verb == "machine.install" ? "install" : "xctest")
        case let verb where Self.containerVerbs.contains(verb):
            guard let id = request.lease, !id.isEmpty else { throw APIError(error: "a \(verb) grant names its lease") }
            guard let lease, lease.id == id, lease.holder == holder, lease.state == .creating || lease.state == .ready else {
                throw APIError(error: "no lease \(id) of \(holder)'s", code: "notFound")
            }
            guard lease.platform == .container else {
                throw APIError(error: "\(verb) is for a container lease (a VM takes SSH, a simulator simctl, an emulator adb)")
            }
            claims.resource = "machines/\(id)"
            path = "/v1/machines/\(id)/" + (verb == "machine.exec" ? "exec" : "files")
        default:
            throw APIError(error: "no verb \(request.verb) (there are \(Self.verbs.joined(separator: ", ")))")
        }
        let full = "\(path)?grant=\(token(claims))"
        guard let url = URL(string: base + full) else { throw APIError(error: "no URL from \(base)") }
        log("grant: \(request.verb) on \(claims.resource) for \(holder), \(Durations.describe(ttl))")
        return Grant(verb: request.verb, url: url, path: full, expires: Date(timeIntervalSince1970: TimeInterval(claims.expires)))
    }
}
#endif

extension Data {
    /// Base64 with `-` and `_`, unpadded: safe in a URL's query.
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
