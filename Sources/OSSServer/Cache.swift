import Foundation
import OSSClient

// A Bazel remote cache, Bazel's HTTP protocol (`--remote_cache=http://…`):
// `GET`, `HEAD` and `PUT` of `/ac/<sha256>` (an action's result) and
// `/cas/<sha256>` (a blob, by its content's hash). One job writes it (CI's,
// after each merge to main) with the write token, which never leaves the
// server's Mac but piped into what keeps it; everyone else reads it with the
// read token, which leases get in their bazelrc and API clients from
// `GET /v1/cache`. Reading is for this Mac, its VMs and its containers only
// (the networks it shares with them), unless the settings open it to the LAN.

/// The cache's settings: `"cache"` in server.json (`{}` for the defaults);
/// without it the server keeps no cache.
struct CacheConfig: Codable, Sendable {
    /// Its port, on every interface: who may do what is by token, and for
    /// reading by where the request comes from.
    var port: Int = 7490
    var directory: String = "\(Paths.state)/bazel-cache"
    /// At most this much, in gigabytes: the entries read longest ago go first.
    var maxGigabytes: Double = 20
    /// The disk's free space is kept above this, in gigabytes: the cache
    /// gives up entries, read longest ago first, to keep it.
    var minFreeGigabytes: Double = 30
    /// Whether computers other than this Mac, its VMs and its containers
    /// (the LAN, a VPN) may read with the read token. The write token reads
    /// and writes from anywhere.
    var lanReads: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CacheConfig()
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        directory = try c.decodeIfPresent(String.self, forKey: .directory) ?? d.directory
        maxGigabytes = try c.decodeIfPresent(Double.self, forKey: .maxGigabytes) ?? d.maxGigabytes
        minFreeGigabytes = try c.decodeIfPresent(Double.self, forKey: .minFreeGigabytes) ?? d.minFreeGigabytes
        lanReads = try c.decodeIfPresent(Bool.self, forKey: .lanReads) ?? d.lanReads
    }

    var maxBytes: Int64 { Int64(maxGigabytes * 1_000_000_000) }
    var minFreeBytes: Int64 { Int64(minFreeGigabytes * 1_000_000_000) }
}

/// The cache's two tokens, made with the first cache the server keeps
/// (readable by its owner only).
enum CacheTokens {
    static let readPath = "\(Paths.config)/cache-read-token"
    static let writePath = "\(Paths.config)/cache-write-token"

    static func read(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func ensure(_ path: String) -> String {
        if let token = read(path) { return token }
        Paths.ensure(Paths.config)
        let token = Random.hex(32)
        FileManager.default.createFile(atPath: path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600])
        return token
    }
}

/// What a computer's Bazel needs to read the cache: an address in its
/// bazelrc (no secret there), the read token in its .netrc, which Bazel's
/// HTTP cache takes credentials from. (`--remote_cache_header` never
/// reaches an HTTP cache; `--remote_header`, quoted, does, but then the
/// token is in the bazelrc, and `--announce_rc` prints it.) Bazel warns,
/// once a build, that credentials go in plaintext: they stay on this Mac's
/// own networks.
enum CacheClientFiles {
    static let begin = "# oss: the server's Bazel cache, read-only (its populate job writes it; the token is in .netrc)"
    static let end = "# oss: end"

    static func bazelrc(host: String, port: Int) -> [String] {
        [begin, "build --remote_cache=http://\(host):\(port)", "build --noremote_upload_local_results", end]
    }

    static func netrcEntry(host: String, token: String) -> String { "machine \(host) login bazel password \(token)" }

