import Foundation
import OSSClient

/// iOS simulators on the server's Mac. A base is a shut-down simulator
/// named `oss-ios-<config>`, set up once (apps installed, settings made,
/// booted and shut down so it starts quickly); a lease is `simctl clone`
/// of it (an APFS clone of the device's directory: seconds, no disk until
/// it changes), booted, and deleted when the lease ends.
enum Simulators {
    struct Device: Decodable {
        var udid: String
        var name: String
        var state: String
        var deviceTypeIdentifier: String?
        /// Its runtime's identifier: what simctl lists it under.
        var runtime: String?
    }

    static func devices(on host: SimulatorHost = .local) async throws -> [Device] {
        let result = try await host.simctl(["list", "devices", "-j"], timeout: 60)
        guard result.ok else { throw ShellError(description: "simctl list: \(result.error)") }
        struct List: Decodable { var devices: [String: [Device]] }
        let list = try JSONDecoder().decode(List.self, from: Data(result.output.utf8))
        return list.devices.flatMap { runtime, devices in devices.map { var device = $0; device.runtime = runtime; return device } }
    }

    /// A device type as `simctl list devicetypes -j` has it: `iPad Pro
    /// 13-inch (M5)`, `com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB`,
    /// `iPad`.
    struct DeviceType: Codable, Equatable, Sendable {
        var name: String
        var identifier: String
        var productFamily: String?
    }

    /// A runtime as `simctl list runtimes -j` has it, with the device
    /// types it runs.
    struct Runtime: Codable, Equatable, Sendable {
        var name: String
        var identifier: String
        var version: String?
        var platform: String?
        var isAvailable: Bool?
        var supportedDeviceTypes: [DeviceType]?
    }

    /// What an iOS lease's simulator is made of.
    struct Choice: Equatable, Sendable {
        var deviceType: DeviceType
        var runtime: Runtime
    }

    static func deviceTypes(on host: SimulatorHost = .local) async throws -> [DeviceType] {
        struct List: Decodable { var devicetypes: [DeviceType] }
        let listed = try await host.simctl(["list", "devicetypes", "-j"], timeout: 60)
        guard listed.ok else { throw ShellError(description: "simctl list devicetypes: \(listed.error)") }
        return try JSONDecoder().decode(List.self, from: Data(listed.output.utf8)).devicetypes
    }

    static func runtimes(on host: SimulatorHost = .local) async throws -> [Runtime] {
        struct List: Decodable { var runtimes: [Runtime] }
        let listed = try await host.simctl(["list", "runtimes", "-j"], timeout: 60)
        guard listed.ok else { throw ShellError(description: "simctl list runtimes: \(listed.error)") }
        return try JSONDecoder().decode(List.self, from: Data(listed.output.utf8)).runtimes
    }

    /// The device type and runtime an iOS lease asks for (`device`,
    /// `runtime`: a name or identifier, in any case), each the config's
    /// base's where it asks for none; nil when it asks for neither (a
    /// clone of the base). Refused (`noDevice`) with the close matches, or
    /// what there is, when the server's Xcode hasn't got one, or the
    /// runtime doesn't run the type. The base's own type and runtime is
    /// nil too: a clone of it is the same, and quicker.
    static func choose(device: String?, runtime: String?, base: Base) async throws -> Choice? {
        guard device != nil || runtime != nil else { return nil }
        let source = try await devices().first { $0.name == base.name }
        let choice = try pick(device: device, runtime: runtime, baseType: source?.deviceTypeIdentifier, baseRuntime: source?.runtime,
                              types: try await deviceTypes(), runtimes: try await runtimes())
        let same = choice.deviceType.identifier == source?.deviceTypeIdentifier && choice.runtime.identifier == source?.runtime
        return same ? nil : choice
    }

    /// `choose`'s decision, from simctl's lists.
    static func pick(device: String?, runtime: String?, baseType: String?, baseRuntime: String?,
                     types: [DeviceType], runtimes: [Runtime]) throws -> Choice {
        let ios = runtimes.filter { $0.isAvailable != false && ($0.platform == "iOS" || $0.identifier.contains(".SimRuntime.iOS-")) }
        let chosenRuntime: Runtime
        if let runtime {
            chosenRuntime = try resolveRuntime(runtime, among: ios)
        } else {
            guard let found = ios.first(where: { $0.identifier == baseRuntime }) else {
                throw APIError(error: "the config's base has no iOS runtime this Mac has: ask for one with --runtime (there are: "
                                    + "\(ios.map(\.name).joined(separator: ", ")))", code: "noDevice")
            }
            chosenRuntime = found
        }
        let chosenType: DeviceType
        if let device {
            chosenType = try resolveDevice(device, among: types, runtime: chosenRuntime)
        } else {
            guard let found = types.first(where: { $0.identifier == baseType }) else {
                throw APIError(error: "the config's base has no device type this Mac has: ask for one with --device", code: "noDevice")
            }
            try supported(found, by: chosenRuntime)
            chosenType = found
        }
        return Choice(deviceType: chosenType, runtime: chosenRuntime)
    }

