import Foundation
import Testing
import OSSClient
@testable import OSSServer

// `oss container-host` (Visor's container-host contract) against a real
// server on this computer's loopback lending fake containers
// (ContainerAPITests' ContainerServer): each container a lease held until
// released and found again by its labels. The network's checks are
// commands of the test's: the fake containers are this Mac's processes.

@Test func theServersRefusalsInTheContractsWords() {
    #expect(ContainerHostCommand.failure(OSSError(status: 409, message: "busy: 2 of 2", code: "busy")).json["code"] as? String == "busy")
    #expect(ContainerHostCommand.failure(OSSError(status: 404, message: "no lease")).json["code"] as? String == "notFound")
    #expect(ContainerHostCommand.failure(OSSError(status: 0, message: "lease 1 failed: image not found: x")).json["code"] as? String == "noImage")
    #expect(ContainerHostCommand.failure(OSSError(status: 0, message: "something else")).json["code"] == nil)
}

#if canImport(Network)

/// A host over `server`, its network checks `resolve` and `reach`, and no
/// waiting worth the name.
private func host(_ server: ContainerServer, resolve: [String] = ["true"], reach: [String] = ["true"]) -> ContainerHostCommand {
    var host = ContainerHostCommand(client: server.client)
    host.resolve = resolve
    host.reach = reach
    host.tries = 2
    host.pause = .milliseconds(10)
    host.step = .milliseconds(50)
    host.patience = .seconds(10)
    return host
}

