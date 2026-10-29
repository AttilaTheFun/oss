import Foundation
import Testing
@testable import OSSClient

@Test func execFramesRoundTrip() {
    let frames: [ExecFrame] = [.start(ExecRequest(arguments: ["sh", "-c", "echo hi"], environment: ["A": "b"], workingDirectory: "/tmp")),
                               .stdin(Data("in".utf8)), .closeStdin, .resize(columns: 120, rows: 40), .signal(15),
                               .stdout(Data("out".utf8)), .stderr(Data()), .exit(-1)]
    var buffer = frames.reduce(Data()) { $0 + $1.encoded }
    // Half a frame stays in the buffer until the rest comes.
    let tail = buffer.suffix(3)
    buffer = Data(buffer.dropLast(3))
    var decoded = ExecFrame.decode(&buffer)
    #expect(decoded == Array(frames.dropLast()))
    buffer.append(tail)
    decoded = ExecFrame.decode(&buffer)
    #expect(decoded == [.exit(-1)])
    #expect(buffer.isEmpty)
}

@Test func distances() {
    #expect(OSSDistance.of(URL(string: "http://127.0.0.1:7480")!) == .thisComputer)
    #expect(OSSDistance.of(URL(string: "http://192.168.1.20:7480")!) == .lan)
    #expect(OSSDistance.of(URL(string: "http://mini.local:7480")!) == .lan)
    #expect(OSSDistance.of(URL(string: "http://100.101.1.2:7480")!) == .tailnet)
    #expect(OSSDistance.of(URL(string: "http://example.com:7480")!) == .internet)
}

/// Servers answering from canned statuses, by host.
struct FakeServers: OSSTransport {
    var hosts: [String: (name: String, status: Status)]
    let leased = Leased()

    final class Leased: @unchecked Sendable {
        let lock = NSLock()
        var hosts: [String] = []
        func add(_ host: String) { lock.lock(); hosts.append(host); lock.unlock() }
    }

    func send(_ request: OSSHTTPRequest) async throws -> OSSHTTPResponse {
        guard let host = request.url.host, let server = hosts[host] else { throw OSSError(status: 0, message: "unreachable") }
        let path = request.url.path
        func json(_ value: some Encodable, _ status: Int = 200) throws -> OSSHTTPResponse {
            OSSHTTPResponse(status: status, headers: [:], body: try JSONEncoder.oss.encode(value))
        }
        switch (request.method, path) {
        case ("GET", "/v1/hello"): return try json(["server": "oss", "host": server.name])
        case ("GET", "/v1/status"): return try json(server.status)
        case ("POST", "/v1/machines"):
            leased.add(host)
            let lease = try JSONDecoder.oss.decode(LeaseRequest.self, from: request.body ?? Data())
            return try json(Lease(id: "1", platform: lease.platform, config: "c", name: "n", holder: "h", state: .ready,
                                  created: Date(), expires: Date()), 201)
        default: return try json(APIError(error: "no"), 404)
        }
    }
}

func status(_ platform: Platform, limit: Int, leased: Int) -> Status {
    Status(server: "s", bases: [Base(platform: platform, config: "c")],
           capacity: [Capacity(platform: platform, limit: limit, leased: leased)], leases: [])
}

@Test func poolLeasesFromTheNearestWithRoom() async throws {
    let fake = FakeServers(hosts: ["100.64.0.2": ("studio", status(.ios, limit: 4, leased: 0)),
                                   "192.168.1.3": ("mini", status(.ios, limit: 2, leased: 2)),
                                   "192.168.1.4": ("other", status(.ios, limit: 2, leased: 1))])
    let pool = OSSPool(entries: [
        OSSServerEntry(name: "studio", servers: [URL(string: "http://100.64.0.2:7480")!], token: { "t" }),
        OSSServerEntry(name: "mini", servers: [URL(string: "http://192.168.1.3:7480")!], token: { "t" }),
        OSSServerEntry(name: "other", servers: [URL(string: "http://192.168.1.4:7480")!], token: { "t" }),
    ], transport: fake)
    let (client, _) = try await pool.lease(LeaseRequest(platform: .ios))
    // The mini is nearer but full; the other LAN server before the tailnet's.
    #expect(client.server.host == "192.168.1.4")
}

