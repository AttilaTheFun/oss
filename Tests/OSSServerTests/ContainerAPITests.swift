#if canImport(Network)
import Foundation
import Network
import Testing
import OSSClient
@testable import OSSServer

// A container lease from any computer (API 8), through a real server on
// this computer's loopback: its containers are fakes whose exec sockets
// run each command here, as a process of this computer's, in a folder of
// its own (its home and working directory). The manager's leases are kept
// in a file of the test's own.

/// An exec socket whose commands run on this computer, as a container's
/// would in it: a connection's first frame starts a process (in `home`,
/// with HOME set to it), its stdin fed from the frames that follow, its
/// stdout and stderr sent back as they come, then its exit status.
final class FakeExecServer: @unchecked Sendable {
    let socket: String
    let home: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "oss.test.exec")

    init(socket: String, home: String) throws {
        // A command that exits before its stdin is all written: an error, not the end of the tests.
        signal(SIGPIPE, SIG_IGN)
        self.socket = socket
        self.home = home
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socket)
        listener = try NWListener(using: parameters)
    }

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready, .failed, .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                Task { await self.serve(connection) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(atPath: socket)
    }

    private func serve(_ connection: NWConnection) async {
        let frames = TestFrames(connection)
        guard case .start(let request)? = await frames.next() else { connection.cancel(); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = request.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory ?? home)
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home]) { $1 }.merging(request.environment) { $1 }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Its output as it comes; its exit once both have ended.
        let outputs = DispatchGroup()
        for (pipe, isOut) in [(stdout, true), (stderr, false)] {
            outputs.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    outputs.leave()
                    return
                }
                connection.send(content: (isOut ? ExecFrame.stdout(data) : .stderr(data)).encoded, completion: .contentProcessed { _ in })
            }
        }
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exited.continuation.yield($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            connection.send(content: ExecFrame.stderr(Data("\(error)\n".utf8)).encoded + ExecFrame.exit(127).encoded,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let pump = Task {
            while let frame = await frames.next() {
                switch frame {
                case .stdin(let data): try? stdin.fileHandleForWriting.write(contentsOf: data)
                case .closeStdin: try? stdin.fileHandleForWriting.close()
                case .signal(let number): kill(process.processIdentifier, number)
                default: break
                }
            }
            // Its client gone: the command ends.
            if process.isRunning { process.terminate() }
        }
        var status: Int32 = -1
        for await code in exited.stream {
            status = code
            break
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            outputs.notify(queue: .global()) { continuation.resume() }
        }
        pump.cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: ExecFrame.exit(status).encoded, completion: .contentProcessed { _ in continuation.resume() })
        }
        connection.cancel()
    }
}

/// A connection's frames, awaited.
final class TestFrames: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    private var pending: [ExecFrame] = []

    init(_ connection: NWConnection) { self.connection = connection }

    func next() async -> ExecFrame? {
        while pending.isEmpty {
            let (data, ended): (Data?, Bool) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    continuation.resume(returning: (data, complete || error != nil))
                }
            }
            if let data { buffer.append(data) }
            pending += ExecFrame.decode(&buffer)
            if pending.isEmpty && ended { return nil }
        }
        return pending.removeFirst()
    }
}

/// Containers that are processes of this computer: each a fake exec socket
/// in a folder of its own, at this computer's loopback address.
final class FakeContainers: ContainerBackend, @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private var running: [String: FakeExecServer] = [:]

    init(root: String) { self.root = root }

    func home(_ name: String) -> String { "\(root)/\(name)" }

    func start(name: String, spec: ContainerSpec) async throws -> String {
        // A Unix socket's path has at most 104 bytes.
        let server = try FakeExecServer(socket: NSTemporaryDirectory() + "oss-test-\(UUID().uuidString.prefix(8)).sock", home: home(name))
        await server.start()
        lock.withLock { running[name] = server }
        return server.socket
    }

    func reattach(name: String, spec: ContainerSpec) async -> String? { lock.withLock { running[name]?.socket } }
    func isRunning(name: String) async -> Bool { lock.withLock { running[name] != nil } }
    func address(name: String) async -> String? { "127.0.0.1" }

    func stop(name: String, spec: ContainerSpec?) async {
        lock.withLock { running.removeValue(forKey: name) }?.stop()
    }

    func prune(keeping: Set<String>) async {}
    func directory(name: String) -> String? { home(name) }
    func volumes() async -> [VolumeInfo] { [] }
    func deleteVolume(name: String) async throws {}
    func prepare() async throws {}
    func isPrepared() async -> Bool { true }
    func removeEverything() async {}
}

