#if canImport(Network)
import Foundation
import Testing
import OSSClient
@testable import OSSServer

// iOS tests on a lease's simulator (API 10), without Xcode running: the
// .xctestrun against rules_apple's own (XCTestFixtures.swift), the UI
// test's runner app made from a fake Xcode's, JUnit from xcresulttool's
// JSON, and the route through a real server on this computer's loopback
// whose xcodebuild is a fake and whose iOS leases are adopted (no
// simulator is made, booted or deleted).

/// A property list's contents, to compare two files whatever their layout.
func plist(_ data: Data) throws -> NSDictionary {
    try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
}

@Test(arguments: [("logic", nil, false), ("hosted", "HelloWorld", false), ("ui", "HelloWorld", true)] as [(String, String?, Bool)])
func theXCTestRunIsRulesApples(_ kind: String, _ host: String?, _ ui: Bool) throws {
    let bundle = ["logic": "HelloWorldTests", "hosted": "HelloWorldAppTests", "ui": "HelloWorldUITests"][kind]!
    let expected = ["logic": rulesAppleLogicXCTestRun, "hosted": rulesAppleHostedXCTestRun, "ui": rulesAppleUIXCTestRun][kind]!
    let written = try XCTestRunFile.data(XCTestRunFile.Layout(bundle: bundle, host: host, ui: ui),
                                         developerDirectory: "/Applications/Xcode.app/Contents/Developer", folder: "/runs/r1",
                                         testingFramework: true)
    #expect(try plist(written) == plist(Data(expected.utf8)))
}

@Test func withoutSwiftTestingAHostedTestLoadsNoFrameworksFolder() throws {
    let environment = { (testing: Bool) -> [String: String]? in
        let file = XCTestRunFile.plist(XCTestRunFile.Layout(bundle: "HelloWorldAppTests", host: "HelloWorld", ui: false),
                                       developerDirectory: "/X", folder: "/runs/r1", testingFramework: testing)
        return (file["HelloWorldAppTests"] as? [String: Any])?["TestingEnvironmentVariables"] as? [String: String]
    }
    #expect(environment(true)?["DYLD_FRAMEWORK_PATH"] == "/X/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks")
    #expect(environment(false)?["DYLD_FRAMEWORK_PATH"] == nil)
    // A bundle's name with a dash: its target's (its module's) with an underscore.
    let dashed = XCTestRunFile.plist(XCTestRunFile.Layout(bundle: "Hello-Tests", host: nil, ui: false), developerDirectory: "/X",
                                     folder: "/runs/r1", testingFramework: false)
    #expect((dashed["Hello_Tests"] as? [String: Any])?["ProductModuleName"] as? String == "Hello_Tests")
    #expect((dashed["Hello_Tests"] as? [String: Any])?["TestBundlePath"] as? String == "__TESTROOT__/Hello-Tests.xctest")
}

@Test func xcodebuildRunsTheFileOnTheLeasesSimulator() {
    let prepared = XCTestFolder.Prepared(layout: XCTestRunFile.Layout(bundle: "Hello-Tests", host: "HelloWorld", ui: false),
                                         xctestrun: "/runs/r1/tests.xctestrun", resultBundle: "/runs/r1/result.xcresult")
    let arguments = XCTestFolder.arguments(prepared, udid: "SIM-UDID", folder: "/runs/r1",
                                           onlyTesting: ["GreetingTests", "GreetingTests/testShouts()", "Hello_Tests/Formatting/rendersISO(_:)"])
    #expect(arguments == ["test-without-building", "-xctestrun", "/runs/r1/tests.xctestrun", "-destination", "id=SIM-UDID",
                          "-resultBundlePath", "/runs/r1/result.xcresult", "-derivedDataPath", "/runs/r1/derived_data",
                          "-only-testing:Hello_Tests/GreetingTests", "-only-testing:Hello_Tests/GreetingTests/testShouts()",
                          "-only-testing:Hello_Tests/Formatting/rendersISO(_:)"])
}

