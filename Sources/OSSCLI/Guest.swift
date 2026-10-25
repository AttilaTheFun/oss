import Foundation
import OSSClient

/// A running guest, reached over SSH with the server's management key.
/// Through Apple's own `/usr/bin/ssh`: macOS's local network privacy stops
/// other binaries from opening connections to UTM's network.
struct Guest: Sendable {
    var platform: Platform
    var address: String
    var user: String
    var key: String

    private var options: [String] {
        ["-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR",
         // Guests come and go on reused addresses: their host keys are never kept.
         "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
    }

    /// Runs a script in the guest: bash on macOS and Linux, PowerShell on
    /// Windows, read from standard input (nothing secret on a command line).
    func run(_ script: String, timeout: TimeInterval = 120) async throws -> ProcessResult {
        let remote = platform == .windows
            ? "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -"
            : "bash -s"
        return try await Shell.run("/usr/bin/ssh", options + ["\(user)@\(address)", remote],
                                   input: Data(script.utf8), timeout: timeout)
    }

    /// SSH answers and takes the key: an SFTP handshake, which starts no
    /// shell (PowerShell takes half a minute to start on a Windows clone
    /// that has just booted).
    func reachable() async -> Bool {
        let result = try? await Shell.run("/usr/bin/sftp", ["-b", "-"] + options + ["\(user)@\(address)"],
                                          input: Data("bye\n".utf8), timeout: 30)
        return result?.ok ?? false
    }

    func waitUntilReachable(seconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if await reachable() { return true }
            try? await Task.sleep(for: .seconds(3))
        }
        return false
    }

    /// Until runner's desktop is up (a screenshot or a UI test needs it, and
    /// SSH answers well before it): Dock on macOS, a Wayland or X11 session
    /// on Ubuntu, Explorer on Windows.
    func waitForDesktop(seconds: Int) async -> Bool {
        let probe: String
        switch platform {
        case .macos: probe = "pgrep -x Dock >/dev/null"
        case .linux: probe = "loginctl list-sessions --no-legend | awk '{print $1}' | while read s; do loginctl show-session $s -p Type --value; done | grep -q -E 'wayland|x11'"
        case .windows: probe = "if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { exit 1 }"
        case .ios, .android: return true
        }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if (try? await run(probe, timeout: 60))?.ok == true { return true }
            try? await Task.sleep(for: .seconds(3))
        }
        return false
    }

    /// The server Mac's time zone, so the guest's clock reads as its holder expects.
    func setTimeZone(_ zone: String) async {
        let windowsZones = ["America/New_York": "Eastern Standard Time", "America/Chicago": "Central Standard Time",
                            "America/Denver": "Mountain Standard Time", "America/Phoenix": "US Mountain Standard Time",
                            "America/Los_Angeles": "Pacific Standard Time", "Europe/London": "GMT Standard Time", "UTC": "UTC"]
        let script: String
        switch platform {
        case .macos: script = "sudo systemsetup -settimezone '\(zone)' >/dev/null 2>&1 || true"
        case .linux: script = "sudo timedatectl set-timezone '\(zone)' || true"
        case .windows: script = "Set-TimeZone -Id '\(windowsZones[zone] ?? "UTC")'"
        case .ios, .android: return
        }
        _ = try? await run(script, timeout: 60)
    }

    /// The server's Bazel cache, read-only, for runner's Bazel in every
    /// workspace: its address in runner's bazelrc, the read token in its
    /// .netrc (where Bazel's HTTP cache takes credentials from; on Windows,
    /// whose SSH sessions have no HOME, NETRC names it). What the cache's
    /// populate job built comes down instead of being built again. The
    /// token goes in by standard input, as every script does.
    func useBazelCache(host: String, port: Int, token: String) async {
        let rc = CacheClientFiles.bazelrc(host: host, port: port).joined(separator: "\n")
        let netrc = CacheClientFiles.netrcEntry(host: host, token: token)
        let script: String
        switch platform {
        case .macos, .linux:
            script = """
                cat >> ~/.bazelrc <<'EOF'
                \(rc)
                EOF
                umask 077
                echo '\(netrc)' >> ~/.netrc
                """
        case .windows:
            // One line each: PowerShell reads a script from standard input a
            // line at a time, which breaks a here-string.
            let values = CacheClientFiles.bazelrc(host: host, port: port).map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ")
            script = """
                Add-Content -Path "$env:USERPROFILE\\.bazelrc" -Value @(\(values))
                Add-Content -Path "$env:USERPROFILE\\.netrc" -Value '\(netrc)'
                [Environment]::SetEnvironmentVariable('NETRC', "$env:USERPROFILE\\.netrc", 'User')
                """
        case .ios, .android: return
        }
        let result = try? await run(script, timeout: 60)
        if result?.ok != true { log("guest \(address): the Bazel cache not set up: \(result?.error ?? "no answer")") }
    }

    /// The lease's own access: the holder's key let in, and on macOS its
    /// Screen Sharing given the lease's VNC password (Windows and Ubuntu show
    /// their screens through QEMU's VNC, which the server sets up).
    func prepare(holderKey: String?, vncPassword: String) async throws {
        let key = (holderKey ?? "").replacingOccurrences(of: "'", with: "")
        let script: String
        switch platform {
        case .macos:
            script = """
                set -e
                key='\(key)'
                if [ -n "$key" ]; then mkdir -p ~/.ssh && echo "$key" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys; fi
                # Screen Sharing's VNC password (its legacy VNC setting, so any VNC client connects).
                printf '%s' '\(vncPassword)' | perl -we 'BEGIN { @k = unpack "C*", pack "H*", "1734516E8BA8C5E2FF1C39567390ADCA" } $_ = <STDIN>; @p = unpack "C*", substr($_ . "\\0" x 8, 0, 8); my $o = ""; foreach my $i (0..15) { $o .= sprintf "%02X", $k[$i] ^ ($i < 8 ? $p[$i] : 0) } print "$o\\n"' | sudo tee /Library/Preferences/com.apple.VNCSettings.txt >/dev/null
                sudo chmod 600 /Library/Preferences/com.apple.VNCSettings.txt
                sudo defaults write /Library/Preferences/com.apple.RemoteManagement.plist VNCLegacyConnectionsEnabled -bool true
                sudo defaults write /Library/Preferences/com.apple.RemoteManagement.plist VNCAlwaysStartOnConsole -bool true
                sudo launchctl enable system/com.apple.screensharing
                sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
                sudo launchctl kickstart -k system/com.apple.screensharing
                # Whatever the image's last session left open (System Settings, say) closes: a clean desktop.
                pkill -x "System Settings" 2>/dev/null || true
                """
        case .linux:
            // The screen is QEMU's VNC (the server's to set up): only the key here.
            script = """
                key='\(key)'
                if [ -n "$key" ]; then mkdir -p ~/.ssh && echo "$key" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys; fi
                """
        case .windows:
            script = """
                $key = '\(key)'
                if ($key) { Add-Content -Path 'C:\\ProgramData\\ssh\\administrators_authorized_keys' -Value $key }
                """
        case .ios, .android:
            return
        }
        let result = try await run(script, timeout: 180)
        guard result.ok else {
            throw ShellError(description: "preparing the \(platform.rawValue) guest: \(result.error)\(result.output)")
        }
    }
}
