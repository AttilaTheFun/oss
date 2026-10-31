import Foundation
import Testing
import OSSClient
@testable import OSSServer

// Lease limits (API 14): each type's count cap, the budget of CPUs and
// memory every lease counts against, and the line of leases waiting for
// room, with the oldest kept room for. None of it needs a machine, so it
// runs on Linux too.

private let gb: Int64 = 1 << 30

private func size(_ cpus: Int, _ memoryGB: Int64) -> LeaseSize { LeaseSize(cpus: cpus, memoryBytes: memoryGB * gb) }
private func demand(_ platform: Platform, _ cpus: Int, _ memoryGB: Int64) -> LeaseDemand {
    LeaseDemand(platform: platform, size: size(cpus, memoryGB))
}
private func policy(caps: [Platform: Int] = [.macos: 2], cpus: Int = 100, memoryGB: Int64 = 1024) -> LeasePolicy {
    LeasePolicy(caps: caps, budget: size(cpus, memoryGB), estimates: LeasePolicy.defaultEstimates)
}
private let mac = demand(.macos, 6, 16)
private let phone = demand(.ios, 1, 2)

// MARK: The limits

@Test func aTypesCapIsItsCountAtMost() {
    let limits = policy()
    #expect(limits.refusal(mac, held: [mac]) == nil)
    let refusal = limits.refusal(mac, held: [mac, mac])
    #expect(refusal == .cap(.macos, held: 2, cap: 2))
    #expect(refusal?.message == "busy: macos 2 of 2 leased")
    #expect(refusal?.code == "busy")
    // Other types' leases don't count against it.
    #expect(limits.refusal(mac, held: [mac, phone, phone]) == nil)
    // 0 lends none.
    #expect(policy(caps: [.windows: 0]).refusal(demand(.windows, 6, 8), held: []) == .cap(.windows, held: 0, cap: 0))
}

@Test func theBudgetByMemory() {
    let limits = policy(caps: [:], memoryGB: 32)
    #expect(limits.refusal(mac, held: [mac]) == nil)
    let refusal = limits.refusal(mac, held: [mac, mac])
    #expect(refusal == .memory(used: 32 * gb, needs: 16 * gb, budget: 32 * gb))
    #expect(refusal?.message == "busy: memory 32 of 32 GB leased; this needs 16")
    // A smaller lease still fits where a bigger one doesn't.
    #expect(limits.refusal(phone, held: [mac, demand(.linux, 2, 14)]) == nil)
    #expect(limits.refusal(demand(.ios, 1, 3), held: [mac, demand(.linux, 2, 14)]) != nil)
}

@Test func theBudgetByCPUs() {
    let limits = policy(caps: [:], cpus: 10)
    #expect(limits.refusal(demand(.linux, 4, 1), held: [mac]) == nil)
    let refusal = limits.refusal(mac, held: [demand(.linux, 6, 8)])
    #expect(refusal == .cpus(used: 6, needs: 6, budget: 10))
    #expect(refusal?.message == "busy: cpus 6 of 10 leased; this needs 6")
}

@Test func aTypeWithNoCapIsLimitedByTheBudgetAlone() {
    // Simulators: no cap, 1 cpu and 2 GB each, a budget of 10 cpus.
    let limits = policy(caps: [.macos: 2], cpus: 10, memoryGB: 64)
    var held: [LeaseDemand] = []
    while limits.refusal(phone, held: held) == nil { held.append(phone) }
    #expect(held.count == 10)
    #expect(limits.refusal(phone, held: held) == .cpus(used: 10, needs: 1, budget: 10))
    // What the status says of it: no cap, room by the budget.
    let line = limits.capacity(.ios, held: Array(held.prefix(4)), typical: phone.size)
    #expect(line.cap == nil && line.leased == 4 && line.limit == 10)
    #expect(line.used == size(4, 8) && line.size == phone.size)
    // A capped type's limit is its cap, or fewer where the budget holds fewer.
    #expect(limits.capacity(.macos, held: [], typical: mac.size).limit == 1)
    #expect(policy().capacity(.macos, held: [mac], typical: mac.size).limit == 2)
}

