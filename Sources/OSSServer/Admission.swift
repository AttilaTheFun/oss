import Foundation
import OSSClient

// Lease limits (API 14): which leases a server grants, and in what order
// those that wait for room get it. Two limits: a count cap per type, where
// server.json sets one (macOS's two by default: Apple's limit), and a
// budget of memory that every lease counts against, its size, less (where
// the server measures it) what VMs and processes OS Server doesn't own
// take, `outside`. A type with no cap is limited by the budget alone. CPUs
// aren't budgeted: most machines leave most of theirs idle, and at worst
// everything slows down; one machine may have at most `maxCPUs`. Nothing
// here touches a machine, so it is all tested on Linux too
// (AdmissionTests).

/// server.json's `budget`: the memory every lease together may take of the
/// Mac (LeasePolicy.defaultMemory where it isn't given).
struct BudgetSettings: Codable, Sendable, Equatable {
    var memoryGB: Double?

    init(memoryGB: Double? = nil) {
        self.memoryGB = memoryGB
    }
}

/// A lease's memory as server.json gives it (`sizes`): the estimate for a
/// type whose leases nothing else measures (simulators, emulators).
struct SizeSettings: Codable, Sendable, Equatable {
    var memoryGB: Double

    var bytes: Int64 { Int64(max(0, memoryGB) * Double(1 << 30)) }
}

/// A lease asked for or held, as the limits see it: its type and its size.
struct LeaseDemand: Sendable, Equatable {
    var platform: Platform
    var size: LeaseSize
}

/// What the limits are: each type's cap (none where absent), the memory
/// budget, the most CPUs one machine may have, and the sizes taken for
/// leases nothing else measures.
struct LeasePolicy: Sendable, Equatable {
    var caps: [Platform: Int]
    var memoryBytes: Int64
    var maxCPUs: Int
    var estimates: [Platform: LeaseSize]
    /// The Mac's memory less its reserve (LeasePolicy.reserve): what the
    /// leases' use and everything else's together stay under, whatever the
    /// budget. Nil: not checked (a test's policy).
    var hostLimitBytes: Int64? = nil

    /// The sizes taken where nothing measures a lease. A simulator is a few
    /// processes of the Mac's own (about 2 GB while it runs an app); an
    /// emulator a VM of its own (its AVD is given 4 GB). Their CPUs are the
    /// Mac's, not counted: 0. A VM's size is its base's (machine.json);
    /// these are for UTM's bases, which say theirs only once made, and are
    /// what OS Server's own installs give a base. A container's is what it
    /// asks for, else what it gets (ContainerDefaults).
    static let defaultEstimates: [Platform: LeaseSize] = [
        .ios: LeaseSize(cpus: 0, memoryBytes: 2 << 30),
        .android: LeaseSize(cpus: 0, memoryBytes: 4 << 30),
        .macos: LeaseSize(cpus: 6, memoryBytes: 16 << 30),
        .linux: LeaseSize(cpus: 6, memoryBytes: 8 << 30),
        .windows: LeaseSize(cpus: 6, memoryBytes: 8 << 30),
        .container: LeaseSize(cpus: ContainerDefaults.cpus, memoryBytes: ContainerDefaults.memoryBytes),
    ]

    /// The budget where server.json gives none: the Mac's memory less what
    /// macOS and its own apps keep, 16 GB or a quarter, whichever is more,
    /// but never more than half (a 16 GB Mac still lends 8). macOS pages
    /// out what doesn't fit, so this is what leases may take before they
    /// slow every one of them down, and the Mac with them.
    static func defaultMemory(_ physical: UInt64) -> Int64 {
        max(0, Int64(clamping: physical) - reserve(physical))
    }

    /// What the Mac keeps for macOS and its own apps whatever the budget.
    static func reserve(_ physical: UInt64) -> Int64 {
        let memory = Int64(clamping: physical)
        return min(max(16 << 30, memory / 4), memory / 2)
    }

    func estimate(_ platform: Platform) -> LeaseSize {
        estimates[platform] ?? Self.defaultEstimates[platform] ?? LeaseSize(cpus: 0, memoryBytes: 1 << 30)
    }

