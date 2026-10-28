#if canImport(Network)
// What rules_apple 5.3.1's ios_xctestrun_runner writes for xcodebuild
// (apple/testing/default_runner/ios_xctestrun_runner.template.xctestrun,
// filled in by its runner's own sed), for a logic test, a hosted unit test
// and a UI test of a host named HelloWorld: Xcode at
// /Applications/Xcode.app/Contents/Developer (with Swift Testing's
// framework), the test folder /runs/r1, its defaults (test order ordered,
// attachments keepNever, no arguments or filter), less Bazel's own test
// variables (TEST_SRCDIR and the like), which name the Mac's test tree.
// The server's .xctestrun must say the same.

let rulesAppleLogicXCTestRun = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>HelloWorldTests</key>
  <dict>
    <key>ProductModuleName</key>
    <string>HelloWorldTests</string>
    <key>TestBundlePath</key>
    <string>__TESTROOT__/HelloWorldTests.xctest</string>
    <key>TestExecutionOrdering</key>
    <string>ordered</string>
    <key>IsAppHostedTestBundle</key>
    <false/>
    <key>TestHostPath</key>
    <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest</string>
    <key>TestHostBundleIdentifier</key>
    <string></string>
    <key>IsUITestBundle</key>
    <false/>
    <key>IsXCTRunnerHostedTestBundle</key>
	  <false/>
    <key>UITargetAppPath</key>
    <string></string>
    <key>DependentProductPaths</key>
    <array>
        <string>__TESTROOT__/HelloWorldTests.xctest</string>
        <string></string>
        <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest</string>
    </array>
    <key>TestingEnvironmentVariables</key>
    <dict>
      <key>DYLD_INSERT_LIBRARIES</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib/libXCTestBundleInject.dylib</string>
      <key>DYLD_LIBRARY_PATH</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib</string>
      <key>__XCODE_BUILT_PRODUCTS_DIR_PATHS</key>
      <string>/DUMMY_SRCROOT/</string>
      
    </dict>
    <key>SystemAttachmentLifetime</key>
    <string>keepNever</string>
    <key>UserAttachmentLifetime</key>
    <string>keepNever</string>

    <key>ClangProfileDataDirectoryPath</key>
    <string>/runs/r1</string>



  </dict>
  <key>__xctestrun_metadata__</key>
  <dict>
    <key>CodeCoverageBuildableInfos</key>
    <array>
      <dict>
        <key>Architecture</key>
        <string>arm64</string>
        <key>BuildableIdentifier</key>
        <string>000000000000000000000000:primary</string>
        <key>IncludeInReport</key>
        <true/>
        <key>IsStatic</key>
        <false/>
        <key>Name</key>
        <string>HelloWorldTests.xctest</string>
        <key>ProductPath</key>
        <string>__TESTROOT__/HelloWorldTests.xctest</string>
        <key>Toolchains</key>
        <array>
          <string>com.apple.dt.toolchain.XcodeDefault</string>
        </array>
      </dict>
    </array>
    <key>FormatVersion</key>
    <integer>1</integer>
  </dict>