@Test func aLeaseBiggerThanTheWholeBudgetIsNoWait() {
    var queue = AdmissionQueue(policy: policy(caps: [:], cpus: 4, memoryGB: 12))
    let refusal = queue.decide(mac, ticket: "big", config: "vanilla", holder: "alice", held: [])
    #expect(refusal?.code == "tooBig")
    #expect(refusal?.message.hasPrefix("busy") == false)
    #expect(refusal?.message == "this lease (6 cpus, 16 GB) is more than the server's whole budget (4 cpus, 12 GB): no wait would get it")
    #expect(queue.waiters.isEmpty)
}

// MARK: The line

@Test func theOldestWaitingIsKeptRoomFor() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var queue = AdmissionQueue(policy: policy(caps: [.macos: 2], memoryGB: 20))
    let phones = Array(repeating: phone, count: 10)
    // The budget is full of simulators: a macOS lease waits.
    let first = queue.decide(mac, ticket: "mac", config: "vanilla", holder: "alice", held: phones, now: start)
    #expect(first == .memory(used: 20 * gb, needs: 16 * gb, budget: 20 * gb))
    #expect(queue.waiters.map(\.ticket) == ["mac"])
    // Three simulators go: another would fit, but would take what the
    // macOS lease needs, so it waits too, waiting or not.
    let fewer = Array(phones.dropFirst(3))
    let later = start.addingTimeInterval(30)
    let small = queue.decide(phone, ticket: nil, config: "iphone", holder: "bob", held: fewer, now: later)
    #expect(small == .behind(mac, waited: 30, .memory(used: 30 * gb, needs: 2 * gb, budget: 20 * gb)))
    #expect(small?.message == "busy: a macos lease waiting 30 s goes first (memory 14 of 20 GB leased and 16 kept for it; this needs 2)")
    #expect(queue.decide(phone, ticket: "phone", config: "iphone", holder: "bob", held: fewer, now: later)?.code == "busy")
    #expect(queue.waiters.map(\.ticket) == ["mac", "phone"])
    // The macOS lease asks again, still without room, and keeps its place.
    #expect(queue.decide(mac, ticket: "mac", config: "vanilla", holder: "alice", held: fewer, now: later) != nil)
    #expect(queue.waiters.map(\.ticket) == ["mac", "phone"])
    // The simulators go: the macOS lease gets its room first, and leaves the line.
    let then = later.addingTimeInterval(30)
    #expect(queue.decide(mac, ticket: "mac", config: "vanilla", holder: "alice", held: [], now: then) == nil)
    #expect(queue.waiters.map(\.ticket) == ["phone"])
    // Then the simulator is the oldest, and fits beside it.
    #expect(queue.decide(phone, ticket: "phone", config: "iphone", holder: "bob", held: [mac], now: then) == nil)
    #expect(queue.waiters.isEmpty)
}

@Test func theLineIsFairAcrossTypes() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var queue = AdmissionQueue(policy: policy(caps: [.macos: 2], memoryGB: 64))
    // A macOS lease waits for its cap; the budget has room for it and more.
    #expect(queue.decide(mac, ticket: "mac", config: "vanilla", holder: "alice", held: [mac, mac], now: now)
            == .cap(.macos, held: 2, cap: 2))
    // A simulator doesn't wait for it: it delays nothing the macOS lease needs.
    #expect(queue.decide(phone, ticket: "phone", config: "iphone", holder: "bob", held: [mac, mac], now: now) == nil)
    // A later macOS lease does: the first in line gets the next place under the cap.
    let held = [mac, phone]
    let second = queue.decide(mac, ticket: "mac2", config: "vanilla", holder: "carol", held: held, now: now)
    #expect(second == .behind(mac, waited: 0, .cap(.macos, held: 2, cap: 2)))
    #expect(second?.message == "busy: a macos lease waiting 0 s goes first (macos 1 of 2 leased and the next kept for it)")
    #expect(queue.decide(mac, ticket: "mac", config: "vanilla", holder: "alice", held: held, now: now) == nil)
    #expect(queue.waiters.map(\.ticket) == ["mac2"])
}

