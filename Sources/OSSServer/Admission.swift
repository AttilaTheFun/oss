import Foundation
import OSSClient

// Lease limits (API 14): which leases a server grants, and in what order
// those that wait for room get it. Two limits: a count cap per type, where
// server.json sets one (macOS's two by default: Apple's limit), and a
// budget of CPUs and memory that every lease counts against, its size. A
// type with no cap is limited by the budget alone. Nothing here touches a
// machine, so it is all tested on Linux too (AdmissionTests).

/// server.json's `budget`: what the leases may take of the Mac together.
/// Either left out takes its default (LeasePolicy.defaultBudget).
struct BudgetSettings: Codable, Sendable, Equatable {
    var memoryGB: Double?
    var cpus: Int?

    init(memoryGB: Double? = nil, cpus: Int? = nil) {
        self.memoryGB = memoryGB
        self.cpus = cpus
    }
}

/// A lease's size as server.json gives it (`sizes`): the estimate for a
/// type whose leases nothing else measures.
struct SizeSettings: Codable, Sendable, Equatable {
    var cpus: Int
    var memoryGB: Double

    var size: LeaseSize { LeaseSize(cpus: max(0, cpus), memoryBytes: Int64(max(0, memoryGB) * Double(1 << 30))) }
}

/// A lease asked for or held, as the limits see it: its type and its size.
struct LeaseDemand: Sendable, Equatable {
    var platform: Platform
    var size: LeaseSize
}

/// What the limits are: each type's cap (none where absent), the budget, and
/// the sizes taken for leases nothing else measures.
struct LeasePolicy: Sendable, Equatable {
    var caps: [Platform: Int]
    var budget: LeaseSize
    var estimates: [Platform: LeaseSize]

    /// The sizes taken where nothing measures a lease. A simulator is a
    /// few processes of the Mac's own (about 2 GB and a core while it runs
    /// an app); an emulator is a VM of its own (its AVD is given 4 GB and
    /// two cores). A VM's size is its base's (machine.json); these are for
    /// UTM's bases, which say theirs only once made, and are what OS
    /// Server's own installs give a base. A container's is what it asks for,
    /// else what it gets (ContainerDefaults).
    static let defaultEstimates: [Platform: LeaseSize] = [
        .ios: LeaseSize(cpus: 1, memoryBytes: 2 << 30),
        .android: LeaseSize(cpus: 2, memoryBytes: 4 << 30),
        .macos: LeaseSize(cpus: 6, memoryBytes: 16 << 30),
        .linux: LeaseSize(cpus: 6, memoryBytes: 8 << 30),
        .windows: LeaseSize(cpus: 6, memoryBytes: 8 << 30),
        .container: LeaseSize(cpus: ContainerDefaults.cpus, memoryBytes: ContainerDefaults.memoryBytes),
    ]

    /// The budget where server.json gives none: the Mac's memory less what
    /// macOS and its own apps keep (16 GB or a quarter, whichever is more,
    /// but never more than half: a 16 GB Mac still lends 8), and its active
    /// cores less two (OS Server itself, the forwarders and the Mac's own
    /// work stay responsive however busy the leases are).
    static func defaultBudget(memoryBytes: UInt64, cores: Int) -> LeaseSize {
        let memory = Int64(clamping: memoryBytes)
        let reserve = min(max(16 << 30, memory / 4), memory / 2)
        return LeaseSize(cpus: max(1, cores - 2), memoryBytes: max(0, memory - reserve))
    }

    func estimate(_ platform: Platform) -> LeaseSize {
        estimates[platform] ?? Self.defaultEstimates[platform] ?? LeaseSize(cpus: 1, memoryBytes: 1 << 30)
    }

    /// How many leases of `size` the whole budget holds.
    func count(of size: LeaseSize) -> Int {
        var count = Int.max
        if size.cpus > 0 { count = min(count, budget.cpus / size.cpus) }
        if size.memoryBytes > 0 { count = min(count, Int(budget.memoryBytes / size.memoryBytes)) }
        return count == .max ? 0 : count
    }

    /// `budget 30 cpus, 112 GB; caps macos 2; the rest by the budget`: the
    /// server's log line.
    var summary: String {
        let capped = caps.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        return "budget \(budget); caps \(capped.isEmpty ? "none" : capped.joined(separator: ", ")); the rest by the budget"
    }

    /// Why a lease can't be granted beside those held, or nil if it can.
    func refusal(_ demand: LeaseDemand, held: [LeaseDemand]) -> AdmissionRefusal? {
        if demand.size.cpus > budget.cpus || demand.size.memoryBytes > budget.memoryBytes {
            return .tooBig(demand.size, budget: budget)
        }
        if let cap = caps[demand.platform] {
            let count = held.filter { $0.platform == demand.platform }.count
            if count >= cap { return .cap(demand.platform, held: count, cap: cap) }
        }
        let used = held.reduce(LeaseSize.zero) { $0 + $1.size }
        if used.memoryBytes + demand.size.memoryBytes > budget.memoryBytes {
            return .memory(used: used.memoryBytes, needs: demand.size.memoryBytes, budget: budget.memoryBytes)
        }
        if used.cpus + demand.size.cpus > budget.cpus {
            return .cpus(used: used.cpus, needs: demand.size.cpus, budget: budget.cpus)
        }
        return nil
    }

