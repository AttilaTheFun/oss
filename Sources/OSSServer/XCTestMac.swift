import Foundation
import OSSClient

// Mac tests on a slot of the primary macOS VM (API 17, docs/primary-vms.md):
// rules_apple's macos_unit_test bundles, built on Linux (rules_applecross)
// or a Mac, run on the primary as `oss machine xctest` runs iOS tests on a
// simulator. The run's folder is made ready on the server's Mac as an iOS
// run's is (the bundles unpacked, an .xctestrun written), copied into the
// slot's home on the primary, and run there by `xcodebuild
// test-without-building` as the slot's user (`--gui`: as the primary's
// console user, in its session, which a test that draws a window needs);
// its output streamed back as it comes, its result bundle copied back for
// JUnit, and its folder on the primary deleted.

/// A Mac run's .xctestrun, as Xcode writes one for a macOS unit test: a
/// logic test hosted by Xcode's `xctest` agent, a hosted one injected into
/// its app's executable (`<app>.app/Contents/MacOS/<executable>`). Paths are
/// `__PLATFORMS__`'s, so the primary's own Xcode is the one they name.
enum MacXCTestRunFile {
    static let platform = "MacOSX.platform"

    struct Layout: Sendable, Equatable {
        /// `<bundle>.xctest` in the run's folder.
        var bundle: String
        /// `<host>.app` in the run's folder, and its executable's name.
        var host: String?
        var hostExecutable: String?
    }

    static func plist(_ layout: Layout) -> [String: Any] {
        let libraries = "__PLATFORMS__/\(platform)/Developer/usr/lib"
        let frameworks = "__PLATFORMS__/\(platform)/Developer/Library/Frameworks"
        let bundlePath = "__TESTROOT__/\(layout.bundle).xctest"
        var hostPath = "__PLATFORMS__/\(platform)/Developer/Library/Xcode/Agents/xctest"
        var environment = [
            "DYLD_FRAMEWORK_PATH": "__TESTROOT__:\(frameworks)",
            "DYLD_LIBRARY_PATH": "__TESTROOT__:\(libraries)",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "__TESTROOT__",
        ]
        if let host = layout.host {
            hostPath = "__TESTROOT__/\(host).app"
            environment["DYLD_INSERT_LIBRARIES"] = "\(libraries)/libXCTestBundleInject.dylib"
            environment["XCInjectBundleInto"] = "__TESTHOST__/Contents/MacOS/\(layout.hostExecutable ?? host)"
        }
        let test: [String: Any] = [
            "ProductModuleName": XCTestRunFile.target(layout.bundle),
            "TestBundlePath": bundlePath,
            "TestExecutionOrdering": "ordered",
            "IsAppHostedTestBundle": layout.host != nil,
            "TestHostPath": hostPath,
            "TestHostBundleIdentifier": "",
            "IsUITestBundle": false,
            "IsXCTRunnerHostedTestBundle": false,
            "UITargetAppPath": "",
            "DependentProductPaths": [bundlePath, hostPath],
            "TestingEnvironmentVariables": environment,
            "SystemAttachmentLifetime": "keepNever",
            "UserAttachmentLifetime": "keepNever",
        ]
        return [
            XCTestRunFile.target(layout.bundle): test,
            "__xctestrun_metadata__": ["FormatVersion": 1] as [String: Any],
        ]
    }

    static func data(_ layout: Layout) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(layout), format: .xml, options: 0)
    }
}

enum MacXCTest {
    /// What a slot's run needs of the server: its primary, reached over SSH;
    /// its keychain's password; the primary's console user (a GUI run's).
    struct Slot: Sendable {
        var guest: Guest
        var keychainPassword: String
        var console: String
    }

    /// A Mac test's tests, as `-only-testing` puts them on the primary's
    /// command line: letters, digits and `_ / ( ) . -` alone (a Swift
    /// Testing `Suite/function()` too), so nothing else reaches its shell.
    static func validTest(_ test: String) -> Bool {
        !test.isEmpty && test.count <= 512 && !test.hasPrefix("-")
            && test.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_/().-".contains($0)) }
    }

    /// The run's folder on the server's Mac made ready: the bundle (and its
    /// app) unpacked, the .xctestrun written. A macOS app's zip holds its
    /// `.app` at its top, as rules_apple's macos_application leaves it.
    static func prepare(tests: String, host: String?, in folder: String) async throws -> (layout: MacXCTestRunFile.Layout, xctestrun: String) {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let bundle = try await XCTestFolder.unpack(tests, kind: "xctest", into: folder, looking: [""],
                                                   what: "the tests (rules_apple's <name>.zip holding <name>.xctest, or a .xctest folder zipped)")
        var layout = MacXCTestRunFile.Layout(bundle: bundle)
        if let host {
            let app = try await XCTestFolder.unpack(host, kind: "app", into: folder, looking: [""], what: "the host (a zipped macOS .app)")
            layout.host = app
            let info = NSDictionary(contentsOfFile: "\(folder)/\(app).app/Contents/Info.plist")
            layout.hostExecutable = info?["CFBundleExecutable"] as? String ?? app
        }
        try Permissions.makeWritable(folder)
        let xctestrun = "\(folder)/tests.xctestrun"
        try MacXCTestRunFile.data(layout).write(to: URL(fileURLWithPath: xctestrun))
        return (layout, xctestrun)
    }

