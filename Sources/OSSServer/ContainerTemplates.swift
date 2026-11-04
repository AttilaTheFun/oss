import Foundation

/// Images' unpacked root filesystems (`Containers/templates/<digest>-<GiB>.ext4`),
/// each cloned for every container made from its image; a file's
/// modification date is its last such use.
public enum ContainerTemplates {
    /// Those unused for `unusedFor`, and partial ones left by an unpacking
    /// that didn't finish, deleted: their names, and the room they took.
    public static func prune(_ folder: URL, unusedFor: TimeInterval, now: Date = Date()) -> (files: [String], bytes: Int64) {
        var deleted: [String] = []
        var bytes: Int64 = 0
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
            let url = folder.appendingPathComponent(file)
            let values = try? url.resourceValues(forKeys: keys)
            let used = values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(used) > unusedFor || file.contains(".partial.") else { continue }
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            deleted.append(file)
            bytes += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return (deleted, bytes)
    }
}
