import Foundation
import OSSClient

// iOS tests on a lease's simulator (API 10). A Linux container builds
// rules_apple's targets (rules_applecross) but can't run them: the server
// runs them, as rules_apple's runner does on a Mac
// (apple/testing/default_runner/ios_xctestrun_runner.template.sh): the test
// bundle (and its host) unpacked into a folder of the run's own, which
// xcodebuild calls `__TESTROOT__`; for a UI test, an XCTRunner app made
// from Xcode's; the .xctestrun written from the runner's template
// (ios_xctestrun_runner.template.xctestrun); then `xcodebuild
// test-without-building` against the lease's simulator, and the result
// bundle's tests turned into JUnit (xcresulttool has no JUnit of its own).
// A run's folder is in the lease's own (`State/uploads/<lease>`), deleted
// with it.

/// What runs iOS tests on the server's Mac: Xcode's own tools. Tests fake
/// them.
protocol XCTestTools: Sendable {
    /// Xcode's developer folder (`DEVELOPER_DIR`, else `xcode-select -p`):
    /// its iPhoneSimulator platform has XCTRunner.app and the frameworks a
    /// UI test's runner carries.
    func developerDirectory() async throws -> String
    /// `xcodebuild` with these arguments, its output (standard output and
    /// error together) handed to `output` as it comes; its exit status.
    /// `output` answering false (its client has gone), or the task
    /// cancelled, ends it: SIGINT, then SIGKILL ten seconds on, for it and
    /// everything it started.
    func xcodebuild(_ arguments: [String], output: @escaping @Sendable (Data) async -> Bool) async throws -> Int32
    /// A result bundle's tests, as `xcresulttool get test-results tests`
    /// gives them (JSON).
    func testResults(_ resultBundle: String) async throws -> Data
}

/// Xcode's tools, by `xcrun` (so `DEVELOPER_DIR` and `xcode-select` pick the Xcode).
struct Xcode: XCTestTools {
    func developerDirectory() async throws -> String {
        if let directory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !directory.isEmpty { return directory }
        let selected = try await Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 60)
        let directory = selected.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected.ok, !directory.isEmpty else {
            throw APIError(error: "no Xcode on the server's Mac (xcode-select -p: \(selected.error.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        return directory
    }

    func xcodebuild(_ arguments: [String], output: @escaping @Sendable (Data) async -> Bool) async throws -> Int32 {
        try await StreamedProcess.run("/usr/bin/xcrun", ["xcodebuild"] + arguments, output: output)
    }

    func testResults(_ resultBundle: String) async throws -> Data {
        let result = try await Shell.run("/usr/bin/xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", resultBundle, "--compact"],
                                         timeout: 600)
        guard result.ok else {
            throw ShellError(description: "xcresulttool: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.data
    }
}

/// A program whose output is handed on as it comes (stdout and stderr in
/// one pipe, as a terminal shows them), stopped when its reader has gone or
/// its task is cancelled: SIGINT, then, `grace` seconds on, SIGKILL for it
/// and everything it started.
enum StreamedProcess {
    static func run(_ executable: String, _ arguments: [String], grace: TimeInterval = 10,
                    output: @escaping @Sendable (Data) async -> Bool) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(data)
            }
        }
        let ended = Ended()
        process.terminationHandler = { process in
            ended.set(process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus)
            // What its children still hold open ends the output a moment later at most.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                pipe.fileHandleForReading.readabilityHandler = nil
                feed.finish()
            }
        }
        try process.run()
        let stopper = Stopper(process, grace: grace)
        return await withTaskCancellationHandler {
            var reading = true
            for await chunk in chunks where reading {
                if !(await output(chunk)) {
                    reading = false
                    stopper.stop()
                }
            }
            return await ended.value()
        } onCancel: {
            stopper.stop()
        }
    }

    /// The exit status, once there is one.
    private final class Ended: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var waiting: [CheckedContinuation<Int32, Never>] = []

        func set(_ value: Int32) {
            let resumed: [CheckedContinuation<Int32, Never>] = lock.withLock {
                status = value
                defer { waiting = [] }
                return waiting
            }
            resumed.forEach { $0.resume(returning: value) }
        }

        func value() async -> Int32 {
            await withCheckedContinuation { continuation in
                let known: Int32? = lock.withLock {
                    if let status { return status }
                    waiting.append(continuation)
                    return nil
                }
                if let known { continuation.resume(returning: known) }
            }
        }
    }

    /// SIGINT (xcodebuild's own Ctrl-C: it stops the tests and says so),
    /// then SIGKILL `grace` seconds on, for its whole tree: xcodebuild
    /// interrupted can still wait half a minute on its log, and what it
    /// started (`simctl diagnose`, in a process group of its own) would
    /// outlive it, writing into the run's folder for minutes.
    private final class Stopper: @unchecked Sendable {
        private let process: Process
        private let grace: TimeInterval
        init(_ process: Process, grace: TimeInterval) {
            self.process = process
            self.grace = grace
        }

        func stop() {
            guard process.isRunning else { return }
            process.interrupt()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                if self.process.isRunning { ProcessTree.killAll(pid) }
            }
        }
    }
}

