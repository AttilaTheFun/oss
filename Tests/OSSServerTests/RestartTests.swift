import Foundation
import Testing
import OSSClient
@testable import OSSServer

// A pending restart (API 16): what holds it up, when it's made, the line of
// leases waiting held meanwhile and kept across it.

private func lease(_ id: String, _ platform: Platform, kind: LeaseKind, state: LeaseState = .ready) -> Lease {
    Lease(id: id, platform: platform, config: "c", name: "oss-lease-\(platform.rawValue)-\(id)", holder: "h", state: state,
          created: Date(timeIntervalSince1970: 1_000_000), expires: Date(timeIntervalSince1970: 1_003_600), kind: kind)
}

@Test func whatHoldsARestartUp() {
    // A CI job's and an image build's, and one being made or deleted.
    #expect(RestartPlan.holdsUp(lease("a", .container, kind: .ci)))
    #expect(RestartPlan.holdsUp(lease("b", .macos, kind: .build)))
    #expect(RestartPlan.holdsUp(lease("c", .macos, kind: .agent, state: .creating)))
    #expect(RestartPlan.holdsUp(lease("d", .linux, kind: .manual, state: .returning)))
    // Machines in helpers of their own outlive the restart: not waited for.
    #expect(!RestartPlan.holdsUp(lease("e", .container, kind: .session)))
    #expect(!RestartPlan.holdsUp(lease("f", .macos, kind: .agent)))
    #expect(!RestartPlan.holdsUp(lease("g", .container, kind: .ci, state: .failed)))
}

@Test func workAlreadyRunningIsGrantedWhatItAsksFor() {
    var runner = lease("r", .container, kind: .ci)
    runner.holder = "build-and-test-41-runner@ci"
    var vm = lease("v", .macos, kind: .ci)
    vm.holder = "proof-42@ci"
    // A CI job whose runner runs, asking for its VM: granted.
    #expect(RestartPlan.granted(kind: .ci, holder: "build-and-test-41@ci", held: [runner, vm]))
    // A job holding one VM, asking for the next: granted.
    #expect(RestartPlan.granted(kind: .ci, holder: "proof-42@ci", held: [runner, vm]))
    // A new job's, or anyone new's: refused until the restart.
    #expect(!RestartPlan.granted(kind: .ci, holder: "linux-43@ci", held: [runner, vm]))
    #expect(!RestartPlan.granted(kind: .manual, holder: "dev@workstation", held: [runner, vm]))
    #expect(RestartPlan.granted(kind: .session, holder: "visor:s1", held: []))
}

@Test func aRestartWaitsThenIsMadeOrHeldReady() {
    let asked = Date(timeIntervalSince1970: 2_000_000)
    let plain = RestartState(requested: asked, hold: false)
    #expect(RestartPlan.step(plain, holdingUp: 2) == .wait)
    #expect(RestartPlan.step(plain, holdingUp: 0) == .restart)
    // An installer's: ready, then made at its `now`, or at the hold's end.
    var held = RestartState(requested: asked, hold: true)
    #expect(RestartPlan.step(held, holdingUp: 1) == .wait)
    #expect(RestartPlan.step(held, holdingUp: 0, now: asked) == .ready)
    held.ready = asked
    #expect(RestartPlan.step(held, holdingUp: 0, now: asked.addingTimeInterval(60)) == .ready)
    #expect(RestartPlan.step(held, holdingUp: 0, now: asked.addingTimeInterval(RestartPlan.holdTimeout)) == .restart)
    held.now = true
    #expect(RestartPlan.step(held, holdingUp: 0, now: asked.addingTimeInterval(60)) == .restart)
}