    /// A device type by its name or identifier (or the identifier's last
    /// part, `iPad-Pro-13-inch-M5-12GB`), in any case, among the iPhones
    /// and iPads; one the runtime runs.
    static func resolveDevice(_ query: String, among types: [DeviceType], runtime: Runtime) throws -> DeviceType {
        let phones = types.filter { ["iPhone", "iPad"].contains($0.productFamily ?? "") }
        let wanted = fold(query)
        let prefix = "com.apple.coresimulator.simdevicetype."
        if let found = phones.first(where: { fold($0.name) == wanted || fold($0.identifier) == wanted || fold($0.identifier) == prefix + wanted }) {
            try supported(found, by: runtime)
            return found
        }
        // The close ones, among those the runtime runs: those whose names
        // have its words together ("ipad pro"), else those with each of
        // them somewhere, or a word beginning so ("ipad m5", "iphone 18 pr").
        let runnable = phones.filter { runs($0, on: runtime) }
        let words = Self.words(query)
        func spaced(_ words: [String]) -> String { " " + words.joined(separator: " ") + " " }
        var close = runnable.filter { !words.isEmpty && spaced(Self.words($0.name)).contains(spaced(words)) }
        if close.isEmpty {
            close = runnable.filter { type in
                let theirs = Self.words(type.name) + Self.words(type.identifier.components(separatedBy: ".").last ?? "")
                return !words.isEmpty && words.allSatisfy { word in theirs.contains { $0.hasPrefix(word) } }
            }
        }
        if !close.isEmpty {
            throw APIError(error: "no device type \"\(query)\"; close: \(close.map(\.name).joined(separator: ", "))", code: "noDevice")
        }
        throw APIError(error: "no device type \"\(query)\"; \(runtime.name) runs: \(runnable.map(\.name).joined(separator: ", "))",
                       code: "noDevice")
    }

    /// An iOS runtime by its name (`iOS 27.0`), identifier
    /// (`com.apple.CoreSimulator.SimRuntime.iOS-27-0`, or `iOS-27-0`) or
    /// version (`27.0`), in any case. Where several answer (Xcode 27.2 has
    /// a runtime of a version for one device type beside the version's
    /// own, `iOS-27-2-iPhone19-4`), the one that runs the most types.
    static func resolveRuntime(_ query: String, among runtimes: [Runtime]) throws -> Runtime {
        let wanted = fold(query)
        let bare = wanted.replacingOccurrences(of: " ", with: "")
        let prefix = "com.apple.coresimulator.simruntime."
        let found = runtimes.filter { runtime in
            fold(runtime.name) == wanted || fold(runtime.name).replacingOccurrences(of: " ", with: "") == bare
                || fold(runtime.identifier) == wanted || fold(runtime.identifier) == prefix + wanted || runtime.version == query
        }
        // One that doesn't list what it runs is taken to run anything; the
        // first of those that run as many.
        func breadth(_ runtime: Runtime) -> Int { runtime.supportedDeviceTypes?.count ?? .max }
        if let widest = found.reduce(nil, { (best: Runtime?, next) in best.map { breadth(next) > breadth($0) ? next : $0 } ?? next }) {
            return widest
        }
        throw APIError(error: "no iOS runtime \"\(query)\"; there are: \(runtimes.map(\.name).joined(separator: ", "))", code: "noDevice")
    }

    /// Whether a runtime runs a device type (one that doesn't list what it
    /// runs is taken to run anything).
    static func runs(_ type: DeviceType, on runtime: Runtime) -> Bool {
        runtime.supportedDeviceTypes.map { $0.contains { $0.identifier == type.identifier } } ?? true
    }