/// A process and everything it started, killed.
enum ProcessTree {
    /// Each process found is stopped (SIGSTOP) before its children are
    /// listed, so none starts another unseen, then all are killed; its
    /// process group too (Foundation's Process makes the program the
    /// leader of its own), for what was started there and left by its
    /// parent.
    static func killAll(_ root: pid_t) {
        var found: [pid_t] = []
        var waiting = [root]
        while let pid = waiting.popLast() {
            guard !found.contains(pid) else { continue }
            _ = kill(pid, SIGSTOP)
            found.append(pid)
            waiting += children(of: pid)
        }
        _ = killpg(root, SIGKILL)
        for pid in found { _ = kill(pid, SIGKILL) }
    }

    /// A process's children, as the kernel lists them (none known off a Mac:
    /// the server runs xcodebuild only there).
    static func children(of pid: pid_t) -> [pid_t] {
        #if canImport(Darwin)
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 && $0 != pid }
        #else
        return []
        #endif
    }
}

// MARK: The .xctestrun

/// rules_apple's .xctestrun for a run: its runner's template filled in as
/// its runner fills it for `xcodebuild` on a Mac (rules_apple 5.3.1), less
/// Bazel's own test variables (`TEST_SRCDIR` and the like, which name the
/// Mac's test tree): its test order `ordered`, attachments `keepNever`
/// (the runner's defaults), no arguments, no filter (xcodebuild's
/// `-only-testing` filters).
enum XCTestRunFile {
    static let platform = "iPhoneSimulator.platform"

    /// What a run's folder holds: the test bundle's name (`<name>.xctest`),
    /// its host's (`<name>.app`), and whether it's a UI test (its bundle in
    /// `<name>-Runner.app`).
    struct Layout: Sendable, Equatable {
        var bundle: String
        var host: String?
        var ui: Bool
    }

    /// The test target's name in the file, and before `-only-testing`'s
    /// tests: the bundle's, `-` made `_` (its module's).
    static func target(_ bundle: String) -> String { bundle.replacingOccurrences(of: "-", with: "_") }

