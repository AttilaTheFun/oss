import Foundation
import OSSClient

/// iOS simulators on the server's Mac. A base is a shut-down simulator
/// named `oss-ios-<config>`, set up once (apps installed, settings made,
/// booted and shut down so it starts quickly); a lease is `simctl clone`
/// of it (an APFS clone of the device's directory: seconds, no disk until
/// it changes), booted, and deleted when the lease ends.
enum Simulators {
    struct Device: Decodable { var udid: String; var name: String; var state: String; var deviceTypeIdentifier: String? }

    static func devices() async throws -> [Device] {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 60)
        guard result.ok else { throw ShellError(description: "simctl list: \(result.error)") }
        struct List: Decodable { var devices: [String: [Device]] }
        let list = try JSONDecoder().decode(List.self, from: Data(result.output.utf8))
        return list.devices.values.flatMap { $0 }
    }

    static func bases() async -> [Base] {
        ((try? await devices()) ?? []).compactMap { Base(name: $0.name) }.filter { $0.platform == .ios }
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

    static func release(udid: String) async {
        _ = try? await simctl(["shutdown", udid], timeout: 120)
        _ = try? await simctl(["delete", udid], timeout: 120)
    }

    /// What a holder may run against its own simulator: the device's UDID
    /// takes the place of `booted`, or follows the subcommand.
    static let allowed: Set<String> = ["install", "uninstall", "launch", "terminate", "openurl", "listapps", "appinfo",
                                       "addmedia", "push", "privacy", "status_bar", "ui", "location", "spawn",
                                       "get_app_container", "keychain", "pbcopy", "pbpaste"]

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
        let result = try await simctl(["io", udid, "screenshot", path], timeout: 60)
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
        _ = try await simctl(["shutdown", udid])
        log("\(name) is ready")
    }
}