    private static func supported(_ type: DeviceType, by runtime: Runtime) throws {
        guard runs(type, on: runtime) else {
            let runnable = (runtime.supportedDeviceTypes ?? []).filter { ["iPhone", "iPad"].contains($0.productFamily ?? "") }
            throw APIError(error: "\(type.name) doesn't run on \(runtime.name); it runs: \(runnable.map(\.name).joined(separator: ", "))",
                           code: "noDevice")
        }
    }

    /// Lowercased, its spaces trimmed and runs of them made one.
    private static func fold(_ string: String) -> String {
        string.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Lowercased words: what's between anything that isn't a letter or a digit.
    private static func words(_ string: String) -> [String] {
        string.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A device's type and runtime by name, from simctl's lists: what a
    /// clone of a base is.
    static func describe(udid: String, on host: SimulatorHost = .local) async -> (device: String?, runtime: String?) {
        guard let device = try? await devices(on: host).first(where: { $0.udid == udid }) else { return (nil, nil) }
        let type = (try? await deviceTypes(on: host))?.first { $0.identifier == device.deviceTypeIdentifier }
        let runtime = (try? await runtimes(on: host))?.first { $0.identifier == device.runtime }
        return (type?.name, runtime?.name)
    }

    static func bases() async -> [Base] {
        (try? await inventory().get()) ?? []
    }

    /// The bases, or why simctl couldn't list them (it failed or timed out:
    /// Xcode mid-update, CoreSimulator waiting on its first launch), which a
    /// lease's refusal says rather than "no ios base".
    static func inventory() async -> Result<[Base], Error> {
        do {
            return .success(try await devices().compactMap { Base(name: $0.name) }.filter { $0.platform == .ios })
        } catch {
            return .failure(error)
        }
    }

    static func simctl(_ arguments: [String], timeout: TimeInterval = 300, on host: SimulatorHost = .local) async throws -> ProcessResult {
        try await host.simctl(arguments, timeout: timeout)
    }

    /// A clone of the base, booted: its UDID.
    static func lease(base: Base, name: String) async throws -> String {
        guard let source = try await devices().first(where: { $0.name == base.name }) else {
            throw APIError(error: "no simulator \(base.name)")
        }
        if source.state != "Shutdown" { _ = try? await simctl(["shutdown", source.udid]) }
        let clone = try await simctl(["clone", source.udid, name])
        let udid = clone.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clone.ok, !udid.isEmpty else { throw APIError(error: "simctl clone: \(clone.error)") }
        let boot = try await simctl(["boot", udid])
        guard boot.ok else { throw APIError(error: "simctl boot: \(boot.error)") }
        let ready = try await simctl(["bootstatus", udid, "-b"], timeout: 600)
        guard ready.ok else { throw APIError(error: "simctl bootstatus: \(ready.error)") }
        return udid
    }

    /// A new simulator of the chosen type on the chosen runtime, set up as
    /// its config's base was (`build`): its first boot, the config's script
    /// with its UDID in OSS_UDID, then (after a script) shut down and
    /// booted again, as a clone of the base boots. Its UDID; nothing is left
    /// of it when this fails.
    ///
    /// On the primary (`host`), a config's script isn't run: it is a script
    /// of the server's Mac, and the primary's simulators have no bases.
    static func create(name: String, choice: Choice, config: String, on host: SimulatorHost = .local) async throws -> String {
        let made = try await simctl(["create", name, choice.deviceType.identifier, choice.runtime.identifier], on: host)
        let udid = made.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard made.ok, !udid.isEmpty else { throw APIError(error: "simctl create: \(made.error)") }
        do {
            try await bootReady(udid, on: host)
            if !host.isPrimary, let script = setupScript(config: config) {
                guard FileManager.default.fileExists(atPath: script) else {
                    throw APIError(error: "\(script), which \(config)'s base was built with, is gone: build the base again "
                                        + "(oss image build ios \(config) …)")
                }
                var environment = ProcessInfo.processInfo.environment
                environment["OSS_UDID"] = udid
                let ran = try await Shell.run("/bin/bash", [script], environment: environment, timeout: 1800)
                guard ran.ok else {
                    throw APIError(error: "\(config)'s setup script \(script) failed (\(ran.status)): "
                                        + String((ran.error.isEmpty ? ran.output : ran.error).suffix(1000)))
                }
                _ = try await simctl(["shutdown", udid], timeout: 120)
                try await bootReady(udid)
            }
            return udid
        } catch {
            await release(udid: udid, on: host)
            throw error
        }
    }

    static func bootReady(_ udid: String, on host: SimulatorHost = .local) async throws {
        let boot = try await simctl(["boot", udid], on: host)
        guard boot.ok else { throw APIError(error: "simctl boot: \(boot.error)") }
        // A new device's first boot sets it up: longer than a clone's.
        let ready = try await simctl(["bootstatus", udid, "-b"], timeout: 900, on: host)
        guard ready.ok else { throw APIError(error: "simctl bootstatus: \(ready.error)") }
    }

    /// A config's setup script, as its base was last built with it
    /// (`image build ios --script`), so a lease of another device type is
    /// set up the same: its path, kept beside the server's files.
    struct Setup: Codable { var script: String }

    static func setupPath(config: String) -> String { "\(Paths.simulators)/\(config).json" }

    static func setupScript(config: String) -> String? {
        guard let data = FileManager.default.contents(atPath: setupPath(config: config)),
              let setup = try? JSONDecoder().decode(Setup.self, from: data) else { return nil }
        return setup.script
    }

    static func release(udid: String, on host: SimulatorHost = .local) async {
        _ = try? await simctl(["shutdown", udid], timeout: 120, on: host)
        _ = try? await simctl(["delete", udid], timeout: 120, on: host)
    }

    /// What a holder may run against its own simulator: the device's UDID
    /// takes the place of `booted`, or follows the subcommand.
    static let allowed: Set<String> = ["install", "uninstall", "launch", "terminate", "openurl", "listapps", "appinfo",
                                       "addmedia", "push", "privacy", "status_bar", "ui", "location", "spawn",
                                       "get_app_container", "keychain", "pbcopy", "pbpaste"]

    /// The status bar held still, as Apple's own screenshots have it: 9:41,
    /// full Wi-Fi and signal, a full battery, no carrier. Every lease starts
    /// so, so screenshots of the same screen match from one run to the next
    /// (`oss machine simctl <id> status_bar clear` gives the live one back).
    /// An iPad's status bar shows the date beside the time: 9:41 on a fixed
    /// day (a Mac's simctl before it took a date gets 9:41 alone).
    /// On the primary as here: its clock's time zone is the server's
    /// (Guest.setTimeZone, when it was handed over), so 9:41 there is 9:41.
    static func holdStatusBarStill(udid: String, on host: SimulatorHost = .local) async {
        if let dated = try? await simctl(statusBarOverride(udid: udid, time: stillTime), timeout: 60, on: host), dated.ok { return }
        _ = try? await simctl(statusBarOverride(udid: udid, time: "9:41"), timeout: 60, on: host)
    }

    /// simctl's arguments for the still status bar at `time`.
    static func statusBarOverride(udid: String, time: String) -> [String] {
        ["status_bar", udid, "override", "--time", time, "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
         "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "", "--batteryState", "charged", "--batteryLevel", "100"]
    }

    /// 9:41 on 9 January 2007 in this Mac's time zone (a simulator's), as
    /// status_bar takes a date: ISO 8601 with its fractional seconds
    /// (`2007-01-09T09:41:00.000-08:00`; without them it's refused).
    static var stillTime: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2007, month: 1, day: 9, hour: 9, minute: 41)) ?? Date(timeIntervalSince1970: 0)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func run(_ arguments: [String], udid: String, on host: SimulatorHost = .local) async throws -> ProcessResult {
        try await simctl(try holderArguments(arguments, udid: udid), on: host)
    }

    /// A holder's simctl arguments against its own simulator: its command
    /// one of `allowed`, the UDID in place of `booted` or after the command.
    static func holderArguments(_ arguments: [String], udid: String) throws -> [String] {
        guard let command = arguments.first, allowed.contains(command) else {
            throw APIError(error: "simctl \(arguments.first ?? ""): not allowed (allowed: \(allowed.sorted().joined(separator: ", ")))")
        }
        var rest = Array(arguments.dropFirst())
        if let booted = rest.firstIndex(of: "booted") { rest[booted] = udid } else { rest.insert(udid, at: 0) }
        return [command] + rest
    }

    /// A device's screen scale (pixels a point), from its device type's
    /// profile: what turns a screenshot's pixels into the points input takes.
    /// Its `profile.plist`'s `mainScreenScale` where it has one, else its
    /// `capabilities.plist`'s main screen's (Xcode 27's types have only that:
    /// an iPad's 2, not the 3 taken where neither says). Kept by UDID: a
    /// device's scale never changes.
    static func screenScale(udid: String, on host: SimulatorHost = .local) async throws -> Double {
        if let known = scales.withLock({ $0[udid] }) { return known }
        guard let type = try await devices(on: host).first(where: { $0.udid == udid })?.deviceTypeIdentifier else {
            throw APIError(error: "no simulator \(udid)")
        }
        struct Types: Decodable { var devicetypes: [DeviceType] }
        struct DeviceType: Decodable { var identifier: String; var bundlePath: String? }
        let listed = try await host.simctl(["list", "devicetypes", "-j"], timeout: 60)
        let types = try JSONDecoder().decode(Types.self, from: Data(listed.output.utf8)).devicetypes
        guard let bundle = types.first(where: { $0.identifier == type })?.bundlePath else { return 3 }
        var scale: Double?
        if host.isPrimary {
            let read = try await host.run("/bin/sh", ["-c", scaleScript, "sh", bundle], timeout: 60)
            scale = Double(read.output.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            let profile = NSDictionary(contentsOfFile: "\(bundle)/Contents/Resources/profile.plist")
            let capabilities = NSDictionary(contentsOfFile: "\(bundle)/Contents/Resources/capabilities.plist")
            let screen = (capabilities?["capabilities"] as? NSDictionary)?["ScreenDimensionsCapability"] as? NSDictionary
            scale = ((profile?["mainScreenScale"] ?? screen?["main-screen-scale"]) as? NSNumber)?.doubleValue
        }
        guard let scale, scale > 0 else { return 3 }
        scales.withLock { $0[udid] = scale }
        return scale
    }

    private static let scales = Locked<[String: Double]>([:])

    /// The scale read on the primary, as `screenScale` reads it here: its
    /// device type's bundle is `$1`.
    static let scaleScript = """
        plutil -extract mainScreenScale raw -o - "$1/Contents/Resources/profile.plist" 2>/dev/null \\
          || plutil -extract capabilities.ScreenDimensionsCapability.main-screen-scale raw -o - "$1/Contents/Resources/capabilities.plist"
        """

    static func screenshot(udid: String, on host: SimulatorHost = .local) async throws -> Data {
        if host.isPrimary {
            // Written on the primary, its bytes back on SSH's standard output (simctl's notes on its error).
            let path = "/tmp/oss-sim-\(Random.hex(4)).png"
            let result = try await host.run("/bin/sh", ["-c", screenshotScript, "sh", udid, path], timeout: 60)
            guard result.ok, !result.data.isEmpty else { throw APIError(error: "simctl io screenshot: \(result.error)") }
            return result.data
        }
        let path = NSTemporaryDirectory() + "oss-sim-\(Random.hex(4)).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // The corners and the Dynamic Island masked black: a fresh simulator
        // draws the island and another doesn't, so unmasked shots of one screen
        // differ there from run to run.
        let result = try await simctl(["io", udid, "screenshot", "--mask=black", path], timeout: 60)
        guard result.ok, let data = FileManager.default.contents(atPath: path) else {
            throw APIError(error: "simctl io screenshot: \(result.error)")
        }
        return data
    }

    /// A screenshot on the primary (`$1` the UDID, `$2` a file of its
    /// /tmp): masked as here, written there, its bytes on standard output,
    /// the file deleted.
    static let screenshotScript = """
        /usr/bin/xcrun simctl io "$1" screenshot --mask=black "$2" 1>&2 && cat "$2"; s=$?; rm -f "$2"; exit $s
        """

    /// A base made: a new simulator of that device type and runtime, booted
    /// once (its first boot's setup done), `script` run with its UDID in
    /// OSS_UDID (install apps, change settings), shut down.
    static func build(config: String, deviceType: String, runtime: String?, script: String?) async throws {
        let name = Base(platform: .ios, config: config).name
        if let old = try await devices().first(where: { $0.name == name }) {
            log("replacing the previous \(name)")
            _ = try? await simctl(["shutdown", old.udid])
            _ = try await simctl(["delete", old.udid])
        }
        var create = ["create", name, deviceType]
        if let runtime { create.append(runtime) }
        let made = try await simctl(create)
        let udid = made.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard made.ok, !udid.isEmpty else { throw ShellError(description: "simctl create: \(made.error)") }
        log("\(name) is \(udid); its first boot")
        _ = try await simctl(["boot", udid])
        _ = try await simctl(["bootstatus", udid, "-b"], timeout: 900)
        if let script {
            log("running \(script)")
            var environment = ProcessInfo.processInfo.environment
            environment["OSS_UDID"] = udid
            // Shell.run, not passthrough: a minute's script mustn't hold one of Swift's cooperative threads.
            let run = try await Shell.run("/bin/bash", [script], environment: environment)
            log(run.output + run.error)
            guard run.ok else { throw ShellError(description: "\(script) failed (\(run.status)); \(name) is left booted for a look") }
        }
        // Its script kept by path, for a lease of another device type (`create`).
        Paths.ensure(Paths.simulators)
        if let script {
            let path = URL(fileURLWithPath: script).standardizedFileURL.path
            try JSONEncoder.oss.encode(Setup(script: path)).write(to: URL(fileURLWithPath: setupPath(config: config)))
        } else {
            try? FileManager.default.removeItem(atPath: setupPath(config: config))
        }
        _ = try await simctl(["shutdown", udid])
        log("\(name) is ready")
    }
}

/// A value behind a lock, read and changed from any thread.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Where a lease's simulator runs (docs/primary-vms.md, "iOS: simulators in
/// the primary"): the server's Mac, or the primary macOS VM, as its guest
/// user (`runner`, an administrator, whose GUI session is logged in) over
/// SSH. simctl needs no GUI session there: create, boot (headless), install,
/// launch, `io screenshot`, `io recordVideo`, status_bar and AXe's input all
/// run from SSH's (checked on an xcode_27_2 clone, 2026-11-03).
struct SimulatorHost: Sendable {
    /// The primary; nil: this Mac.
    var guest: Guest?

    static let local = SimulatorHost(guest: nil)

    var isPrimary: Bool { guest != nil }

    /// The primary's command line for a program and its arguments: each a
    /// single-quoted word (SlotCommand.quote), read by the guest user's
    /// login shell as given.
    static func remoteLine(_ program: String, _ arguments: [String]) -> String {
        SlotCommand.words([program] + arguments)
    }

    /// A program run to its end: here, or on the primary by SSH (its
    /// output, error and status SSH's, which are the program's).
    func run(_ program: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval) async throws -> ProcessResult {
        guard let guest else { return try await Shell.run(program, arguments, input: input, timeout: timeout) }
        return try await Shell.run("/usr/bin/ssh", guest.sshArguments(Self.remoteLine(program, arguments)), input: input, timeout: timeout)
    }

    func simctl(_ arguments: [String], timeout: TimeInterval = 300) async throws -> ProcessResult {
        try await run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: timeout)
    }

    /// simctl with `environment` (SimulatorFiles.childEnvironment's
    /// `SIMCTL_CHILD_` names, which simctl hands the app it launches without
    /// the prefix): here in its process's environment, on the primary by
    /// `env` on SSH's command line (`primaryInvocation`).
    func simctl(_ arguments: [String], environment: [String: String], timeout: TimeInterval = 300) async throws -> ProcessResult {
        guard !environment.isEmpty else { return try await simctl(arguments, timeout: timeout) }
        guard let guest else {
            let merged = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            return try await Shell.run("/usr/bin/xcrun", ["simctl"] + arguments, environment: merged, timeout: timeout)
        }
        let (program, words) = Self.primaryInvocation(arguments, environment: environment)
        return try await Shell.run("/usr/bin/ssh", guest.sshArguments(Self.remoteLine(program, words)), timeout: timeout)
    }

    /// The program and arguments simctl runs as on the primary with an
    /// environment: `/usr/bin/env NAME=value… /usr/bin/xcrun simctl …`, the
    /// names sorted, each word quoted by `remoteLine`.
    static func primaryInvocation(_ arguments: [String], environment: [String: String]) -> (String, [String]) {
        guard !environment.isEmpty else { return ("/usr/bin/xcrun", ["simctl"] + arguments) }
        let assignments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return ("/usr/bin/env", assignments + ["/usr/bin/xcrun", "simctl"] + arguments)
    }
}

/// An iOS lease's files (API 20): a folder of its own on the machine its
/// simulator runs on, where `oss machine upload` puts them (`PUT
/// /v1/machines/<id>/files?path=…`, as a container's) and `@name` in a
/// simctl argument or environment value names them. On the primary it is
/// `/Users/Shared/oss-ios/<id>/files` (the guest user's, which runs the
/// simulator); on the server's Mac the lease's uploads. Both go at release.
enum SimulatorFiles {
    /// The lease's folder: on the primary, or this Mac's (`uploads`).
    static func root(lease: String, inPrimary: Bool, uploads: String = Paths.uploads) -> String {
        inPrimary ? "\(PrimarySimulators.folder(lease))/files" : "\(uploads)/\(lease)"
    }

