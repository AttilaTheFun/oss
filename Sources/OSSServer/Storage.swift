import Foundation
import OSSClient

// Storage: files kept on the server by their content's SHA-256 for a while,
// for agents (through Visor) and anyone else with the API's token. An
// object is kept while some lease on it lasts: a holder's (24 hours unless
// asked otherwise, at most 7 days, renewable), or the server's own for the
// files it serves by their SHA-256 (ServedFiles), which never ends. A sweep
// deletes what no lease holds. The objects share ServedFiles' folder
// (`Files/sha256/<hex>`): bytes put twice, or put and served, are kept once.
// The holders' leases are `State/storage-leases.json`; a served file's
// lease is its entry beside it (`<hex>.json`), which `oss files add` writes
// from its own process with no server involved.

/// The store's settings: `"storage"` in server.json (every field optional;
/// the store is kept without it, at these).
struct StorageConfig: Codable, Sendable {
    /// What the holders' leases keep, in gigabytes, at most: in all (the
    /// served files apart: they're the server's own), and for one holder.
    var maxGigabytes: Double = 100
    var maxGigabytesPerHolder: Double = 20

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StorageConfig()
        maxGigabytes = try c.decodeIfPresent(Double.self, forKey: .maxGigabytes) ?? d.maxGigabytes
        maxGigabytesPerHolder = try c.decodeIfPresent(Double.self, forKey: .maxGigabytesPerHolder) ?? d.maxGigabytesPerHolder
    }

    var maxBytes: Int64 { Int64(maxGigabytes * 1_000_000_000) }
    var maxBytesPerHolder: Int64 { Int64(maxGigabytesPerHolder * 1_000_000_000) }
}

/// Durations as the API and the command line write them: `90s`, `30m`,
/// `24h`, `7d`, or a number of seconds.
enum Durations {
    static func parse(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let unit = text.last.flatMap({ units[$0] }), let number = Double(text.dropLast()), number >= 0, number.isFinite {
            return number * unit
        }
        if let seconds = Double(text), seconds >= 0, seconds.isFinite { return seconds }
        return nil
    }

    /// `text` (or `fallback` without one), kept between a minute and `most`.
    static func clamped(_ text: String?, default fallback: TimeInterval, most: TimeInterval) throws -> TimeInterval {
        guard let text, !text.isEmpty else { return fallback }
        guard let seconds = parse(text) else { throw APIError(error: "a TTL is a duration (90s, 30m, 24h, 7d, or seconds), not \(text)") }
        return min(max(seconds, 60), most)
    }

    static func describe(_ seconds: TimeInterval) -> String {
        seconds >= 86400 && seconds.truncatingRemainder(dividingBy: 86400) == 0 ? "\(Int(seconds / 86400)) d"
            : seconds >= 3600 ? String(format: "%.0f h", seconds / 3600) : "\(Int(seconds / 60)) min"
    }
}

