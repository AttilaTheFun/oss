import Foundation
import OSSClient

/// VM bases, built a layer at a time on the server's Mac (local commands,
/// not the API): `oss image build <platform> <layer> --from <base layer>`
/// clones `oss-<platform>-<base>`, copies in what `--copy` names, runs a
/// script in it over SSH (`--script`, or `provision/<platform>/<layer>` for
/// the layers oss makes itself), shuts it down and names it
/// `oss-<platform>-<layer>` (the previous one deleted).
enum Images {
    static func build(platform: Platform, layer: String, from base: String, script: String?, copies: [(String, String)],
                      repo: String) async throws {
        let config = ServerConfig.load()
        let source = "oss-\(platform.rawValue)-\(base)"
        let target = "oss-\(platform.rawValue)-\(layer)"
        let work = "build-\(platform.rawValue)-\(layer)-\(Random.hex(3))"
        let ext = platform == .windows ? "ps1" : "sh"
        let scriptPath = script ?? "\(repo)/provision/\(platform.rawValue)/\(layer).\(ext)"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw ShellError(description: "no script \(scriptPath): give the layer's with --script")
        }
        #if canImport(Virtualization)
        if platform == .macos, MacVMStore.hasBase(base) {
            return try await buildMac(layer: layer, from: base, scriptPath: scriptPath, copies: copies, config: config)
        }
        #endif
        guard try await UTM.vm(named: source) != nil else { throw ShellError(description: "no image \(source)") }