@Test func aWaiterThatStopsAskingLeavesTheLine() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var queue = AdmissionQueue(policy: policy(caps: [:], memoryGB: 16), patience: 45)
    #expect(queue.decide(mac, ticket: "gone", config: "vanilla", holder: "alice", held: [phone], now: start) != nil)
    // Asking again keeps its place.
    #expect(queue.decide(mac, ticket: "gone", config: "vanilla", holder: "alice", held: [phone], now: start.addingTimeInterval(30)) != nil)
    #expect(queue.waiting(now: start.addingTimeInterval(60)).map(\.holder) == ["alice"])
    #expect(queue.waiting(now: start.addingTimeInterval(60)).first?.since == start)
    // Silent for longer than its patience: gone, and nothing is kept for it.
    #expect(queue.decide(phone, ticket: nil, config: "iphone", holder: "bob", held: [phone], now: start.addingTimeInterval(80)) == nil)
    #expect(queue.waiters.isEmpty)
}

// MARK: server.json

private func decode(_ json: String) throws -> ServerConfig {
    try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
}

@Test func theDefaultsCapMacOSAlone() {
    let config = ServerConfig()
    #expect(config.limits == ["macos": 2])
    #expect(config.cap(.macos) == 2 && config.cap(.ios) == nil && config.cap(.container) == nil)
    let limits = config.leasePolicy(memoryBytes: 128 << 30, cores: 28)
    #expect(limits.budget == size(26, 96))
    #expect(limits.estimate(.ios) == size(1, 2) && limits.estimate(.android) == size(2, 4))
    #expect(limits.summary == "budget 26 cpus, 96 GB; caps macos 2; the rest by the budget")
}

@Test func theDefaultBudgetKeepsMacOSsShare() {
    // A quarter of the memory, at least 16 GB, at most half; all but two cores.
    #expect(LeasePolicy.defaultBudget(memoryBytes: 128 << 30, cores: 28) == size(26, 96))
    #expect(LeasePolicy.defaultBudget(memoryBytes: 64 << 30, cores: 14) == size(12, 48))
    #expect(LeasePolicy.defaultBudget(memoryBytes: 32 << 30, cores: 10) == size(8, 16))
    #expect(LeasePolicy.defaultBudget(memoryBytes: 16 << 30, cores: 8) == size(6, 8))
    #expect(LeasePolicy.defaultBudget(memoryBytes: 8 << 30, cores: 2) == size(1, 4))
}

