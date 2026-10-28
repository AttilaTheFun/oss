import Foundation
import OSSClient

#if canImport(Network)

/// iOS tests on a lease's simulator, through the API (API 10). With the
/// API's token, for the holder the request names (`OSS-Holder`), whose
/// lease it must be; or with a `machine.xctest` grant's URL for the lease,
/// which runs its tests and reads their results.
///
/// - `POST /v1/machines/<id>/xctest`, `Connection: Upgrade`, `Upgrade:
///   oss-exec`, the body an `XCTestRequest` (JSON, with its length): the
///   bundles taken from the holder's objects, unpacked and made ready
///   (a refusal is an answer as any other), then `101 Switching Protocols`
///   with the run's id (`OSS-XCTest-Run`), then frames as an exec's:
///   `stdout`, xcodebuild's output as it comes; `stderr`, the server's own
///   notes; last `exit`, xcodebuild's status. The connection closing first
///   ends the run (xcodebuild killed). One run at a time a lease (409
///   `busy`).
/// - `GET /v1/machines/<id>/xctest/<run>/junit`: its JUnit (XML), from its
///   result bundle; `…/result`: the result bundle, zipped, streamed. 409
///   `notReady` while it runs; kept as long as the lease.
enum XCTestAPI {
    /// The routes whose connection is handed over once their head has come.
    static func streams(_ method: String, _ parts: [String]) -> Bool {
        guard parts.count >= 4, parts[0] == "v1", parts[1] == "machines", parts[3] == "xctest" else { return false }
        return (method == "POST" && parts.count == 4) || (method == "GET" && parts.count == 6 && ["junit", "result"].contains(parts[5]))
    }

    static func serve(_ request: HTTPRequest, _ peer: CachePeer, api: API) async {
        let parts = (request.path.split(separator: "?").first ?? "").split(separator: "/").map(String.init)
        let access = Server.access(request, parts, api: api)
        if case .refused(let response) = access {
            _ = await peer.send(response)
            return
        }
        do {
            let lease = try await self.lease(parts[2], access: access, request: request, api: api)
            if request.method == "POST" {
                try await run(request, peer, lease: lease, api: api)
            } else {
                try await results(run: parts[4], parts[5], peer, lease: lease, api: api)
            }
        } catch let error as APIError {
            _ = await peer.send(Server.response(for: error))
        } catch {
            _ = await peer.send(.error("\(error)", status: 500))
        }
    }

    /// The iOS lease a request may use: its holder's, its simulator booted.
    static func lease(_ id: String, access: Access, request: HTTPRequest, api: API) async throws -> Lease {
        let lease = try await Server.holdersLease(id, access: access, request: request, api: api, what: "an xctest and its results are")
        guard lease.platform == .ios else {
            throw APIError(error: "xctest is for an iOS lease (a simulator): build the tests for the iOS simulator and lease ios")
        }
        guard lease.state == .ready, lease.udid != nil else { throw APIError(error: "lease \(id) isn't ready yet", code: "notReady") }
        return lease
    }

    // MARK: A run