// MARK: A fake Xcode

/// An Xcode's iPhoneSimulator platform, as much of it as a UI test's
/// runner takes, in `root`: its developer folder. XCTRunner.app read-only
/// (as Xcode's is to its user), its Info.plist binary with Xcode's
/// placeholders. XCUIAutomation public (Xcode 16.3 on) or private; XCUnit
/// (gone in Xcode 27.2) and Swift Testing's framework where asked.
func makeFakeXcode(_ root: String, publicAutomation: Bool = true, xcunit: Bool = false, testing: Bool = true,
                   xctestCore: Bool = true) throws -> String {
    let developer = "\(root)/Xcode.app/Contents/Developer"
    let platform = "\(developer)/Platforms/iPhoneSimulator.platform/Developer"
    let manager = FileManager.default
    func file(_ path: String, _ contents: String = "") throws {
        try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }
    let agent = "\(platform)/Library/Xcode/Agents/XCTRunner.app"
    try file("\(agent)/XCTRunner", "runner")
    try file("\(agent)/PkgInfo", "APPL????")
    let info: [String: Any] = ["CFBundleExecutable": "$(WRAPPEDPRODUCTNAME)", "CFBundleName": "$(WRAPPEDPRODUCTNAME)",
                               "CFBundleIdentifier": "$(WRAPPEDPRODUCTBUNDLEIDENTIFIER)",
                               "CFBundleDisplayName": "WRAPPEDPRODUCTNAME", "XCTestTarget": ["WRAPPEDPRODUCTBUNDLEIDENTIFIER"],
                               "CFBundlePackageType": "APPL", "UIDeviceFamily": [1, 2]]
    try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: URL(fileURLWithPath: "\(agent)/Info.plist"))
    var frameworks = ["Frameworks/XCTest.framework", "PrivateFrameworks/XCTAutomationSupport.framework",
                      "PrivateFrameworks/XCTestSupport.framework",
                      publicAutomation ? "Frameworks/XCUIAutomation.framework" : "PrivateFrameworks/XCUIAutomation.framework"]
    if xctestCore { frameworks.append("PrivateFrameworks/XCTestCore.framework") }
    if xcunit { frameworks.append("PrivateFrameworks/XCUnit.framework") }
    if testing { frameworks.append("Frameworks/Testing.framework") }
    for framework in frameworks {
        let name = ((framework as NSString).lastPathComponent as NSString).deletingPathExtension
        try file("\(platform)/Library/\(framework)/\(name)", name)
        try file("\(platform)/Library/\(framework)/Info.plist")
    }
    try file("\(platform)/usr/lib/libXCTestSwiftSupport.dylib", "swift support")
    try file("\(platform)/usr/lib/libXCTestBundleInject.dylib", "inject")
    try file("\(platform)/Library/Xcode/Agents/xctest", "xctest")
    // Read-only, as Xcode's own files are to the server's user.
    for case let item as String in manager.enumerator(atPath: agent)! {
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: "\(agent)/\(item)")
    }
    try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: agent)
    return developer
}

/// A test bundle (`<name>.xctest`, its Info.plist and binary) in `folder`, read-only as Bazel leaves it.
func makeTestBundle(_ name: String, in folder: String) throws {
    let bundle = "\(folder)/\(name).xctest"
    try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": name, "CFBundlePackageType": "BNDL"], format: .xml, options: 0)
        .write(to: URL(fileURLWithPath: "\(bundle)/Info.plist"))
    try Data("tests".utf8).write(to: URL(fileURLWithPath: "\(bundle)/\(name)"))
    for item in ["Info.plist", name] { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: "\(bundle)/\(item)") }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle)
}

func isWritable(_ path: String) -> Bool {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o200 != 0
}