@Test func poolLendsContainersWithMountsOnlyFromThisComputer() async throws {
    let fake = FakeServers(hosts: ["192.168.1.3": ("mini", status(.container, limit: 1, leased: 0)),
                                   "127.0.0.1": (OSSPool.thisHost, status(.container, limit: 1, leased: 0))])
    let mounted = LeaseRequest(platform: .container,
                               container: ContainerSpec(image: "alpine", mounts: [ContainerMount(source: "/src", destination: "/src")]))
    let elsewhere = OSSPool(entries: [OSSServerEntry(name: "mini", servers: [URL(string: "http://192.168.1.3:7480")!], token: { "t" })],
                            transport: fake)
    await #expect(throws: OSSError.self) { try await elsewhere.lease(mounted) }
    // Without mounts, from another computer's server too (API 8).
    let (anywhere, _) = try await elsewhere.lease(LeaseRequest(platform: .container, container: ContainerSpec(image: "alpine")))
    #expect(anywhere.server.host == "192.168.1.3")
    let both = OSSPool(entries: [OSSServerEntry(name: "mini", servers: [URL(string: "http://192.168.1.3:7480")!], token: { "t" }),
                                 OSSServerEntry(name: "here", servers: [URL(string: "http://127.0.0.1:7480")!], token: { "t" })],
                       transport: fake)
    let (client, _) = try await both.lease(mounted)
    #expect(client.server.host == "127.0.0.1")
}

@Test func containerSpecsFromBeforePortsStillRead() throws {
    // A spec an older client sent, or a lease an older server saved: no ports.
    let spec = try JSONDecoder.oss.decode(ContainerSpec.self, from: Data(#"{"image": "alpine:3.20"}"#.utf8))
    #expect(spec.ports.isEmpty)
    let lease = try JSONDecoder.oss.decode(Lease.self, from: Data(#"""
        {"id": "a1", "platform": "container", "config": "linux", "name": "oss-lease-container-a1", "holder": "h",
         "state": "ready", "created": "2026-10-27T00:00:00Z", "expires": "2026-10-27T01:00:00Z"}
        """#.utf8))
    #expect(lease.ports == nil)
    #expect(ForwardedPort(port: 8080, host: "server.local", hostPort: 47512).description == "8080 → server.local:47512")
}

@Test func aGrantsPathGoesToTheFirstServerThatAnswers() async throws {
    // A grant asked for on the server's Mac names it as 127.0.0.1; its path
    // alone is the same grant wherever the server is reached.
    let fake = FakeServers(hosts: ["192.168.1.3": ("lan", status(.container, limit: 1, leased: 0))])
    let path = "/v1/machines/a1/exec?grant=e30.c2ln"
    let servers = [URL(string: "http://127.0.0.1:7480")!, URL(string: "http://192.168.1.3:7480/")!]
    let client = try await OSSGrantClient.resolving(path, servers: servers, transport: fake)
    #expect(client.url.absoluteString == "http://192.168.1.3:7480" + path)
    // A whole URL as it is, no server asked.
    let whole = "http://100.64.0.2:7480" + path
    #expect(try await OSSGrantClient.resolving(whole, servers: [], transport: fake).url.absoluteString == whole)
    // No server answering, or neither a URL nor a path: said so.
    let none = await #expect(throws: OSSError.self) {
        try await OSSGrantClient.resolving(path, servers: [URL(string: "http://127.0.0.1:7480")!], transport: fake)
    }
    #expect(none?.message.contains("no oss server answered") == true)
    await #expect(throws: OSSError.self) { try await OSSGrantClient.resolving("v1/machines/a1/exec", servers: servers, transport: fake) }
}
