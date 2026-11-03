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
    #expect(make.contains("as_user security unlock-keychain -p 'kc' '/Users/oss-ab12/Library/Keychains/login.keychain-db' 2>/dev/null || {"))
    #expect(make.contains("as_user security create-keychain -p 'kc' '/Users/oss-ab12/Library/Keychains/login.keychain-db'"))
    // In the user's bootstrap, and never failing the slot.
    #expect(make.contains("as_user() { sudo launchctl asuser \"$uid\" sudo -u \"$user\" -H \"$@\"; }"))
    #expect(make.contains("its keychain wasn't made; the slot has none"))
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

/// Two primaries (a restart's keepPrimary once made one beside the primary
/// it was recovering): one is kept, one with slots first, else the oldest;
/// the other released, never one with a slot held.
@Test func aSecondPrimaryIsReleased() {
    func primary(_ id: String, created: TimeInterval) -> Lease {
        var lease = Lease(id: id, platform: .macos, config: "xcode_27_2", name: "oss-primary-macos-\(id)", holder: PrimaryPlan.holder,
                          state: .ready, created: Date(timeIntervalSince1970: created), expires: .distantFuture)
        lease.kind = .primary
        lease.size = PrimaryMacSettings().size
        return lease
    }
    func slot(_ id: String, on primary: String) -> Lease {
        var lease = Lease(id: id, platform: .mac, config: "xcode_27_2", name: id, holder: "h", state: .ready, created: Date(), expires: .distantFuture)
        lease.primary = primary
        return lease
    }
    let older = primary("p1", created: 100), newer = primary("p2", created: 200)
    let settings = PrimaryMacSettings()
    // The oldest kept, whatever the order held.
    for held in [[older, newer], [newer, older]] {
        #expect(PrimaryPlan.macos(held)?.id == "p1")
        #expect(PrimaryPlan.step(settings, lendsMacOS: true, restartPending: false, held: held)
                == .release("p2", because: "a second primary macOS VM: p1 is kept"))
    }
    // The one with slots kept, though newer; with no primary wanted, the extra goes first too.
    let withSlot = [older, newer, slot("s1", on: "p2")]
    #expect(PrimaryPlan.macos(withSlot)?.id == "p2")
    #expect(PrimaryPlan.step(nil, lendsMacOS: true, restartPending: false, held: withSlot)
            == .release("p1", because: "a second primary macOS VM: p2 is kept"))
    // No primary wanted: released only once its slots are.
    #expect(PrimaryPlan.step(nil, lendsMacOS: true, restartPending: false, held: [newer, slot("s1", on: "p2")]) == .none)
    #expect(PrimaryPlan.step(nil, lendsMacOS: true, restartPending: false, held: [newer])
            == .release("p2", because: "server.json keeps no primary macOS VM"))
    // Both with slots: neither released for it.
    #expect(PrimaryPlan.extras([older, newer, slot("s1", on: "p1"), slot("s2", on: "p2")]).isEmpty)
}

/// The primary's setup: server.json's lines, one script stopping at the first that fails, Homebrew on its PATH.
@Test func aPrimarysSetupIsOneScript() throws {
    let config = try JSONDecoder().decode(ServerConfig.self, from: Data(#"""
        {"primary": {"macos": {"setup": ["command -v qemu-system-aarch64 || brew install qemu"]}}}
        """#.utf8))
    let settings = try #require(config.primary?.macos)
    #expect(settings.setup == ["command -v qemu-system-aarch64 || brew install qemu"])
    #expect(settings.setupScript == "set -e\nexport PATH=\"/opt/homebrew/bin:$PATH\" HOMEBREW_NO_AUTO_UPDATE=1\ncommand -v qemu-system-aarch64 || brew install qemu")
    #expect(PrimaryMacSettings().setupScript == nil)
    // The setup isn't the primary's size or base: changing it doesn't replace the VM.
    #expect(settings.size == PrimaryMacSettings().size)
}