@Test func aUITestsRunnerIsMadeFromXcodesXCTRunner() throws {
    let root = NSTemporaryDirectory() + "oss-xctest-runner-\(UUID().uuidString)"
    defer { try? Permissions.remove(root) }
    for (publicAutomation, xcunit, testing) in [(true, false, true), (false, true, false)] {
        let developer = try makeFakeXcode("\(root)/xcode-\(publicAutomation)", publicAutomation: publicAutomation, xcunit: xcunit, testing: testing)
        let folder = "\(root)/run-\(publicAutomation)"
        try makeTestBundle("HelloWorldUITests", in: folder)
        let runner = try XCTRunnerApp.assemble(bundle: "HelloWorldUITests", in: folder, developerDirectory: developer)
        #expect(runner == "\(folder)/HelloWorldUITests-Runner.app")

        // The test bundle moved into its PlugIns, a Frameworks folder inside it.
        #expect(!FileManager.default.fileExists(atPath: "\(folder)/HelloWorldUITests.xctest"))
        #expect(FileManager.default.fileExists(atPath: "\(runner)/PlugIns/HelloWorldUITests.xctest/HelloWorldUITests"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: "\(runner)/PlugIns/HelloWorldUITests.xctest/Frameworks", isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(FileManager.default.contents(atPath: "\(runner)/XCTRunner") == Data("runner".utf8))

        // Its Info.plist: binary again, named XCTRunner, identified as the bundle's runner.
        let data = try #require(FileManager.default.contents(atPath: "\(runner)/Info.plist"))
        #expect(data.prefix(8) == Data("bplist00".utf8))
        let info = try plist(data)
        #expect(info["CFBundleExecutable"] as? String == "XCTRunner")
        #expect(info["CFBundleName"] as? String == "XCTRunner")
        #expect(info["CFBundleDisplayName"] as? String == "XCTRunner")
        #expect(info["CFBundleIdentifier"] as? String == "com.apple.test.HelloWorldUITests-Runner")
        #expect(info["XCTestTarget"] as? [String] == ["com.apple.test.HelloWorldUITests-Runner"])
        #expect(info["UIDeviceFamily"] as? [Int] == [1, 2])

        // XCTest's frameworks and libraries: each one this Xcode has.
        var expected: Set = ["XCTest.framework", "XCTestCore.framework", "XCTAutomationSupport.framework", "libXCTestSwiftSupport.dylib",
                             "libXCTestBundleInject.dylib", "XCTestSupport.framework", "XCUIAutomation.framework"]
        if xcunit { expected.insert("XCUnit.framework") }
        if testing { expected.insert("Testing.framework") }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: "\(runner)/Frameworks")) == expected)
        #expect(FileManager.default.contents(atPath: "\(runner)/Frameworks/XCUIAutomation.framework/XCUIAutomation") == Data("XCUIAutomation".utf8))

        // All of it writable (xcodebuild writes into it; the run's folder is deleted with its lease).
        #expect(isWritable(runner) && isWritable("\(runner)/Info.plist") && isWritable("\(runner)/XCTRunner"))
        #expect(isWritable("\(runner)/PlugIns/HelloWorldUITests.xctest/HelloWorldUITests"))
    }

    // An Xcode without a framework the runner needs: refused, saying which.
    let lacking = try makeFakeXcode("\(root)/lacking", xctestCore: false)
    try makeTestBundle("HelloWorldUITests", in: "\(root)/run-lacking")
    let refused = #expect(throws: APIError.self) {
        try XCTRunnerApp.assemble(bundle: "HelloWorldUITests", in: "\(root)/run-lacking", developerDirectory: lacking)
    }
    #expect(refused?.error.contains("XCTestCore.framework") == true)
}

@Test func junitComesFromTheResultBundlesTests() throws {
    #expect(try JUnit.xml(fromTestResults: Data(sampleTestResults.utf8)) == sampleJUnit)
    // No tests: an empty report, not an error.
    #expect(try JUnit.xml(fromTestResults: Data(#"{"devices": [], "testPlanConfigurations": [], "testNodes": []}"#.utf8))
            == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites tests=\"0\" failures=\"0\" skipped=\"0\" time=\"0.000\">\n</testsuites>\n")
    #expect(JUnit.escape("a\u{1}b\t<c>") == "ab\t&lt;c&gt;")
}