    /// The file's property list. `folder`: the run's (its coverage data's);
    /// `testingFramework`: whether the platform has Swift Testing's
    /// framework (Xcode 16 on), whose folder a hosted test then loads from.
    static func plist(_ layout: Layout, developerDirectory: String, folder: String, testingFramework: Bool) -> [String: Any] {
        let libraries = "__PLATFORMS__/\(platform)/Developer/usr/lib"
        var bundlePath = "__TESTROOT__/\(layout.bundle).xctest"
        var hostPath = "__PLATFORMS__/\(platform)/Developer/Library/Xcode/Agents/xctest"
        var hostIdentifier = "", targetApp = ""
        var environment = [
            // A UI test's bundle is its runner's own: nothing injected.
            "DYLD_INSERT_LIBRARIES": layout.ui ? "" : "\(libraries)/libXCTestBundleInject.dylib",
            "DYLD_LIBRARY_PATH": libraries,
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/DUMMY_SRCROOT/",
        ]
        if let host = layout.host {
            hostPath = "__TESTROOT__/\(host).app"
            // (rules_apple's: the host's, a UI test's too.)
            environment["XCInjectBundleInto"] = "__TESTHOST__/\(host).app/\(host)"
            if testingFramework {
                environment["DYLD_FRAMEWORK_PATH"] = "\(developerDirectory)/Platforms/\(platform)/Developer/Library/Frameworks"
            }
            if layout.ui {
                targetApp = hostPath
                hostPath = "__TESTROOT__/\(XCTRunnerApp.name(layout.bundle)).app"
                hostIdentifier = XCTRunnerApp.bundleIdentifier(layout.bundle)
                bundlePath = "__TESTHOST__/PlugIns/\(layout.bundle).xctest"
            }
        }
        let test: [String: Any] = [
            "ProductModuleName": target(layout.bundle),
            "TestBundlePath": bundlePath,
            "TestExecutionOrdering": "ordered",
            "IsAppHostedTestBundle": layout.host != nil,
            "TestHostPath": hostPath,
            "TestHostBundleIdentifier": hostIdentifier,
            "IsUITestBundle": layout.ui && layout.host != nil,
            "IsXCTRunnerHostedTestBundle": layout.ui && layout.host != nil,
            "UITargetAppPath": targetApp,
            "DependentProductPaths": [bundlePath, targetApp, hostPath],
            "TestingEnvironmentVariables": environment,
            "SystemAttachmentLifetime": "keepNever",
            "UserAttachmentLifetime": "keepNever",
            "ClangProfileDataDirectoryPath": folder,
        ]
        let coverage: [String: Any] = [
            // arm64: a simulator on Apple silicon (rules_applecross builds sim_arm64).
            "Architecture": "arm64",
            "BuildableIdentifier": "000000000000000000000000:primary",
            "IncludeInReport": true,
            "IsStatic": false,
            "Name": "\(layout.bundle).xctest",
            "ProductPath": bundlePath,
            "Toolchains": ["com.apple.dt.toolchain.XcodeDefault"],
        ]
        return [
            target(layout.bundle): test,
            "__xctestrun_metadata__": ["CodeCoverageBuildableInfos": [coverage], "FormatVersion": 1] as [String: Any],
        ]
    }

    /// The file itself (XML).
    static func data(_ layout: Layout, developerDirectory: String, folder: String, testingFramework: Bool) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(layout, developerDirectory: developerDirectory, folder: folder,
                                                                   testingFramework: testingFramework), format: .xml, options: 0)
    }
}

// MARK: A UI test's runner

/// The app a UI test runs in, made from Xcode's XCTRunner.app as
/// rules_apple's runner makes it for a simulator (unsigned: a simulator
/// needs no signature): `<bundle>-Runner.app`, the test bundle in its
/// PlugIns, XCTest's frameworks in its Frameworks.
enum XCTRunnerApp {
    static func name(_ bundle: String) -> String { "\(bundle)-Runner" }
    static func bundleIdentifier(_ bundle: String) -> String { "com.apple.test.\(bundle)-Runner" }

    /// Made in `folder`, from `folder/<bundle>.xctest`: its path.
    @discardableResult
    static func assemble(bundle: String, in folder: String, developerDirectory: String) throws -> String {
        let manager = FileManager.default
        let developer = "\(developerDirectory)/Platforms/\(XCTestRunFile.platform)/Developer"
        let library = "\(developer)/Library"
        let agent = "\(library)/Xcode/Agents/XCTRunner.app"
        guard manager.fileExists(atPath: agent) else {
            throw APIError(error: "the server's Xcode (\(developerDirectory)) has no XCTRunner.app for a UI test")
        }
        let runner = "\(folder)/\(name(bundle)).app"
        try? Permissions.remove(runner)
        try manager.copyItem(atPath: agent, toPath: runner)
        try Permissions.makeWritable(runner)

        // The test bundle in its PlugIns, with a Frameworks folder of its own.
        let plugIns = "\(runner)/PlugIns"
        try manager.createDirectory(atPath: plugIns, withIntermediateDirectories: true)
        let plugged = "\(plugIns)/\(bundle).xctest"
        // (Writable first: a read-only folder can't move to another.)
        try Permissions.makeWritable("\(folder)/\(bundle).xctest")
        try manager.moveItem(atPath: "\(folder)/\(bundle).xctest", toPath: plugged)
        try manager.createDirectory(atPath: "\(plugged)/Frameworks", withIntermediateDirectories: true)

        // Its Info.plist named XCTRunner and identified as this bundle's runner (binary again, as it was).
        try rewriteInfo("\(runner)/Info.plist", bundleIdentifier: bundleIdentifier(bundle))

        // XCTest's frameworks and libraries, from the platform: some only in some Xcodes.
        let frameworks = "\(runner)/Frameworks"
        try manager.createDirectory(atPath: frameworks, withIntermediateDirectories: true)
        let publicAutomation = "\(library)/Frameworks/XCUIAutomation.framework"   // public from Xcode 16.3
        let copies: [(source: String, required: Bool)] = [
            ("\(library)/Frameworks/XCTest.framework", true),
            ("\(library)/PrivateFrameworks/XCTestCore.framework", true),
            ("\(library)/PrivateFrameworks/XCTAutomationSupport.framework", true),
            ("\(library)/PrivateFrameworks/XCUnit.framework", false),            // gone in Xcode 27.2
            ("\(developer)/usr/lib/libXCTestSwiftSupport.dylib", true),
            ("\(developer)/usr/lib/libXCTestBundleInject.dylib", true),
            ("\(library)/PrivateFrameworks/XCTestSupport.framework", false),     // from Xcode 14.3
            ("\(library)/Frameworks/Testing.framework", false),                  // from Xcode 16
            (manager.fileExists(atPath: publicAutomation) ? publicAutomation : "\(library)/PrivateFrameworks/XCUIAutomation.framework", true),
        ]
        for (source, required) in copies {
            guard manager.fileExists(atPath: source) else {
                if required { throw APIError(error: "the server's Xcode has no \(source) for a UI test's runner") }
                continue
            }
            try manager.copyItem(atPath: source, toPath: "\(frameworks)/\((source as NSString).lastPathComponent)")
        }
        try Permissions.makeWritable(runner)
        return runner
    }