    /// This computer's own (`oss cache use`): any earlier block of oss's
    /// replaced, and the server's line in .netrc replaced; `nil` takes both away.
    static func use(host: String, port: Int, token: String?) throws {
        let rcPath = "\(Paths.home)/.bazelrc", netrcPath = "\(Paths.home)/.netrc"
        var rc = (FileManager.default.contents(atPath: rcPath).map { String(decoding: $0, as: UTF8.self) } ?? "")
            .components(separatedBy: "\n")
        if let first = rc.firstIndex(of: begin), let last = rc[first...].firstIndex(of: end) { rc.removeSubrange(first...last) }
        while rc.last == "" { rc.removeLast() }
        if token != nil { rc += bazelrc(host: host, port: port) }
        try Data((rc.joined(separator: "\n") + (rc.isEmpty ? "" : "\n")).utf8).write(to: URL(fileURLWithPath: rcPath))
        var netrc = (FileManager.default.contents(atPath: netrcPath).map { String(decoding: $0, as: UTF8.self) } ?? "")
            .components(separatedBy: "\n").filter { !$0.hasPrefix("machine \(host) login bazel ") }
        while netrc.last == "" { netrc.removeLast() }
        if let token { netrc.append(netrcEntry(host: host, token: token)) }
        FileManager.default.createFile(atPath: netrcPath, contents: Data((netrc.joined(separator: "\n") + (netrc.isEmpty ? "" : "\n")).utf8),
                                       attributes: [.posixPermissions: 0o600])
    }
}

/// The cache's files: `ac/` and `cas/`, each entry under the first two
/// characters of its hash; an upload is written in `incoming/` and renamed
/// into place whole. An entry's modification time is when it was last read
/// or written, which is what eviction goes by.
actor CacheStore {
    enum Kind: String, Sendable { case ac, cas }

    nonisolated let root: String
    let config: CacheConfig
    private var bytes: Int64 = 0
    private var measured = false
    private var evicting = false
    private var hits = 0
    private var misses = 0
    private var writes = 0
    private var evicted = 0

    init(config: CacheConfig) {
        root = config.directory
        self.config = config
        for kind in ["ac", "cas", "incoming"] { Paths.ensure("\(root)/\(kind)") }
        // Uploads a stopped server left half-written.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "\(root)/incoming")) ?? [] {
            try? FileManager.default.removeItem(atPath: "\(root)/incoming/\(name)")
        }
    }

    nonisolated func path(_ kind: Kind, _ hash: String) -> String { "\(root)/\(kind.rawValue)/\(hash.prefix(2))/\(hash)" }
    nonisolated func incoming() -> String { "\(root)/incoming/\(Random.hex(8))" }

    /// The disk's free space, as the volume the cache is on says it.
    nonisolated func freeBytes() -> Int64 {
        let values = try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init) ?? .max
    }

    /// What is there, added up once at start (until then nothing is evicted).
    func measure() {
        bytes = entries().reduce(0) { $0 + $1.size }
        measured = true
        log("cache: \(Self.gigabytes(bytes)) in \(root)")
        evictIfNeeded()
    }

    /// An action cache lookup, answered or not (what a build's hit rate is).
    func looked(hit: Bool) {
        if hit { hits += 1 } else { misses += 1 }
    }

    /// An entry written: `added` bytes more than were there.
    func stored(added: Int64) {
        bytes += added
        writes += 1
        evictIfNeeded()
    }

    func info(port: Int, readToken: String) -> CacheInfo {
        CacheInfo(port: port, readToken: readToken, bytes: bytes, maxBytes: config.maxBytes, freeBytes: freeBytes(),
                  hits: hits, misses: misses, writes: writes, evicted: evicted)
    }

    /// Over its size, or the disk short of its free space: the entries read
    /// longest ago go, until the cache is at nine tenths of its size and the
    /// disk has its free space again (or the cache is empty).
    func evictIfNeeded() {
        guard measured, !evicting else { return }
        let free = freeBytes()
        guard bytes > config.maxBytes || free < config.minFreeBytes else { return }
        evicting = true
        defer { evicting = false }
        let goal = max(bytes - config.maxBytes * 9 / 10, config.minFreeBytes - free)
        var freed: Int64 = 0
        var count = 0
        for entry in entries().sorted(by: { $0.date < $1.date }) where freed < goal {
            guard (try? FileManager.default.removeItem(atPath: entry.path)) != nil else { continue }
            freed += entry.size
            count += 1
        }
        bytes -= freed
        evicted += count
        log("cache: evicted \(count) entries (\(Self.gigabytes(freed))); \(Self.gigabytes(bytes)) kept, \(Self.gigabytes(freeBytes())) free on the disk")
    }

    private func entries() -> [(path: String, date: Date, size: Int64)] {
        var found: [(path: String, date: Date, size: Int64)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        for kind in ["ac", "cas"] {
            guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: "\(root)/\(kind)"), includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walk {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                found.append((url.path, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0)))
            }
        }
        return found
    }

    static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
}