    /// A path the holder gives, under `root`: relative to it (`ctl.json`,
    /// `runs/1/ctl.json`). Absolute, `~`, `..` and nothing at all are refused.
    static func resolve(_ path: String, root: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !path.isEmpty, path.count <= 4096, !path.contains("\0"), !path.hasPrefix("/"), !path.hasPrefix("~"),
              !parts.isEmpty, !parts.contains("..") else {
            throw APIError(error: "an iOS lease's file is a path in its own folder (ctl.json, runs/ctl.json): not \(path)")
        }
        return root + "/" + parts.joined(separator: "/")
    }

    /// `@name` arguments (the lease's files) as paths under `root`, with the
    /// names they took (each once); other arguments as given.
    static func mapNames(_ arguments: [String], root: String) throws -> (arguments: [String], files: [String]) {
        var files: [String] = []
        let mapped = try arguments.map { argument -> String in
            guard argument.hasPrefix("@"), argument.count > 1 else { return argument }
            let name = String(argument.dropFirst())
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
                throw APIError(error: "\(argument): a file of the lease's own folder, by its name")
            }
            if !files.contains(name) { files.append(name) }
            return try resolve(name, root: root)
        }
        return (mapped, files)
    }

    /// A launch's environment for simctl: each name prefixed
    /// `SIMCTL_CHILD_` (one that has it already kept so), a value that is
    /// `@name` the path of that file of the lease's; with the names of the
    /// files it took. A name is a shell's (SlotCommand.validName); no NUL.
    static func childEnvironment(_ environment: [String: String], root: String) throws -> (environment: [String: String], files: [String]) {
        var result: [String: String] = [:]
        var files: [String] = []
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard SlotCommand.validName(name) else { throw APIError(error: "an environment variable's name is letters, digits and _: not \(name)") }
            guard !value.contains("\0") else { throw APIError(error: "\(name)'s value can't hold a NUL") }
            let (mapped, taken) = try mapNames([value], root: root)
            for file in taken where !files.contains(file) { files.append(file) }
            result[name.hasPrefix(childPrefix) ? name : childPrefix + name] = mapped[0]
        }
        return (result, files)
    }

    static let childPrefix = "SIMCTL_CHILD_"

    /// The simctl commands an environment is for: those that start a process.
    static let takesEnvironment: Set<String> = ["launch", "spawn"]
}

