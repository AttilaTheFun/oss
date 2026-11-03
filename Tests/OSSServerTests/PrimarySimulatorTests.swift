import Foundation
import Testing
import OSSClient
@testable import OSSServer

// iOS leases whose simulators run in the primary macOS VM (docs/primary-vms.md,
// "iOS: simulators in the primary"): server.json's setting, the room it
// makes, which leases live in a primary, the device a lease gets there, and
// the command lines sent to the primary. Nothing here reaches a primary.

@Test func simulatorsInThePrimaryAreOffUnlessServerJSONAsks() throws {
    let defaults = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"primary": {"macos": {}}}"#.utf8))
    #expect(defaults.primary?.macos?.simulators == 0)
    #expect(defaults.primary?.macos?.simulatorDevice == "iPhone 17 Pro")
    #expect(defaults.primary?.macos?.size == LeaseSize(cpus: 8, memoryBytes: 24 << 30))
    #expect(defaults.primary?.macos?.label == "Primary macOS VM: 4 slots")
    #expect(!PrimaryPlan.simulatorsInPrimary(defaults.primary?.macos, lendsMacOS: true))

    let on = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"primary": {"macos": {"simulators": 4, "simulatorDevice": "iPhone 18 Pro"}}}"#.utf8))
    let settings = try #require(on.primary?.macos)
    #expect(settings.simulators == 4 && settings.simulatorDevice == "iPhone 18 Pro")
    // Its memory grows by 2 GB a simulator: 24 + 4 × 2.
    #expect(settings.vmGigabytes == 32)
    #expect(settings.size == LeaseSize(cpus: 8, memoryBytes: 32 << 30))
    #expect(settings.label == "Primary macOS VM: 4 slots, 4 simulators")
    #expect(PrimaryPlan.simulatorsInPrimary(settings, lendsMacOS: true))
    // A server that lends no macOS keeps no primary: its simulators stay its Mac's.
    #expect(!PrimaryPlan.simulatorsInPrimary(settings, lendsMacOS: false))
    #expect(!PrimaryPlan.simulatorsInPrimary(nil, lendsMacOS: true))
    // Less than none is none.
    let negative = try JSONDecoder().decode(PrimaryMacSettings.self, from: Data(#"{"simulators": -2}"#.utf8))
    #expect(negative.simulators == 0)
}

/// In the primary, `ios` leases are as many as it runs (the type's cap),
/// taking nothing of the budget (the primary's memory holds them); off, the
/// budget's 2 GB estimate and no cap, as before.
@Test func simulatorsInThePrimaryAreItsCapAndTakeNoMemory() throws {
    let gb: Int64 = 1 << 30
    func policy(_ json: String) throws -> LeasePolicy {
        try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8)).leasePolicy(memoryBytes: 128 << 30, cores: 16)
    }
    let off = try policy(#"{"budget": {"memoryGB": 96}, "primary": {"macos": {}}}"#)
    #expect(off.caps[.ios] == nil)
    #expect(off.estimate(.ios) == LeaseSize(cpus: 0, memoryBytes: 2 * gb))

    let on = try policy(#"{"budget": {"memoryGB": 96}, "primary": {"macos": {"simulators": 3}}}"#)
    #expect(on.caps[.ios] == 3)
    #expect(on.estimate(.ios) == .zero)
    let simulator = LeaseDemand(platform: .ios, size: on.estimate(.ios))
    // A budget all but full: a simulator still fits; three held, the fourth waits.
    let full = [LeaseDemand(platform: .macos, size: LeaseSize(cpus: 8, memoryBytes: 30 * gb)),
                LeaseDemand(platform: .macos, size: LeaseSize(cpus: 6, memoryBytes: 16 * gb))]
    #expect(on.refusal(simulator, held: full, outside: 50 * gb) == nil)
    #expect(on.refusal(simulator, held: full + [simulator, simulator, simulator]) != nil)
    #expect(on.capacity(.ios, held: full + [simulator], typical: simulator.size).limit == 3)
    // server.json's own cap for ios, if lower, stays.
    #expect(try policy(#"{"limits": {"ios": 2}, "primary": {"macos": {"simulators": 4}}}"#).caps[.ios] == 2)
    #expect(try policy(#"{"limits": {"ios": 9}, "primary": {"macos": {"simulators": 4}}}"#).caps[.ios] == 4)
    // A server that lends no macOS: its Mac's simulators, as before.
    let noMac = try policy(#"{"lends": ["ios"], "primary": {"macos": {"simulators": 4}}}"#)
    #expect(noMac.caps[.ios] == nil && noMac.estimate(.ios).memoryBytes == 2 * gb)
}

private func lease(_ id: String, _ platform: Platform, primary: String? = nil, state: LeaseState = .ready, kind: LeaseKind? = nil) -> Lease {
    var lease = Lease(id: id, platform: platform, config: platform == .ios ? "iphone" : "xcode_27_2",
                      name: platform == .ios ? "oss-lease-ios-\(id)" : id, holder: kind == .primary ? PrimaryPlan.holder : "h",
                      state: state, created: Date(), expires: .distantFuture)
    lease.primary = primary
    lease.kind = kind
    if kind == .primary { lease.size = PrimaryMacSettings().size }
    return lease
}

/// A simulator in a primary lives there as a slot does: released with it
/// (orphaned when it's gone, after a restart too), and holding off its
/// replacement; one on the server's Mac is no primary's.
@Test func aPrimarysSimulatorsAreItsTenants() {
    let primary = lease("p1", .macos, kind: .primary)
    let inside = lease("s1", .ios, primary: "p1")
    let onTheMac = lease("s2", .ios)
    let slot = lease("m1", .mac, primary: "p1")
    let held = [primary, inside, onTheMac, slot]
    #expect(Set(PrimaryPlan.tenants(of: "p1", held).map(\.id)) == ["s1", "m1"])
    #expect(PrimaryPlan.slots(of: "p1", held).map(\.id) == ["m1"])
    #expect(PrimaryPlan.orphans(held).isEmpty)
    // Its primary gone (or going): its simulator and slot go too; the Mac's simulator stays.
    #expect(Set(PrimaryPlan.orphans([inside, onTheMac, slot]).map(\.id)) == ["s1", "m1"])
    #expect(Set(PrimaryPlan.orphans([lease("p1", .macos, state: .returning, kind: .primary), inside, onTheMac]).map(\.id)) == ["s1"])
    // One already going isn't released again.
    #expect(PrimaryPlan.orphans([lease("s3", .ios, primary: "p9", state: .returning)]).isEmpty)

    // New settings (more simulators: a bigger VM) replace it only once its simulator is released.
    let more = PrimaryMacSettings(simulators: 2)
    #expect(PrimaryPlan.outdated(primary, more)?.contains("28 GB") == true)
    #expect(PrimaryPlan.step(more, lendsMacOS: true, restartPending: false, held: [primary, inside]) == .check("p1"))
    guard case .release("p1", _) = PrimaryPlan.step(more, lendsMacOS: true, restartPending: false, held: [primary, onTheMac]) else {
        Issue.record("a primary of another size, with no simulator of its, is replaced"); return
    }
    #expect(PrimaryPlan.outdated(primary, PrimaryMacSettings()) == nil)
    // Not wanted any more: kept while its simulator is held.
    #expect(PrimaryPlan.step(nil, lendsMacOS: true, restartPending: false, held: [primary, inside]) == .none)
    // A second primary with a simulator in it is kept; one with nothing is released.
    var second = lease("p2", .macos, kind: .primary)
    second.created = primary.created.addingTimeInterval(60)
    // (The one with a tenant is kept even though newer: the empty one is the extra.)
    #expect(PrimaryPlan.extras([primary, second, lease("s4", .ios, primary: "p2")]).map(\.id) == ["p1"])
    #expect(PrimaryPlan.extras([primary, second]).map(\.id) == ["p2"])
}

/// The device a lease in the primary gets: what it asks for, else
/// server.json's simulatorDevice on the newest runtime that runs it, else
/// that runtime's first iPhone.
@Test func aSimulatorInThePrimaryIsTheDeviceAskedForElseTheServersOwn() throws {
    let lists = try SimctlLists()
    func choose(_ device: String?, _ runtime: String?, preferred: String = "iPhone 17 Pro") throws -> Simulators.Choice {
        try PrimarySimulators.choose(device: device, runtime: runtime, preferred: preferred, types: lists.types, runtimes: lists.runtimes)
    }
    // Neither asked for: the server's device on the newest runtime that runs it (27.0, not 18.6).
    let plain = try choose(nil, nil)
    #expect(plain.deviceType.name == "iPhone 17 Pro" && plain.runtime.name == "iOS 27.0")
    // Only on an older runtime: that one.
    #expect(try choose(nil, nil, preferred: "iPhone Xs").runtime.name == "iOS 18.6")
    // Not this Xcode's: the newest runtime's first iPhone.
    let unknown = try choose(nil, nil, preferred: "iPhone 3G")
    #expect(unknown.deviceType.name == "iPhone 18 Pro" && unknown.runtime.name == "iOS 27.0")
    // Asked for, as on the server's Mac.
    #expect(try choose("iPad Pro 13-inch (M5)", nil).deviceType.identifier == "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB")
    #expect(try choose(nil, "iOS 18.6").runtime.name == "iOS 18.6")
    #expect(throws: APIError.self) { try choose("iPhone 18 Pro", "18.6") }
    #expect(throws: APIError.self) { try choose("Apple Watch Series 11 (46mm)", nil) }
}

/// The command lines a simulator in the primary is driven by: each word
/// single-quoted, as the guest user's shell reads them.
@Test func aSimulatorInThePrimaryIsDrivenBySimctlOverSSH() throws {
    #expect(SimulatorHost.remoteLine("/usr/bin/xcrun", ["simctl", "launch", "UDID-1", "com.example.App", "--arg=it's"])
                == #"'/usr/bin/xcrun' 'simctl' 'launch' 'UDID-1' 'com.example.App' '--arg=it'\''s'"#)
    #expect(!SimulatorHost.local.isPrimary)
    // The status bar held still as on the Mac: 9:41, full bars, a full battery, no carrier.
    let still = Simulators.statusBarOverride(udid: "U", time: "9:41")
    #expect(still.prefix(5) == ["status_bar", "U", "override", "--time", "9:41"])
    #expect(still.contains("--operatorName") && still[still.firstIndex(of: "--operatorName")! + 1] == "")
    #expect(still.suffix(4) == ["--batteryState", "charged", "--batteryLevel", "100"])
    // A screenshot there: masked, written to the primary's /tmp, its bytes on standard output, the file deleted.
    #expect(Simulators.screenshotScript.contains(#"simctl io "$1" screenshot --mask=black "$2" 1>&2 && cat "$2""#))
    #expect(Simulators.screenshotScript.contains(#"rm -f "$2""#))
    // The scale from the device type's capabilities where its profile has none (Xcode 27's).
    #expect(Simulators.scaleScript.contains("capabilities.ScreenDimensionsCapability.main-screen-scale"))

    // A lease's folder there; its simulator and folder deleted at release (or with no UDID yet, its folder).
    #expect(PrimarySimulators.folder("ab12") == "/Users/Shared/oss-ios/ab12")
    #expect(PrimarySimulators.deleteLine(lease: "ab12", udid: "U-1")
                == "/usr/bin/xcrun simctl shutdown 'U-1' >/dev/null 2>&1; /usr/bin/xcrun simctl delete 'U-1' >/dev/null 2>&1; "
                    + "rm -rf '/Users/Shared/oss-ios/ab12'; exit 0")
    #expect(PrimarySimulators.deleteLine(lease: "ab12", udid: nil) == "rm -rf '/Users/Shared/oss-ios/ab12'; exit 0")
    #expect(PrimarySimulators.untarLine(into: "/Users/Shared/oss-ios/ab12/files")
                == "mkdir -p '/Users/Shared/oss-ios/ab12/files' && tar -xzf - -C '/Users/Shared/oss-ios/ab12/files'")
}

