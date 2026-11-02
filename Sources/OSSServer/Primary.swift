import Foundation
import OSSClient

// The primary VMs (docs/primary-vms.md): the owner (2026-10-31, 2026-11-01,
// 2026-11-02) wants the host Mac to run no tests or simulators of its own,
// apps and tests to run in primary VMs that OS Server keeps running, and CI
// to lease a slot on one rather than a whole GUI VM. This is the first of
// them, the macOS one: a lease of OS Server's own (kind `primary`, holder
// `primary@oss`), its memory held from the budget, made at start and kept:
// checked every minute, released and made again when it stops answering or
// its settings change. Its slots (`mac` leases) come next.

/// server.json's `primary`: the primary VMs to keep.
struct PrimarySettings: Codable, Equatable, Sendable {
    /// The macOS one, if any: `{"macos": {}}` keeps one of the defaults.
    var macos: PrimaryMacSettings?

    init(macos: PrimaryMacSettings? = nil) {
        self.macos = macos
    }
}

/// The primary macOS VM: the base it is cloned from, its size and how
/// many slots it lends. One of the two macOS VMs Apple allows.
struct PrimaryMacSettings: Codable, Equatable, Sendable {
    /// Its base's config: Xcode's, for tests.
    var config = "xcode_27_2"
    var cpus = 8
    var memoryGigabytes = 24
    /// Slots (`mac` leases) at once.
    var slots = 4

    init(config: String = "xcode_27_2", cpus: Int = 8, memoryGigabytes: Int = 24, slots: Int = 4) {
        self.config = config
        self.cpus = cpus
        self.memoryGigabytes = memoryGigabytes
        self.slots = slots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrimaryMacSettings()
        config = try c.decodeIfPresent(String.self, forKey: .config) ?? d.config
        cpus = max(1, try c.decodeIfPresent(Int.self, forKey: .cpus) ?? d.cpus)
        memoryGigabytes = max(4, try c.decodeIfPresent(Int.self, forKey: .memoryGigabytes) ?? d.memoryGigabytes)
        slots = max(0, try c.decodeIfPresent(Int.self, forKey: .slots) ?? d.slots)
    }

    /// What it holds of the budget, and its VM's CPUs and memory.
    var size: LeaseSize { LeaseSize(cpus: cpus, memoryBytes: Int64(memoryGigabytes) << 30) }
}

/// What keeping the primary asks for now.
enum PrimaryStep: Equatable {
    /// Nothing: none is wanted and none is held, or a restart is pending.
    case none
    /// None is held: make it.
    case make
    /// It is being made: wait.
    case wait
    /// It is ready: see that it answers.
    case check(String)
    /// Released: it is no longer wanted (server.json has none), or no longer
    /// as server.json says (its config or size changed), and the next step
    /// makes it again.
    case release(String, because: String)
}

enum PrimaryPlan {
    /// Whom the primary's lease is for.
    static let holder = "primary@oss"
    /// Checks in a row it doesn't answer before it is made again.
    static let misses = 3

    /// The macOS primary of the leases held, if any.
    static func macos(_ held: [Lease]) -> Lease? {
        held.first { $0.kind == .primary && $0.platform == .macos && $0.state != .returning && $0.state != .failed }
    }

    /// The next step for the macOS primary: wanted where server.json has one
    /// and the server lends macOS; never begun while a restart is pending.
    static func step(_ settings: PrimaryMacSettings?, lendsMacOS: Bool, restartPending: Bool, held: [Lease]) -> PrimaryStep {
        let lease = macos(held)
        guard let settings, lendsMacOS else {
            return lease.map { .release($0.id, because: "server.json keeps no primary macOS VM") } ?? .none
        }
        guard let lease else { return restartPending ? .none : .make }
        if lease.state == .creating { return .wait }
        if lease.config != settings.config {
            return .release(lease.id, because: "its base is now \(settings.config), not \(lease.config)")
        }
        if let size = lease.size, size != settings.size {
            return .release(lease.id, because: "its size is now \(settings.cpus) CPUs and \(settings.memoryGigabytes) GB")
        }
        return .check(lease.id)
    }
}
