#if canImport(Network)
import Foundation
import Testing
import OSSClient
@testable import OSSServer

// Lease limits (API 14) through a real server on this computer's loopback,
// lending fake containers (ContainerAPITests): what a lease counts, what
// the status says, and a lease waited for keeping its place in line.

private let gb: Int64 = 1 << 30

private func container(cpus: Int, memoryGB: Int64, holder: String = "alice", ticket: String? = nil) -> LeaseRequest {
    LeaseRequest(platform: .container, holder: holder, container: ContainerSpec(image: "alpine:3.20", cpus: cpus, memoryBytes: memoryGB * gb),
                 waitTicket: ticket)
}

@Test func containersCountAgainstTheMemoryBudget() async throws {
    try await withContainerServer(ports: 38730...38731, budget: BudgetSettings(memoryGB: 20), maxCPUs: 8) { server in
        let first = try await server.machines.lease(container(cpus: 4, memoryGB: 8), local: true)
        #expect(first.size == LeaseSize(cpus: 4, memoryBytes: 8 * gb))
        let second = try await server.machines.lease(container(cpus: 8, memoryGB: 4), local: true)
        // Full by memory: refused, saying so (CPUs are shared out: 12 of the Mac's 8 is fine).
        let refused = await #expect(throws: APIError.self) { try await server.machines.lease(container(cpus: 1, memoryGB: 10), local: true) }
        #expect(refused?.code == "busy")
        #expect(refused?.error == "busy: memory 12 of 20 GB leased; this needs 10")
        // Through the API: 409, as busy always was; more than one machine's CPUs, or the whole budget, is tooBig.
        let busy = await #expect(throws: OSSError.self) { try await server.client.requestLease(container(cpus: 1, memoryGB: 10)) }
        #expect(busy?.status == 409 && busy?.code == "busy")
        let wide = await #expect(throws: OSSError.self) { try await server.client.requestLease(container(cpus: 16, memoryGB: 1)) }
        #expect(wide?.status == 409 && wide?.code == "tooBig")
        let big = await #expect(throws: OSSError.self) { try await server.client.requestLease(container(cpus: 1, memoryGB: 32)) }
        #expect(big?.code == "tooBig")

        // What the status says: the budget and what the leases take;
        // containers have no cap, and room for one more of the default size
        // (8 GB of the 8 left).
        let status = try await server.client.status()
        let budget = try #require(status.budget)
        #expect(budget.memoryBytes == 20 * gb && budget.leasedMemoryBytes == 12 * gb)
        #expect(budget.leasedCPUs == 12 && budget.maxCPUs == 8)
        let line = try #require(status.capacity.first { $0.platform == .container })
        #expect(line.cap == nil && line.leased == 2 && line.limit == 3)
        #expect(status.leases.compactMap(\.size).count == 2)

        // A lease waited for keeps its place; another that would delay it waits too.
        let waited = await #expect(throws: OSSError.self) {
            try await server.client.requestLease(container(cpus: 4, memoryGB: 10, holder: "bob", ticket: "bob-1"))
        }
        #expect(waited?.code == "busy")
        #expect(try await server.client.status().budget?.waiting.map(\.platform) == [.container])
        await server.machines.release(second.id, reason: "released")
        let later = await #expect(throws: APIError.self) { try await server.machines.lease(container(cpus: 2, memoryGB: 4), local: true) }
        #expect(later?.error.hasPrefix("busy: a container lease waiting") == true)
        // The first release makes room for the one waiting, which gets it.
        await server.machines.release(first.id, reason: "released")
        let got = try await server.machines.lease(container(cpus: 4, memoryGB: 10, holder: "bob", ticket: "bob-1"), local: true)
        #expect(got.state != .failed)
        #expect(try await server.client.status().budget?.waiting.isEmpty == true)
    }
}

/// A server lending macOS for a test of image builds' places: nothing is
/// made (a build's place has no machine), so no base is needed.
private func buildServer(memoryGB: Double) -> MachineManager {
    let root = NSTemporaryDirectory() + "oss-build-places-\(UUID().uuidString)"
    var config = ServerConfig()
    config.lends = [.macos]
    config.useUTM = false
    config.budget = BudgetSettings(memoryGB: memoryGB)
    config.maxCPUs = 64
    return MachineManager(config: config, leasesPath: "\(root)/leases.json")
}

private func place(_ layer: String, ticket: String? = nil) -> LeaseRequest {
    LeaseRequest(platform: .macos, config: "vanilla", holder: "alice", waitTicket: ticket, build: layer)
}

@Test func anImageBuildTakesAPlaceLikeALease() async throws {
    let machines = buildServer(memoryGB: 1024)
    // Its VM counts against macOS's cap: two builds, or a build and a lease.
    let first = try await machines.lease(place("tools"), local: true)
    #expect(first.state == .ready && first.build == "tools" && first.name.hasPrefix("oss-build-macos-tools-"))
    #expect(first.size == LeaseSize(cpus: 6, memoryBytes: 16 << 30))
    #expect(first.label == "image build: tools from vanilla")
    let second = try await machines.lease(place("xcode"), local: true)
    let refused = await #expect(throws: APIError.self) { try await machines.lease(place("other"), local: true) }
    #expect(refused?.error == "busy: macos 2 of 2 leased")
    // Waited for, it keeps its place in line, and gets the next one.
    _ = await #expect(throws: APIError.self) { try await machines.lease(place("later", ticket: "later-1"), local: true) }
    #expect(await machines.budget().waiting.map(\.config) == ["vanilla"])
    await machines.release(first.id, reason: "built")
    #expect(await machines.lease(first.id) == nil)
    let later = try await machines.lease(place("later", ticket: "later-1"), local: true)
    #expect(later.build == "later")
    await machines.release(second.id, reason: "built")
    await machines.release(later.id, reason: "built")
    // A build is on the server's Mac, of a VM.
    let remote = await #expect(throws: APIError.self) { try await machines.lease(place("tools"), local: false) }
    #expect(remote?.code == "notLocal")
    _ = await #expect(throws: APIError.self) {
        try await machines.lease(LeaseRequest(platform: .ios, holder: "alice", build: "tools"), local: true)
    }
}

@Test func anImageBuildCountsAgainstTheMemoryBudget() async throws {
    let machines = buildServer(memoryGB: 20)
    let first = try await machines.lease(place("tools"), local: true)
    let refused = await #expect(throws: APIError.self) { try await machines.lease(place("xcode"), local: true) }
    #expect(refused?.error == "busy: memory 16 of 20 GB leased; this needs 16")
    await machines.release(first.id, reason: "built")
}
#endif