        log("building \(target): \(source) cloned as \(work)")
        try await UTM.clone(source, as: work)
        try await UTM.setMAC(work, Random.mac())
        do {
            try await UTM.start(work)
            let guest = try await reach(work, platform: platform, config: config)
            try await runLayer(scriptPath, copies: copies, in: guest, named: work, platform: platform, config: config)
            if platform == .windows {
                // Settled before it's sealed: a restart, runner's first sign-in
                // since the layer (Active Setup), and the devices set up. A clone
                // of an unsettled image does all that at its own boot, for minutes.
                log("restarting \(work) to settle it")
                _ = try? await guest.run("Restart-Computer -Force", timeout: 60)
                try await Task.sleep(for: .seconds(30))
                guard await guest.waitUntilReachable(seconds: 600), await guest.waitForDesktop(seconds: 600) else {
                    throw ShellError(description: "\(work) didn't come back after its restart")
                }
                try await Task.sleep(for: .seconds(60))
            }
            try await seal(work, guest: guest, platform: platform)
        } catch {
            log("\(error)")
            throw error
        }
        if try await UTM.vm(named: target) != nil {
            log("replacing the previous \(target)")
            try await UTM.delete(target)
        }
        try await UTM.rename(work, to: target)
        log("\(target) is ready")
    }

    /// The layer's copies and script, in a running guest.
    static func runLayer(_ scriptPath: String, copies: [(String, String)], in guest: Guest, named work: String,
                         platform: Platform, config: ServerConfig) async throws {
        for (host, guestPath) in copies { try await copy(host, to: guestPath, guest: guest, platform: platform) }
        try await upload(scriptPath, to: guest, platform: platform)
        log("running \(URL(fileURLWithPath: scriptPath).lastPathComponent) in \(work) (\(guest.address))")
        let run = platform == .windows
            ? "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\\(config.guestUser)\\layer.ps1"
            : "bash ~/layer.sh"
        // The guest's password, when given (a base image's first sudo,
        // Windows' auto-login), goes on standard input, never a command line.
        let password = ProcessInfo.processInfo.environment["OSS_GUEST_PASSWORD"]
        let remote = platform == .windows ? run
            : (password == nil ? "" : "IFS= read -r pw; printf '%s\\n' \"$pw\" | sudo -S -p '' -v; ") + run
        let result = try await Shell.run("/usr/bin/ssh", sshOptions(config) + ["\(config.guestUser)@\(guest.address)", remote],
                                         input: password.map { Data(($0 + "\n").utf8) }, timeout: 4 * 3600)
        print(result.output, terminator: "")
        FileHandle.standardError.write(Data(result.error.utf8))
        guard result.ok else { throw ShellError(description: "the layer's script failed (\(result.status)); \(work) is kept for a look") }
    }

    #if canImport(Virtualization)
    /// A layer on one of OS Server's own macOS bases: the base cloned and
    /// started here, the layer run in it, shut down from inside, and put in
    /// the layer's place (the previous one deleted).
    static func buildMac(layer: String, from base: String, scriptPath: String, copies: [(String, String)],
                         config: ServerConfig) async throws {
        let work = "build-macos-\(layer)-\(Random.hex(3))"
        let path = "\(MacVMStore.bases)/\(work).building"
        log("building macOS \(layer): \(base) cloned as \(work)")
        let vm = try await MacVMs.startClone(of: base, as: work, at: path)
        do {
            let address = try await MacVMs.address(of: vm.spec.mac, seconds: 300)
            let guest = Guest(platform: .macos, address: address, user: config.guestUser, key: config.managementKey)
            guard await guest.waitUntilReachable(seconds: 300) else { throw ShellError(description: "\(work) at \(address): no SSH") }
            try await runLayer(scriptPath, copies: copies, in: guest, named: work, platform: .macos, config: config)
            try await MacVMs.seal(vm, guest: guest)
        } catch {
            await vm.stop()
            log("\(error)")
            throw error
        }
        var spec = try MacMachineSpec.load(path)
        spec.origin = base
        try spec.save(path)
        MacVMStore.remove(MacVMStore.basePath(layer))
        try FileManager.default.moveItem(atPath: path, toPath: MacVMStore.basePath(layer))
        log("macOS \(layer) is ready")
    }
    #endif

    /// A file or directory of the server's Mac copied into the guest
    /// (rsync over SSH; on macOS and Linux owned by root once it's there, the
    /// way an installed application is). A layer that needs this Mac's Xcode
    /// copies /Applications/Xcode.app (Apple's licence lets it run in a VM on
    /// the same Mac).
    static func copy(_ host: String, to guestPath: String, guest: Guest, platform: Platform) async throws {
        let config = ServerConfig.load()
        log("copying \(host) into the guest's \(guestPath)")
        var source = host
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: host, isDirectory: &directory), directory.boolValue, !source.hasSuffix("/") { source += "/" }
        if platform != .windows {
            _ = try await guest.run("sudo mkdir -p '\(guestPath)' && sudo chown -R \(config.guestUser) '\(guestPath)'")
        }
        let rsync = try await Shell.run("/usr/bin/rsync", ["-a", "--delete", "-e", "/usr/bin/ssh " + sshOptions(config).joined(separator: " "),
                                                           source, "\(config.guestUser)@\(guest.address):\(guestPath)"],
                                        timeout: 7200)
        guard rsync.ok else { throw ShellError(description: "copying \(host): \(rsync.error)") }
        if platform == .macos { _ = try await guest.run("sudo chown -R root:wheel '\(guestPath)'") }
        if platform == .linux { _ = try await guest.run("sudo chown -R root:root '\(guestPath)'") }
    }

    static func sshOptions(_ config: ServerConfig) -> [String] {
        ["-i", config.managementKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR",
         "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
    }

    static func reach(_ vm: String, platform: Platform, config: ServerConfig) async throws -> Guest {
        var address: String?
        for _ in 0..<120 where address == nil {
            address = try? await UTM.ipAddress(vm)
            if address == nil { try await Task.sleep(for: .seconds(2)) }
        }
        guard let address else { throw ShellError(description: "\(vm) reported no address") }
        let guest = Guest(platform: platform, address: address, user: config.guestUser, key: config.managementKey)
        guard await guest.waitUntilReachable(seconds: 300) else { throw ShellError(description: "\(vm) at \(address): no SSH") }
        return guest
    }

    static func upload(_ path: String, to guest: Guest, platform: Platform) async throws {
        let config = ServerConfig.load()
        let destination = platform == .windows ? "layer.ps1" : "layer.sh"
        let result = try await Shell.run("/usr/bin/scp", sshOptions(config) + [path, "\(guest.user)@\(guest.address):\(destination)"])
        guard result.ok else { throw ShellError(description: "copying the script: \(result.error)") }
    }

    /// Cleared of what a build leaves, and shut down from inside (a clean
    /// shutdown: the golden image's disk is whole).
    static func seal(_ vm: String, guest: Guest, platform: Platform) async throws {
        let script: String
        switch platform {
        case .macos:
            script = "rm -f ~/layer.sh ~/.zsh_history ~/.bash_history; rm -rf ~/.zsh_sessions; find ~/Library/Caches -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; sudo shutdown -h now"
        case .linux:
            script = "rm -f ~/layer.sh ~/.bash_history; sudo apt-get clean; sudo journalctl --vacuum-time=1s >/dev/null 2>&1; sudo poweroff"
        case .windows:
            script = "Remove-Item -Force $HOME\\layer.ps1 -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force \"$env:TEMP\\*\" -ErrorAction SilentlyContinue; Stop-Computer -Force"

        case .ios, .android:
            return
        }
        _ = try? await guest.run(script, timeout: 60)
        for _ in 0..<90 {
            if try await UTM.vm(named: vm)?.status == "stopped" { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw ShellError(description: "\(vm) did not shut down")
    }

    /// A macOS VM just installed in UTM's window (its IPSW picked there:
    /// UTM is sandboxed and keeps only files a person picked) and stopped
    /// before Setup Assistant, set up with no clicks on its first start (UTM
    /// 5's provisioning, macOS 27 host and guest): `runner`, logged in at
    /// boot, Remote Login on; the server's key let in with the password
    /// (OSS_GUEST_PASSWORD, which stays the account's); a fixed-resolution
    /// display (one sized to UTM's window has none when the VM runs without
    /// one, as leases do); shut down.
    static func provisionMacOS(name: String) async throws {
        guard let password = ProcessInfo.processInfo.environment["OSS_GUEST_PASSWORD"], !password.isEmpty else {
            throw ShellError(description: "set OSS_GUEST_PASSWORD to the password runner gets")
        }
        let config = ServerConfig.load()
        try await UTM.configure(name, """
                set displays of config to {{dynamic resolution:false}}
            """)
        // A VM made in UTM's wizard and not yet started still has its IPSW:
        // macOS is installed from it here, with no dialog.
        if ProcessInfo.processInfo.environment["OSS_INSTALL"] == "1" {
            _ = try await UTM.script("""
                on run argv
                  tell application "UTM" to install (virtual machine named (item 1 of argv))
                end run
                """, [name], timeout: 600)
            while true {
                try await Task.sleep(for: .seconds(20))
                let progress = try await UTM.script("""
                    on run argv
                      tell application "UTM"
                        set p to query install (virtual machine named (item 1 of argv))
                        return ((installing of p) as text) & " " & ((progress of p) as text)
                      end tell
                    end run
                    """, [name])
                log("installing macOS: \(progress)")
                if progress.hasPrefix("false") { break }
            }
        }
        log("first start: provisioning runner")
        try await UTM.start(name, extra: ["--provision-username", config.guestUser, "--provision-password-stdin",
                                          "--provision-auto-login", "--provision-ssh"],
                            input: Data((password + "\n").utf8))
        var address: String?
        for _ in 0..<300 where address == nil {
            address = try? await UTM.ipAddress(name)
            if address == nil { try await Task.sleep(for: .seconds(3)) }
        }
        guard let address else { throw ShellError(description: "\(name) reported no address") }
        // The server's key, let in once with the password (ssh-copy-id, the password from an askpass of our own).
        let askpass = NSTemporaryDirectory() + "oss-askpass-\(Random.hex(4))"
        FileManager.default.createFile(atPath: askpass, contents: Data("#!/bin/sh\nprintf '%s\\n' \"$OSS_GUEST_PASSWORD\"\n".utf8),
                                       attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: askpass) }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "none"
        var copied = false
        for _ in 0..<60 where !copied {
            let result = try await Shell.run("/usr/bin/ssh-copy-id", ["-i", config.managementKey + ".pub", "-o", "ConnectTimeout=5",
                                                                      "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                                                                      "-o", "PubkeyAuthentication=no", "\(config.guestUser)@\(address)"],
                                             environment: environment, timeout: 60)
            copied = result.ok
            if !copied { try await Task.sleep(for: .seconds(5)) }
        }
        guard copied else { throw ShellError(description: "could not let the server's key into \(name) at \(address)") }
        let guest = Guest(platform: .macos, address: address, user: config.guestUser, key: config.managementKey)
        // runner's sudo asks nothing from now on (the password, once, on standard input).
        let sudoers = try await Shell.run("/usr/bin/ssh", sshOptions(config) + ["\(config.guestUser)@\(address)",
            "IFS= read -r pw; printf '%s\\n' \"$pw\" | sudo -S -p '' sh -c 'echo \"\(config.guestUser) ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/\(config.guestUser) && chmod 440 /etc/sudoers.d/\(config.guestUser)' && sudo -n true && echo sudo-ok"],
            input: Data((password + "\n").utf8), timeout: 60)
        guard sudoers.output.contains("sudo-ok") else { throw ShellError(description: "could not set up sudo in \(name): \(sudoers.error)") }
        try await seal(name, guest: guest, platform: .macos)
        log("\(name) is ready: macOS installed, runner set up, the server's key let in")
    }
}
