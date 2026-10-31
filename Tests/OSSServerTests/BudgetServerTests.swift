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

@Test func containersCountAgainstTheBudget() async throws {
    try await withContainerServer(ports: 38730...38731, budget: BudgetSettings(memoryGB: 16, cpus: 8)) { server in
        let first = try await server.machines.lease(container(cpus: 4, memoryGB: 8), local: true)
        #expect(first.size == LeaseSize(cpus: 4, memoryBytes: 8 * gb))
        let second = try await server.machines.lease(container(cpus: 2, memoryGB: 4), local: true)
        // Full by memory: refused, saying so.
        let refused = await #expect(throws: APIError.self) { try await server.machines.lease(container(cpus: 1, memoryGB: 8), local: true) }
        #expect(refused?.code == "busy")
        #expect(refused?.error == "busy: memory 12 of 16 GB leased; this needs 8")
        // Through the API: 409, as busy always was; a lease bigger than the whole budget is tooBig.
        let busy = await #expect(throws: OSSError.self) { try await server.client.requestLease(container(cpus: 1, memoryGB: 8)) }
        #expect(busy?.status == 409 && busy?.code == "busy")
        let big = await #expect(throws: OSSError.self) { try await server.client.requestLease(container(cpus: 16, memoryGB: 1)) }
        #expect(big?.status == 409 && big?.code == "tooBig")

        // What the status says: the budget and what's used; containers have
        // no cap, and room for none more of the default size (4 cpus, 8 GB).
        let status = try await server.client.status()
        #expect(status.budget?.limit == LeaseSize(cpus: 8, memoryBytes: 16 * gb))
        #expect(status.budget?.used == LeaseSize(cpus: 6, memoryBytes: 12 * gb))
        let line = try #require(status.capacity.first { $0.platform == .container })
        #expect(line.cap == nil && line.leased == 2 && line.limit == 2)
        #expect(line.used == LeaseSize(cpus: 6, memoryBytes: 12 * gb))
        #expect(status.leases.compactMap(\.size).count == 2)

        // A lease waited for keeps its place; another that would delay it waits too.
        let waited = await #expect(throws: OSSError.self) {
            try await server.client.requestLease(container(cpus: 4, memoryGB: 8, holder: "bob", ticket: "bob-1"))
        }
        #expect(waited?.code == "busy")
        #expect(try await server.client.status().budget?.waiting.map(\.platform) == [.container])
        await server.machines.release(second.id, reason: "released")
        let later = await #expect(throws: APIError.self) { try await server.machines.lease(container(cpus: 2, memoryGB: 4), local: true) }
        #expect(later?.error.hasPrefix("busy: a container lease waiting") == true)
        // The first release makes room for the one waiting, which gets it.
        await server.machines.release(first.id, reason: "released")
        let got = try await server.machines.lease(container(cpus: 4, memoryGB: 8, holder: "bob", ticket: "bob-1"), local: true)
        #expect(got.holder == "bob")
        #expect(try await server.client.status().budget?.waiting.isEmpty == true)
    }
}
#endif