/// This Mac and the networks it shares with its VMs and containers: the
/// bridges vmnet makes for them (which come and go with them), and loopback.
enum LocalNetworks {
    struct Network: Sendable {
        var name: String
        var address: UInt32
        var mask: UInt32
    }

    static func current() -> [Network] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var networks: [Network] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("bridge") || name.hasPrefix("lo"), let address = entry.ifa_addr, let mask = entry.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            func ipv4(_ socketAddress: UnsafeMutablePointer<sockaddr>) -> UInt32 {
                socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            }
            networks.append(Network(name: name, address: ipv4(address), mask: ipv4(mask)))
        }
        return networks
    }

    static func value(_ dotted: String) -> UInt32? {
        let parts = dotted.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1 }
    }

    static func dotted(_ value: UInt32) -> String { [24, 16, 8, 0].map { String(value >> $0 & 0xFF) }.joined(separator: ".") }

    /// Whether an IPv4 address is this Mac's own or on a network it shares with its VMs and containers.
    static func isInternal(_ address: UInt32) -> Bool {
        current().contains { address & $0.mask == $0.address & $0.mask }
    }

    /// This Mac's address on the network a guest is on: where the guest reaches it.
    static func hostAddress(facing guest: String) -> String? {
        guard let guest = value(guest) else { return nil }
        return current().first { !$0.name.hasPrefix("lo") && guest & $0.mask == $0.address & $0.mask }.map { dotted($0.address) }
    }
}

#if canImport(Network)
import CryptoKit
import Network

/// The cache's listener: HTTP/1.1, connections kept open between requests,
/// bodies streamed to and from the disk.
final class CacheServer: @unchecked Sendable {
    enum Role { case none, read, write }

    private let listener: NWListener
    let store: CacheStore
    let config: CacheConfig
    let readToken: String
    private let writeToken: String

