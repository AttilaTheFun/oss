#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import OSSClient

#if canImport(CryptoKit)
/// The API's keys (API 12), one an application's: `user`, `ci`, a Visor
/// server's (`mac-mini-visor`), each made with `oss keys create`. Kept as
/// SHA-256s in `keys.json` in the server's folder (its owner's alone): a
/// key is shown once, when it is made. A request carries one as `API_KEY`,
/// or as its bearer; with `CLIENT_ID`, what it leases and stores is
/// `<CLIENT_ID>@<application>`'s (`Server.holder`).
final class APIKeys: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var application: String
        var sha256: String
        var created: Date
    }

    private struct File: Codable {
        var keys: [Entry]
    }

    let path: String
    private let lock = NSLock()
    /// The file as last read, and when it was last changed then: read again
    /// when it changes (`oss keys` on the server's Mac writes it too).
    private var read: (modified: Date?, entries: [Entry]) = (nil, [])

    init(path: String = Paths.keys) {
        self.path = path
    }

    /// The application `key` is, if it is a key.
    func application(for key: String) -> String? {
        guard !key.isEmpty else { return nil }
        let given = Self.digest(key)
        return entries().first { constantTimeEqual($0.sha256, given) }?.application
    }

    /// The applications with keys, by name.
    func applications() -> [Entry] {
        entries().sorted { $0.application < $1.application }
    }

    /// A new key for `application`, replacing any it had: returned once,
    /// kept as its digest.
    func make(_ application: String) throws -> String {
        guard Self.validName(application) else {
            throw APIError(error: "an application is named with a-z, 0-9 and -, at most 40 characters")
        }
        let key = "oss_" + Random.hex(32)
        try lock.withLock {
            var entries = loaded().filter { $0.application != application }
            entries.append(Entry(application: application, sha256: Self.digest(key), created: Date()))
            try write(entries)
        }
        return key
    }

    /// `application`'s key taken away: whether it had one.
    func remove(_ application: String) throws -> Bool {
        try lock.withLock {
            let entries = loaded()
            guard entries.contains(where: { $0.application == application }) else { return false }
            try write(entries.filter { $0.application != application })
            return true
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func entries() -> [Entry] {
        lock.withLock { loaded() }
    }

    /// The entries, read again if the file changed. Under the lock.
    private func loaded() -> [Entry] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if modified != read.modified || modified == nil {
            let file = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder.oss.decode(File.self, from: $0) }
            read = (modified, file?.keys ?? [])
        }
        return read.entries
    }

    /// The entries written, readable by the server's owner only. Under the lock.
    private func write(_ entries: [Entry]) throws {
        Paths.ensure((path as NSString).deletingLastPathComponent)
        let data = try JSONEncoder.oss.encode(File(keys: entries))
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw APIError(error: "the keys couldn't be written to \(path)")
        }
        read = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, entries)
    }
}
#endif