@Test func theLineIsHeldAndKeptAcrossARestart() throws {
    let start = Date(timeIntervalSince1970: 3_000_000)
    var queue = AdmissionQueue(policy: LeasePolicy(caps: [:], memoryBytes: 64 << 30, maxCPUs: 64, estimates: LeasePolicy.defaultEstimates))
    let mac = LeaseDemand(platform: .macos, size: LeaseSize(cpus: 6, memoryBytes: 16 << 30))
    queue.hold(mac, ticket: "t1", config: "xcode", holder: "a@ci", reason: "restarting", now: start)
    queue.hold(mac, ticket: "t2", config: "xcode", holder: "b@ci", reason: "restarting", now: start.addingTimeInterval(5))
    #expect(queue.waiting(now: start.addingTimeInterval(10)).map(\.holder) == ["a@ci", "b@ci"])
    // Written down, and read once after the restart.
    let path = NSTemporaryDirectory() + "restart-line-\(UUID().uuidString).json"
    RestartLine.save(queue.waitersForRestart(now: start.addingTimeInterval(10)), to: path, now: start.addingTimeInterval(10))
    let line = RestartLine.take(from: path, now: start.addingTimeInterval(40))
    #expect(line.map(\.ticket) == ["t1", "t2"])
    #expect(RestartLine.take(from: path, now: start.addingTimeInterval(41)).isEmpty)
    // Put back first, before one who asked since; kept through its grace
    // though its clients haven't asked again yet.
    var after = AdmissionQueue(policy: queue.policy)
    after.hold(mac, ticket: "new", config: "xcode", holder: "c@ci", reason: "x", now: start.addingTimeInterval(40))
    after.restore(line, grace: 180, now: start.addingTimeInterval(41))
    #expect(after.waiting(now: start.addingTimeInterval(60)).map(\.holder) == ["a@ci", "b@ci", "c@ci"])
    #expect(after.waiting(now: start.addingTimeInterval(200)).map(\.holder) == ["a@ci", "b@ci"])
    #expect(after.waiting(now: start.addingTimeInterval(300)).isEmpty)
    // A line too old when the server starts is no one's.
    RestartLine.save(line, to: path, now: start)
    #expect(RestartLine.take(from: path, now: start.addingTimeInterval(RestartLine.maxAge + 1)).isEmpty)
}

#if canImport(Network)
@Test func aRestartIsAskedForWithTheTokenAndHoldsNewLeases() async throws {
    let api = makeAPI(makeStore())
    var asked = request("POST", "/v1/server/restart", holder: nil)
    asked.body = try JSONEncoder.oss.encode(RestartRequest(reason: "an update", hold: true))
    let made = await Server.route(asked, api: api)
    #expect(made.status == 200)
    let restart = try JSONDecoder.oss.decode(ServerRestart.self, from: made.body)
    // Nothing runs that it waits for: held, it's ready for its installer.
    #expect(restart.pending && restart.hold && restart.ready != nil && restart.reason == "an update")
    // No new lease meanwhile, but a session's; one waited for keeps its place.
    let manual = LeaseRequest(platform: .linux, minutes: 5, holder: "dev@workstation", waitTicket: "w1")
    await #expect(throws: APIError.self) { _ = try await api.machines.admit(manual, config: "vanilla") }
    let refused = (try? await api.machines.admit(manual, config: "vanilla")) == nil
    #expect(refused)
    #expect(await api.machines.restartStatus().waiting.map(\.holder) == ["dev@workstation"])
    var session = LeaseRequest(platform: .container, minutes: 0, holder: "visor:s1")
    session.kind = .session
    _ = try await api.machines.admit(session, config: "linux")
    // The status says so; called off, leases are granted again.
    #expect(await api.machines.restartPending()?.pending == true)
    let off = await Server.route(request("DELETE", "/v1/server/restart", holder: nil), api: api)
    #expect(try JSONDecoder.oss.decode(ServerRestart.self, from: off.body).pending == false)
    _ = try await api.machines.admit(LeaseRequest(platform: .linux, minutes: 5, holder: "dev@workstation"), config: "vanilla")
    // Only the server's token asks for one.
    let other = makeAPI(makeStore())
    #expect(await Server.route(request("POST", "/v1/server/restart", holder: nil, token: "monitor"), api: other).status != 200)
}
#endif