    /// Why a lease can't be granted beside those held and what VMs and
    /// processes OS Server doesn't own take (`outside`), or nil if it can.
    /// `leasesInUse`, where the server measures it: what its leases take
    /// now, each the more of its size and its footprint, which with
    /// `outside` and the lease must stay under `hostLimitBytes` (the Mac's
    /// reserve kept, whatever the budget).
    func refusal(_ demand: LeaseDemand, held: [LeaseDemand], outside: Int64 = 0, leasesInUse: Int64? = nil) -> AdmissionRefusal? {
        if demand.size.cpus > maxCPUs { return .tooManyCPUs(demand.size.cpus, max: maxCPUs) }
        if demand.size.memoryBytes > memoryBytes { return .tooBig(demand.size.memoryBytes, budget: memoryBytes) }
        if let cap = caps[demand.platform] {
            let count = held.filter { $0.platform == demand.platform }.count
            if count >= cap { return .cap(demand.platform, held: count, cap: cap) }
        }
        let used = held.reduce(Int64(0)) { $0 + $1.size.memoryBytes }
        if used + outside + demand.size.memoryBytes > memoryBytes {
            return .memory(used: used, outside: outside, needs: demand.size.memoryBytes, budget: memoryBytes)
        }
        if let limit = hostLimitBytes, let leasesInUse, leasesInUse + outside + demand.size.memoryBytes > limit {
            return .reserve(inUse: leasesInUse + outside, needs: demand.size.memoryBytes, limit: limit)
        }
        return nil
    }

    /// A type's line in the status: how many are held, what they take, and
    /// how many may be held now (`limit`: its cap, or fewer where the
    /// budget, less `outside`, has room for fewer more of `typical`, its
    /// default config's size).
    func capacity(_ platform: Platform, held: [LeaseDemand], typical: LeaseSize, outside: Int64 = 0) -> Capacity {
        let mine = held.filter { $0.platform == platform }
        let free = memoryBytes - outside - held.reduce(Int64(0)) { $0 + $1.size.memoryBytes }
        let more = typical.memoryBytes > 0 && typical.cpus <= maxCPUs ? Int(max(0, free) / typical.memoryBytes) : 0
        var limit = mine.count + more
        if let cap = caps[platform] { limit = min(limit, cap) }
        return Capacity(platform: platform, limit: limit, leased: mine.count, cap: caps[platform],
                        used: mine.reduce(LeaseSize.zero) { $0 + $1.size }, size: typical)
    }

    /// How many leases of `memory` the whole budget holds.
    func count(of memory: Int64) -> Int {
        memory > 0 ? Int(memoryBytes / memory) : 0
    }

    /// `budget 96 GB, at most 28 cpus a machine; caps macos 2; the rest by
    /// the budget`: the server's log line.
    var summary: String {
        let capped = caps.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        return "budget \(LeaseSize.gigabytes(memoryBytes)) GB, at most \(maxCPUs) cpus a machine; "
            + "caps \(capped.isEmpty ? "none" : capped.joined(separator: ", ")); the rest by the budget"
    }
}