</dict>
</plist>
"""

let rulesAppleHostedXCTestRun = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>HelloWorldAppTests</key>
  <dict>
    <key>ProductModuleName</key>
    <string>HelloWorldAppTests</string>
    <key>TestBundlePath</key>
    <string>__TESTROOT__/HelloWorldAppTests.xctest</string>
    <key>TestExecutionOrdering</key>
    <string>ordered</string>
    <key>IsAppHostedTestBundle</key>
    <true/>
    <key>TestHostPath</key>
    <string>__TESTROOT__/HelloWorld.app</string>
    <key>TestHostBundleIdentifier</key>
    <string></string>
    <key>IsUITestBundle</key>
    <false/>
    <key>IsXCTRunnerHostedTestBundle</key>
	  <false/>
    <key>UITargetAppPath</key>
    <string></string>
    <key>DependentProductPaths</key>
    <array>
        <string>__TESTROOT__/HelloWorldAppTests.xctest</string>
        <string></string>
        <string>__TESTROOT__/HelloWorld.app</string>
    </array>
    <key>TestingEnvironmentVariables</key>
    <dict>
      <key>DYLD_INSERT_LIBRARIES</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib/libXCTestBundleInject.dylib</string>
      <key>DYLD_LIBRARY_PATH</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib</string>
      <key>__XCODE_BUILT_PRODUCTS_DIR_PATHS</key>
      <string>/DUMMY_SRCROOT/</string>
      <key>XCInjectBundleInto</key><string>__TESTHOST__/HelloWorld.app/HelloWorld</string><key>DYLD_FRAMEWORK_PATH</key><string>/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks</string>
    </dict>
    <key>SystemAttachmentLifetime</key>
    <string>keepNever</string>
    <key>UserAttachmentLifetime</key>
    <string>keepNever</string>

    <key>ClangProfileDataDirectoryPath</key>
    <string>/runs/r1</string>



  </dict>
  <key>__xctestrun_metadata__</key>
  <dict>
    <key>CodeCoverageBuildableInfos</key>
    <array>
      <dict>
        <key>Architecture</key>
        <string>arm64</string>
        <key>BuildableIdentifier</key>
        <string>000000000000000000000000:primary</string>
        <key>IncludeInReport</key>
        <true/>
        <key>IsStatic</key>
        <false/>
        <key>Name</key>
        <string>HelloWorldAppTests.xctest</string>
        <key>ProductPath</key>
        <string>__TESTROOT__/HelloWorldAppTests.xctest</string>
        <key>Toolchains</key>
        <array>
          <string>com.apple.dt.toolchain.XcodeDefault</string>
        </array>
      </dict>
    </array>
    <key>FormatVersion</key>
    <integer>1</integer>
  </dict>
</dict>
</plist>
"""

let rulesAppleUIXCTestRun = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>HelloWorldUITests</key>
  <dict>
    <key>ProductModuleName</key>
    <string>HelloWorldUITests</string>
    <key>TestBundlePath</key>
    <string>__TESTHOST__/PlugIns/HelloWorldUITests.xctest</string>
    <key>TestExecutionOrdering</key>
    <string>ordered</string>
    <key>IsAppHostedTestBundle</key>
    <true/>
    <key>TestHostPath</key>
    <string>__TESTROOT__/HelloWorldUITests-Runner.app</string>
    <key>TestHostBundleIdentifier</key>
    <string>com.apple.test.HelloWorldUITests-Runner</string>
    <key>IsUITestBundle</key>
    <true/>
    <key>IsXCTRunnerHostedTestBundle</key>
	  <true/>
    <key>UITargetAppPath</key>
    <string>__TESTROOT__/HelloWorld.app</string>
    <key>DependentProductPaths</key>
    <array>
        <string>__TESTHOST__/PlugIns/HelloWorldUITests.xctest</string>
        <string>__TESTROOT__/HelloWorld.app</string>
        <string>__TESTROOT__/HelloWorldUITests-Runner.app</string>
    </array>
    <key>TestingEnvironmentVariables</key>
    <dict>
      <key>DYLD_INSERT_LIBRARIES</key>
      <string></string>
      <key>DYLD_LIBRARY_PATH</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib</string>
      <key>__XCODE_BUILT_PRODUCTS_DIR_PATHS</key>
      <string>/DUMMY_SRCROOT/</string>
      <key>XCInjectBundleInto</key><string>__TESTHOST__/HelloWorld.app/HelloWorld</string><key>DYLD_FRAMEWORK_PATH</key><string>/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks</string>
    </dict>
    <key>SystemAttachmentLifetime</key>
    <string>keepNever</string>
    <key>UserAttachmentLifetime</key>
    <string>keepNever</string>

    <key>ClangProfileDataDirectoryPath</key>
    <string>/runs/r1</string>



  </dict>
  <key>__xctestrun_metadata__</key>
  <dict>
    <key>CodeCoverageBuildableInfos</key>
    <array>
      <dict>
        <key>Architecture</key>
        <string>arm64</string>
        <key>BuildableIdentifier</key>
        <string>000000000000000000000000:primary</string>
        <key>IncludeInReport</key>
        <true/>
        <key>IsStatic</key>
        <false/>
        <key>Name</key>
        <string>HelloWorldUITests.xctest</string>
        <key>ProductPath</key>
        <string>__TESTHOST__/PlugIns/HelloWorldUITests.xctest</string>
        <key>Toolchains</key>
        <array>
          <string>com.apple.dt.toolchain.XcodeDefault</string>
        </array>
      </dict>
    </array>
    <key>FormatVersion</key>
    <integer>1</integer>
  </dict>
