import Foundation
import OSSClient

/// Who a lease is for, as the server keeps it (API 8): the kind its
/// request said, or the one its holder implies; a label on one line; a link
/// that is a web page. Made here, once, so every view of the server (`oss`,
/// OS Server's window, OS Monitor) shows the same.
struct LeaseOrigin: Equatable {
    var kind: LeaseKind
    var label: String?
    var link: URL?

    /// A label longer than this is cut (it is a line beside a lease, not a
    /// description).
    static let maxLabel = 200

    init(_ request: LeaseRequest) throws {
        kind = request.kind ?? Self.kind(holder: request.holder ?? "unknown", platform: request.platform)
        label = request.label.flatMap(Self.line)
        if let link = request.link {
            guard ["http", "https"].contains(link.scheme?.lowercased() ?? ""), link.host?.isEmpty == false else {
                throw APIError(error: "a lease's link is an http or https URL")
            }
            self.link = link
        }
    }

    /// The kind of a lease that says none (a client before API 8, or one
    /// that left it out). Visor leases in a session's name — `visor:<session>`,
    /// or with a key `<session>@<a Visor's application>` (API 12; such an
    /// application is named `…-visor`): a session's own machine is the
    /// container it runs in, and an agent in it leases anything but
    /// containers, so a Visor holder's container is a session's and its other
    /// machines an agent's. The `ci` application's are CI's; any other
    /// holder's is manual.
    static func kind(holder: String, platform: Platform) -> LeaseKind {
        let application = holder.split(separator: "@").count > 1 ? holder.split(separator: "@").last.map(String.init) : nil
        if application == "ci" { return .ci }
        guard holder.hasPrefix("visor:") || application?.hasSuffix("-visor") == true || application == "visor" else { return .manual }
        return platform == .container ? .session : .agent
    }

    /// One line: newlines and tabs as spaces, trimmed, at most `maxLabel`
    /// characters; nil when nothing is left.
    static func line(_ text: String) -> String? {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return flat.count > maxLabel ? String(flat.prefix(maxLabel - 1)) + "…" : flat
    }
}

extension Lease {
    /// Who it is for, from its request.
    mutating func take(_ origin: LeaseOrigin) {
        kind = origin.kind
        label = origin.label
        link = origin.link
    }
}

/// The leases as the server keeps them across its restarts
/// (`State/leases.json`).
enum LeaseFile {
    static func write(_ leases: [Lease], to path: String) {
        Paths.ensure((path as NSString).deletingLastPathComponent)
        if let data = try? JSONEncoder.oss.encode(leases) {
            FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// What was written; a lease saved before kinds (a server before API 8)
    /// gets the one its holder implies.
    static func read(_ path: String) -> [Lease] {
        let saved = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder.oss.decode([Lease].self, from: $0) } ?? []
        return saved.map { lease in
            var lease = lease
            if lease.kind == nil { lease.kind = LeaseOrigin.kind(holder: lease.holder, platform: lease.platform) }
            return lease
        }
    }
}