/// A server on this computer's loopback lending fake containers: its
/// manager (its leases in a file of its own, its forwarded ports from
/// `ports`), its API (the token `server-token`), a client of it.
struct ContainerServer {
    let containers: FakeContainers
    let machines: MachineManager
    let api: API
    let http: HTTPServer
    let url: URL
    let client: OSSClient

    static func start(ports: ClosedRange<Int> = 38700...38709) async throws -> ContainerServer {
        let root = NSTemporaryDirectory() + "oss-containers-test-\(UUID().uuidString)"
        var config = ServerConfig()
        config.lends = [.container]
        config.useUTM = false
        config.firstPort = ports.lowerBound
        config.lastPort = ports.upperBound
        let containers = FakeContainers(root: root)
        let machines = MachineManager(config: config, containers: containers, leasesPath: "\(root)/leases.json")
        let api = API(machines: machines, token: "server-token", cache: nil, storage: makeStore(),
                      grants: GrantKey(key: Data(repeating: 7, count: 32)))
        let http = try HTTPServer(port: 0, streams: Server.streams, streamer: { request, peer in
            await Server.stream(request, peer, api: api)
        }) { request in
            await Server.route(request, api: api)
        }
        http.start()
        var port: Int?
        for _ in 0..<250 where port == nil {
            port = http.boundPort
            if port == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let url = URL(string: "http://127.0.0.1:\(try #require(port))")!
        return ContainerServer(containers: containers, machines: machines, api: api, http: http, url: url,
                               client: OSSClient(server: url, token: "server-token"))
    }

    /// A container lease of `holder`'s, once it is ready (or has failed).
    func lease(_ holder: String = "alice", ports: [Int] = [], local: Bool = true) async throws -> Lease {
        let made = try await machines.lease(LeaseRequest(platform: .container, holder: holder,
                                                         container: ContainerSpec(image: "alpine:3.20", ports: ports)), local: local)
        for _ in 0..<500 {
            if let lease = await machines.lease(made.id), lease.state == .ready || lease.state == .failed { return lease }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw APIError(error: "lease \(made.id) wasn't ready in 10 s")
    }

    func stop() async {
        for lease in await machines.all() { await machines.release(lease.id, reason: "the test is done") }
        http.stop()
        try? FileManager.default.removeItem(atPath: containers.root)
    }
}

/// `body` with a server of its own, stopped afterwards however it ends.
func withContainerServer(ports: ClosedRange<Int>, _ body: (ContainerServer) async throws -> Void) async throws {
    let server = try await ContainerServer.start(ports: ports)
    do {
        try await body(server)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

/// What a command wrote, by stream.
final class Written: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()

    func take(_ frame: ExecFrame) {
        lock.withLock {
            switch frame {
            case .stdout(let data): out.append(data)
            case .stderr(let data): err.append(data)
            default: break
            }
        }
    }

    var stdout: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var stderr: String { lock.withLock { String(decoding: err, as: UTF8.self) } }
}

/// Input that is `frames` and then nothing (its stream left open: a
/// command's stdin ends by `closeStdin`, not by the input ending).
func input(_ frames: ExecFrame...) -> AsyncStream<ExecFrame> {
    let (stream, continuation) = AsyncStream<ExecFrame>.makeStream()
    for frame in frames { continuation.yield(frame) }
    return stream
}

/// A grant's token (its URL's `grant`).
func grantParameter(_ grant: Grant) -> String {
    URLComponents(url: grant.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "grant" }?.value ?? ""
}

@Test func execThroughTheServerRoundTripsStdinStdoutStderrAndStatus() async throws {
    try await withContainerServer(ports: 38700...38701) { server in
        let lease = try await server.lease()
        #expect(lease.state == .ready)

        // stdin in and its end; stdout and stderr apart; the status last.
        let written = Written()
        let status = try await server.client.exec(lease.id, holder: "alice",
                                                  ExecRequest(arguments: ["sh", "-c", "cat; echo to stderr >&2; exit 3"]),
                                                  input: input(.stdin(Data("hello ".utf8)), .stdin(Data("from stdin\n".utf8)), .closeStdin),
                                                  output: written.take)
        #expect(status == 3)
        #expect(written.stdout == "hello from stdin\n")
        #expect(written.stderr == "to stderr\n")

        // Its environment and working directory, as the request gives them.
        let folder = server.containers.home(lease.name) + "/work"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("marked".utf8).write(to: URL(fileURLWithPath: folder + "/marker"))
        let asked = Written()
        let zero = try await server.client.exec(lease.id, holder: "alice",
                                                ExecRequest(arguments: ["sh", "-c", "printf '%s ' \"$GREETING\"; cat marker"],
                                                            environment: ["GREETING": "hi"], workingDirectory: folder),
                                                input: input(.closeStdin), output: asked.take)
        #expect(zero == 0)
        #expect(asked.stdout == "hi marked")

        // A lot of output comes whole, in order.
        let big = Written()
        #expect(try await server.client.exec(lease.id, holder: "alice", ExecRequest(arguments: ["sh", "-c", "seq 1 100000"]),
                                             input: input(.closeStdin), output: big.take) == 0)
        #expect(big.stdout == (1...100_000).map(String.init).joined(separator: "\n") + "\n")
    }
}

@Test func execIsTheLeasesHoldersAndAGrantsForItsLeaseAlone() async throws {
    try await withContainerServer(ports: 38702...38703) { server in
        let lease = try await server.lease()
        let other = try await server.lease()

        // With the token, in another holder's name: not found; in none: refused.
        let bob = await #expect(throws: OSSError.self) {
            try await server.client.exec(lease.id, holder: "bob", ExecRequest(arguments: ["true"]), input: input(.closeStdin)) { _ in }
        }
        #expect(bob?.status == 404)
        let nobody = await #expect(throws: OSSError.self) {
            try await server.client.exec(lease.id, holder: "", ExecRequest(arguments: ["true"]), input: input(.closeStdin)) { _ in }
        }
        #expect(nobody?.status == 400)