/// The primary's simulators: what an `ios` lease is there, and the files
/// and tools it takes there.
enum PrimarySimulators {
    /// Where a lease's files are on the primary (its uploads, installs and
    /// test runs), the guest user's: deleted with the simulator.
    static func folder(_ lease: String) -> String { "/Users/Shared/oss-ios/\(lease)" }

    /// The device type and runtime of a lease that asks for neither: the
    /// newest iOS runtime that runs `device` (server.json's
    /// `primary.macos.simulatorDevice`, the server's own base's type until
    /// now), else the newest; and that device, else that runtime's first
    /// iPhone. Asked for (`device`, `runtime`), as on this Mac
    /// (Simulators.pick), with the defaults standing in for the base's.
    static func choose(device: String?, runtime: String?, preferred: String, types: [Simulators.DeviceType],
                       runtimes: [Simulators.Runtime]) throws -> Simulators.Choice {
        let ios = runtimes.filter { $0.isAvailable != false && ($0.platform == "iOS" || $0.identifier.contains(".SimRuntime.iOS-")) }
        let preferredType = types.first { $0.name == preferred || $0.identifier == preferred }
        // Newest first: by version, then the one that runs the most types (Xcode 27.2's
        // runtime of one device type beside its version's own).
        func newer(_ a: Simulators.Runtime, _ b: Simulators.Runtime) -> Bool {
            let (va, vb) = (versionParts(a.version), versionParts(b.version))
            if va != vb { return va.lexicographicallyPrecedes(vb) == false }
            return (a.supportedDeviceTypes?.count ?? .max) > (b.supportedDeviceTypes?.count ?? .max)
        }
        let newest = ios.sorted(by: newer)
        let baseRuntime = (preferredType.flatMap { type in newest.first { Simulators.runs(type, on: $0) } } ?? newest.first)
        let baseType = preferredType.flatMap { type in baseRuntime.map { Simulators.runs(type, on: $0) } == true ? type : nil }
            ?? baseRuntime.flatMap { runtime in types.first { $0.productFamily == "iPhone" && Simulators.runs($0, on: runtime) } }
        return try Simulators.pick(device: device, runtime: runtime, baseType: baseType?.identifier, baseRuntime: baseRuntime?.identifier,
                                   types: types, runtimes: runtimes)
    }