@Test func capacityBeforeZeroFourteenIsReadAsTheCaps() throws {
    // The old shape: each type it names is capped as before; the others
    // take the new defaults (macOS two, the rest the budget's).
    let old = try decode(#"{"capacity": {"macos": 2, "windows": 2, "linux": 2, "ios": 4, "android": 2, "container": 4}}"#)
    #expect(old.limits == ["macos": 2, "windows": 2, "linux": 2, "ios": 4, "android": 2, "container": 4])
    let some = try decode(#"{"capacity": {"ios": 6}}"#)
    #expect(some.limits == ["macos": 2, "ios": 6])
    #expect(some.leasePolicy(memoryBytes: 64 << 30, cores: 12).caps == [.macos: 2, .ios: 6])
    // `limits` wins where both name a type; null takes a cap away.
    let both = try decode(#"{"capacity": {"ios": 6, "linux": 1}, "limits": {"ios": 8, "macos": null}}"#)
    #expect(both.limits == ["ios": 8, "linux": 1])
}

@Test func theBudgetAndSizesFromServerJSON() throws {
    let config = try decode(#"{"limits": {"windows": 1}, "budget": {"memoryGB": 100, "cpus": 20}, "sizes": {"ios": {"cpus": 2, "memoryGB": 3.5}}}"#)
    let limits = config.leasePolicy(memoryBytes: 128 << 30, cores: 28)
    #expect(limits.caps == [.macos: 2, .windows: 1])
    #expect(limits.budget == size(20, 100))
    #expect(limits.estimate(.ios) == LeaseSize(cpus: 2, memoryBytes: 7 * gb / 2))
    #expect(limits.estimate(.android) == size(2, 4))
    // Either left out takes its default.
    let half = try decode(#"{"budget": {"cpus": 4}}"#).leasePolicy(memoryBytes: 64 << 30, cores: 12)
    #expect(half.budget == size(4, 48))
    #expect(try decode("{}").limits == ["macos": 2])
}

// MARK: The status

@Test func theStatusSaysTheBudgetEachCapAndWhoWaits() throws {
    let since = Date(timeIntervalSince1970: 1_000_000)
    let status = Status(server: "s", bases: [Base(platform: .macos, config: "vanilla"), Base(platform: .ios, config: "iphone")],
                        capacity: [Capacity(platform: .macos, limit: 2, leased: 2, cap: 2, used: size(12, 32), size: mac.size),
                                   Capacity(platform: .ios, limit: 12, leased: 3, cap: nil, used: size(3, 6), size: phone.size),
                                   Capacity(platform: .linux, limit: 0, leased: 0, cap: 2, used: .zero, size: size(6, 8))],
                        leases: [],
                        budget: LeaseBudget(limit: size(30, 112), used: size(15, 38),
                                            waiting: [WaitingLease(platform: .macos, config: "vanilla", holder: "alice", size: mac.size,
                                                                   since: since, reason: "busy: macos 2 of 2 leased")]))
    let lines = capacityLines(status, now: since.addingTimeInterval(90))
    #expect(lines.first == "  budget: 15 of 30 cpus, 38 of 112 GB leased")
    #expect(lines.contains("  macos: 2 of 2 leased; 6 cpus, 16 GB each; configs: vanilla"))
    #expect(lines.contains("  ios: 3 leased, room for 9 more (no cap); 1 cpu, 2 GB each; configs: iphone"))
    #expect(lines.contains("  linux: 0 of 2 leased, room for 0 more in the budget; 6 cpus, 8 GB each; configs: none"))
    #expect(lines.last == "  waiting: macos/vanilla (6 cpus, 16 GB) for alice, 1 min: busy: macos 2 of 2 leased")
    #expect(status.capacity[1].summary(budgeted: true) == "3, room for 9")
    #expect(status.capacity[0].summary(budgeted: true) == "2 of 2")
    #expect(status.budget?.summary == "15 of 30 cpus, 38 of 112 GB")

    // Through the wire and back.
    let decoded = try JSONDecoder.oss.decode(Status.self, from: try JSONEncoder.oss.encode(status))
    #expect(decoded.budget?.waiting.first?.holder == "alice")
    #expect(decoded.capacity[1].cap == nil && decoded.capacity[0].cap == 2)
}

@Test func aStatusFromBeforeAPI14ReadsAsBefore() throws {
    // What a server before API 14 sends: no budget, no cap, no sizes.
    let json = #"{"server": "s", "bases": [], "leases": [], "capacity": [{"platform": "macos", "limit": 2, "leased": 1}]}"#
    let status = try JSONDecoder.oss.decode(Status.self, from: Data(json.utf8))
    #expect(status.budget == nil)
    #expect(status.capacity[0].cap == nil && status.capacity[0].size == nil)
    #expect(capacityLines(status).first == "  macos: 1/2 leased; configs: none")
    #expect(status.capacity[0].summary(budgeted: false) == "1 of 2")
    // And a request from an older client: no ticket.
    let request = try JSONDecoder.oss.decode(LeaseRequest.self, from: Data(#"{"platform": "ios"}"#.utf8))
    #expect(request.waitTicket == nil)
}