    /// `$(WRAPPEDPRODUCTNAME)` and `WRAPPEDPRODUCTNAME` made `XCTRunner`,
    /// `$(WRAPPEDPRODUCTBUNDLEIDENTIFIER)` and `WRAPPEDPRODUCTBUNDLEIDENTIFIER`
    /// the runner's identifier, in that order (rules_apple's sed over the XML),
    /// in every value; written back binary.
    static func rewriteInfo(_ path: String, bundleIdentifier: String) throws {
        let replacements = [("$(WRAPPEDPRODUCTNAME)", "XCTRunner"), ("WRAPPEDPRODUCTNAME", "XCTRunner"),
                            ("$(WRAPPEDPRODUCTBUNDLEIDENTIFIER)", bundleIdentifier), ("WRAPPEDPRODUCTBUNDLEIDENTIFIER", bundleIdentifier)]
        func substitute(_ value: Any) -> Any {
            switch value {
            case let text as String: return replacements.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            case let array as [Any]: return array.map(substitute)
            case let dictionary as [String: Any]: return dictionary.mapValues(substitute)
            default: return value
            }
        }
        let read = try PropertyListSerialization.propertyList(from: try Data(contentsOf: URL(fileURLWithPath: path)), format: nil)
        try PropertyListSerialization.data(fromPropertyList: substitute(read), format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: path))
    }
}

/// Files' permissions as a run needs them.
enum Permissions {
    /// `path` and everything in it writable by its owner (`chmod -R u+w`):
    /// Bazel leaves its outputs read-only, xcodebuild writes into the
    /// bundles, and a run's folder must be deletable. Symbolic links are
    /// left alone (what they point at isn't the run's).
    static func makeWritable(_ path: String) throws {
        let manager = FileManager.default
        func writable(_ item: String) throws {
            let attributes = try manager.attributesOfItem(atPath: item)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue, mode & 0o200 == 0 else { return }
            try manager.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: item)
        }
        try writable(path)
        guard let walk = manager.enumerator(atPath: path) else { return }
        for case let item as String in walk { try writable("\(path)/\(item)") }
    }

    /// Deleted, whatever its permissions.
    static func remove(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? makeWritable(path)
        try FileManager.default.removeItem(atPath: path)
    }
}

// MARK: A run's folder

/// A run's folder made ready as rules_apple's runner makes its test folder:
/// the bundle (and its host) unpacked into it and writable, its binary
/// touched, a UI test's runner made, the .xctestrun written beside them.
enum XCTestFolder {
    struct Prepared: Sendable {
        var layout: XCTestRunFile.Layout
        var xctestrun: String
        var resultBundle: String
    }

