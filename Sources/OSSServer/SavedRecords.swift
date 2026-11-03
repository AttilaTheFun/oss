import Foundation

// A state file read record by record (2026-11-02): eee4b96 saved a slot's
// lease (platform `mac`), the build rolled back to read leases.json as one
// [Lease], failed on that record, took the whole file for empty and deleted
// every machine it found as one "no lease holds": an agent's container, the
// primary VM. A record this build can't read is now a later build's: kept as
// it was written, written back with the rest, and what it names (a machine,
// an object) left alone. A file that isn't a list at all is put aside, and
// nothing is deleted for want of a lease while the server runs.

/// What a state file of records holds.
struct SavedRecords<Record: Codable> {
    /// The records this build reads.
    var records: [Record] = []
    /// The others as they were written: JSON objects.
    var unread: [[String: Any]] = []
    /// The file is there but holds no list this build can read: nothing it
    /// would delete for want of a record may be deleted.
    var unreadable = false

    /// What the unread records name under `key` (a lease's `name` or `udid`,
    /// a stored object's `sha256`): left alone.
    func unreadValues(_ key: String) -> Set<String> {
        Set(unread.compactMap { $0[key] as? String })
    }

    static func read(_ path: String, decoder: JSONDecoder = .oss, label: String) -> SavedRecords {
        var saved = SavedRecords()
        guard let data = FileManager.default.contents(atPath: path) else { return saved }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            saved.unreadable = true
            let aside = "\(path).unreadable-\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.copyItem(atPath: path, toPath: aside)
            log("\(label): \(path) is unreadable (put aside as \(aside)): nothing is deleted for want of a lease until a restart")
            return saved
        }
        for item in list {
            guard let object = item as? [String: Any], let one = try? JSONSerialization.data(withJSONObject: object) else { continue }
            if let record = try? decoder.decode(Record.self, from: one) {
                saved.records.append(record)
            } else {
                saved.unread.append(object)
                log("\(label): a record this build can't read (a later build's?) kept as it is: \(object["id"] as? String ?? "?")")
            }
        }
        return saved
    }

    /// The records and the unread ones, as a list, or nil if they can't be
    /// encoded.
    static func encode(_ records: [Record], unread: [[String: Any]], encoder: JSONEncoder = .oss) -> Data? {
        guard let data = try? encoder.encode(records) else { return nil }
        guard !unread.isEmpty else { return data }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: list + unread, options: [.sortedKeys])
    }
}