// MARK: The route

/// xcodebuild and xcresulttool as a test has them: a fake Xcode's folder;
/// xcodebuild writes a line, makes the result bundle and passes, holding
/// first while `holding` (until `release()`, or its cancellation).
final class FakeXcode: XCTestTools, @unchecked Sendable {
    let developer: String
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var held = false
    private var cancellations = 0

    init(developer: String) { self.developer = developer }

    var arguments: [[String]] { lock.withLock { calls } }
    var cancelled: Int { lock.withLock { cancellations } }
    func hold() { lock.withLock { held = true } }
    func release() { lock.withLock { held = false } }

    func developerDirectory() async throws -> String { developer }

    func xcodebuild(_ arguments: [String], output: @escaping @Sendable (Data) async -> Bool) async throws -> Int32 {
        lock.withLock { calls.append(arguments) }
        _ = await output(Data("Test Suite 'All tests' started\n".utf8))
        do {
            while lock.withLock({ held }) { try await Task.sleep(for: .milliseconds(20)) }
        } catch {
            lock.withLock { cancellations += 1 }
            throw error
        }
        if let index = arguments.firstIndex(of: "-resultBundlePath") {
            let bundle = arguments[index + 1]
            try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(bundle)/Info.plist"))
        }
        _ = await output(Data("** TEST EXECUTE SUCCEEDED **\n".utf8))
        return 0
    }

    func testResults(_ resultBundle: String) async throws -> Data { Data(sampleTestResults.utf8) }
}

/// A server on this computer's loopback whose iOS leases are adopted (each
/// a fake simulator's) and whose xcodebuild is a `FakeXcode`: its manager,
/// its API (the token `server-token`), a client of it.
struct XCTestServer {
    let root: String
    let xcode: FakeXcode
    let machines: MachineManager
    let api: API
    let http: HTTPServer
    let url: URL
    let client: OSSClient

    static func start() async throws -> XCTestServer {
        let root = NSTemporaryDirectory() + "oss-xctest-server-\(UUID().uuidString)"
        var config = ServerConfig()
        config.lends = [.ios]
        config.useUTM = false
        let xcode = FakeXcode(developer: try makeFakeXcode("\(root)/xcode"))
        let machines = MachineManager(config: config, leasesPath: "\(root)/leases.json",
                                      xctests: XCTestRuns(tools: xcode, root: "\(root)/uploads"))
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
        return XCTestServer(root: root, xcode: xcode, machines: machines, api: api, http: http, url: url,
                            client: OSSClient(server: url, token: "server-token"))
    }

    /// A ready lease of `holder`'s, adopted: an iOS lease's fake simulator, or another platform's.
    func lease(_ id: String, holder: String = "alice", platform: Platform = .ios) async -> Lease {
        var lease = Lease(id: id, platform: platform, config: "iphone", name: "oss-lease-\(platform.rawValue)-\(id)", holder: holder,
                          state: .ready, created: Date(), expires: Date().addingTimeInterval(3600))
        if platform == .ios { lease.udid = "00000000-0000-0000-0000-0000000000\(id.suffix(2))" }
        await machines.adopt(lease)
        return lease
    }

    /// A zip of `item` (a folder) with its folder, put in storage for `holder`: its SHA-256.
    func put(_ item: String, as name: String, holder: String = "alice") async throws -> String {
        let zip = "\(root)/zips/\(name)"
        try FileManager.default.createDirectory(atPath: "\(root)/zips", withIntermediateDirectories: true)
        let made = try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", item, zip], timeout: 60)
        try #require(made.ok)
        return try await client.putObject(file: URL(fileURLWithPath: zip), holder: holder, name: name).object.sha256
    }