    private static func versionParts(_ version: String?) -> [Int] {
        (version ?? "").split(separator: ".").map { Int($0) ?? 0 }
    }

    /// A holder's `@name` arguments (its uploads on the server's Mac) as
    /// the primary has them: under the lease's folder there, each one's
    /// path. Arguments that aren't `@name` are as given. A name that climbs
    /// out (`..`) or is absolute is refused: only the lease's own uploads go.
    static func remoteArguments(_ arguments: [String], lease: String) throws -> (arguments: [String], files: [String]) {
        try SimulatorFiles.mapNames(arguments, root: SimulatorFiles.root(lease: lease, inPrimary: true))
    }

    /// The command line that unpacks a tarball (on standard input) into a
    /// folder on the primary, made first: the files of a command, an app to
    /// install, a test run's folder.
    static func untarLine(into directory: String) -> String {
        "mkdir -p \(SlotCommand.quote(directory)) && tar -xzf - -C \(SlotCommand.quote(directory))"
    }

    /// Files and folders of this Mac's `directory` sent into the primary's
    /// `remote` (tar over SSH, made there first).
    static func send(_ names: [String], from directory: String, to remote: String, guest: Guest, timeout: TimeInterval = 1800) async throws {
        guard !names.isEmpty else { return }
        let sent = try await Shell.run("/bin/bash", ["-c", "set -o pipefail; cd \"$1\" && tar -cz -- \"${@:3:$2}\" | /usr/bin/ssh \"${@:$(($2 + 3))}\"",
                                                     "bash", directory, String(names.count)] + names
                                        + guest.sshArguments(untarLine(into: remote)), timeout: timeout)
        guard sent.ok else { throw APIError(error: "copying to the primary: \(sent.error.suffix(300))") }
    }