        // A machine.exec grant: no token, its own lease.
        let grant = try await server.client.grant(GrantRequest(verb: "machine.exec", lease: lease.id), holder: "alice")
        #expect(grant.path.hasPrefix("/v1/machines/\(lease.id)/exec?grant="))
        let written = Written()
        let status = try await OSSGrantClient(url: grant.url).exec(ExecRequest(arguments: ["sh", "-c", "echo granted; exit 7"]),
                                                                   input: input(.closeStdin), output: written.take)
        #expect(status == 7)
        #expect(written.stdout == "granted\n")

        // The same grant on another lease's route: refused.
        let elsewhere = URL(string: server.url.absoluteString + "/v1/machines/\(other.id)/exec?grant=\(grantParameter(grant))")!
        let refused = await #expect(throws: OSSError.self) {
            try await OSSGrantClient(url: elsewhere).exec(ExecRequest(arguments: ["true"]), input: input(.closeStdin)) { _ in }
        }
        #expect(refused?.status == 403)

        // Another verb's grant for the same lease on the exec route: refused.
        let upload = try await server.client.grant(GrantRequest(verb: "machine.upload", lease: lease.id), holder: "alice")
        let wrongVerb = URL(string: server.url.absoluteString + "/v1/machines/\(lease.id)/exec?grant=\(grantParameter(upload))")!
        let refusedVerb = await #expect(throws: OSSError.self) {
            try await OSSGrantClient(url: wrongVerb).exec(ExecRequest(arguments: ["true"]), input: input(.closeStdin)) { _ in }
        }
        #expect(refusedVerb?.status == 403)

        // No grant for another holder's lease, nor for a lease that isn't a container's.
        await #expect(throws: OSSError.self) {
            try await server.client.grant(GrantRequest(verb: "machine.exec", lease: lease.id), holder: "bob")
        }
        var simulator = Lease(id: "s1", platform: .ios, config: "iphone", name: "oss-lease-ios-s1", holder: "alice", state: .ready,
                              created: Date(), expires: Date().addingTimeInterval(3600))
        simulator.udid = "00000000-0000-0000-0000-000000000000"
        await #expect(throws: APIError.self) {
            try await server.api.grants.issue(GrantRequest(verb: "machine.exec", lease: "s1"), holder: "alice", lease: simulator,
                                              storage: server.api.storage, readsServedFiles: false, base: server.url.absoluteString)
        }
    }
}