    init(config: CacheConfig, store: CacheStore, readToken: String, writeToken: String) throws {
        let parameters = NWParameters.listening
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(config.port))!)
        self.store = store
        self.config = config
        self.readToken = readToken
        self.writeToken = writeToken
    }

    func start() {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: DispatchQueue(label: "oss.cache.connection"))
            Task { await self.serve(connection) }
        }
        listener.stateUpdateHandler = { [config] state in
            // The machines go on without it.
            if case .failed(let error) = state { log("cache: the listener on :\(config.port) failed: \(error)") }
        }
        listener.start(queue: DispatchQueue(label: "oss.cache"))
        // The disk's free space can go by other means than the cache's own writes.
        Task { [store] in
            await store.measure()
            while true {
                try? await Task.sleep(for: .seconds(300))
                await store.evictIfNeeded()
            }
        }
    }

    func role(_ authorization: String?) -> Role {
        guard let authorization else { return .none }
        var secret = ""
        if authorization.hasPrefix("Bearer ") {
            secret = String(authorization.dropFirst(7))
        } else if authorization.hasPrefix("Basic "), let data = Data(base64Encoded: String(authorization.dropFirst(6))) {
            // Any user name; the token is the password.
            let pair = String(decoding: data, as: UTF8.self)
            secret = pair.firstIndex(of: ":").map { String(pair[pair.index(after: $0)...]) } ?? pair
        }
        secret = secret.trimmingCharacters(in: .whitespaces)
        if constantTimeEqual(secret, writeToken) { return .write }
        if constantTimeEqual(secret, readToken) { return .read }
        return .none
    }

    /// Where a connection comes from, as an IPv4 address (an IPv6 one only
    /// as loopback or an IPv4 one mapped).
    static func internalPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let ipv4: IPv4Address?
        switch host {
        case .ipv4(let address): ipv4 = address
        case .ipv6(let address):
            if address == .loopback { return true }
            ipv4 = address.asIPv4
        default: ipv4 = nil
        }
        guard let bytes = ipv4?.rawValue, bytes.count == 4 else { return false }
        return LocalNetworks.isInternal(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    /// `/…/ac/<sha256>` or `/…/cas/<sha256>` (a prefix is the client's own:
    /// `--remote_cache=http://host:port/prefix`).
    static func entry(_ target: String) -> (CacheStore.Kind, String)? {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let kind = CacheStore.Kind(rawValue: parts[parts.count - 2]) else { return nil }
        let hash = parts[parts.count - 1]
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return (kind, hash)
    }

    private func serve(_ connection: NWConnection) async {
        let peer = CachePeer(connection)
        let internalPeer = Self.internalPeer(connection.endpoint)
        defer { connection.cancel() }
        while let head = await peer.head() {
            guard let request = CacheRequest(head) else {
                _ = await peer.respond(400, "unreadable request", close: true)
                return
            }
            guard await handle(request, peer, internalPeer: internalPeer) else { return }
        }
    }

    /// Answers one request: whether the connection carries on.
    private func handle(_ request: CacheRequest, _ peer: CachePeer, internalPeer: Bool) async -> Bool {
        // A refused request's body is never read: the connection closes after it.
        let unreadBody = request.chunked || (request.contentLength ?? 0) > 0
        func refuse(_ status: Int, _ message: String) async -> Bool {
            let close = unreadBody || !request.keepAlive
            return await peer.respond(status, message, close: close) && !close
        }
        guard let (kind, hash) = Self.entry(request.target) else {
            return await refuse(404, "not a cache entry: /ac/<sha256> or /cas/<sha256>")
        }
        let role = self.role(request.header("authorization"))
        switch request.method {
        case "GET", "HEAD":
            guard role != .none else { return await refuse(401, "the cache takes a token") }
            guard role == .write || internalPeer || config.lanReads else {
                return await refuse(403, "the cache is read from the server's Mac, its VMs and its containers")
            }
            return await read(kind, hash, request, peer, refuse: refuse)
        case "PUT":
            guard role != .none else { return await refuse(401, "the cache takes a token") }
            guard role == .write else { return await refuse(403, "this token reads the cache; only its populate job writes it") }
            return await write(kind, hash, request, peer, refuse: refuse)
        default:
            return await refuse(405, "GET, HEAD or PUT")
        }
    }

    private func read(_ kind: CacheStore.Kind, _ hash: String, _ request: CacheRequest, _ peer: CachePeer,
                      refuse: (Int, String) async -> Bool) async -> Bool {
        let path = store.path(kind, hash)
        guard let file = FileHandle(forReadingAtPath: path) else {
            if kind == .ac { await store.looked(hit: false) }
            return await refuse(404, "")
        }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd(), (try? file.seek(toOffset: 0)) != nil else { return await refuse(500, "unreadable entry") }
        // Read now: the last to be evicted.
        utimes(path, nil)
        if kind == .ac { await store.looked(hit: true) }
        guard await peer.respond(200, length: Int64(size), close: !request.keepAlive) else { return false }
        if request.method == "GET" {
            while let chunk = try? file.read(upToCount: 1 << 20), !chunk.isEmpty {
                guard await peer.send(chunk) else { return false }
            }
        }
        return request.keepAlive
    }

    private func write(_ kind: CacheStore.Kind, _ hash: String, _ request: CacheRequest, _ peer: CachePeer,
                       refuse: (Int, String) async -> Bool) async -> Bool {
        guard request.chunked || request.contentLength != nil else { return await refuse(411, "a length (or chunks) is needed") }
        if request.expectsContinue {
            guard await peer.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) else { return false }
        }
        let temporary = store.incoming()
        FileManager.default.createFile(atPath: temporary, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let out = FileHandle(forWritingAtPath: temporary) else { return await refuse(500, "the cache can't write") }
        var hasher = SHA256()
        var written: Int64 = 0
        var complete = false
        do {
            let sink: (Data) throws -> Void = { data in
                try out.write(contentsOf: data)
                if kind == .cas { hasher.update(data: data) }
                written += Int64(data.count)
            }
            complete = request.chunked ? try await peer.chunkedBody(sink) : try await peer.body(request.contentLength ?? 0, sink)
        } catch {
            complete = false
        }
        try? out.close()
        // A body cut short, or a disk that took no more: nothing kept, and
        // the connection can't go on past a body only partly read.
        guard complete else {
            try? FileManager.default.removeItem(atPath: temporary)
            _ = await refuse(500, "the upload was cut short")
            return false
        }
        if kind == .cas, hasher.finalize().map({ String(format: "%02x", $0) }).joined() != hash {
            try? FileManager.default.removeItem(atPath: temporary)
            return await peer.respond(400, "its content's SHA-256 is not \(hash)", close: !request.keepAlive) && request.keepAlive
        }
        let path = store.path(kind, hash)
        Paths.ensure((path as NSString).deletingLastPathComponent)
        let before = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        guard rename(temporary, path) == 0 else {
            try? FileManager.default.removeItem(atPath: temporary)
            return await refuse(500, "the cache can't keep it")
        }
        await store.stored(added: written - before)
        return await peer.respond(200, "", close: !request.keepAlive) && request.keepAlive
    }
}