    /// rules_apple's outputs, in storage: `HelloWorldUITests.zip` and `HelloWorld.ipa` (Payload/HelloWorld.app).
    func bundles(holder: String = "alice") async throws -> (tests: String, host: String) {
        let built = "\(root)/built-\(UUID().uuidString.prefix(6))"
        try makeTestBundle("HelloWorldUITests", in: built)
        let app = "\(built)/Payload/HelloWorld.app"
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        try Data("app".utf8).write(to: URL(fileURLWithPath: "\(app)/HelloWorld"))
        return (try await put("\(built)/HelloWorldUITests.xctest", as: "HelloWorldUITests.zip", holder: holder),
                try await put("\(built)/Payload", as: "HelloWorld.ipa", holder: holder))
    }

    /// Stopped and its files deleted. Its adopted leases aren't released:
    /// there is no simulator to delete.
    func stop() {
        http.stop()
        try? Permissions.remove(root)
    }
}

func withXCTestServer(_ body: (XCTestServer) async throws -> Void) async throws {
    let server = try await XCTestServer.start()
    do {
        try await body(server)
    } catch {
        server.stop()
        throw error
    }
    server.stop()
}

@Test func anXCTestRunsOnTheHoldersLeaseAndItsResultsAreKept() async throws {
    try await withXCTestServer { server in
        let lease = await server.lease("x1")
        let (tests, _) = try await server.bundles()

        // A UI test: its output streamed, its run's id, xcodebuild's status.
        let written = Written()
        let run = try await server.client.xctest(lease.id, holder: "alice", XCTestRequest(tests: tests, host: "HelloWorld.ipa", ui: true,
                                                                                         onlyTesting: ["GreetingTests/testShouts()"]),
                                                 output: written.take)
        #expect(run.status == 0)
        #expect(!run.id.isEmpty)
        #expect(written.stdout == "Test Suite 'All tests' started\n** TEST EXECUTE SUCCEEDED **\n")

        // xcodebuild ran the run's .xctestrun on the lease's simulator.
        let arguments = try #require(server.xcode.arguments.last)
        let folder = "\(server.root)/uploads/\(lease.id)/xctest-\(run.id)"
        #expect(Array(arguments.prefix(5)) == ["test-without-building", "-xctestrun", "\(folder)/tests.xctestrun", "-destination", "id=\(lease.udid!)"])
        #expect(arguments.contains("-only-testing:HelloWorldUITests/GreetingTests/testShouts()"))
        // Its folder as rules_apple's runner lays out its own: the host, the runner with the bundle in it, the file.
        #expect(FileManager.default.fileExists(atPath: "\(folder)/HelloWorld.app/HelloWorld"))
        #expect(FileManager.default.fileExists(atPath: "\(folder)/HelloWorldUITests-Runner.app/PlugIns/HelloWorldUITests.xctest/HelloWorldUITests"))
        let file = try plist(try #require(FileManager.default.contents(atPath: "\(folder)/tests.xctestrun")))
        #expect((file["HelloWorldUITests"] as? NSDictionary)?["UITargetAppPath"] as? String == "__TESTROOT__/HelloWorld.app")
        #expect(isWritable("\(folder)/HelloWorld.app"))

        // Its JUnit and its result bundle, read back.
        #expect(String(decoding: try await server.client.xctestJUnit(lease.id, holder: "alice", run: run.id), as: UTF8.self) == sampleJUnit)
        let zip = "\(server.root)/result.xcresult.zip"
        try await server.client.downloadXCTestResult(lease.id, holder: "alice", run: run.id, to: URL(fileURLWithPath: zip))
        #expect(FileManager.default.contents(atPath: zip)?.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        let unknown = await #expect(throws: OSSError.self) { try await server.client.xctestJUnit(lease.id, holder: "alice", run: "nope") }
        #expect(unknown?.status == 404)

        // A logic test (no host), by the object's name: no runner, the platform's xctest its host.
        let logic = try await server.client.xctest(lease.id, holder: "alice", XCTestRequest(tests: "HelloWorldUITests.zip"), output: { _ in })
        #expect(logic.status == 0)
        let logicFolder = "\(server.root)/uploads/\(lease.id)/xctest-\(logic.id)"
        #expect(FileManager.default.fileExists(atPath: "\(logicFolder)/HelloWorldUITests.xctest"))
        #expect(!FileManager.default.fileExists(atPath: "\(logicFolder)/HelloWorldUITests-Runner.app"))

        // A UI test without its host; an object the holder hasn't got; not a zip: refused before anything runs.
        let calls = server.xcode.arguments.count
        let noHost = await #expect(throws: OSSError.self) {
            try await server.client.xctest(lease.id, holder: "alice", XCTestRequest(tests: tests, ui: true), output: { _ in })
        }
        #expect(noHost?.status == 400)
        let notHeld = await #expect(throws: OSSError.self) {
            try await server.client.xctest(lease.id, holder: "alice", XCTestRequest(tests: String(repeating: "0", count: 64)), output: { _ in })
        }
        #expect(notHeld?.status == 404)
        let text = try await server.client.putObject(Data("not a zip".utf8), holder: "alice", name: "notes.txt").object.sha256
        let notZip = await #expect(throws: OSSError.self) {
            try await server.client.xctest(lease.id, holder: "alice", XCTestRequest(tests: text), output: { _ in })
        }
        #expect(notZip?.status == 400)
        #expect(server.xcode.arguments.count == calls)

        // Released, the lease's runs go with it.
        await server.machines.xctests.forget(lease.id)
        #expect(!FileManager.default.fileExists(atPath: "\(server.root)/uploads/\(lease.id)"))
        #expect(await server.machines.xctests.state(lease.id, run: run.id) == .unknown)
    }
}