@Test func filesGoInAndComeOutWhole() async throws {
    try await withContainerServer(ports: 38704...38705) { server in
        let lease = try await server.lease()
        let home = server.containers.home(lease.name)

        // More than a frame's worth, into folders that aren't there yet, with a mode.
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        let put = try await server.client.uploadFile(lease.id, holder: "alice", data: data, to: "nested/dir/blob.bin", mode: "750")
        #expect(put.size == Int64(data.count))
        #expect(put.path.hasPrefix("/") && put.path.hasSuffix("/nested/dir/blob.bin"))
        #expect(FileManager.default.contents(atPath: "\(home)/nested/dir/blob.bin") == data)
        let permissions = try FileManager.default.attributesOfItem(atPath: "\(home)/nested/dir/blob.bin")[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o750)
        // Nothing left beside it of its upload.
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(home)/nested/dir") == ["blob.bin"])

        // A file of this computer's, streamed; then both back, ~/ being the container's home.
        let local = NSTemporaryDirectory() + "oss-upload-\(UUID().uuidString)"
        try Data("from a file\n".utf8).write(to: URL(fileURLWithPath: local))
        defer { try? FileManager.default.removeItem(atPath: local) }
        _ = try await server.client.uploadFile(lease.id, holder: "alice", file: URL(fileURLWithPath: local), to: "~/small.txt")
        #expect(try await server.client.downloadFile(lease.id, holder: "alice", path: "~/small.txt") == Data("from a file\n".utf8))
        let back = NSTemporaryDirectory() + "oss-download-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: back) }
        try await server.client.downloadFile(lease.id, holder: "alice", path: "nested/dir/blob.bin", to: URL(fileURLWithPath: back))
        #expect(FileManager.default.contents(atPath: back) == data)

        // A file that isn't there; a folder; another holder's lease.
        let missing = await #expect(throws: OSSError.self) { try await server.client.downloadFile(lease.id, holder: "alice", path: "nothing") }
        #expect(missing?.status == 404)
        #expect(missing?.code == "noFile")
        let folder = await #expect(throws: OSSError.self) { try await server.client.downloadFile(lease.id, holder: "alice", path: "nested") }
        #expect(folder?.status == 400)
        let theirs = await #expect(throws: OSSError.self) { try await server.client.downloadFile(lease.id, holder: "bob", path: "~/small.txt") }
        #expect(theirs?.status == 404)

        // Grants: an upload grant puts, a download grant reads; neither does the other's.
        let upload = try await server.client.grant(GrantRequest(verb: "machine.upload", lease: lease.id), holder: "alice")
        let download = try await server.client.grant(GrantRequest(verb: "machine.download", lease: lease.id), holder: "alice")
        #expect(try await OSSGrantClient(url: upload.url).uploadFile(Data("granted".utf8), to: "granted.txt").size == 7)
        #expect(try await OSSGrantClient(url: download.url).downloadFile("granted.txt") == Data("granted".utf8))
        let readByUpload = await #expect(throws: OSSError.self) { try await OSSGrantClient(url: upload.url).downloadFile("granted.txt") }
        #expect(readByUpload?.status == 403)
        let putByDownload = await #expect(throws: OSSError.self) {
            try await OSSGrantClient(url: download.url).uploadFile(Data("no".utf8), to: "granted.txt")
        }
        #expect(putByDownload?.status == 403)
        #expect(FileManager.default.contents(atPath: "\(home)/granted.txt") == Data("granted".utf8))
    }
}