/// `@name` arguments (the holder's uploads) become the lease's files on the
/// primary, copied there first; nothing else of the server's Mac goes.
@Test func aCommandsFilesGoToTheLeasesFolderOnThePrimary() throws {
    let (arguments, files) = try PrimarySimulators.remoteArguments(["install", "@My.app", "@My.app", "booted"], lease: "ab12")
    #expect(arguments == ["install", "/Users/Shared/oss-ios/ab12/files/My.app", "/Users/Shared/oss-ios/ab12/files/My.app", "booted"])
    #expect(files == ["My.app"])
    // Then the holder's arguments, against its own simulator.
    #expect(try Simulators.holderArguments(arguments, udid: "U-1") == ["install", "/Users/Shared/oss-ios/ab12/files/My.app",
                                                                          "/Users/Shared/oss-ios/ab12/files/My.app", "U-1"])
    #expect(throws: APIError.self) { try PrimarySimulators.remoteArguments(["install", "@../../token"], lease: "ab12") }
    #expect(throws: APIError.self) { try PrimarySimulators.remoteArguments(["addmedia", "@/etc/hosts"], lease: "ab12") }
    #expect(throws: APIError.self) { try Simulators.holderArguments(["erase"], udid: "U-1") }
}

/// What a sweep of the primary deletes: simulators named as a lease's that
/// no lease holds (nobody else's, and not the primary's own Xcode's).
@Test func aPrimarysStraySimulatorsAreThoseNoLeaseHolds() {
    func device(_ name: String, _ udid: String) -> Simulators.Device {
        Simulators.Device(udid: udid, name: name, state: "Booted", deviceTypeIdentifier: nil, runtime: nil)
    }
    let devices = [device("oss-lease-ios-ab12", "U1"), device("oss-lease-ios-cd34", "U2"), device("iPhone 17", "U3")]
    #expect(PrimarySimulators.strays(devices, held: ["oss-lease-ios-ab12"]).map(\.udid) == ["U2"])
    #expect(PrimarySimulators.strays(devices, held: ["oss-lease-ios-ab12", "oss-lease-ios-cd34"]).isEmpty)
}