@Test func anXCTestIsTheLeasesHoldersAndAGrantsForItsLeaseAlone() async throws {
    try await withXCTestServer { server in
        let lease = await server.lease("x1")
        let other = await server.lease("x2")
        let container = await server.lease("c1", platform: .container)
        let (tests, _) = try await server.bundles()
        let request = XCTestRequest(tests: tests)

        // With the token, in another holder's name: not found; in none: refused.
        let bob = await #expect(throws: OSSError.self) { try await server.client.xctest(lease.id, holder: "bob", request, output: { _ in }) }
        #expect(bob?.status == 404)
        let nobody = await #expect(throws: OSSError.self) { try await server.client.xctest(lease.id, holder: "", request, output: { _ in }) }
        #expect(nobody?.status == 400)
        // A lease that isn't an iOS lease's: refused, saying so.
        let notIOS = await #expect(throws: OSSError.self) { try await server.client.xctest(container.id, holder: "alice", request, output: { _ in }) }
        #expect(notIOS?.status == 400)
        #expect(notIOS?.message.contains("iOS lease") == true)

        // A machine.xctest grant: no token, its own lease, its tests run and their results read.
        let grant = try await server.client.grant(GrantRequest(verb: "machine.xctest", lease: lease.id), holder: "alice")
        #expect(grant.path.hasPrefix("/v1/machines/\(lease.id)/xctest?grant="))
        let granted = OSSGrantClient(url: grant.url)
        let run = try await granted.xctest(request, output: { _ in })
        #expect(run.status == 0)
        #expect(String(decoding: try await granted.xctestJUnit(run: run.id), as: UTF8.self) == sampleJUnit)

        // The same grant on another lease's route, or another lease's results: refused.
        let elsewhere = URL(string: server.url.absoluteString + "/v1/machines/\(other.id)/xctest?grant=\(grantParameter(grant))")!
        let refused = await #expect(throws: OSSError.self) { try await OSSGrantClient(url: elsewhere).xctest(request, output: { _ in }) }
        #expect(refused?.status == 403)
        let theirResults = await #expect(throws: OSSError.self) { try await OSSGrantClient(url: elsewhere).xctestJUnit(run: run.id) }
        #expect(theirResults?.status == 403)

        // Another verb's grant for the same lease (an install's) on the xctest route: refused.
        let install = try await server.client.grant(GrantRequest(verb: "machine.install", lease: lease.id), holder: "alice")
        let wrongVerb = URL(string: server.url.absoluteString + "/v1/machines/\(lease.id)/xctest?grant=\(grantParameter(install))")!
        let refusedVerb = await #expect(throws: OSSError.self) { try await OSSGrantClient(url: wrongVerb).xctest(request, output: { _ in }) }
        #expect(refusedVerb?.status == 403)

        // No grant for another holder's lease, nor for a lease that isn't an iOS lease's.
        await #expect(throws: OSSError.self) {
            try await server.client.grant(GrantRequest(verb: "machine.xctest", lease: lease.id), holder: "bob")
        }
        await #expect(throws: OSSError.self) {
            try await server.client.grant(GrantRequest(verb: "machine.xctest", lease: container.id), holder: "alice")
        }
    }
}

