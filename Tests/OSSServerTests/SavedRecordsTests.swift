import Foundation
import Testing
import OSSClient
@testable import OSSServer

// State files read record by record (SavedRecords): a rollback's build keeps
// what a later build saved, and deletes nothing it names.

private func folder() -> String {
    let path = NSTemporaryDirectory() + "oss-saved-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// A file as a later build writes it: one lease this build reads, one of a
/// platform it doesn't know (as eee4b96's slots were to 5017d71).
private let laterBuilds = #"""
    [{"id": "a1", "platform": "container", "config": "linux", "name": "oss-lease-container-a1", "holder": "visor:s",
      "state": "ready", "created": "2026-11-02T18:00:00Z", "expires": "4001-01-01T00:00:00Z"},
     {"id": "b2", "platform": "hologram", "config": "x", "name": "oss-lease-hologram-b2", "udid": "U-B2", "holder": "runner@ci",
      "state": "ready", "created": "2026-11-02T18:00:00Z", "expires": "2026-11-02T19:00:00Z", "somethingNew": {"n": 1}}]
    """#

@Test func aLaterBuildsLeaseIsKeptAsItWasWritten() throws {
    let path = folder() + "/leases.json"
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    FileManager.default.createFile(atPath: path, contents: Data(laterBuilds.utf8))

    let saved = LeaseFile.readAll(path)
    #expect(saved.records.map(\.id) == ["a1"])
    #expect(!saved.unreadable)
    #expect(saved.unreadValues("name") == ["oss-lease-hologram-b2"])
    #expect(saved.unreadValues("udid") == ["U-B2"])

    // Written back with this build's leases, the unread one unchanged.
    LeaseFile.write(saved.records, unread: saved.unread, to: path)
    let again = LeaseFile.readAll(path)
    #expect(again.records.map(\.id) == ["a1"])
    #expect(again.unread.count == 1)
    #expect(again.unread.first?["platform"] as? String == "hologram")
    #expect((again.unread.first?["somethingNew"] as? [String: Any])?["n"] as? Int == 1)
}

@Test func anUnreadableFileIsPutAsideAndHoldsDeletes() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/leases.json"
    FileManager.default.createFile(atPath: path, contents: Data("{not a list".utf8))

    let saved = LeaseFile.readAll(path)
    #expect(saved.unreadable)
    #expect(saved.records.isEmpty)
    let aside = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("leases.json.unreadable-") }
    #expect(aside.count == 1)

    // No file at all is a first start, not an unreadable one.
    #expect(!LeaseFile.readAll(dir + "/none.json").unreadable)
}

#if canImport(Network)
@Test func storageKeepsTheObjectsOfLeasesItCantRead() async throws {
    let root = folder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let kept = String(repeating: "a", count: 64), loose = String(repeating: "b", count: 64)
    try FileManager.default.createDirectory(atPath: "\(root)/sha256", withIntermediateDirectories: true)
    for name in [kept, loose] { FileManager.default.createFile(atPath: "\(root)/sha256/\(name)", contents: Data("x".utf8)) }
    // A record this build can't read (its size a later build's shape) holds its object still.
    let state = #"[{"id": "s1", "holder": "h", "sha256": "\#(kept)", "size": {"bytes": 1}, "created": "2026-11-02T18:00:00Z", "expires": "4001-01-01T00:00:00Z"}]"#
    FileManager.default.createFile(atPath: "\(root)/storage-leases.json", contents: Data(state.utf8))

    let store = StorageStore(directory: "\(root)/sha256", incoming: "\(root)/incoming", statePath: "\(root)/storage-leases.json")
    let swept = await store.sweep()
    #expect(swept.objects == 1)
    #expect(FileManager.default.fileExists(atPath: "\(root)/sha256/\(kept)"))
    #expect(!FileManager.default.fileExists(atPath: "\(root)/sha256/\(loose)"))

    // Unreadable: nothing deleted.
    FileManager.default.createFile(atPath: "\(root)/sha256/\(loose)", contents: Data("x".utf8))
    FileManager.default.createFile(atPath: "\(root)/storage-leases.json", contents: Data("garbage".utf8))
    let held = StorageStore(directory: "\(root)/sha256", incoming: "\(root)/incoming", statePath: "\(root)/storage-leases.json")
    #expect(await held.sweep().objects == 0)
    #expect(FileManager.default.fileExists(atPath: "\(root)/sha256/\(loose)"))
}
#endif
