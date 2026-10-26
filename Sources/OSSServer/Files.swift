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
/// (`oss files add|list|remove`): nothing writes them over the network, and
/// they're never evicted. `Files/sha256/<hex>`, with `<hex>.json` beside it
/// (the name it was added as, its size, when).
public enum ServedFiles {
    public struct Entry: Codable, Sendable {
        public var sha256: String
        public var name: String
        public var bytes: Int64
        public var added: Date
    }

    static var directory: String { "\(Paths.files)/sha256" }
    static func path(_ hash: String) -> String { "\(directory)/\(hash)" }

    static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Hashed, then cloned in (on APFS its blocks aren't copied).
    static func add(_ source: String) throws -> Entry {
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
        let target = path(hash)
        if !FileManager.default.fileExists(atPath: target) {
            let temporary = "\(directory)/.\(hash).adding"
            try? FileManager.default.removeItem(atPath: temporary)
            try FileManager.default.copyItem(atPath: source, toPath: temporary)
            chmod(temporary, 0o644)
            guard rename(temporary, target) == 0 else {
                try? FileManager.default.removeItem(atPath: temporary)
                throw ShellError(description: "can't keep \(source) as \(target)")
            }
        }
        let entry = Entry(sha256: hash, name: URL(fileURLWithPath: source).lastPathComponent, bytes: bytes, added: Date())
        try JSONEncoder.oss.encode(entry).write(to: URL(fileURLWithPath: "\(target).json"))
        return entry
    }

    static func list() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter(isHash).compactMap { hash in
            if let data = FileManager.default.contents(atPath: "\(path(hash)).json"),
               let entry = try? JSONDecoder.oss.decode(Entry.self, from: data) {
                return entry
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path(hash))[.size] as? Int64) ?? 0
            return Entry(sha256: hash, name: hash, bytes: size, added: .distantPast)
        }.sorted { $0.added < $1.added }
    }

    static func remove(_ hash: String) throws {
        guard isHash(hash), FileManager.default.fileExists(atPath: path(hash)) else { throw ShellError(description: "no file \(hash)") }
        try FileManager.default.removeItem(atPath: path(hash))
        try? FileManager.default.removeItem(atPath: "\(path(hash)).json")
    }

    /// `/files/sha256/<hex>` (a query ignored): the hash, or nil for anything else.
    static func hash(inTarget target: String) -> String? {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard path.hasPrefix("/files/sha256/") else { return nil }
        let hash = String(path.dropFirst("/files/sha256/".count))
        return isHash(hash) ? hash : nil
    }
}