    /// The lease's folder and simulator gone from the primary: what release
    /// and a sweep run there.
    static func deleteLine(lease: String, udid: String?) -> String {
        var lines: [String] = []
        if let udid {
            let quoted = SlotCommand.quote(udid)
            lines += ["/usr/bin/xcrun simctl shutdown \(quoted) >/dev/null 2>&1", "/usr/bin/xcrun simctl delete \(quoted) >/dev/null 2>&1"]
        }
        lines.append("rm -rf \(SlotCommand.quote(folder(lease)))")
        return lines.joined(separator: "; ") + "; exit 0"
    }

    /// The primary's simulators no lease holds: named as a lease's
    /// (`oss-lease-ios-…`), but not one of `held`'s names.
    static func strays(_ devices: [Simulators.Device], held names: Set<String>) -> [Simulators.Device] {
        devices.filter { $0.name.hasPrefix("oss-lease-ios-") && !names.contains($0.name) }
    }

    // MARK: AXe on the primary

    /// Where AXe is on the primary: the server's own copy (OS Server.app's
    /// Helpers/axe, its frameworks beside it), sent there at its first use
    /// and again when the server's changes, kept in the guest user's home.
    static let axeFolder = ".oss/axe"

    /// The primary's AXe is this one (its executable's size and time here):
    /// written beside it there, and checked before each input.
    static func axeStamp(_ executable: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return "\(size)-\(Int(date.timeIntervalSince1970))"
    }

    /// AXe's own folder on this Mac (Helpers/axe: the executable and its Frameworks).
    static func axeDirectory(_ executable: String) -> String {
        URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent().path
    }

    /// The command line that says whether the primary's AXe is `stamp`'s.
    static func axeCheckLine(stamp: String) -> String {
        "test \"$(cat \(axeFolder)/stamp 2>/dev/null)\" = \(SlotCommand.quote(stamp)) && test -x \(axeFolder)/axe"
    }

    /// The command line that takes AXe's folder (a tarball on standard
    /// input) in place of the last, its stamp written last.
    static func axeInstallLine(stamp: String) -> String {
        "rm -rf \(axeFolder) && mkdir -p \(axeFolder) && tar -xzf - -C \(axeFolder) && echo \(SlotCommand.quote(stamp)) > \(axeFolder)/stamp"
    }
}