</dict>
</plist>
"""

/// A result bundle's tests as `xcresulttool get test-results tests` gives
/// them (its schema 0.4.0): a test plan, a bundle, an XCTest class with a
/// test passed, failed and skipped, and Swift Testing's suites, one in
/// another, with a parameterized test.
let sampleTestResults = #"""
{"devices": [{"architecture": "arm64", "deviceId": "00000000-0000-0000-0000-000000000001", "deviceName": "oss-lease-ios-x1",
              "modelName": "iPhone 17 Pro", "osVersion": "27.0", "platform": "iOS Simulator"}],
 "testPlanConfigurations": [{"configurationId": "1", "configurationName": "Test Scheme Action"}],
 "testNodes": [
  {"name": "HelloWorldTests", "nodeType": "Test Plan", "result": "Failed", "children": [
   {"name": "HelloWorldTests", "nodeType": "Unit test bundle", "result": "Failed", "children": [
    {"name": "GreetingTests", "nodeType": "Test Suite", "result": "Failed", "children": [
     {"name": "testGreets()", "nodeType": "Test Case", "result": "Passed", "durationInSeconds": 0.012,
      "nodeIdentifier": "GreetingTests/testGreets()"},
     {"name": "testShouts()", "nodeType": "Test Case", "result": "Failed", "durationInSeconds": 0.5,
      "nodeIdentifier": "GreetingTests/testShouts()", "children": [
       {"name": "GreetingTests.swift:12: XCTAssertEqual failed: (\"hi\") is not equal to (\"HI\")", "nodeType": "Failure Message"},
       {"name": "GreetingTests.swift:13: XCTAssertTrue failed", "nodeType": "Failure Message"}]},
     {"name": "testLater()", "nodeType": "Test Case", "result": "Skipped", "durationInSeconds": 0.001,
      "nodeIdentifier": "GreetingTests/testLater()", "children": [
       {"name": "Not yet & <soon>", "nodeType": "Skip Message"}]}]},
    {"name": "Formatting", "nodeType": "Test Suite", "result": "Passed", "children": [
     {"name": "Dates", "nodeType": "Test Suite", "result": "Passed", "children": [
      {"name": "rendersISO(_:)", "nodeType": "Test Case", "result": "Passed", "durationInSeconds": 0.25, "children": [
       {"name": "\"2026-10-28\"", "nodeType": "Arguments", "result": "Passed"},
       {"name": "\"2026-10-29\"", "nodeType": "Arguments", "result": "Passed"}]}]}]}]}]}]}
"""#

/// The JUnit the server makes of `sampleTestResults`.
let sampleJUnit = """
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="4" failures="1" skipped="1" time="0.763">
  <testsuite name="HelloWorldTests" tests="4" failures="1" skipped="1" time="0.763">
    <testcase classname="HelloWorldTests.GreetingTests" name="testGreets()" time="0.012"/>
    <testcase classname="HelloWorldTests.GreetingTests" name="testShouts()" time="0.500">
      <failure message="GreetingTests.swift:12: XCTAssertEqual failed: (&quot;hi&quot;) is not equal to (&quot;HI&quot;)">GreetingTests.swift:12: XCTAssertEqual failed: (&quot;hi&quot;) is not equal to (&quot;HI&quot;)
GreetingTests.swift:13: XCTAssertTrue failed</failure>
    </testcase>
    <testcase classname="HelloWorldTests.GreetingTests" name="testLater()" time="0.001">
      <skipped message="Not yet &amp; &lt;soon&gt;"/>
    </testcase>
    <testcase classname="HelloWorldTests.Formatting.Dates" name="rendersISO(_:)" time="0.250"/>
  </testsuite>
</testsuites>

"""
#endif