@Test func aLeaseRunsOneXCTestAtATime() async throws {
    try await withXCTestServer { server in
        let lease = await server.lease("x1")
        let other = await server.lease("x2")
        let (tests, _) = try await server.bundles()
        let request = XCTestRequest(tests: tests)

        // The first holds in xcodebuild.
        server.xcode.hold()
        let first = Task { try await server.client.xctest(lease.id, holder: "alice", request, output: { _ in }) }
        for _ in 0..<500 where server.xcode.arguments.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.xcode.arguments.count == 1)

        // A second on the same lease meanwhile: 409, busy.
        let second = await #expect(throws: OSSError.self) { try await server.client.xctest(lease.id, holder: "alice", request, output: { _ in }) }
        #expect(second?.status == 409)
        #expect(second?.code == "busy")
        // The first's results while it runs: not yet.
        let running = try #require(server.xcode.arguments.first?.first { $0.hasSuffix("/tests.xctestrun") })
        let runID = String(((running as NSString).deletingLastPathComponent as NSString).lastPathComponent.dropFirst("xctest-".count))
        let early = await #expect(throws: OSSError.self) { try await server.client.xctestJUnit(lease.id, holder: "alice", run: runID) }
        #expect(early?.status == 409)

        // Another lease isn't held up by it: its run starts while the first still runs.
        let elsewhere = Task { try await server.client.xctest(other.id, holder: "alice", request, output: { _ in }) }
        for _ in 0..<500 where server.xcode.arguments.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.xcode.arguments.count == 2)
        server.xcode.release()
        #expect(try await elsewhere.value.status == 0)
        #expect(try await first.value.status == 0)
        #expect(try await first.value.id == runID)

        // Once it has ended, the lease runs the next.
        #expect(try await server.client.xctest(lease.id, holder: "alice", request, output: { _ in }).status == 0)
    }
}

@Test func aClientThatGoesEndsItsRun() async throws {
    try await withXCTestServer { server in
        let lease = await server.lease("x1")
        let (tests, _) = try await server.bundles()
        let request = XCTestRequest(tests: tests)

        server.xcode.hold()
        let gone = Task { try await server.client.xctest(lease.id, holder: "alice", request, output: { _ in }) }
        for _ in 0..<500 where server.xcode.arguments.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        // The client's task ended: its connection closes, and the server stops xcodebuild.
        gone.cancel()
        await #expect(throws: (any Error).self) { try await gone.value }
        for _ in 0..<500 where server.xcode.cancelled == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.xcode.cancelled == 1)

        // The lease is free for the next run (once the server has seen the first end).
        server.xcode.release()
        var next: XCTestRun?
        for _ in 0..<250 where next == nil {
            do {
                next = try await server.client.xctest(lease.id, holder: "alice", request, output: { _ in })
            } catch let error as OSSError where error.code == "busy" {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(next?.status == 0)
    }
}
#endif
