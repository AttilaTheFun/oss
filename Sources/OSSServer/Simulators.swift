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

    static func devices() async throws -> [Device] {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 60)
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

    static func deviceTypes() async throws -> [DeviceType] {
        struct List: Decodable { var devicetypes: [DeviceType] }
        let listed = try await simctl(["list", "devicetypes", "-j"], timeout: 60)
        guard listed.ok else { throw ShellError(description: "simctl list devicetypes: \(listed.error)") }
        return try JSONDecoder().decode(List.self, from: Data(listed.output.utf8)).devicetypes
    }

    static func runtimes() async throws -> [Runtime] {
        struct List: Decodable { var runtimes: [Runtime] }
        let listed = try await simctl(["list", "runtimes", "-j"], timeout: 60)
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
    static func describe(udid: String) async -> (device: String?, runtime: String?) {
        guard let device = try? await devices().first(where: { $0.udid == udid }) else { return (nil, nil) }
        let type = (try? await deviceTypes())?.first { $0.identifier == device.deviceTypeIdentifier }
        let runtime = (try? await runtimes())?.first { $0.identifier == device.runtime }
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

    static func simctl(_ arguments: [String], timeout: TimeInterval = 300) async throws -> ProcessResult {
        try await Shell.run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: timeout)
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
    static func create(name: String, choice: Choice, config: String) async throws -> String {
        let made = try await simctl(["create", name, choice.deviceType.identifier, choice.runtime.identifier])
        let udid = made.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard made.ok, !udid.isEmpty else { throw APIError(error: "simctl create: \(made.error)") }
        do {
            try await bootReady(udid)
            if let script = setupScript(config: config) {
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
            await release(udid: udid)
            throw error
        }
    }

    private static func bootReady(_ udid: String) async throws {
        let boot = try await simctl(["boot", udid])
        guard boot.ok else { throw APIError(error: "simctl boot: \(boot.error)") }
        // A new device's first boot sets it up: longer than a clone's.
        let ready = try await simctl(["bootstatus", udid, "-b"], timeout: 900)
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

    static func release(udid: String) async {
        _ = try? await simctl(["shutdown", udid], timeout: 120)
        _ = try? await simctl(["delete", udid], timeout: 120)
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
    static func holdStatusBarStill(udid: String) async {
        let rest = ["--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
                    "--operatorName", "", "--batteryState", "charged", "--batteryLevel", "100"]
        if let dated = try? await simctl(["status_bar", udid, "override", "--time", stillTime] + rest, timeout: 60), dated.ok { return }
        _ = try? await simctl(["status_bar", udid, "override", "--time", "9:41"] + rest, timeout: 60)
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

    static func run(_ arguments: [String], udid: String) async throws -> ProcessResult {
        guard let command = arguments.first, allowed.contains(command) else {
            throw APIError(error: "simctl \(arguments.first ?? ""): not allowed (allowed: \(allowed.sorted().joined(separator: ", ")))")
        }
        var rest = Array(arguments.dropFirst())
        if let booted = rest.firstIndex(of: "booted") { rest[booted] = udid } else { rest.insert(udid, at: 0) }
        return try await simctl([command] + rest)
    }

    /// A device's screen scale (pixels a point), from its device type's
    /// profile: what turns a screenshot's pixels into the points input takes.
    static func screenScale(udid: String) async throws -> Double {
        guard let type = try await devices().first(where: { $0.udid == udid })?.deviceTypeIdentifier else {
            throw APIError(error: "no simulator \(udid)")
        }
        struct Types: Decodable { var devicetypes: [DeviceType] }
        struct DeviceType: Decodable { var identifier: String; var bundlePath: String? }
        let listed = try await simctl(["list", "devicetypes", "-j"], timeout: 60)
        let types = try JSONDecoder().decode(Types.self, from: Data(listed.output.utf8)).devicetypes
        guard let bundle = types.first(where: { $0.identifier == type })?.bundlePath,
              let profile = NSDictionary(contentsOfFile: "\(bundle)/Contents/Resources/profile.plist"),
              let scale = (profile["mainScreenScale"] as? NSNumber)?.doubleValue, scale > 0 else { return 3 }
        return scale
    }

    static func screenshot(udid: String) async throws -> Data {
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
            let status = try Shell.passthrough("/bin/bash", [script], environment: environment)
            guard status == 0 else { throw ShellError(description: "\(script) failed (\(status)); \(name) is left booted for a look") }
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