/// AXe on the primary: the server's own copy, sent when the primary's
/// isn't the same (its stamp), into the guest user's home.
@Test func theServersAXeGoesToThePrimaryOnce() throws {
    #expect(PrimarySimulators.axeCheckLine(stamp: "5724080-1762160000")
                == #"test "$(cat .oss/axe/stamp 2>/dev/null)" = '5724080-1762160000' && test -x .oss/axe/axe"#)
    #expect(PrimarySimulators.axeInstallLine(stamp: "5724080-1762160000")
                == "rm -rf .oss/axe && mkdir -p .oss/axe && tar -xzf - -C .oss/axe && echo '5724080-1762160000' > .oss/axe/stamp")
    let folder = NSTemporaryDirectory() + "oss-axe-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: folder) }
    try FileManager.default.createDirectory(atPath: "\(folder)/Frameworks", withIntermediateDirectories: true)
    try Data("axe".utf8).write(to: URL(fileURLWithPath: "\(folder)/axe"))
    #expect(PrimarySimulators.axeStamp("\(folder)/axe")?.hasPrefix("3-") == true)
    #expect(PrimarySimulators.axeStamp("\(folder)/none") == nil)
    #expect(PrimarySimulators.axeDirectory("\(folder)/axe") == URL(fileURLWithPath: folder).resolvingSymlinksInPath().path)
}