/// Why a lease isn't granted now: the limit that is full (`busy`, which a
/// client may wait out), or a lease no wait would get (`tooBig`: more
/// memory than the whole budget, more CPUs than one machine may have).
indirect enum AdmissionRefusal: Sendable, Equatable {
    case cap(Platform, held: Int, cap: Int)
    /// The leases' memory, what VMs and processes OS Server doesn't own take, what this needs, the budget.
    case memory(used: Int64, outside: Int64, needs: Int64, budget: Int64)
    case tooBig(Int64, budget: Int64)
    case tooManyCPUs(Int, max: Int)
    /// What the leases and everything else use, what this needs, and the
    /// Mac's memory less its reserve.
    case reserve(inUse: Int64, needs: Int64, limit: Int64)
    /// It would fit, but would take room the oldest lease waiting needs:
    /// that lease's type and size, how long it has waited, and what would
    /// be full with room kept for it.
    case behind(LeaseDemand, waited: TimeInterval, AdmissionRefusal)

    var code: String {
        switch self {
        case .tooBig, .tooManyCPUs: return "tooBig"
        default: return "busy"
        }
    }

    /// `busy: macos 2 of 2 leased`, `busy: memory 120 of 128 GB leased; this needs 16`.
    var message: String {
        switch self {
        case .tooBig, .tooManyCPUs: return detail
        default: return "busy: \(detail)"
        }
    }

    private static func memory(_ used: Int64, _ outside: Int64, _ budget: Int64) -> String {
        "memory \(LeaseSize.gigabytes(used + outside)) of \(LeaseSize.gigabytes(budget)) GB "
            + (outside > 0 ? "taken (\(LeaseSize.gigabytes(outside)) of it outside OS Server's leases)" : "leased")
    }

    private var detail: String {
        switch self {
        case .cap(let platform, let held, let cap):
            return "\(platform.rawValue) \(held) of \(cap) leased"
        case .memory(let used, let outside, let needs, let budget):
            return "\(Self.memory(used, outside, budget)); this needs \(LeaseSize.gigabytes(needs))"
        case .tooBig(let needs, let budget):
            return "this lease's \(LeaseSize.gigabytes(needs)) GB are more than the server's whole budget "
                + "(\(LeaseSize.gigabytes(budget)) GB): no wait would get it"
        case .tooManyCPUs(let cpus, let max):
            return "this lease asks for \(cpus) cpus; one machine here has at most \(max) (server.json's maxCPUs)"
        case .reserve(let inUse, let needs, let limit):
            return "memory \(LeaseSize.gigabytes(inUse)) of the Mac's \(LeaseSize.gigabytes(limit)) GB in use (it keeps the rest for "
                + "itself); this needs \(LeaseSize.gigabytes(needs))"
        case .behind(let oldest, let waited, let full):
            // What is full, the room kept for the oldest told apart from what's leased.
            let kept: String
            switch full {
            case .cap(let platform, let held, let cap):
                kept = "\(platform.rawValue) \(held - 1) of \(cap) leased and the next kept for it"
            case .memory(let used, let outside, let needs, let budget):
                kept = "\(Self.memory(used - oldest.size.memoryBytes, outside, budget)) and "
                    + "\(LeaseSize.gigabytes(oldest.size.memoryBytes)) kept for it; this needs \(LeaseSize.gigabytes(needs))"
            default:
                kept = full.detail
            }
            return "a \(oldest.platform.rawValue) lease waiting \(Self.duration(waited)) goes first (\(kept))"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(max(0, Int(seconds))) s" : seconds < 3600 ? "\(Int(seconds / 60)) min" : "\(Int(seconds / 3600)) h"
    }
}

/// The leases waiting for room, in the order they first asked, and the
/// decision for each request. A waiter names its wait with a ticket
/// (`LeaseRequest.waitTicket`) and keeps its place while it asks again
/// within `patience` (clients ask every 15 seconds); one that stops asking
/// leaves the line.
///
/// Fair across types: a lease is granted as soon as its own limits allow,
/// whatever waits for other limits, but for one rule that keeps a big lease
/// from being starved by small ones: the oldest in line is kept room for,
/// so a later request (waiting or not) that fits only by taking room it
/// needs (its type's last place under the cap, or the memory the budget
/// has left) waits too. Unless the line is stalled: no lease granted or
/// released for `stall` while the oldest waits. Then the room it's kept
/// may be what a lease held is waiting for itself (a CI job's runner
/// waiting for its VM, a proof holding one VM while it waits for the
/// next), and nothing would ever free it; a request that fits goes ahead,
/// and its end is what lets the line move again.
struct AdmissionQueue: Sendable {
    struct Waiter: Sendable, Equatable {
        var ticket: String
        var demand: LeaseDemand
        var config: String
        var holder: String
        var arrived: Date
        var seen: Date
        var reason: String
    }

    var policy: LeasePolicy
    var patience: TimeInterval = 45
    /// How long nothing granted or released makes the line stalled.
    var stall: TimeInterval = 300
    private(set) var waiters: [Waiter] = []
    /// When a lease was last granted or released.
    private(set) var lastProgress: Date?

    init(policy: LeasePolicy, patience: TimeInterval = 45, stall: TimeInterval = 300) {
        self.policy = policy
        self.patience = patience
        self.stall = stall
    }

    /// A lease released (or granted elsewhere): the line moved.
    mutating func progressed(now: Date = Date()) {
        lastProgress = now
    }

    /// Whether nothing has been granted or released for `stall` while the
    /// oldest waited.
    func isStalled(now: Date = Date()) -> Bool {
        guard let oldest = waiters.first else { return false }
        return now.timeIntervalSince(max(lastProgress ?? oldest.arrived, oldest.arrived)) >= stall
    }

    /// Nil: grant it (its ticket leaves the line). Else why not; a `busy`
    /// request with a ticket is kept in line (or its place kept). `outside`:
    /// what VMs and processes OS Server doesn't own take, where it measures
    /// that, and `leasesInUse` what its leases do (LeasePolicy.refusal).
    mutating func decide(_ demand: LeaseDemand, ticket: String?, config: String, holder: String,
                         held: [LeaseDemand], outside: Int64 = 0, leasesInUse: Int64? = nil, now: Date = Date()) -> AdmissionRefusal? {
        prune(now: now)
        let ticket = ticket.flatMap { $0.isEmpty ? nil : $0 }
        if let refusal = policy.refusal(demand, held: held, outside: outside, leasesInUse: leasesInUse) {
            if refusal.code == "tooBig" {
                if let ticket { waiters.removeAll { $0.ticket == ticket } }
            } else {
                wait(ticket, demand, config: config, holder: holder, now: now, reason: refusal.message)
            }
            return refusal
        }
        // The oldest in line before this one: kept room for, while the line moves.
        if let oldest = waiters.first, oldest.ticket != ticket, !isStalled(now: now),
           let refusal = policy.refusal(demand, held: held + [oldest.demand], outside: outside,
                                        leasesInUse: leasesInUse.map { $0 + oldest.demand.size.memoryBytes }) {
            let behind = AdmissionRefusal.behind(oldest.demand, waited: now.timeIntervalSince(oldest.arrived), refusal)
            wait(ticket, demand, config: config, holder: holder, now: now, reason: behind.message)
            return behind
        }
        if let ticket { waiters.removeAll { $0.ticket == ticket } }
        lastProgress = now
        return nil
    }

    /// A waiter's place taken, or kept and seen again.
    private mutating func wait(_ ticket: String?, _ demand: LeaseDemand, config: String, holder: String, now: Date, reason: String) {
        guard let ticket else { return }
        if let index = waiters.firstIndex(where: { $0.ticket == ticket }) {
            waiters[index].seen = now
            waiters[index].demand = demand
            waiters[index].reason = reason
        } else {
            waiters.append(Waiter(ticket: ticket, demand: demand, config: config, holder: holder, arrived: now, seen: now, reason: reason))
        }
    }

    /// Those that stopped asking leave the line.
    mutating func prune(now: Date = Date()) {
        waiters.removeAll { now.timeIntervalSince($0.seen) > patience }
    }

    /// The line, oldest first, as the status shows it.
    func waiting(now: Date = Date()) -> [WaitingLease] {
        waiters.filter { now.timeIntervalSince($0.seen) <= patience }.map {
            WaitingLease(platform: $0.demand.platform, config: $0.config, holder: $0.holder, size: $0.demand.size, since: $0.arrived,
                         reason: $0.reason)
        }
    }
}

extension ServerConfig {
    /// The limits server.json sets, its budget's default from this Mac's
    /// memory, and one machine's CPUs at most its cores.
    func leasePolicy(memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
                     cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> LeasePolicy {
        var caps: [Platform: Int] = [:]
        for (name, cap) in limits {
            if let platform = Platform(rawValue: name) { caps[platform] = max(0, cap) }
        }
        let memory = budget?.memoryGB.map { Int64(max(0, $0) * Double(1 << 30)) } ?? LeasePolicy.defaultMemory(memoryBytes)
        var estimates = LeasePolicy.defaultEstimates
        for (name, size) in sizes {
            if let platform = Platform(rawValue: name) { estimates[platform] = LeaseSize(cpus: 0, memoryBytes: size.bytes) }
        }
        return LeasePolicy(caps: caps, memoryBytes: memory, maxCPUs: max(1, maxCPUs ?? cores), estimates: estimates,
                           hostLimitBytes: max(0, Int64(clamping: memoryBytes) - LeasePolicy.reserve(memoryBytes)))
    }
}