    /// `tests` and `host`: the archives (zips), as the store keeps them.
    static func prepare(tests: String, host: String?, ui: Bool, in folder: String, developerDirectory: String) async throws -> Prepared {
        guard host != nil || !ui else { throw APIError(error: "a UI test needs its host: the app it drives (an .ipa or a zipped .app)") }
        let manager = FileManager.default
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let bundle = try await unpack(tests, kind: "xctest", into: folder, looking: [""],
                                      what: "the tests (rules_apple's <name>.zip holding <name>.xctest, or a .xctest folder zipped)")
        var hostName: String?
        if let host {
            hostName = try await unpack(host, kind: "app", into: folder, looking: ["Payload", ""], what: "the host (an .ipa, or a zipped .app)")
        }
        try Permissions.makeWritable(folder)
        // Its binary touched: a delta install skips a binary whose time it has seen.
        let info = NSDictionary(contentsOfFile: "\(folder)/\(bundle).xctest/Info.plist")
        let executable = info?["CFBundleExecutable"] as? String ?? bundle
        try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: "\(folder)/\(bundle).xctest/\(executable)")
        let layout = XCTestRunFile.Layout(bundle: bundle, host: hostName, ui: ui)
        if ui { try XCTRunnerApp.assemble(bundle: bundle, in: folder, developerDirectory: developerDirectory) }
        let testing = manager.fileExists(atPath: "\(developerDirectory)/Platforms/\(XCTestRunFile.platform)/Developer/Library/Frameworks/Testing.framework")
        let xctestrun = "\(folder)/tests.xctestrun"
        try XCTestRunFile.data(layout, developerDirectory: developerDirectory, folder: folder, testingFramework: testing)
            .write(to: URL(fileURLWithPath: xctestrun))
        return Prepared(layout: layout, xctestrun: xctestrun, resultBundle: "\(folder)/result.xcresult")
    }

    /// A zip unpacked beside the run's folder, and the one `.<kind>` it
    /// holds (at its top, or in one of `looking`) moved into the folder:
    /// its name.
    private static func unpack(_ archive: String, kind: String, into folder: String, looking: [String], what: String) async throws -> String {
        let handle = FileHandle(forReadingAtPath: archive)
        let magic = try? handle?.read(upToCount: 4)
        try? handle?.close()
        guard magic == Data([0x50, 0x4B, 0x03, 0x04]) else { throw APIError(error: "\(what): it isn't a zip") }
        let staging = "\(folder)/.unpack-\(Random.hex(4))"
        defer { try? Permissions.remove(staging) }
        let unzip = try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive, staging], timeout: 900)
        guard unzip.ok else { throw APIError(error: "unpacking \(what): \(unzip.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
        // Writable before it moves: a folder read-only (as Bazel leaves its outputs) can't move to another.
        try Permissions.makeWritable(staging)
        let found = looking.flatMap { inside -> [String] in
            let directory = inside.isEmpty ? staging : "\(staging)/\(inside)"
            return ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".\(kind)") }.map { "\(directory)/\($0)" }
        }
        guard found.count == 1, let bundle = found.first else {
            throw APIError(error: found.isEmpty ? "no .\(kind) in \(what)" : "more than one .\(kind) in \(what)")
        }
        let name = String(((bundle as NSString).lastPathComponent).dropLast(kind.count + 1))
        try FileManager.default.moveItem(atPath: bundle, toPath: "\(folder)/\(name).\(kind)")
        return name
    }

    /// xcodebuild's arguments for a run: rules_apple's (its derived data in
    /// the run's folder, so nothing is left in ~/Library/Developer), the
    /// lease's simulator, the result bundle in the run's folder, no test
    /// diagnostics; and each of `onlyTesting` under the test target's name,
    /// unless it starts with it.
    ///
    /// Test diagnostics are xcodebuild's `simctl diagnose` of the simulator
    /// when a test fails (and when it's interrupted), into the result
    /// bundle: it can take the whole of its ten minutes (it did on every
    /// failure in a macOS VM) and outlive xcodebuild. A failing test's own
    /// failures, logs and timings are in the result bundle without them.
    static func arguments(_ prepared: Prepared, udid: String, folder: String, onlyTesting: [String]) -> [String] {
        var arguments = ["test-without-building", "-xctestrun", prepared.xctestrun, "-destination", "id=\(udid)",
                         "-resultBundlePath", prepared.resultBundle, "-derivedDataPath", "\(folder)/derived_data",
                         "-collect-test-diagnostics", "never"]
        let target = XCTestRunFile.target(prepared.layout.bundle)
        for test in onlyTesting {
            arguments.append("-only-testing:" + (test == target || test.hasPrefix(target + "/") ? test : "\(target)/\(test)"))
        }
        return arguments
    }

    /// The result bundle zipped (`result.xcresult` inside), once, beside it: its path.
    static func zippedResult(_ folder: String) async throws -> String {
        let zip = "\(folder)/result.xcresult.zip"
        if FileManager.default.fileExists(atPath: zip) { return zip }
        guard FileManager.default.fileExists(atPath: "\(folder)/result.xcresult") else {
            throw APIError(error: "this run made no result bundle (xcodebuild ended before the tests ran)", code: "noFile")
        }
        // Made aside and moved into place whole: two reads at once each get a whole one.
        let making = "\(folder)/.result-\(Random.hex(4)).zip"
        let zipped = try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "\(folder)/result.xcresult", making], timeout: 900)
        guard zipped.ok, rename(making, zip) == 0 else {
            try? FileManager.default.removeItem(atPath: making)
            throw APIError(error: "zipping the result bundle: \(zipped.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return zip
    }
}