/// A recording there: simctl's file in the primary's /tmp, ended by pkill
/// matching its path alone, brought back and deleted.
@Test func aRecordingInThePrimaryIsSimctlsThere() {
    let path = ScreenMedia.primaryRecordingPath("a1b2c3")
    #expect(path == "/tmp/oss-recording-a1b2c3.mp4")
    #expect(ScreenMedia.primaryRecordingPattern(path) == #"recordVideo.*/tmp/oss-recording-a1b2c3\.mp4"#)
    #expect(SimulatorHost.remoteLine("/usr/bin/xcrun", ScreenMedia.simulatorRecord(udid: "U", path: path))
                == "'/usr/bin/xcrun' 'simctl' 'io' 'U' 'recordVideo' '--codec=h264' '--mask=black' '--force' '/tmp/oss-recording-a1b2c3.mp4'")
    #expect(ScreenMedia.fetchAndDeleteScript == #"cat -- "$1"; s=$?; rm -f -- "$1"; exit $s"#)
}

/// An iOS run in the primary: its .xctestrun names the primary's Xcode and
/// folder, xcodebuild there is the same command against the lease's
/// simulator, and a UI test's runner is made there, not here.
@Test func anIOSRunInThePrimaryIsXcodebuildThere() {
    #expect(PrimaryXCTest.parseXcode("/Applications/Xcode.app/Contents/Developer\ntesting\n")
                == PrimaryXCTest.Xcode(developerDirectory: "/Applications/Xcode.app/Contents/Developer", testingFramework: true))
    #expect(PrimaryXCTest.parseXcode("/Applications/Xcode-27.2.app/Contents/Developer\n")?.testingFramework == false)
    #expect(PrimaryXCTest.parseXcode("xcode-select: error: no developer tools\n") == nil)
    #expect(PrimaryXCTest.folder(lease: "ab12", run: "r1") == "/Users/Shared/oss-ios/ab12/xctest-r1")

    let prepared = XCTestFolder.Prepared(layout: XCTestRunFile.Layout(bundle: "HelloWorldUITests", host: "HelloWorld", ui: true),
                                         xctestrun: "/server/uploads/ab12/xctest-r1/tests.xctestrun",
                                         resultBundle: "/server/uploads/ab12/xctest-r1/result.xcresult")
    let remote = "/Users/Shared/oss-ios/ab12/xctest-r1"
    #expect(PrimaryXCTest.xcodebuildLine(prepared, udid: "U-1", folder: remote, onlyTesting: ["LaunchTests"])
                == "'/usr/bin/xcrun' 'xcodebuild' 'test-without-building' '-xctestrun' '\(remote)/tests.xctestrun' '-destination' 'id=U-1' "
                    + "'-resultBundlePath' '\(remote)/result.xcresult' '-derivedDataPath' '\(remote)/derived_data' "
                    + "'-collect-test-diagnostics' 'never' '-only-testing:HelloWorldUITests/LaunchTests'")
}

