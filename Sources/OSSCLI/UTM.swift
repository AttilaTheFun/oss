import Foundation
import OSSClient

/// UTM, driven by its own `utmctl` and, for what that lacks (a VM's
/// settings), its AppleScript dictionary. Both are Apple Events to UTM.app:
/// the process running oss needs Automation permission for UTM once.
enum UTM {
    static let utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"

    struct VM: Sendable {
        var uuid: String
        var status: String
        var name: String
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// UTM can stall for a minute or two around a big operation: each call
    /// waits up to three minutes, and is tried again once.
    static func list() async throws -> [VM] {
        var result = try await Shell.run(utmctl, ["list"], timeout: 180)
        if !result.ok { result = try await Shell.run(utmctl, ["list"], timeout: 180) }
        guard result.ok else { throw Failure(description: "utmctl list: \(result.status) \(result.error)\(result.output)") }
        return result.output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 3 else { return nil }
            return VM(uuid: parts[0], status: parts[1], name: parts[2].trimmingCharacters(in: .whitespaces))
        }
    }

    static func vm(named name: String) async throws -> VM? {
        try await list().first { $0.name == name }
    }

    /// utmctl prints "OSStatus error -10004" for some commands that succeed
    /// (--hide's window event), so each change is checked by its outcome.
    @discardableResult
    static func ctl(_ arguments: [String], timeout: TimeInterval = 300) async throws -> ProcessResult {
        try await Shell.run(utmctl, arguments, timeout: timeout)
    }

    static func clone(_ source: String, as name: String) async throws {
        let result = try await ctl(["clone", "--hide", source, "--name", name])
        guard try await vm(named: name) != nil else {
            throw Failure(description: "clone of \(source) as \(name) failed: \(result.error)\(result.output)")
        }
    }

    static func start(_ name: String, extra: [String] = [], input: Data? = nil) async throws {
        let result = try await Shell.run(utmctl, ["start", "--hide", name] + extra, input: input, timeout: 300)
        for _ in 0..<30 {
            if try await vm(named: name)?.status == "started" { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw Failure(description: "\(name) did not start: \(result.error)\(result.output)")
    }

    /// Power off (the guest is thrown away, so no shutdown is waited for).
    static func stop(_ name: String) async throws {
        _ = try await ctl(["stop", "--hide", name, "--force"])
        for _ in 0..<30 {
            guard let vm = try await vm(named: name), vm.status != "stopped" else { return }
            try await Task.sleep(for: .seconds(2))
        }
        _ = try await ctl(["stop", "--hide", name, "--kill"])
    }

    static func delete(_ name: String) async throws {
        _ = try await ctl(["delete", "--hide", name])
        if try await vm(named: name) != nil { throw Failure(description: "\(name) was not deleted") }
    }

    /// The address macOS's DHCP server (bootpd, behind UTM's shared network)
    /// gave this MAC: known as soon as the guest asks, whatever its agent does.
    static func addressFromDHCP(_ mac: String) -> String? {
        func normal(_ mac: Substring) -> [Int] { mac.split(separator: ":").compactMap { Int($0, radix: 16) } }
        let wanted = normal(Substring(mac))
        guard let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        var address: String?
        var newest = -1
        for entry in text.components(separatedBy: "}") {
            var ip: String?, hw: [Int] = [], lease = 0
            for line in entry.split(separator: "\n") {
                let field = line.trimmingCharacters(in: .whitespaces)
                if field.hasPrefix("ip_address=") { ip = String(field.dropFirst(11)) }
                if field.hasPrefix("hw_address=1,") { hw = normal(field.dropFirst(13)[...]) }
                if field.hasPrefix("lease=0x") { lease = Int(field.dropFirst(8), radix: 16) ?? 0 }
            }
            if hw == wanted, let ip, lease > newest { address = ip; newest = lease }
        }
        return address
    }

    /// The guest's IPv4 address, as its agent (or Apple's framework) reports it.
    static func ipAddress(_ name: String) async throws -> String? {
        let result = try await ctl(["ip-address", "--hide", name], timeout: 90)
        return result.output.split(separator: "\n").map(String.init)
            .first { $0.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
    }

    /// AppleScript to UTM; `arguments` arrive as `item n of argv` (never
    /// pasted into the script's text).
    /// UTM can answer a VM it has only just made with -600 or -1728 for a
    /// moment, or time out while busy (-1712): those are tried again.
    static func script(_ source: String, _ arguments: [String] = [], timeout: TimeInterval = 120) async throws -> String {
        var last = ""
        for attempt in 1...5 {
            let result = try await Shell.run("/usr/bin/osascript", ["-"] + arguments, input: Data(source.utf8), timeout: timeout)
            if result.ok { return result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            last = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["(-600)", "(-1728)", "(-1712)"].contains(where: { last.contains($0) }), attempt < 5 else { break }
            try await Task.sleep(for: .seconds(3))
        }
        throw Failure(description: "AppleScript: \(last)")
    }

    /// Changes a stopped VM's settings: `edit` is AppleScript run on its
    /// configuration record, `config` (UTM's records can only be changed
    /// outside its `tell` block), with `item n of argv` the arguments after
    /// the VM's name.
    static func configure(_ name: String, _ edit: String, _ arguments: [String] = []) async throws {
        _ = try await script("""
            on run argv
              tell application "UTM"
                set vm to virtual machine named (item 1 of argv)
                set config to configuration of vm
              end tell
              using terms from application "UTM"
            \(edit)
              end using terms from
              tell application "UTM" to update configuration of vm with config
            end run
            """, [name] + arguments)
    }

    /// Gives a stopped VM's network card this MAC address, so its clone gets
    /// an address of its own from UTM's DHCP server.
    static func setMAC(_ name: String, _ mac: String) async throws {
        try await configure(name, """
                set card to item 1 of (network interfaces of config)
                set address of card to (item 2 of argv)
                set network interfaces of config to {card}
            """, [mac])
    }

    /// QEMU's own VNC server for a stopped QEMU VM: its screen on this Mac's
    /// loopback at `port`. Without a password: UTM's QEMU has no DES for
    /// VNC's; the forwarder asks the client for the lease's instead.
    static func setQEMUVNC(_ name: String, port: Int?) async throws {
        if let port {
            try await configure(name, """
                    set qemu additional arguments of config to {{argument string:"-vnc"}, {argument string:("127.0.0.1:" & (item 2 of argv))}}
                """, [String(port - 5900)])
        } else {
            try await configure(name, """
                    set qemu additional arguments of config to {}
                """)
        }
    }

    /// Renames a stopped VM.
    static func rename(_ name: String, to newName: String) async throws {
        try await configure(name, """
                set name of config to (item 2 of argv)
            """, [newName])
    }
}