// MARK: JUnit

/// JUnit's XML from a result bundle's tests (`xcresulttool get test-results
/// tests`): a `<testsuite>` for each test bundle, a `<testcase>` for each
/// test, its classname the bundle and its suites (outermost first, by
/// `.`), with its failures' messages or why it was skipped.
enum JUnit {
    struct Tests: Decodable { var testNodes: [Node] }

    struct Node: Decodable {
        var nodeType: String
        var name: String
        var result: String?
        var durationInSeconds: Double?
        var children: [Node]?
    }

    struct Case: Equatable {
        var classname: String
        var name: String
        var seconds: Double
        var failures: [String]
        var skipped: String?
    }

    /// A test bundle's cases (a `<testsuite>`).
    struct Suite: Equatable {
        var name: String
        var cases: [Case]
    }

    static func xml(fromTestResults json: Data) throws -> String { xml(try suites(fromTestResults: json)) }

    /// The report's bundles and their tests.
    static func suites(fromTestResults json: Data) throws -> [Suite] {
        let tests = try JSONDecoder().decode(Tests.self, from: json)
        var suites: [Suite] = []
        // Tests outside any bundle (none that Xcode makes): a suite of their own.
        var loose: Int?
        func messages(_ node: Node, _ type: String) -> [String] {
            (node.children ?? []).flatMap { child in (child.nodeType == type ? [child.name] : []) + messages(child, type) }
        }
        func visit(_ node: Node, bundle: Int?, path: [String]) {
            switch node.nodeType {
            case "Unit test bundle", "UI test bundle":
                suites.append(Suite(name: node.name, cases: []))
                for child in node.children ?? [] { visit(child, bundle: suites.count - 1, path: [node.name]) }
            case "Test Suite":
                for child in node.children ?? [] { visit(child, bundle: bundle, path: path + [node.name]) }
            case "Test Case":
                if bundle == nil && loose == nil {
                    suites.append(Suite(name: "Tests", cases: []))
                    loose = suites.count - 1
                }
                guard let index = bundle ?? loose else { return }
                let failures = messages(node, "Failure Message")
                let failed = node.result == "Failed"
                suites[index].cases.append(Case(classname: path.isEmpty ? "Tests" : path.joined(separator: "."), name: node.name,
                                                seconds: node.durationInSeconds ?? 0,
                                                failures: failed ? (failures.isEmpty ? ["failed"] : failures) : [],
                                                skipped: node.result == "Skipped" ? (messages(node, "Skip Message").first ?? "skipped") : nil))
            default:
                // A test plan, a device, a configuration: what's under it.
                for child in node.children ?? [] { visit(child, bundle: bundle, path: path) }
            }
        }
        for node in tests.testNodes { visit(node, bundle: nil, path: []) }
        return suites
    }