#if os(macOS)
/// The folder made ready here for the primary: no runner made here, the
/// .xctestrun the primary's.
@Test func anIOSRunsFolderForThePrimaryNamesThePrimarys() async throws {
    let remote = "/Users/Shared/oss-ios/ab12/xctest-r1"
    let root = NSTemporaryDirectory() + "oss-primary-xctest-\(UUID().uuidString)"
    defer { try? Permissions.remove(root) }
    try makeTestBundle("HelloWorldUITests", in: "\(root)/bundle")
    try FileManager.default.createDirectory(atPath: "\(root)/app/HelloWorld.app", withIntermediateDirectories: true)
    try Data("app".utf8).write(to: URL(fileURLWithPath: "\(root)/app/HelloWorld.app/HelloWorld"))
    for (folder, name) in [("bundle", "HelloWorldUITests.xctest"), ("app", "HelloWorld.app")] {
        let zipped = try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "\(root)/\(folder)/\(name)", "\(root)/\(folder).zip"],
                                         timeout: 60)
        try #require(zipped.ok, "\(zipped.error)")
    }
    let made = try await XCTestFolder.prepare(tests: "\(root)/bundle.zip", host: "\(root)/app.zip", ui: true, in: "\(root)/run",
                                              developerDirectory: "/Applications/Xcode-27.2.app/Contents/Developer",
                                              primary: (remote, true))
    #expect(FileManager.default.fileExists(atPath: "\(root)/run/HelloWorldUITests.xctest"))
    #expect(!FileManager.default.fileExists(atPath: "\(root)/run/HelloWorldUITests-Runner.app"))
    let file = try plist(try #require(FileManager.default.contents(atPath: made.xctestrun)))
    let test = try #require(file["HelloWorldUITests"] as? [String: Any])
    #expect(test["ClangProfileDataDirectoryPath"] as? String == remote)
    #expect((test["TestingEnvironmentVariables"] as? [String: String])?["DYLD_FRAMEWORK_PATH"]
                == "/Applications/Xcode-27.2.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks")
    #expect(test["TestHostPath"] as? String == "__TESTROOT__/HelloWorldUITests-Runner.app")
}

