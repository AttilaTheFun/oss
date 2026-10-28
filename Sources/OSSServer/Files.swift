import CryptoKit
import Foundation
import OSSClient

/// Files OS Server serves as they are, by their content's SHA-256: pinned
/// Bazel dependencies (an Xcode SDK archive) for this Mac's VMs and
/// containers, CI and the other Macs, as `/files/sha256/<hex>` on the
/// cache's port with the cache's read token (so the `.netrc` a lease gets
/// covers Bazel's downloader too). The hash in the URL is the one a
/// dependency pins, so a copy on any server is the same bytes and a wrong
/// file can't be served in its place. Added and removed on this Mac only
/// (`oss files add|list|remove`): nothing writes them over the network.
/// `Files/sha256/<hex>`, with `<hex>.json` beside it (the name it was added
/// as, its size, when).
///
/// They share their folder with the store's objects (StorageStore), which
/// keeps a file while some lease holds it. A served file's entry is its
/// lease, the server's own: it never expires, so the file is never swept,
/// and no holder sees it among its own. Only a file with an entry is served
/// on the cache's port: a holder's object isn't.
public enum ServedFiles {
    public struct Entry: Codable, Sendable {
        public var sha256: String
        public var name: String
        public var bytes: Int64
        public var added: Date
    }

    static var directory: String { "\(Paths.files)/sha256" }
    static func path(_ hash: String, in directory: String = directory) -> String { "\(directory)/\(hash)" }
    static func entryPath(_ hash: String, in directory: String = directory) -> String { "\(path(hash, in: directory)).json" }

    static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Whether the server serves it: it has an entry.
    static func isServed(_ hash: String, in directory: String = directory) -> Bool {
        isHash(hash) && FileManager.default.fileExists(atPath: entryPath(hash, in: directory))
    }

    /// Hashed, then cloned in (on APFS its blocks aren't copied). The entry
    /// is written first: a server sweeping the folder meanwhile (another
    /// process: this runs in `oss files add`) keeps a file with one. Bytes a
    /// holder's object has already are served as they are.
    static func add(_ source: String, into directory: String = directory) throws -> Entry {
        guard let handle = FileHandle(forReadingAtPath: source) else { throw ShellError(description: "can't read \(source)") }
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        Paths.ensure(directory)
        let entry = Entry(sha256: hash, name: URL(fileURLWithPath: source).lastPathComponent, bytes: bytes, added: Date())
        let hadEntry = FileManager.default.fileExists(atPath: entryPath(hash, in: directory))
        try JSONEncoder.oss.encode(entry).write(to: URL(fileURLWithPath: entryPath(hash, in: directory)))
        let target = path(hash, in: directory)
        if !FileManager.default.fileExists(atPath: target) {
            let temporary = "\(directory)/.\(hash).adding"
            try? FileManager.default.removeItem(atPath: temporary)
            do {
                try FileManager.default.copyItem(atPath: source, toPath: temporary)
                chmod(temporary, 0o644)
                guard rename(temporary, target) == 0 else { throw ShellError(description: "can't keep \(source) as \(target)") }
            } catch {
                try? FileManager.default.removeItem(atPath: temporary)
                if !hadEntry { try? FileManager.default.removeItem(atPath: entryPath(hash, in: directory)) }
                throw error
            }
        }
        return entry
    }

    /// The served files: those with an entry (a holder's objects beside them aren't).
    static func list(in directory: String = directory) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter(isHash).compactMap { hash in
            guard let data = FileManager.default.contents(atPath: entryPath(hash, in: directory)) else { return nil }
            return try? JSONDecoder.oss.decode(Entry.self, from: data)
        }.sorted { $0.added < $1.added }
    }

    /// No longer served: its entry, the server's lease, is gone, and the
    /// server's next sweep deletes the bytes unless a holder's lease holds
    /// them (so a holder's object of the same bytes is left alone).
    static func remove(_ hash: String, in directory: String = directory) throws {
        guard isServed(hash, in: directory) else { throw ShellError(description: "no file \(hash)") }
        try FileManager.default.removeItem(atPath: entryPath(hash, in: directory))
    }

    /// `/files/sha256/<hex>` (a query ignored): the hash, or nil for anything else.
    static func hash(inTarget target: String) -> String? {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard path.hasPrefix("/files/sha256/") else { return nil }
        let hash = String(path.dropFirst("/files/sha256/".count))
        return isHash(hash) ? hash : nil
    }
}