private func request(_ name: String = "visor-s1", image: String = "alpine:3.20", session: String = "s1") -> Data {
    Data(#"""
        {"api": 1, "name": "\#(name)", "image": "\#(image)", "cpus": 2, "memoryBytes": 4294967296,
         "volumes": [{"name": "\#(name)-build", "destination": "/var/cache/bazel", "sizeBytes": 17179869184}],
         "environment": {"VISOR_URL": "ws://host:7633"}, "rosetta": true,
         "labels": {"visor.session": "\#(session)", "visor.server": "server-1"}}
        """#.utf8)
}

@Test func aLeaseKeepsItsLabels() async throws {
    try await withContainerServer(ports: 38720...38721) { server in
        let made = try await server.machines.lease(LeaseRequest(platform: .container, holder: "alice", container: ContainerSpec(image: "alpine"),
                                                                labels: ["app/role": "line\none", "visor.session": "s1"]), local: true)
        #expect(made.labels == ["app/role": "line one", "visor.session": "s1"])
        #expect(try await server.client.lease(made.id).labels?["visor.session"] == "s1")

        await #expect(throws: APIError.self) {
            try await server.machines.lease(LeaseRequest(platform: .container, holder: "alice", container: ContainerSpec(image: "alpine"),
                                                         labels: ["no spaces": "x"]), local: true)
        }
        let many = Dictionary(uniqueKeysWithValues: (0...32).map { ("k\($0)", "v") })
        await #expect(throws: APIError.self) {
            try await server.machines.lease(LeaseRequest(platform: .container, holder: "alice", container: ContainerSpec(image: "alpine"),
                                                         labels: many), local: true)
        }
    }
}

@Test func createLeasesAContainerHeldUntilReleasedAndLabelled() async throws {
    try await withContainerServer(ports: 38722...38723) { server in
        let made = await host(server).create(request())
        #expect(made.status == 0, "\(made.text)")
        let id = try #require(made.json["id"] as? String)
        #expect(made.json["name"] as? String == "visor-s1")
        #expect(made.json["cpus"] as? Int == 2)

        let lease = try await server.client.lease(id)
        #expect(lease.holder == "visor-s1")
        #expect(lease.kind == .session)
        #expect(lease.expires == .distantFuture)
        #expect(lease.labels?["visor.session"] == "s1")
        #expect(lease.labels?[ContainerHostCommand.nameLabel] == "visor-s1")
        #expect(lease.container?.volumes == [ContainerVolume(name: "visor-s1-build", destination: "/var/cache/bazel", sizeBytes: 16 << 30, keep: true)])
        #expect(lease.container?.rosetta == true)
        #expect(lease.container?.environment == ["VISOR_URL": "ws://host:7633"])
    }
}

@Test func createAskedAgainAnswersTheOneItMadeAndRefusesANameMadeOtherwise() async throws {
    try await withContainerServer(ports: 38724...38725) { server in
        let host = host(server)
        let first = try #require(await host.create(request()).json["id"] as? String)
        let again = await host.create(request())
        #expect(again.status == 0)
        #expect(again.json["id"] as? String == first)
        #expect(try await server.client.leases().count == 1)

        let other = await host.create(request(image: "alpine:3.21"))
        #expect(other.status == 1)
        #expect(other.json["code"] as? String == "exists")
        #expect(try await server.client.leases().count == 1)
    }
}

@Test func oneThatResolvesNothingIsNotHandedOver() async throws {
    try await withContainerServer(ports: 38726...38727) { server in
        let made = await host(server, resolve: ["false"]).create(request())
        #expect(made.status == 1)
        #expect(made.json["code"] as? String == "network")
        for _ in 0..<100 {
            if try await server.client.leases().filter({ $0.state != .returning }).isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await server.client.leases().filter { $0.state != .returning }.isEmpty)
    }
}

@Test func putWritesInTheContainer() async throws {
    try await withContainerServer(ports: 38728...38729) { server in
        let host = host(server)
        let id = try #require(await host.create(request()).json["id"] as? String)
        let put = await host.put(id, path: "~/.config/sign-in.json", mode: "600", data: Data("{}".utf8))
        #expect(put.status == 0, "\(put.text)")
        #expect(put.json["size"] as? Int64 == 2)
        let lease = try await server.client.lease(id)
        #expect(FileManager.default.contents(atPath: server.containers.home(lease.name) + "/.config/sign-in.json") == Data("{}".utf8))

        let missing = await host.put("nosuch", path: "~/x", mode: "600", data: Data())
        #expect(missing.json["code"] as? String == "notFound")
    }
}

@Test func removeReleasesItAndOneGoneIsNoError() async throws {
    try await withContainerServer(ports: 38730...38731) { server in
        let host = host(server)
        let id = try #require(await host.create(request()).json["id"] as? String)
        let removed = await host.remove(id, volumes: true)
        #expect(removed.status == 0)
        #expect(removed.json["removed"] as? String == id)
        #expect((try? await server.client.lease(id)) == nil)
        #expect(await host.remove(id, volumes: false).status == 0)

        // Made again by its name, after: a new one.
        let again = try #require(await host.create(request()).json["id"] as? String)
        #expect(again != id)
    }
}

@Test func listIsTheHostsContainersWithTheirOwnLabels() async throws {
    try await withContainerServer(ports: 38732...38734) { server in
        let host = host(server)
        let id = try #require(await host.create(request()).json["id"] as? String)
        _ = try await server.lease("alice")
        let listed = await host.list()
        let containers = try #require(listed.json["containers"] as? [[String: Any]])
        #expect(containers.count == 1)
        #expect(containers.first?["id"] as? String == id)
        #expect(containers.first?["name"] as? String == "visor-s1")
        #expect(containers.first?["image"] as? String == "alpine:3.20")
        #expect(containers.first?["state"] as? String == "ready")
        #expect(containers.first?["labels"] as? [String: String] == ["visor.session": "s1", "visor.server": "server-1"])
    }
}

@Test func networkSaysWhatWorks() async throws {
    try await withContainerServer(ports: 38735...38736) { server in
        let id = try #require(await host(server).create(request()).json["id"] as? String)
        let fine = await host(server).network(id)
        #expect(fine.json["ok"] as? Bool == true)
        let unreached = await host(server, reach: ["false"]).network(id)
        #expect(unreached.json["ok"] as? Bool == false)
        #expect(unreached.json["dns"] as? Bool == true)
        let unresolved = await host(server, resolve: ["false"]).network(id)
        #expect(unresolved.json["dns"] as? Bool == false)
        #expect(await host(server).network("nosuch").json["code"] as? String == "notFound")
    }
}

@Test func healthSaysTheServerLendsContainersAndKeepsLabels() async throws {
    try await withContainerServer(ports: 38737...38738) { server in
        let health = await host(server).health()
        #expect(health.status == 0)
        #expect(health.json["ok"] as? Bool == true, "\(health.text)")
        #expect(health.json["api"] as? Int == 1)
        #expect(health.json["version"] as? String == OSS.version)
    }
}

#endif
