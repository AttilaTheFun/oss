import Foundation
import Testing
import OSSClient
@testable import OSSServer

// Mac tests on a slot (XCTestMac.swift): the .xctestrun, what -only-testing
// may name, and the commands a run sends the primary.

@Test func aMacLogicTestIsHostedByXcodesAgentAndAHostedOneInjectedIntoItsApp() throws {
    let logic = MacXCTestRunFile.plist(MacXCTestRunFile.Layout(bundle: "App-Tests"))
    let test = try #require(logic["App_Tests"] as? [String: Any])
    #expect(test["TestHostPath"] as? String == "__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest")
    #expect(test["TestBundlePath"] as? String == "__TESTROOT__/App-Tests.xctest")
    #expect(test["IsAppHostedTestBundle"] as? Bool == false)
    #expect((test["TestingEnvironmentVariables"] as? [String: String])?["XCInjectBundleInto"] == nil)

    let hosted = MacXCTestRunFile.plist(MacXCTestRunFile.Layout(bundle: "AppTests", host: "Reviews", hostExecutable: "Reviews"))
    let hostedTest = try #require(hosted["AppTests"] as? [String: Any])
    #expect(hostedTest["TestHostPath"] as? String == "__TESTROOT__/Reviews.app")
    #expect(hostedTest["IsAppHostedTestBundle"] as? Bool == true)
    let environment = try #require(hostedTest["TestingEnvironmentVariables"] as? [String: String])
    #expect(environment["XCInjectBundleInto"] == "__TESTHOST__/Contents/MacOS/Reviews")
    #expect(environment["DYLD_INSERT_LIBRARIES"] == "__PLATFORMS__/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib")
    // A plist xcodebuild reads.
    _ = try MacXCTestRunFile.data(MacXCTestRunFile.Layout(bundle: "AppTests"))
}

@Test func aMacRunsOnlyTestingNamesNothingItsShellWouldRead() {
    for good in ["ReviewsTests", "ReviewsTests/testTitle", "Suite/function()", "App_Tests/Class/test-case.1"] {
        #expect(MacXCTest.validTest(good), "\(good)")
    }
    for bad in ["", "-only-testing:x", "a b", "a'b", "a;rm -rf", "$(id)", "a`b`", "a\nb", "é"] {
        #expect(!MacXCTest.validTest(bad), "\(bad)")
    }
}

@Test func aSlotsRunIsItsUsersAndAGUIRunTheConsoleUsersInItsSession() {
    let slot = MacXCTest.Place(lease: "ab12", run: "r1", gui: false, console: "runner")
    #expect(slot.user == "oss-ab12")
    #expect(slot.directory == "/Users/oss-ab12/xctest-r1")
    #expect(slot.asUser("true") == "sudo -u oss-ab12 -H bash -c 'true'")
    let gui = MacXCTest.Place(lease: "ab12", run: "r1", gui: true, console: "runner")
    #expect(gui.user == "runner")
    #expect(gui.directory == "/Users/Shared/oss-gui/ab12-r1")
    #expect(gui.asUser("true") == "sudo launchctl asuser \"$(id -u runner)\" sudo -u runner -H bash -c 'true'")

    let command = MacXCTest.xcodebuild(slot, bundle: "App-Tests", onlyTesting: ["Foo/testBar", "App_Tests/Baz"])
    #expect(command.contains("test-without-building -xctestrun /Users/oss-ab12/xctest-r1/tests.xctestrun"))
    #expect(command.contains("-destination platform=macOS"))
    #expect(command.contains("-resultBundlePath /Users/oss-ab12/xctest-r1/result.xcresult"))
    #expect(command.contains("-only-testing:App_Tests/Foo/testBar"))
    #expect(command.contains("-only-testing:App_Tests/Baz"))
    #expect(!command.contains("'"))
}