/// The runner the primary makes from its Xcode is the one made here from
/// the server's (XCTRunnerApp.assemble): the same script, run here against
/// a fake Xcode (`DEVELOPER_DIR`, which xcode-select answers).
@Test func thePrimarysUITestRunnerIsTheOneMadeHere() async throws {
    let root = NSTemporaryDirectory() + "oss-primary-runner-\(UUID().uuidString)"
    defer { try? Permissions.remove(root) }
    let developer = try makeFakeXcode("\(root)/xcode")
    try makeTestBundle("HelloWorldUITests", in: "\(root)/run")
    var environment = ProcessInfo.processInfo.environment
    environment["DEVELOPER_DIR"] = developer
    let ran = try await Shell.run("/bin/bash", ["-c", PrimaryXCTest.runnerScript, "bash", "\(root)/run", "HelloWorldUITests",
                                                XCTRunnerApp.bundleIdentifier("HelloWorldUITests")], environment: environment, timeout: 60)
    #expect(ran.ok, "\(ran.error)")
    let runner = "\(root)/run/HelloWorldUITests-Runner.app"
    #expect(!FileManager.default.fileExists(atPath: "\(root)/run/HelloWorldUITests.xctest"))
    #expect(FileManager.default.fileExists(atPath: "\(runner)/PlugIns/HelloWorldUITests.xctest/HelloWorldUITests"))
    #expect(FileManager.default.fileExists(atPath: "\(runner)/PlugIns/HelloWorldUITests.xctest/Frameworks"))
    let data = try #require(FileManager.default.contents(atPath: "\(runner)/Info.plist"))
    #expect(data.prefix(8) == Data("bplist00".utf8))
    let info = try plist(data)
    #expect(info["CFBundleExecutable"] as? String == "XCTRunner")
    #expect(info["CFBundleDisplayName"] as? String == "XCTRunner")
    #expect(info["CFBundleIdentifier"] as? String == "com.apple.test.HelloWorldUITests-Runner")
    #expect(info["XCTestTarget"] as? [String] == ["com.apple.test.HelloWorldUITests-Runner"])
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: "\(runner)/Frameworks"))
                == ["XCTest.framework", "XCTestCore.framework", "XCTAutomationSupport.framework", "libXCTestSwiftSupport.dylib",
                    "libXCTestBundleInject.dylib", "XCTestSupport.framework", "XCUIAutomation.framework", "Testing.framework"])
    #expect(isWritable(runner) && isWritable("\(runner)/Info.plist"))

    // An Xcode without a framework the runner needs: refused, saying which.
    let lacking = try makeFakeXcode("\(root)/lacking", xctestCore: false)
    try makeTestBundle("HelloWorldUITests", in: "\(root)/run-lacking")
    environment["DEVELOPER_DIR"] = lacking
    let refused = try await Shell.run("/bin/bash", ["-c", PrimaryXCTest.runnerScript, "bash", "\(root)/run-lacking", "HelloWorldUITests",
                                                    "com.apple.test.HelloWorldUITests-Runner"], environment: environment, timeout: 60)
    #expect(!refused.ok && refused.error.contains("XCTestCore.framework"))
}
#endif