    /// A type's line in the status: how many are held, what they take, and
    /// how many may be held now (`limit`: its cap, or fewer where the budget
    /// has room for fewer more of `typical`, its default config's size).
    func capacity(_ platform: Platform, held: [LeaseDemand], typical: LeaseSize) -> Capacity {
        let mine = held.filter { $0.platform == platform }
        let free = budget - held.reduce(LeaseSize.zero) { $0 + $1.size }
        var more = Int.max
        if typical.cpus > 0 { more = min(more, free.cpus / typical.cpus) }
        if typical.memoryBytes > 0 { more = min(more, Int(free.memoryBytes / typical.memoryBytes)) }
        if more == .max { more = 0 }
        var limit = mine.count + max(0, more)
        if let cap = caps[platform] { limit = min(limit, cap) }
        return Capacity(platform: platform, limit: limit, leased: mine.count, cap: caps[platform],
                        used: mine.reduce(LeaseSize.zero) { $0 + $1.size }, size: typical)
    }
}

/// Why a lease isn't granted now: the limit that is full (`busy`, which a
/// client may wait out), or a lease bigger than the whole budget
/// (`tooBig`, which it can't).
indirect enum AdmissionRefusal: Sendable, Equatable {
    case cap(Platform, held: Int, cap: Int)
    case memory(used: Int64, needs: Int64, budget: Int64)
    case cpus(used: Int, needs: Int, budget: Int)
    case tooBig(LeaseSize, budget: LeaseSize)
    /// It would fit, but would take room the oldest lease waiting needs:
    /// that lease's type and size, how long it has waited, and what would
    /// be full with room kept for it.
    case behind(LeaseDemand, waited: TimeInterval, AdmissionRefusal)

    var code: String {
        if case .tooBig = self { return "tooBig" }
        return "busy"
    }

    /// `busy: macos 2 of 2 leased`, `busy: memory 120 of 128 GB leased; this needs 16`.
    var message: String {
        switch self {
        case .tooBig: return detail
        default: return "busy: \(detail)"
        }
    }

    private var detail: String {
        switch self {
        case .cap(let platform, let held, let cap):
            return "\(platform.rawValue) \(held) of \(cap) leased"
        case .memory(let used, let needs, let budget):
            return "memory \(LeaseSize.gigabytes(used)) of \(LeaseSize.gigabytes(budget)) GB leased; this needs \(LeaseSize.gigabytes(needs))"
        case .cpus(let used, let needs, let budget):
            return "cpus \(used) of \(budget) leased; this needs \(needs)"
        case .tooBig(let size, let budget):
            return "this lease (\(size)) is more than the server's whole budget (\(budget)): no wait would get it"
        case .behind(let oldest, let waited, let full):
            // What is full, the room kept for the oldest told apart from what's leased.
            let kept: String
            switch full {
            case .cap(let platform, let held, let cap):
                kept = "\(platform.rawValue) \(held - 1) of \(cap) leased and the next kept for it"
            case .memory(let used, let needs, let budget):
                kept = "memory \(LeaseSize.gigabytes(used - oldest.size.memoryBytes)) of \(LeaseSize.gigabytes(budget)) GB leased and "
                    + "\(LeaseSize.gigabytes(oldest.size.memoryBytes)) kept for it; this needs \(LeaseSize.gigabytes(needs))"
            case .cpus(let used, let needs, let budget):
                kept = "cpus \(used - oldest.size.cpus) of \(budget) leased and \(oldest.size.cpus) kept for it; this needs \(needs)"
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
/// needs (its type's last place under the cap, or the CPUs and memory the
/// budget has left) waits too.
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
    private(set) var waiters: [Waiter] = []

    init(policy: LeasePolicy, patience: TimeInterval = 45) {
        self.policy = policy
        self.patience = patience
    }

    /// Nil: grant it (its ticket leaves the line). Else why not; a `busy`
    /// request with a ticket is kept in line (or its place kept).
    mutating func decide(_ demand: LeaseDemand, ticket: String?, config: String, holder: String,
                         held: [LeaseDemand], now: Date = Date()) -> AdmissionRefusal? {
        prune(now: now)
        let ticket = ticket.flatMap { $0.isEmpty ? nil : $0 }
        if let refusal = policy.refusal(demand, held: held) {
            if case .tooBig = refusal {
                if let ticket { waiters.removeAll { $0.ticket == ticket } }
            } else {
                wait(ticket, demand, config: config, holder: holder, now: now, reason: refusal.message)
            }
            return refusal
        }
        // The oldest in line before this one: kept room for.
        if let oldest = waiters.first, oldest.ticket != ticket,
           let refusal = policy.refusal(demand, held: held + [oldest.demand]) {
            let behind = AdmissionRefusal.behind(oldest.demand, waited: now.timeIntervalSince(oldest.arrived), refusal)
            wait(ticket, demand, config: config, holder: holder, now: now, reason: behind.message)
            return behind
        }
        if let ticket { waiters.removeAll { $0.ticket == ticket } }
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
    /// The limits server.json sets, its budget's defaults from this Mac.
    func leasePolicy(memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
                     cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> LeasePolicy {
        var caps: [Platform: Int] = [:]
        for (name, cap) in limits {
            if let platform = Platform(rawValue: name) { caps[platform] = max(0, cap) }
        }
        let defaults = LeasePolicy.defaultBudget(memoryBytes: memoryBytes, cores: cores)
        let budget = LeaseSize(cpus: self.budget?.cpus.map { max(0, $0) } ?? defaults.cpus,
                               memoryBytes: self.budget?.memoryGB.map { Int64(max(0, $0) * Double(1 << 30)) } ?? defaults.memoryBytes)
        var estimates = LeasePolicy.defaultEstimates
        for (name, size) in sizes {
            if let platform = Platform(rawValue: name) { estimates[platform] = size.size }
        }
        return LeasePolicy(caps: caps, budget: budget, estimates: estimates)
    }
}
