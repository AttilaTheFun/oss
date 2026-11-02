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
