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

// iOS tests on a simulator in the primary (docs/primary-vms.md, "iOS:
// simulators in the primary"): the run's folder made ready here as a
// simulator's on this Mac is, its .xctestrun naming the primary's Xcode and
// its folder there; copied into the lease's folder on the primary (tar over
// SSH), a UI test's runner made there from the primary's own Xcode (its
// XCTest frameworks are the ones its simulators run), xcodebuild run there
// as its guest user against the lease's simulator, its output streamed
// back, its result bundle copied back for JUnit and `…/result`, and its
// folder there deleted.
enum PrimaryXCTest {
    /// What a run needs to know of the primary's Xcode first.
    struct Xcode: Sendable, Equatable {
        var developerDirectory: String
        /// Whether its simulator platform has Swift Testing's framework.
        var testingFramework: Bool
    }

    /// The primary's developer folder, then `testing` if its simulator
    /// platform has Testing.framework.
    static let xcodeScript = """
        d=$(/usr/bin/xcode-select -p) || exit 1
        echo "$d"
        if [ -d "$d/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/Testing.framework" ]; then echo testing; fi
        """

    static func parseXcode(_ output: String) -> Xcode? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, first.hasPrefix("/") else { return nil }
        return Xcode(developerDirectory: first, testingFramework: lines.dropFirst().contains("testing"))
    }

    static func xcode(_ guest: Guest) async throws -> Xcode {
        let read = try await Shell.run("/usr/bin/ssh", guest.sshArguments(SimulatorHost.remoteLine("/bin/sh", ["-c", xcodeScript])), timeout: 60)
        guard read.ok, let xcode = parseXcode(read.output) else {
            throw APIError(error: "the primary's Xcode couldn't be read: \(read.error.suffix(300))")
        }
        return xcode
    }

    /// A run's folder on the primary.
    static func folder(lease: String, run: String) -> String { "\(PrimarySimulators.folder(lease))/xctest-\(run)" }

    /// A UI test's runner made in the run's folder on the primary, from its
    /// Xcode's XCTRunner.app, as XCTRunnerApp.assemble makes one here (and
    /// rules_apple's runner on a Mac): `$1` the folder, `$2` the bundle's
    /// name, `$3` the runner's bundle identifier.
    static let runnerScript = #"""
        set -euo pipefail
        dir=$1; bundle=$2; id=$3
        developer="$(/usr/bin/xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer"
        library="$developer/Library"
        agent="$library/Xcode/Agents/XCTRunner.app"
        [ -d "$agent" ] || { echo "oss: the primary's Xcode has no XCTRunner.app for a UI test" >&2; exit 1; }
        runner="$dir/$bundle-Runner.app"
        rm -rf "$runner"
        cp -R "$agent" "$runner"
        chmod -R u+w "$runner" "$dir/$bundle.xctest"
        mkdir -p "$runner/PlugIns"
        mv "$dir/$bundle.xctest" "$runner/PlugIns/$bundle.xctest"
        mkdir -p "$runner/PlugIns/$bundle.xctest/Frameworks"
        plutil -convert xml1 "$runner/Info.plist"
        sed -i '' -e 's/$(WRAPPEDPRODUCTNAME)/XCTRunner/g' -e 's/WRAPPEDPRODUCTNAME/XCTRunner/g' \
            -e "s/\$(WRAPPEDPRODUCTBUNDLEIDENTIFIER)/$id/g" -e "s/WRAPPEDPRODUCTBUNDLEIDENTIFIER/$id/g" "$runner/Info.plist"
        plutil -convert binary1 "$runner/Info.plist"
        mkdir -p "$runner/Frameworks"
        copy() {
            if [ -e "$1" ]; then cp -R "$1" "$runner/Frameworks/"
            elif [ "$2" = required ]; then echo "oss: the primary's Xcode has no $1 for a UI test's runner" >&2; exit 1; fi
        }
        copy "$library/Frameworks/XCTest.framework" required
        copy "$library/PrivateFrameworks/XCTestCore.framework" required
        copy "$library/PrivateFrameworks/XCTAutomationSupport.framework" required
        copy "$library/PrivateFrameworks/XCUnit.framework" optional
        copy "$developer/usr/lib/libXCTestSwiftSupport.dylib" required
        copy "$developer/usr/lib/libXCTestBundleInject.dylib" required
        copy "$library/PrivateFrameworks/XCTestSupport.framework" optional
        copy "$library/Frameworks/Testing.framework" optional
        if [ -e "$library/Frameworks/XCUIAutomation.framework" ]; then
            copy "$library/Frameworks/XCUIAutomation.framework" required
        else
            copy "$library/PrivateFrameworks/XCUIAutomation.framework" required
        fi
        chmod -R u+w "$runner"
        """#

    /// The run's files on the primary: its .xctestrun and result bundle
    /// there (`prepared`'s, moved into `remote`).
    static func remote(_ prepared: XCTestFolder.Prepared, folder remote: String) -> XCTestFolder.Prepared {
        XCTestFolder.Prepared(layout: prepared.layout, xctestrun: "\(remote)/tests.xctestrun", resultBundle: "\(remote)/result.xcresult")
    }

    /// xcodebuild's command line on the primary for the run (its
    /// arguments XCTestFolder.arguments', the folder the primary's).
    static func xcodebuildLine(_ prepared: XCTestFolder.Prepared, udid: String, folder remote: String, onlyTesting: [String]) -> String {
        SimulatorHost.remoteLine("/usr/bin/xcrun", ["xcodebuild"] + XCTestFolder.arguments(self.remote(prepared, folder: remote), udid: udid,
                                                                                          folder: remote, onlyTesting: onlyTesting))
    }

    /// The run on the primary: its folder copied there (a UI test's runner
    /// made there), xcodebuild run with its output to `output` as it comes,
    /// its result bundle copied back into `folder`, its folder there
    /// deleted. The task cancelled (its client gone) or `output` answering
    /// false stops xcodebuild there too. Its exit status.
    static func run(folder: String, prepared: XCTestFolder.Prepared, lease: String, run: String, udid: String, guest: Guest,
                    onlyTesting: [String], output: @escaping @Sendable (Data) async -> Bool) async throws -> Int32 {
        let remote = self.folder(lease: lease, run: run)
        defer {
            Task { _ = try? await Shell.run("/usr/bin/ssh", guest.sshArguments(SimulatorHost.remoteLine("/bin/rm", ["-rf", remote])), timeout: 300) }
        }
        let sent = try await Shell.run("/bin/bash", ["-c", "set -o pipefail; tar -cz -C \"$1\" . | /usr/bin/ssh \"${@:2}\"", "bash", folder]
                                        + guest.sshArguments(PrimarySimulators.untarLine(into: remote)), timeout: 1800)
        guard sent.ok else { throw APIError(error: "copying the run to the primary: \(sent.error.suffix(300))") }
        let layout = prepared.layout
        if layout.ui {
            let made = try await Shell.run("/usr/bin/ssh", guest.sshArguments(SimulatorHost.remoteLine(
                "/bin/bash", ["-c", runnerScript, "bash", remote, layout.bundle, XCTRunnerApp.bundleIdentifier(layout.bundle)])), timeout: 600)
            guard made.ok else { throw APIError(error: "the UI test's runner wasn't made on the primary: \(made.error.suffix(400))") }
        }
        let status: Int32
        do {
            status = try await StreamedProcess.run("/usr/bin/ssh", guest.sshArguments(xcodebuildLine(prepared, udid: udid, folder: remote,
                                                                                                     onlyTesting: onlyTesting)), output: output)
        } catch {
            await stop(remote, guest: guest)
            throw error
        }
        if Task.isCancelled {
            await stop(remote, guest: guest)
            return status
        }
        let fetched = try await Shell.run("/bin/bash", ["-c", "set -o pipefail; /usr/bin/ssh \"${@:2}\" | tar -xz -C \"$1\"", "bash", folder]
                                           + guest.sshArguments("cd \(SlotCommand.quote(remote)) && tar -cz result.xcresult"), timeout: 1800)
        if !fetched.ok { _ = await output(Data("oss: no result bundle came back from the primary: \(fetched.error.suffix(300))\n".utf8)) }
        return status
    }

    /// The run's xcodebuild on the primary stopped (found by its folder's
    /// .xctestrun on its command line): SIGINT, then SIGKILL ten seconds on.
    static func stop(_ remote: String, guest: Guest) async {
        _ = try? await Shell.run("/usr/bin/ssh", guest.sshArguments(SimulatorHost.remoteLine("/bin/sh", ["-c", stopScript, "sh",
                                                                                                         "\(remote)/tests.xctestrun"])),
                                 timeout: 60)
    }

    static let stopScript = """
        pkill -INT -f -- "$1" || true
        for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f -- "$1" >/dev/null || exit 0; sleep 1; done
        pkill -KILL -f -- "$1" || true
        """
}