/// A request's head: its line and fields.
struct CacheRequest {
    var method: String
    var target: String
    var version: String
    var headers: [String: String] = [:]

    init?(_ head: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ").map(String.init)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return nil }
        method = first[0]
        target = first[1]
        version = first[2]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    func header(_ name: String) -> String? { headers[name] }
    var contentLength: Int64? { header("content-length").flatMap { Int64($0) } }
    var chunked: Bool { header("transfer-encoding")?.lowercased().contains("chunked") == true }
    var expectsContinue: Bool { header("expect")?.lowercased() == "100-continue" }
    /// HTTP/1.1 keeps a connection unless it says close; 1.0 only if it asks.
    var keepAlive: Bool {
        let connection = header("connection")?.lowercased() ?? ""
        return version == "HTTP/1.1" ? connection != "close" : connection == "keep-alive"
    }
}

/// One connection's bytes, read as they come and written in order.
final class CachePeer: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    private var ended = false

    init(_ connection: NWConnection) { self.connection = connection }

    /// More bytes: false once the peer has nothing more to send.
    private func fill() async -> Bool {
        guard !ended else { return false }
        let (data, done): (Data?, Bool) = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                continuation.resume(returning: (data, complete || error != nil))
            }
        }
        if done { ended = true }
        guard let data, !data.isEmpty else { return false }
        buffer.append(data)
        return true
    }

    private func take(_ count: Int) -> Data {
        let taken = buffer.prefix(count)
        buffer = count >= buffer.count ? Data() : buffer.suffix(from: buffer.startIndex + count)
        return Data(taken)
    }

    /// A request's head, its blank line taken too; nil when the connection
    /// ends first (or sends a head past 64 KB).
    func head() async -> Data? {
        let blank = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: blank) {
                let head = take(range.lowerBound - buffer.startIndex)
                _ = take(blank.count)
                return head
            }
            guard buffer.count <= 64 << 10, await fill() else { return nil }
        }
    }

    private func line() async -> String? {
        let end = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: end) {
                let line = take(range.lowerBound - buffer.startIndex)
                _ = take(end.count)
                return String(decoding: line, as: UTF8.self)
            }
            guard buffer.count <= 8 << 10, await fill() else { return nil }
        }
    }

    /// Exactly `count` bytes, handed on as they come: whether they all came.
    func body(_ count: Int64, _ sink: (Data) throws -> Void) async throws -> Bool {
        var left = count
        while left > 0 {
            if buffer.isEmpty { guard await fill() else { return false } }
            let part = take(Int(min(Int64(buffer.count), left)))
            try sink(part)
            left -= Int64(part.count)
        }
        return true
    }

    /// A chunked body, handed on as it comes.
    func chunkedBody(_ sink: (Data) throws -> Void) async throws -> Bool {
        while true {
            guard let sizeLine = await line(),
                  let size = Int64((sizeLine.split(separator: ";").first ?? "").trimmingCharacters(in: .whitespaces), radix: 16) else { return false }
            if size == 0 {
                // Trailers, to the blank line.
                while let trailer = await line() { if trailer.isEmpty { return true } }
                return false
            }
            guard try await body(size, sink), await line() == "" else { return false }
        }
    }

    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }

    /// A response's head, with `message` as its body unless `length` says
    /// the caller sends the body itself.
    func respond(_ status: Int, _ message: String = "", length: Int64? = nil, close: Bool) async -> Bool {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                       405: "Method Not Allowed", 411: "Length Required", 500: "Internal Server Error"]
        let body = length == nil ? Data(message.utf8) : Data()
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\nContent-Length: \(length ?? Int64(body.count))\r\n"
        if length == nil { head += "Content-Type: text/plain; charset=utf-8\r\n" }
        if close { head += "Connection: close\r\n" }
        head += "\r\n"
        return await send(Data(head.utf8) + body)
    }
}

#endif
