import Foundation
import Testing
import OSSClient
@testable import OSSServer

// The primary VMs (Primary.swift, docs/primary-vms.md): server.json's
// settings and what keeping the macOS one asks for.

@Test func serverJSONsPrimaryTakesItsDefaultsAndItsOwn() throws {
    let none = try JSONDecoder().decode(ServerConfig.self, from: Data("{}".utf8))
    #expect(none.primary == nil)
    let defaults = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"primary": {"macos": {}}}"#.utf8))
    #expect(defaults.primary?.macos == PrimaryMacSettings(config: "xcode_27_2", cpus: 8, memoryGigabytes: 24, slots: 4))
    #expect(defaults.primary?.macos?.size == LeaseSize(cpus: 8, memoryBytes: 24 << 30))
    let own = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"primary": {"macos": {"config": "xcode_27_0", "memoryGigabytes": 32, "slots": 6}}}"#.utf8))
    #expect(own.primary?.macos == PrimaryMacSettings(config: "xcode_27_0", cpus: 8, memoryGigabytes: 32, slots: 6))
}

@Test func keepingThePrimaryMakesChecksAndReplacesIt() {
    let settings = PrimaryMacSettings()
    func primary(_ state: LeaseState, config: String = "xcode_27_2", size: LeaseSize? = PrimaryMacSettings().size) -> Lease {
        var lease = Lease(id: "p1", platform: .macos, config: config, name: "oss-primary-macos-p1", holder: PrimaryPlan.holder,
                          state: state, created: Date(), expires: .distantFuture)
        lease.kind = .primary
        lease.size = size
        return lease
    }
    var agents = Lease(id: "a1", platform: .macos, config: "xcode_27_2", name: "oss-lease-macos-a1", holder: "someone",
                       state: .ready, created: Date(), expires: Date())
    agents.kind = .agent

    // None wanted, none held; or none held while a restart is pending.
    #expect(PrimaryPlan.step(nil, lendsMacOS: true, restartPending: false, held: [agents]) == .none)
    #expect(PrimaryPlan.step(settings, lendsMacOS: true, restartPending: true, held: [agents]) == .none)
    // Wanted, none held (an agent's macOS VM is not it): made.
    #expect(PrimaryPlan.step(settings, lendsMacOS: true, restartPending: false, held: [agents]) == .make)
    // Being made: waited for; ready: checked.
    #expect(PrimaryPlan.step(settings, lendsMacOS: true, restartPending: false, held: [primary(.creating)]) == .wait)
    #expect(PrimaryPlan.step(settings, lendsMacOS: true, restartPending: false, held: [agents, primary(.ready)]) == .check("p1"))
    // Being released (or failed): not it, so another is made.
    #expect(PrimaryPlan.step(settings, lendsMacOS: true, restartPending: false, held: [primary(.returning)]) == .make)
    // No longer wanted, or no longer as server.json says: released.
    guard case .release("p1", _) = PrimaryPlan.step(nil, lendsMacOS: true, restartPending: false, held: [primary(.ready)]) else {
        Issue.record("an unwanted primary is released"); return
    }
    guard case .release("p1", _) = PrimaryPlan.step(settings, lendsMacOS: false, restartPending: false, held: [primary(.ready)]) else {
        Issue.record("a server that lends no macOS keeps none"); return
    }
    guard case .release("p1", let why) = PrimaryPlan.step(settings, lendsMacOS: true, restartPending: false,
                                                           held: [primary(.ready, config: "vanilla")]) else {
        Issue.record("a primary of another base is replaced"); return
    }
    #expect(why.contains("xcode_27_2"))
    guard case .release("p1", _) = PrimaryPlan.step(settings, lendsMacOS: true, restartPending: false,
                                                     held: [primary(.ready, size: LeaseSize(cpus: 4, memoryBytes: 16 << 30))]) else {
        Issue.record("a primary of another size is replaced"); return
    }
}