@Test func portsComeFromTheRangeVMsUseAndGoWithTheirLease() async throws {
    // What leases hold of the range: a VM's SSH and VNC, an emulator's adb, a
    // container's ports; a failed lease nothing.
    var vm = Lease(id: "v1", platform: .linux, config: "vanilla", name: "oss-lease-linux-v1", holder: "alice", state: .ready,
                   created: Date(), expires: Date().addingTimeInterval(3600))
    vm.sshPort = 38720
    vm.vncPort = 38721
    var emulator = Lease(id: "a1", platform: .android, config: "phone", name: "oss-lease-android-a1", holder: "alice", state: .ready,
                         created: Date(), expires: Date().addingTimeInterval(3600))
    emulator.adbPort = 38722
    var container = Lease(id: "c1", platform: .container, config: "linux", name: "oss-lease-container-c1", holder: "alice",
                          state: .ready, created: Date(), expires: Date().addingTimeInterval(3600))
    container.ports = [ForwardedPort(port: 8080, hostPort: 38723)]
    var failed = container
    failed.id = "c2"
    failed.state = .failed
    failed.ports = [ForwardedPort(port: 8080, hostPort: 38724)]
    #expect(MachineManager.portsHeld(by: [vm, emulator, container, failed]) == [38720, 38721, 38722, 38723])

    // A container's ports through the manager: each its own port of the
    // range, reached at the server's host, relayed to the container's port.
    let echo = try await EchoServer.start()
    defer { echo.stop() }
    try await withContainerServer(ports: 38710...38712) { server in
        let first = try await server.lease(ports: [echo.port, 9090])
        let mapped = try #require(first.ports)
        #expect(mapped.map(\.port) == [echo.port, 9090])
        #expect(Set(mapped.map(\.hostPort)).count == 2)
        #expect(mapped.allSatisfy { (38710...38712).contains($0.hostPort) })
        let answered = try await server.client.lease(first.id)
        #expect(answered.ports?.allSatisfy { $0.host == "127.0.0.1" } == true)
        // (Its listener starts as the lease is handed over: tried again for a moment.)
        var connected: OSSSocketStream?
        for _ in 0..<100 where connected == nil {
            connected = try? await OSSSocketStream.connect(host: "127.0.0.1", port: mapped[0].hostPort)
            if connected == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let relayed = try #require(connected)
        try await relayed.write(Data("ping".utf8))
        #expect(try await relayed.read() == Data("ping".utf8))
        relayed.close()

        // A second lease gets the range's last; a third finds none free.
        let second = try await server.lease(ports: [8080])
        let last = try #require(second.ports?.first?.hostPort)
        #expect(!mapped.map(\.hostPort).contains(last))
        let third = try await server.lease(ports: [8080])
        #expect(third.state == .failed)
        #expect(third.error?.contains("no free port") == true)

        // Released, the first's ports are free again, and the next lease gets one.
        await server.machines.release(first.id, reason: "released")
        #expect(await server.machines.lease(first.id) == nil)
        let fourth = try await server.lease(ports: [8080])
        #expect(fourth.state == .ready)
        #expect(mapped.map(\.hostPort).contains(try #require(fourth.ports?.first?.hostPort)))
    }
}

@Test func aGrantsPathAloneGoesToTheFirstOfOSSServersThatAnswers() async throws {
    try await withContainerServer(ports: 38713...38714) { server in
        let lease = try await server.lease()
        let grant = try await server.client.grant(GrantRequest(verb: "machine.exec", lease: lease.id), holder: "alice")

        // `oss machine exec --url=<its path>` with OSS_SERVERS: one that
        // doesn't answer, then this server, which the path is taken to.
        let servers = ["OSS_SERVERS": "http://127.0.0.1:1, \(server.url.absoluteString)"]
        let client = try await OSSGrantClient.cli(grant.path, environment: servers)
        #expect(client.url.absoluteString == server.url.absoluteString + grant.path)
        let written = Written()
        let status = try await client.exec(ExecRequest(arguments: ["sh", "-c", "echo by its path"]), input: input(.closeStdin),
                                           output: written.take)
        #expect(status == 0)
        #expect(written.stdout == "by its path\n")

        // Its whole URL is taken as it is; its path with no server answering is refused, saying so.
        let nowhere = ["OSS_SERVERS": "http://127.0.0.1:1"]
        #expect(try await OSSGrantClient.cli(grant.url.absoluteString, environment: nowhere).url == grant.url)
        let refused = await #expect(throws: OSSError.self) { try await OSSGrantClient.cli(grant.path, environment: nowhere) }
        #expect(refused?.message.contains("no oss server answered") == true)
    }
}

@Test func aMountIsForAClientOnTheServersMacAlone() async throws {
    try await withContainerServer(ports: 38706...38707) { server in
        let mounted = LeaseRequest(platform: .container, holder: "alice",
                                   container: ContainerSpec(image: "alpine:3.20", mounts: [ContainerMount(source: "/tmp", destination: "/src")]))

        // From another computer (or a container): refused, saying why.
        let refused = await #expect(throws: APIError.self) { try await server.machines.lease(mounted, local: false) }
        #expect(refused?.code == "notLocal")
        #expect(refused?.error.contains("mount") == true)
        // Through the route, from an address that isn't this Mac's: 403.
        var request = HTTPRequest(method: "POST", path: "/v1/machines",
                                  headers: ["authorization": "Bearer server-token", "oss-api": "\(OSS.apiLevel)"],
                                  body: try JSONEncoder.oss.encode(mounted))
        request.remoteAddress = "203.0.113.9"
        #expect(await Server.route(request, api: server.api).status == 403)

        // Without the mount, from anywhere: lent, with everything else it asks for.
        var elsewhere = mounted
        elsewhere.container?.mounts = []
        elsewhere.container?.volumes = [ContainerVolume(name: "cache", destination: "/cache", sizeBytes: 1 << 30, keep: true)]
        elsewhere.container?.environment = ["A": "b"]
        elsewhere.container?.ports = [8080]
        elsewhere.container?.rosetta = true
        let remote = try await server.machines.lease(elsewhere, local: false)
        #expect(remote.container == elsewhere.container)
        // And with it, from the server's Mac.
        #expect(try await server.machines.lease(mounted, local: true).container?.mounts.count == 1)
    }
}

/// A TCP server on this computer's loopback that sends back what it's sent.
final class EchoServer: @unchecked Sendable {
    let listener: NWListener
    let port: Int

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> EchoServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "oss.test.echo")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            @Sendable func echo() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
                    if complete || error != nil { connection.cancel() } else { echo() }
                }
            }
            echo()
        }
        let port: Int = await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: Int(listener.port?.rawValue ?? 0))
                case .failed, .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: 0)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard port != 0 else { throw APIError(error: "the echo server didn't start") }
        return EchoServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}
#endif