    static func run(_ request: HTTPRequest, _ peer: CachePeer, lease: Lease, api: API) async throws {
        guard request.header("upgrade")?.lowercased() == OSSExecProtocol.name else {
            throw APIError(error: "an xctest's connection is upgraded: Connection: Upgrade, Upgrade: \(OSSExecProtocol.name)", code: "upgrade")
        }
        guard let length = Int(request.header("content-length") ?? ""), length > 0, length <= 1 << 20 else {
            throw APIError(error: "an xctest's body is its XCTestRequest (JSON), with its length", code: "length")
        }
        var body = Data()
        guard try await peer.body(Int64(length), { body.append($0) }) else { return }   // the client went away
        guard let asked = try? JSONDecoder().decode(XCTestRequest.self, from: body), !asked.tests.isEmpty else {
            throw APIError(error: "an xctest's body is an XCTestRequest: {\"tests\": <sha256 | name>, \"host\"?, \"ui\"?, \"onlyTesting\"?: [...]}")
        }
        guard !asked.ui || asked.host?.isEmpty == false else {
            throw APIError(error: "a UI test needs its host: the app it drives (an .ipa or a zipped .app)")
        }
        let only = asked.onlyTesting ?? []
        guard only.count <= 1000, only.allSatisfy({ !$0.isEmpty && $0.count <= 1024 && !$0.hasPrefix("-") && !$0.contains(where: \.isNewline) }) else {
            throw APIError(error: "onlyTesting: at most 1000 tests, each Class, Class/method or <bundle>/Class/method")
        }
        let runs = api.machines.xctests
        let run = try await runs.start(lease.id)
        // Its lease ended while the last run was being stopped: its runs went with it.
        guard let current = await api.machines.lease(lease.id), current.state == .ready else {
            await runs.finish(lease.id, run: run, discard: true)
            throw APIError(error: "lease \(lease.id) has ended", code: "notFound")
        }
        let folder = runs.folder(lease: lease.id, run: run)
        let prepared: XCTestFolder.Prepared
        do {
            prepared = try await prepare(asked, lease: lease, folder: folder, api: api)
            // Its lease ended meanwhile: its folder went with it.
            guard await runs.state(lease.id, run: run) == .running else { throw APIError(error: "lease \(lease.id) has ended", code: "notFound") }
        } catch {
            await runs.finish(lease.id, run: run, discard: true)
            throw error
        }
        let upgraded = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: \(OSSExecProtocol.name)\r\n"
            + "\(OSSHeaders.xctestRun): \(run)\r\n\r\n"
        guard await peer.send(Data(upgraded.utf8)) else {
            await runs.finish(lease.id, run: run, discard: true)
            return
        }
        let layout = prepared.layout
        log("lease \(lease.id): xctest run \(run): \(layout.bundle)" + (layout.host.map { " on \($0)" } ?? "") + (layout.ui ? " (UI)" : ""))

        // xcodebuild, its output to the client as it comes (each piece sent
        // before the next is read); the client going ends it, and the
        // lease's next run waits while it's stopped.
        let tools = runs.tools
        let arguments = XCTestFolder.arguments(prepared, udid: lease.udid ?? "", folder: folder, onlyTesting: only)
        let work = Task {
            try await tools.xcodebuild(arguments) { data in
                let sent = await peer.send(ExecFrame.stdout(data).encoded)
                if !sent { await runs.stopping(lease.id, run: run) }
                return sent
            }
        }
        await runs.attach(lease.id, run: run) { work.cancel() }
        // Nothing comes from the client once it is upgraded: its connection closing is its going.
        let watcher = Task {
            while await peer.next() != nil {}
            await runs.stopping(lease.id, run: run)
            work.cancel()
        }
        var status: Int32
        var note: String?
        do {
            status = try await work.value
        } catch {
            status = 127
            note = "oss: xcodebuild: \(error)\n"
        }
        if work.isCancelled {
            log("lease \(lease.id): xctest run \(run) stopped (its client went, or its lease ended)")
            await runs.finish(lease.id, run: run)
            watcher.cancel()
            peer.close()
            return
        }
        if let note { _ = await peer.send(ExecFrame.stderr(Data(note.utf8)).encoded) }
        // Its JUnit, from the result bundle, before the client hears it ended (and asks for it).
        if FileManager.default.fileExists(atPath: prepared.resultBundle) {
            do {
                let suites = try JUnit.suites(fromTestResults: try await tools.testResults(prepared.resultBundle))
                try Data(JUnit.xml(suites).utf8).write(to: URL(fileURLWithPath: "\(folder)/junit.xml"))
                // Passed with no test run (an --only-testing that names none, or an empty bundle): failed, as
                // rules_apple's runner fails it (xcodebuild's status is 0).
                if status == 0 && suites.allSatisfy({ $0.cases.isEmpty }) {
                    status = 1
                    let none = "oss: no tests were executed in run \(run): is the bundle empty, or does --only-testing name none of its tests?\n"
                    _ = await peer.send(ExecFrame.stderr(Data(none.utf8)).encoded)
                }
            } catch {
                _ = await peer.send(ExecFrame.stderr(Data("oss: no JUnit from run \(run)'s result bundle: \(error)\n".utf8)).encoded)
            }
        }
        await runs.finish(lease.id, run: run)
        log("lease \(lease.id): xctest run \(run) ended (\(status))")
        _ = await peer.send(ExecFrame.exit(status).encoded)
        watcher.cancel()
        peer.close()
    }

    /// The run's folder made ready from the holder's objects, each kept
    /// from the sweep while it's unpacked.
    private static func prepare(_ asked: XCTestRequest, lease: Lease, folder: String, api: API) async throws -> XCTestFolder.Prepared {
        var opened: [String] = []
        do {
            var paths: [String] = []
            for object in [asked.tests] + (asked.host.map { [$0] } ?? []) {
                let hash = try await api.storage.resolve(object, holder: lease.holder)
                guard let (path, _) = await api.storage.open(hash) else {
                    throw APIError(error: "no object \(object) of \(lease.holder)'s", code: "notFound")
                }
                opened.append(hash)
                paths.append(path)
            }
            let developer = try await api.machines.xctests.tools.developerDirectory()
            let prepared = try await XCTestFolder.prepare(tests: paths[0], host: paths.count > 1 ? paths[1] : nil, ui: asked.ui, in: folder,
                                                          developerDirectory: developer)
            for hash in opened { await api.storage.close(hash) }
            return prepared
        } catch {
            for hash in opened { await api.storage.close(hash) }
            throw error
        }
    }

    // MARK: Its results

    /// `GET …/xctest/<run>/junit` or `/result`.
    static func results(run: String, _ what: String, _ peer: CachePeer, lease: Lease, api: API) async throws {
        let runs = api.machines.xctests
        switch await runs.state(lease.id, run: run) {
        case .unknown: throw APIError(error: "no run \(run) of lease \(lease.id)", code: "notFound")
        case .running: throw APIError(error: "run \(run) is still running", code: "notReady")
        case .done: break
        }
        let folder = runs.folder(lease: lease.id, run: run)
        if what == "junit" {
            guard let xml = FileManager.default.contents(atPath: "\(folder)/junit.xml") else {
                throw APIError(error: "run \(run) has no JUnit: xcodebuild made no result bundle, or it couldn't be read", code: "noFile")
            }
            _ = await peer.send(HTTPResponse(status: 200, body: xml, contentType: "application/xml"))
            return
        }
        let zip = try await XCTestFolder.zippedResult(folder)
        guard let file = FileHandle(forReadingAtPath: zip),
              let size = (try? FileManager.default.attributesOfItem(atPath: zip)[.size] as? NSNumber)?.int64Value else {
            throw APIError(error: "run \(run)'s result bundle can't be read")
        }
        defer { try? file.close() }
        let head = HTTPResponse(status: 200, body: Data(), contentType: "application/zip", length: size)
        guard await peer.send(head.head(headOnly: true)) else { return }
        while let chunk = try? file.read(upToCount: 1 << 20), !chunk.isEmpty {
            guard await peer.send(chunk) else { break }
        }
    }
}

#endif
