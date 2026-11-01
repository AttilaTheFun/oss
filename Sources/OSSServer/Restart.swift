import Foundation
import OSSClient

// A pending restart (API 16): an update, or a restart asked for, waits for
// what runs to end rather than ending it. From the request on, the server
// grants no new lease but a session's container (`restarting`; one asked
// for with `--wait` keeps its place in line) and starts no CI runner. The
// leases it waits for are those a restart would end or leave half made: a
// CI job's (its runner runs in the server's process), an image build's,
// and any being made or deleted. The machines everything else holds run in
// helpers of their own and outlive the server's process, as before. Once
// none it waits for is held, the line of leases waiting goes to disk and
// the server restarts itself (the app opens itself again), or, held (an
// installer's), says it's ready and waits for the installer's `now`, at
// most `holdTimeout`. After the restart the line is put back first.

/// A restart asked for and not yet made.
struct RestartState: Sendable, Equatable {
    var requested: Date
    var reason: String?
    var by: String?
    var hold: Bool
    /// When nothing held it up any more.
    var ready: Date?
    /// The installer's go.
    var now = false
}

enum RestartPlan {
    /// A held restart's wait for its installer, at most.
    static let holdTimeout: TimeInterval = 15 * 60
    /// The kinds of lease granted while one is pending.
    static let grantedMeanwhile: Set<LeaseKind> = [.session]

    /// Whether a lease asked for while a restart is pending is granted: a
    /// session's, or one for work already running, whose holder holds a
    /// lease already, or whose job's runner does (a CI job's VM: refused, the
    /// job would wait for it, and the restart for the job).
    static func granted(kind: LeaseKind, holder: String, held: [Lease]) -> Bool {
        if grantedMeanwhile.contains(kind) { return true }
        let runner = holder.hasSuffix("@ci") ? String(holder.dropLast(3)) + "-runner@ci" : nil
        return held.contains { $0.state != .failed && ($0.holder == holder || $0.holder == runner) }
    }

    enum Step: Equatable {
        /// What it waits for still runs.
        case wait
        /// Held: ready, waiting for the installer.
        case ready
        case restart
    }

    /// Whether a lease holds the restart up: a CI job's or an image build's,
    /// or one being made or deleted.
    static func holdsUp(_ lease: Lease) -> Bool {
        if lease.state == .failed { return false }
        if lease.state == .creating || lease.state == .returning { return true }
        return lease.kind == .ci || lease.kind == .build
    }

    static func step(_ state: RestartState, holdingUp: Int, now: Date = Date()) -> Step {
        guard holdingUp == 0 else { return .wait }
        guard state.hold else { return .restart }
        if state.now { return .restart }
        if let ready = state.ready, now.timeIntervalSince(ready) >= holdTimeout { return .restart }
        return .ready
    }
}

/// The line of leases waiting, kept across a restart.
enum RestartLine {
    static var path: String { "\(Paths.state)/restart-line.json" }
    /// A line older than this when the server starts is no one's any more.
    static let maxAge: TimeInterval = 15 * 60
    /// How long a restored place is kept for its client to ask again.
    static let grace: TimeInterval = 180

    struct Saved: Codable {
        var saved: Date
        var waiters: [AdmissionQueue.Waiter]
    }

    static func save(_ waiters: [AdmissionQueue.Waiter], to path: String = RestartLine.path, now: Date = Date()) {
        guard let data = try? JSONEncoder.oss.encode(Saved(saved: now, waiters: waiters)) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The line saved before this start, if recent: read once and removed.
    static func take(from path: String = RestartLine.path, now: Date = Date()) -> [AdmissionQueue.Waiter] {
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let data = FileManager.default.contents(atPath: path),
              let saved = try? JSONDecoder.oss.decode(Saved.self, from: data),
              now.timeIntervalSince(saved.saved) < maxAge else { return [] }
        return saved.waiters
    }
}