    /// The suites as JUnit's XML.
    static func xml(_ suites: [Suite]) -> String {
        func seconds(_ value: Double) -> String { String(format: "%.3f", value) }
        func counts(_ cases: [Case]) -> String {
            "tests=\"\(cases.count)\" failures=\"\(cases.filter { !$0.failures.isEmpty }.count)\" "
                + "skipped=\"\(cases.filter { $0.skipped != nil }.count)\" time=\"\(seconds(cases.reduce(0) { $0 + $1.seconds }))\""
        }
        let all = suites.flatMap(\.cases)
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<testsuites \(counts(all))>"]
        for suite in suites {
            lines.append("  <testsuite name=\"\(escape(suite.name))\" \(counts(suite.cases))>")
            for test in suite.cases {
                let head = "    <testcase classname=\"\(escape(test.classname))\" name=\"\(escape(test.name))\" time=\"\(seconds(test.seconds))\""
                if let first = test.failures.first {
                    lines.append(head + ">")
                    lines.append("      <failure message=\"\(escape(first))\">\(escape(test.failures.joined(separator: "\n")))</failure>")
                    lines.append("    </testcase>")
                } else if let skipped = test.skipped {
                    lines.append(head + ">")
                    lines.append("      <skipped message=\"\(escape(skipped))\"/>")
                    lines.append("    </testcase>")
                } else {
                    lines.append(head + "/>")
                }
            }
            lines.append("  </testsuite>")
        }
        lines.append("</testsuites>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Text for an attribute or an element: XML's five escaped, and control
    /// characters XML 1.0 can't hold dropped.
    static func escape(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            case "\t", "\n", "\r": escaped.unicodeScalars.append(scalar)
            default: if scalar.value >= 0x20 { escaped.unicodeScalars.append(scalar) }
            }
        }
        return escaped
    }
}

// MARK: The runs

/// Each iOS lease's runs: one at a time a lease, each in a folder of the
/// lease's own (`<root>/<lease>/xctest-<run>`), kept until the lease ends.
actor XCTestRuns {
    nonisolated let tools: any XCTestTools
    nonisolated let root: String
    /// How long a run asked for waits for the lease's last one to be
    /// stopped (StreamedProcess's grace, and a little more) before it's
    /// refused as busy.
    nonisolated let stoppingWait: Duration

    private struct Active {
        var run: String
        var cancel: (@Sendable () -> Void)?
        /// Its client has gone: xcodebuild is being stopped, within seconds.
        var stopping = false
    }

    private var active: [String: Active] = [:]
    private var runs: [String: Set<String>] = [:]

    enum State: Sendable { case running, done, unknown }

    init(tools: any XCTestTools = Xcode(), root: String = Paths.uploads, stoppingWait: Duration = .seconds(20)) {
        self.tools = tools
        self.root = root
        self.stoppingWait = stoppingWait
    }

    nonisolated func folder(lease: String, run: String) -> String { "\(root)/\(lease)/xctest-\(run)" }

    /// A run begun on the lease: its id. Refused (409, `busy`) while
    /// another runs; one whose client has gone (Ctrl-C, then the same
    /// command again) is waited for while xcodebuild is stopped.
    func start(_ lease: String) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + stoppingWait
        while let running = active[lease] {
            guard running.stopping, clock.now < deadline else {
                throw APIError(error: "busy: lease \(lease) is running tests (run \(running.run)" + (running.stopping ? ", being stopped" : "")
                                    + "); one run at a time a lease", code: "busy")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        var run = Random.hex(4)
        while runs[lease]?.contains(run) == true { run = Random.hex(4) }
        active[lease] = Active(run: run)
        runs[lease, default: []].insert(run)
        return run
    }

    /// What ends the run should its lease end first (at once, if it has).
    func attach(_ lease: String, run: String, cancel: @escaping @Sendable () -> Void) {
        guard active[lease]?.run == run else { return cancel() }
        active[lease]?.cancel = cancel
    }

    /// The run's client has gone: it's being stopped, and the next run
    /// asked for waits for it rather than being refused.
    func stopping(_ lease: String, run: String) {
        if active[lease]?.run == run { active[lease]?.stopping = true }
    }

    /// The run ended: the lease may run another. Its files are kept, or
    /// with `discard` (it never ran) deleted.
    func finish(_ lease: String, run: String, discard: Bool = false) {
        if active[lease]?.run == run { active[lease] = nil }
        if discard {
            runs[lease]?.remove(run)
            try? Permissions.remove(folder(lease: lease, run: run))
        }
    }

    func state(_ lease: String, run: String) -> State {
        if active[lease]?.run == run { return .running }
        return runs[lease]?.contains(run) == true ? .done : .unknown
    }

    /// The lease ended: its run (if any) stopped, its runs' files deleted.
    func forget(_ lease: String) {
        active.removeValue(forKey: lease)?.cancel?()
        runs[lease] = nil
        try? Permissions.remove("\(root)/\(lease)")
    }
}