    /// Where a run's folder is on the primary, and whom it runs as: the
    /// slot's user in its home, or (`gui`) the console user in a folder of
    /// the run's own under /Users/Shared.
    struct Place: Sendable, Equatable {
        var lease: String
        var user: String
        var directory: String
        var gui: Bool

        init(lease: String, run: String, gui: Bool, console: String) {
            self.gui = gui
            self.lease = lease
            user = gui ? console : SlotUser.name(lease)
            directory = gui ? "/Users/Shared/oss-gui/\(lease)-\(run)" : "/Users/\(SlotUser.name(lease))/xctest-\(run)"
        }

        /// A command line run as the place's user: in the console user's
        /// session (`launchctl asuser`) for a GUI run. `command` is quoted
        /// once, in single quotes, and has none of its own.
        func asUser(_ command: String) -> String {
            let inner = "sudo -u \(user) -H bash -c '\(command)'"
            return gui ? "sudo launchctl asuser \"$(id -u \(user))\" \(inner)" : inner
        }
    }

    /// xcodebuild's command on the primary, in the run's folder there.
    static func xcodebuild(_ place: Place, bundle: String, onlyTesting: [String]) -> String {
        var command = "cd \(place.directory) && /usr/bin/xcrun xcodebuild test-without-building -xctestrun \(place.directory)/tests.xctestrun"
            + " -destination platform=macOS -resultBundlePath \(place.directory)/result.xcresult"
            + " -derivedDataPath \(place.directory)/derived_data -collect-test-diagnostics never"
        let target = XCTestRunFile.target(bundle)
        for test in onlyTesting {
            command += " -only-testing:" + (test == target || test.hasPrefix(target + "/") ? test : "\(target)/\(test)")
        }
        return command
    }

    /// The run on the primary: its folder copied there, the slot's keychain
    /// unlocked, xcodebuild run with its output to `output` as it comes,
    /// its result bundle copied back into `folder`, its folder there deleted.
    /// The task cancelled (its client gone) or `output` answering false stops
    /// xcodebuild there too. Its exit status.
    static func run(folder: String, place: Place, guest: Guest, keychainPassword: String, bundle: String, onlyTesting: [String],
                    output: @escaping @Sendable (Data) async -> Bool) async throws -> Int32 {
        // The folder there, its user's; a GUI run's under /Users/Shared.
        let made = try await guest.run("""
            set -e
            sudo mkdir -p \(place.directory)
            sudo chown \(place.user) \(place.directory)
            """, timeout: 60)
        guard made.ok else { throw APIError(error: "the run's folder on the primary: \(made.error.suffix(300))") }
        defer {
            Task { _ = try? await guest.run("sudo rm -rf \(place.directory)", timeout: 300) }
        }
        let sent = try await Shell.run("/bin/bash", ["-c", "set -o pipefail; tar -cz -C \"$1\" . | /usr/bin/ssh \"${@:2}\"", "bash", folder]
                                        + guest.sshArguments("sudo -u \(place.user) tar -xz -C \(place.directory)"), timeout: 1800)
        guard sent.ok else { throw APIError(error: "copying the run to the primary: \(sent.error.suffix(300))") }
        if !place.gui {
            // A slot's keychain unlocked for the run (its password on no command line: a script's standard input).
            _ = try? await guest.run(SlotUser.unlockScript(lease: place.lease, password: keychainPassword), timeout: 60)
        }
        let remote = place.asUser(xcodebuild(place, bundle: bundle, onlyTesting: onlyTesting))
        let status: Int32
        do {
            status = try await StreamedProcess.run("/usr/bin/ssh", guest.sshArguments(remote), output: output)
        } catch {
            await stop(place, guest: guest)
            throw error
        }
        if Task.isCancelled {
            await stop(place, guest: guest)
            return status
        }
        // Its result bundle back, for JUnit and `…/result`.
        let fetched = try await Shell.run("/bin/bash", ["-c", "set -o pipefail; /usr/bin/ssh \"${@:2}\" | tar -xz -C \"$1\"", "bash", folder]
                                           + guest.sshArguments("cd \(place.directory) && sudo -u \(place.user) tar -cz result.xcresult"),
                                          timeout: 1800)
        if !fetched.ok { _ = await output(Data("oss: no result bundle came back from the primary: \(fetched.error.suffix(300))\n".utf8)) }
        return status
    }

    /// The run's xcodebuild on the primary stopped (found by its folder):
    /// SIGINT, then SIGKILL ten seconds on.
    static func stop(_ place: Place, guest: Guest) async {
        _ = try? await guest.run("""
            sudo pkill -INT -f -- '\(place.directory)/tests.xctestrun' || true
            for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f -- '\(place.directory)/tests.xctestrun' >/dev/null || exit 0; sleep 1; done
            sudo pkill -KILL -f -- '\(place.directory)/tests.xctestrun' || true
            """, timeout: 60)
    }
}