/// The store: the objects in their folder, the holders' leases on them, and
/// what's being read (kept from the sweep until it's done).
actor StorageStore {
    static let defaultTTL: TimeInterval = 24 * 3600
    static let maxTTL: TimeInterval = 7 * 86400
    /// The SHA-256 of nothing: an empty body is that object, never a put by
    /// its hash alone.
    static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    nonisolated let directory: String
    /// Uploads, written here until they're whole and checked, then moved
    /// into place (the same volume): never seen by the sweep half-written.
    nonisolated let incomingDirectory: String
    nonisolated let config: StorageConfig
    private let statePath: String
    private var leases: [String: StorageLease]
    private var reading: [String: Int] = [:]

    init(directory: String = ServedFiles.directory, incoming: String = "\(Paths.files)/incoming",
         statePath: String = Paths.storageLeases, config: StorageConfig = StorageConfig()) {
        self.directory = directory
        incomingDirectory = incoming
        self.statePath = statePath
        self.config = config
        Paths.ensure(directory)
        Paths.ensure(incoming)
        // Uploads a stopped server left half-written.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: incoming)) ?? [] {
            try? FileManager.default.removeItem(atPath: "\(incoming)/\(name)")
        }
        leases = Self.load(statePath: statePath, directory: directory)
    }

    /// The saved leases. The first time (no file yet: a server from before
    /// storage), every file in the folder is a served one: one without an
    /// entry (none should be) is given one, so the sweep keeps it.
    private static func load(statePath: String, directory: String) -> [String: StorageLease] {
        if let data = FileManager.default.contents(atPath: statePath) {
            guard let saved = try? JSONDecoder.oss.decode([StorageLease].self, from: data) else {
                log("storage: \(statePath) is unreadable; starting with no leases")
                return [:]
            }
            return saved.reduce(into: [:]) { $0[$1.id] = $1 }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        where ServedFiles.isHash(name) && !ServedFiles.isServed(name, in: directory) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: ServedFiles.path(name, in: directory))
            let entry = ServedFiles.Entry(sha256: name, name: name, bytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                                          added: attributes?[.modificationDate] as? Date ?? Date())
            try? JSONEncoder.oss.encode(entry).write(to: URL(fileURLWithPath: ServedFiles.entryPath(name, in: directory)))
            log("storage: \(name) was served before storage came; served still")
        }
        save([], to: statePath)
        return [:]
    }

    private static func save(_ leases: [StorageLease], to path: String) {
        Paths.ensure((path as NSString).deletingLastPathComponent)
        guard let data = try? JSONEncoder.oss.encode(leases.sorted { $0.created < $1.created }) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o600)
    }

    private func save() { Self.save(Array(leases.values), to: statePath) }

    // MARK: Objects

    nonisolated func path(_ hash: String) -> String { ServedFiles.path(hash, in: directory) }
    nonisolated func incoming() -> String { "\(incomingDirectory)/\(Random.hex(8))" }

    /// An object's size, if the store has it.
    nonisolated func size(_ hash: String) -> Int64? {
        guard ServedFiles.isHash(hash), let attributes = try? FileManager.default.attributesOfItem(atPath: path(hash)) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// Whether the server holds it itself: a file it serves.
    nonisolated func isServed(_ hash: String) -> Bool { ServedFiles.isServed(hash, in: directory) }

    // MARK: What requests name

    /// A holder, as a request names it.
    static func holder(_ text: String?) throws -> String {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw APIError(error: "a storage request names its holder (the \(OSSHeaders.holder) header)")
        }
        guard text.count <= 256, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw APIError(error: "a holder is at most 256 characters, none of them control characters")
        }
        return text
    }

    /// A lease's name: never a SHA-256, so `<sha256 | name>` says which.
    static func name(_ text: String?) throws -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.count <= 256, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ServedFiles.isHash(text.lowercased()) else {
            throw APIError(error: "a name is at most 256 characters, no control characters, and not a SHA-256")
        }
        return text
    }

    // MARK: Leases

    private func live(_ now: Date = Date()) -> [StorageLease] { leases.values.filter { $0.expires > now } }

    /// A holder's unexpired leases, oldest first.
    func leases(of holder: String) -> [StorageLease] {
        live().filter { $0.holder == holder }.sorted { $0.created < $1.created }
    }

    func holds(_ holder: String, _ hash: String) -> Bool { live().contains { $0.holder == holder && $0.sha256 == hash } }

    /// The object a holder names, by its SHA-256 or a lease's name, if the
    /// holder has a lease on it.
    func resolve(_ object: String, holder: String) throws -> String {
        let mine = leases(of: holder)
        if let lease = mine.first(where: { $0.sha256 == object.lowercased() }) ?? mine.last(where: { $0.name == object }) {
            return lease.sha256
        }
        throw APIError(error: "\(holder) holds no object \(object)", code: "notFound")
    }

    /// Distinct objects' bytes: an object leased twice counts once.
    private static func bytes(_ leases: [StorageLease]) -> Int64 {
        var seen = Set<String>()
        return leases.reduce(0) { seen.insert($1.sha256).inserted ? $0 + $1.size : $0 }
    }

    /// Refused if `lease` (the one of the holder's with its name gone) would
    /// take the holder or the store past its cap. Only growth is refused: a
    /// store over a lowered cap still renames and re-leases what it has.
    private func checkCaps(_ lease: StorageLease, now: Date = Date()) throws {
        let before = live(now)
        let after = before.filter { !($0.holder == lease.holder && lease.name != nil && $0.name == lease.name) } + [lease]
        let holderBefore = Self.bytes(before.filter { $0.holder == lease.holder })
        let holderAfter = Self.bytes(after.filter { $0.holder == lease.holder })
        if holderAfter > holderBefore && holderAfter > config.maxBytesPerHolder {
            throw APIError(error: "refused: \(lease.holder)'s objects would be \(CacheStore.gigabytes(holderAfter)), past the "
                           + "\(CacheStore.gigabytes(config.maxBytesPerHolder)) a holder may keep (release some: oss storage rm)", code: "quota")
        }
        let storeBefore = Self.bytes(before.filter { !isServed($0.sha256) })
        let storeAfter = Self.bytes(after.filter { !isServed($0.sha256) })
        if storeAfter > storeBefore && storeAfter > config.maxBytes {
            throw APIError(error: "refused: the store would hold \(CacheStore.gigabytes(storeAfter)), past its "
                           + "\(CacheStore.gigabytes(config.maxBytes))", code: "quota")
        }
    }

    /// Before a put's body is read: refused at once if `length` bytes would
    /// pass a cap, as a new object unless the client said its hash.
    func admit(holder: String, name: String?, hash: String?, length: Int64?) throws {
        guard let length else { return }
        let size = hash.flatMap { self.size($0) } ?? length
        try checkCaps(StorageLease(id: "", holder: holder, sha256: hash ?? "incoming-\(Random.hex(8))", size: size, name: name,
                                   created: Date(), expires: .distantFuture))
    }

    /// A lease on an object: its bytes moved in from `temporary`, or (if the
    /// store has them already) the upload dropped; without `temporary`, a
    /// put by its hash alone, which the store must have. A lease of the
    /// holder's with the same name is released: the name moves.
    func store(temporary: String?, hash: String, holder: String, name: String?, ttl: TimeInterval) throws -> StoragePut {
        let now = Date()
        let existing = size(hash)
        guard existing != nil || temporary != nil else { throw APIError(error: "no object \(hash) here: send its bytes", code: "noObject") }
        let size = existing ?? temporary.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber }?.int64Value ?? 0
        var id = Random.hex(4)
        while leases[id] != nil { id = Random.hex(4) }
        let lease = StorageLease(id: id, holder: holder, sha256: hash, size: size, name: name, created: now, expires: now.addingTimeInterval(ttl))
        try checkCaps(lease, now: now)
        if let temporary {
            if existing != nil {
                try? FileManager.default.removeItem(atPath: temporary)
            } else {
                chmod(temporary, 0o644)
                guard rename(temporary, path(hash)) == 0 else { throw APIError(error: "the store can't keep it (\(String(cString: strerror(errno))))") }
            }
        }
        if let name {
            for old in leases.values where old.holder == holder && old.name == name {
                leases[old.id] = nil
                log("storage: lease \(old.id): \(holder)'s name \(name) moved to lease \(id)")
            }
        }
        leases[id] = lease
        save()
        log("storage: lease \(id): \(hash.prefix(12))… (\(CacheStore.gigabytes(size))\(existing != nil ? ", kept already" : "")) for \(holder)"
            + (name.map { " as \($0)" } ?? "") + ", \(Durations.describe(ttl))")
        return StoragePut(object: StorageObject(sha256: hash, size: size), lease: lease, existed: existing != nil)
    }

    /// A holder's lease's time set again: `ttl` from now. Another holder's is not found.
    func renew(_ id: String, holder: String, ttl: TimeInterval) throws -> StorageLease {
        guard var lease = leases[id], lease.holder == holder, lease.expires > Date() else {
            throw APIError(error: "no lease \(id) of \(holder)'s", code: "notFound")
        }
        lease.expires = Date().addingTimeInterval(ttl)
        leases[id] = lease
        save()
        return lease
    }

    /// A holder's lease released: its object goes at the next sweep, unless
    /// another lease holds it.
    func release(_ id: String, holder: String) throws {
        guard let lease = leases[id], lease.holder == holder, lease.expires > Date() else {
            throw APIError(error: "no lease \(id) of \(holder)'s", code: "notFound")
        }
        leases[id] = nil
        save()
        log("storage: lease \(id) (\(holder)) released")
    }

    // MARK: Reading

    /// An object opened for reading: kept from the sweep until `close`.
    func open(_ hash: String) -> (path: String, size: Int64)? {
        guard let size = size(hash) else { return nil }
        reading[hash, default: 0] += 1
        return (path(hash), size)
    }

    func close(_ hash: String) {
        let left = (reading[hash] ?? 1) - 1
        reading[hash] = left > 0 ? left : nil
    }

    // MARK: Sweeping

    /// Leases whose time ran out end, and objects no lease holds are
    /// deleted: never a served file (the server's own lease), one being
    /// read, or an upload (in `incoming/` until it's in place, then leased
    /// in the same step).
    @discardableResult
    func sweep(now: Date = Date()) -> (leases: Int, objects: Int) {
        let expired = leases.values.filter { $0.expires <= now }
        for lease in expired {
            leases[lease.id] = nil
            log("storage: lease \(lease.id) (\(lease.holder)) expired")
        }
        if !expired.isEmpty { save() }
        let held = Set(leases.values.map(\.sha256))
        var deleted = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        where ServedFiles.isHash(name) && !held.contains(name) && reading[name] == nil && !isServed(name) {
            guard (try? FileManager.default.removeItem(atPath: path(name))) != nil else { continue }
            deleted += 1
            log("storage: deleted \(name): no lease holds it")
        }
        return (expired.count, deleted)
    }

    /// The store's use, for `Status`.
    func info() -> StorageInfo {
        let live = live()
        var seen = Set<String>()
        let kept = live.filter { !isServed($0.sha256) && seen.insert($0.sha256).inserted }
        let served = ServedFiles.list(in: directory)
        return StorageInfo(objects: kept.count, bytes: kept.reduce(0) { $0 + $1.size }, maxBytes: config.maxBytes,
                           maxBytesPerHolder: config.maxBytesPerHolder, leases: live.count,
                           servedFiles: served.count, servedBytes: served.reduce(0) { $0 + $1.bytes })
    }
}