/// Slots (`mac` leases): as many as the primary lends, its type's cap; none
/// without a primary; taking nothing of the budget, so a full budget still
/// has room for one.
@Test func slotsAreTheirPrimarysCapAndTakeNoMemory() throws {
    let gb: Int64 = 1 << 30
    let config = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"budget": {"memoryGB": 96}, "primary": {"macos": {"slots": 2}}}"#.utf8))
    let policy = config.leasePolicy(memoryBytes: 128 << 30, cores: 16)
    #expect(policy.caps[.mac] == 2)
    let slot = LeaseDemand(platform: .mac, size: policy.estimate(.mac))
    #expect(slot.size.memoryBytes == 0)
    // A budget all but full (the primary and agents): a slot still fits.
    let full = [LeaseDemand(platform: .macos, size: LeaseSize(cpus: 8, memoryBytes: 24 * gb)),
                LeaseDemand(platform: .macos, size: LeaseSize(cpus: 6, memoryBytes: 16 * gb))]
    #expect(policy.refusal(slot, held: full, outside: 56 * gb) == nil)
    #expect(policy.capacity(.mac, held: full, typical: slot.size).limit == 2)
    // Two held: the third waits for one.
    #expect(policy.refusal(slot, held: full + [slot, slot]) != nil)
    #expect(policy.capacity(.mac, held: full + [slot], typical: slot.size).limit == 2)
    // No primary: no cap of slots (leaseSlot lends none), the caps as they were.
    #expect(ServerConfig().leasePolicy(memoryBytes: 128 << 30, cores: 16).caps[.mac] == nil)
}

@Test func aSlotsOrphansAndItsPrimarysSlots() {
    func lease(_ id: String, _ platform: Platform, kind: LeaseKind? = nil, primary: String? = nil, state: LeaseState = .ready) -> Lease {
        var lease = Lease(id: id, platform: platform, config: "xcode_27_2", name: id, holder: "h", state: state, created: Date(), expires: .distantFuture)
        lease.kind = kind
        lease.primary = primary
        return lease
    }
    let held = [lease("p1", .macos, kind: .primary), lease("s1", .mac, primary: "p1"), lease("s2", .mac, primary: "gone"),
                lease("s3", .mac, primary: "p1", state: .returning)]
    #expect(PrimaryPlan.slots(of: "p1", held).map(\.id).sorted() == ["s1", "s3"])
    #expect(PrimaryPlan.orphans(held).map(\.id) == ["s2"])
    // A primary whose settings changed is kept while a slot of its is held.
    #expect(PrimaryPlan.step(PrimaryMacSettings(config: "xcode_27_0"), lendsMacOS: true, restartPending: false, held: held) == .check("p1"))
}

@Test func aSlotUsersScriptsMakeAndDeleteIt() {
    let make = SlotUser.makeScript(lease: "ab12", password: "kc")
    #expect(make.contains("sysadminctl -addUser \"$user\" -fullName \"OS Server slot ab12\" -password 'kc'"))
    #expect(make.contains("user=oss-ab12"))
    // The login keychain sysadminctl made, unlocked with the same password; made again if it won't.
    #expect(make.contains("if ! sudo -u \"$user\" -H security unlock-keychain -p 'kc' '/Users/oss-ab12/Library/Keychains/login.keychain-db'"))
    #expect(make.contains("security create-keychain -p 'kc' '/Users/oss-ab12/Library/Keychains/login.keychain-db'"))
    let delete = SlotUser.deleteScript(lease: "ab12")
    #expect(delete.contains("sysadminctl -deleteUser \"$user\""))
    #expect(delete.contains("rm -rf \"/Users/$user\""))
    #expect(SlotSecrets.keychainPassword("ab12", key: "/nonexistent") == SlotSecrets.keychainPassword("ab12", key: "/nonexistent"))
    #expect(SlotSecrets.keychainPassword("ab12", key: "/nonexistent") != SlotSecrets.keychainPassword("cd34", key: "/nonexistent"))
}

/// A client below API 17 can't read a slot's platform: the waiting line it
/// is shown has none (Server.route's `visible` hides them elsewhere).
@Test func aBudgetsWaitingLineHidesWhatAClientCantRead() {
    let waiting = [WaitingLease(platform: .mac, config: "xcode_27_2", holder: "a", size: LeaseSize(cpus: 0, memoryBytes: 0), since: Date(), reason: "cap"),
                   WaitingLease(platform: .macos, config: "xcode_27_2", holder: "b", size: LeaseSize(cpus: 6, memoryBytes: 16 << 30), since: Date(), reason: "cap")]
    let budget = LeaseBudget(memoryBytes: 96 << 30, leasedMemoryBytes: 0, leasedCPUs: 0, maxCPUs: 28, waiting: waiting)
    #expect(budget.visible { $0 != .mac }.waiting.map(\.holder) == ["b"])
    #expect(budget.visible { _ in true }.waiting.count == 2)
}
