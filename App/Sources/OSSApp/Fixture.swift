import AppKit
import Foundation
import OSSClient
import OSSServer

/// A server's state, made up and always the same, for the proof's screens:
/// the app shows it instead of running a server when it is launched with
/// `-fixture YES` (or OSS_APP_FIXTURE=1). Nothing is started or asked. The
/// launch arguments are AppKit's `-key value` pairs, read as defaults: a
/// flag without its value would take the next one, and a word left over is
/// a file to open, for which SwiftUI opens no window.
enum Fixture {
    static var isOn: Bool {
        ProcessInfo.processInfo.environment["OSS_APP_FIXTURE"] == "1" || UserDefaults.standard.bool(forKey: "fixture")
    }

    /// Light or dark, whatever the Mac's appearance (`-appearance light|dark`).
    static var appearance: NSAppearance.Name? {
        guard isOn else { return nil }
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": return .aqua
        case "dark": return .darkAqua
        default: return nil
        }
    }

    /// The menu bar's panel in a window of its own instead of the main
    /// window (`-panel YES`), for its screen.
    static var showsPanel: Bool { isOn && UserDefaults.standard.bool(forKey: "panel") }

    /// Onboarding's window (`-setup YES`), for its screen.
    static var showsSetUp: Bool { isOn && UserDefaults.standard.bool(forKey: "setup") }

    /// A Linux or Windows VM's Screen window instead of the main window
    /// (`-guestScreen YES`, with `-guestScreenHost`, `-guestScreenPort` and
    /// `-guestScreenName`; its VNC password in ~/oss-fixture-vnc-password),
    /// for its screen: a real guest's, through its lease's relay.
    static var guestScreen: GuestScreenTarget? {
        let defaults = UserDefaults.standard
        guard isOn, defaults.bool(forKey: "guestScreen"), let host = defaults.string(forKey: "guestScreenHost") else { return nil }
        return GuestScreenTarget(name: defaults.string(forKey: "guestScreenName") ?? "guest", host: host,
                                 port: defaults.integer(forKey: "guestScreenPort"))
    }

    static var guestScreenPassword: String {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("oss-fixture-vnc-password")
        return ((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The components as a Mac part-way through setting up has them.
    static let components: [ComponentInfo] = [
        ComponentInfo(id: "containers", name: "Linux containers",
                      detail: "Containers from any registry's images, on Apple's Containerization: its Linux kernel and init.",
                      symbol: "shippingbox", state: .installed, accepts: []),
        ComponentInfo(id: "macos", name: "macOS VMs",
                      detail: "The newest macOS this Mac runs, installed from Apple's restore image with no one at its screen.",
                      symbol: "laptopcomputer", state: .absent, accepts: ["ipsw"]),
        ComponentInfo(id: "linux", name: "Ubuntu VMs",
                      detail: "Ubuntu 26.04 with GNOME, from Ubuntu's cloud image, on OS Server's QEMU.",
                      symbol: "server.rack", state: .installing("build-linux-base: first boot, cloud-init installing the desktop (a while)"),
                      accepts: ["img"]),
        ComponentInfo(id: "windows", name: "Windows VMs",
                      detail: "Windows 11 on Arm from Microsoft's ISO (downloaded from Microsoft, about 9 GB), installed by an answer file on OS Server's QEMU, with Fedora's virtio drivers.",
                      symbol: "pc", state: .absent, accepts: ["iso"]),
        ComponentInfo(id: "android", name: "Android emulators",
                      detail: "Google's emulator and an Android 15 phone image, from Google's repository.",
                      symbol: "candybarphone", state: .installed, accepts: []),
        ComponentInfo(id: "ios", name: "iOS simulators", detail: "An iPhone simulator of the newest runtime Xcode has.",
                      symbol: "iphone", state: .absent, accepts: []),
    ]

    /// The moment the screens show, so every relative time is the same.
    static let now = Date(timeIntervalSince1970: 1_793_534_400)

    @MainActor
    static func apply(to monitor: Monitor, server: ServerRunner) {
        let gb: Int64 = 1_073_741_824
        func lease(_ id: String, _ platform: Platform, _ config: String, _ holder: String, minutesAgo: Double,
                   minutesLeft: Double, cpus: Int?, memory: Int64?) -> Lease {
            var lease = Lease(id: id, platform: platform, config: config, name: "oss-lease-\(platform.rawValue)-\(id)",
                              holder: holder, state: .ready, created: now.addingTimeInterval(-minutesAgo * 60),
                              expires: now.addingTimeInterval(minutesLeft * 60))
            lease.cpus = cpus
            lease.memoryLimitBytes = memory
            // OS Server's own QEMU: its Screen window.
            if platform == .linux || platform == .windows { lease.qemuVNCPort = 46500 }
            return lease
        }
        let leases = [
            lease("3f2a91c0", .macos, "xcode-27.0", "visor:session-a", minutesAgo: 42, minutesLeft: 18, cpus: 6, memory: 16 * gb),
            lease("7b1e04d2", .windows, "swift-6.3.2", "visor:session-a", minutesAgo: 31, minutesLeft: 29, cpus: 6, memory: 16 * gb),
            lease("a90c3e17", .linux, "dev", "ci@runner", minutesAgo: 12, minutesLeft: 48, cpus: 6, memory: 16 * gb),
            lease("c44d8a20", .ios, "iphone", "visor:session-b", minutesAgo: 8, minutesLeft: 52, cpus: nil, memory: nil),
            lease("e5f61b39", .android, "phone", "visor:session-b", minutesAgo: 6, minutesLeft: 54, cpus: 4, memory: 4 * gb),
            {
                // An agent's container, held until it is released.
                var held = lease("0d9c27f4", .container, "linux", "visor:session-c", minutesAgo: 95, minutesLeft: 0, cpus: 6, memory: 16 * gb)
                held.expires = .distantFuture
                return held
            }(),
        ]
        let usage = Usage(
            sampledAt: now,
            host: HostUsage(name: "Mac Studio", cpus: 32, cpuPercent: 1184, memoryBytes: 512 * gb, memoryUsedBytes: 171 * gb),
            machines: [
                MachineUsage(id: "3f2a91c0", platform: .macos, config: "xcode-27.0", holder: "visor:session-a", cpus: 6,
                             memoryLimitBytes: 16 * gb, cpuPercent: 412, memoryBytes: 17 * gb, diskBytes: 38 * gb),
                MachineUsage(id: "7b1e04d2", platform: .windows, config: "swift-6.3.2", holder: "visor:session-a", cpus: 6,
                             memoryLimitBytes: 16 * gb, cpuPercent: 538, memoryBytes: 19 * gb, diskBytes: 46 * gb),
                MachineUsage(id: "a90c3e17", platform: .linux, config: "dev", holder: "ci@runner", cpus: 6,
                             memoryLimitBytes: 16 * gb, cpuPercent: 96, memoryBytes: 7 * gb, diskBytes: 12 * gb),
                MachineUsage(id: "c44d8a20", platform: .ios, config: "iphone", holder: "visor:session-b",
                             cpuPercent: 64, memoryBytes: 3 * gb, diskBytes: 4 * gb),
                MachineUsage(id: "e5f61b39", platform: .android, config: "phone", holder: "visor:session-b", cpus: 4,
                             memoryLimitBytes: 4 * gb, cpuPercent: 38, memoryBytes: 5 * gb, diskBytes: 9 * gb),
                MachineUsage(id: "0d9c27f4", platform: .container, config: "linux", holder: "visor:session-c", cpus: 6,
                             memoryLimitBytes: 16 * gb, cpuPercent: 214, memoryBytes: 9 * gb, diskBytes: 7 * gb),
            ])
        let bases = [
            Base(platform: .macos, config: "vanilla"), Base(platform: .macos, config: "dev"), Base(platform: .macos, config: "xcode-27.0"),
            Base(platform: .ios, config: "iphone"), Base(platform: .android, config: "phone"),
            Base(platform: .linux, config: "vanilla"), Base(platform: .linux, config: "dev"),
            Base(platform: .windows, config: "vanilla"), Base(platform: .windows, config: "dev"), Base(platform: .windows, config: "swift-6.3.2"),
            Base(platform: .container, config: "linux"),
        ]
        let capacity = [
            Capacity(platform: .macos, limit: 2, leased: 1), Capacity(platform: .ios, limit: 10, leased: 1),
            Capacity(platform: .android, limit: 8, leased: 1), Capacity(platform: .linux, limit: 2, leased: 1),
            Capacity(platform: .windows, limit: 2, leased: 1), Capacity(platform: .container, limit: 4, leased: 1),
        ]
        let history = (0..<150).map { i -> Monitor.Sample in
            let t = Double(i)
            return Monitor.Sample(date: now.addingTimeInterval(Double(i - 149) * 2),
                                  cpuFraction: 0.30 + 0.12 * sin(t / 9) + 0.05 * sin(t / 2.3),
                                  memoryFraction: 0.31 + 0.02 * sin(t / 17))
        }
        monitor.pretend(
            capabilities: Capabilities(version: OSS.version, api: OSS.apiLevel, features: ["machines", "screenshots", "input", "usage", "cache"],
                                       platforms: Platform.allCases),
            status: Status(server: "Mac Studio", bases: bases, capacity: capacity, leases: leases),
            usage: usage,
            cache: CacheInfo(port: 7490, readToken: "", bytes: 61 * gb, maxBytes: 200 * gb, freeBytes: 2_900 * gb,
                             hits: 48_213, misses: 3_907, writes: 11_542, evicted: 0),
            history: history)
        server.pretend(.running(since: now.addingTimeInterval(-3 * 3600 - 17 * 60)), lines: [
            "2026-11-01T09:18:02Z lease a90c3e17: oss-linux-dev for ci@runner, 60 min",
            "2026-11-01T09:18:27Z lease a90c3e17: ready at 192.168.65.12, ssh :47502, vnc :47503",
            "2026-11-01T09:22:10Z lease c44d8a20: oss-ios-iphone for visor:session-b, 60 min",
            "2026-11-01T09:22:15Z lease c44d8a20: simulator booted",
            "2026-11-01T09:24:01Z lease e5f61b39: oss-android-phone for visor:session-b, 60 min",
            "2026-11-01T09:24:07Z lease e5f61b39: emulator-5700 booted, adb :47504",
        ])
    }

    /// Where the app's windows are, in the screenshot's pixels (top-left
    /// origin), for the proof to crop each screen to: ~/oss-fixture-windows.json.
    @MainActor
    static func writeWindowFrames() {
        guard let screen = NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let frames = NSApp.windows.filter { $0.isVisible && $0.frame.width > 120 }.map { window -> [String: Any] in
            let frame = window.frame
            return ["title": window.title,
                    "x": Int(frame.minX * scale), "y": Int((screen.frame.height - frame.maxY) * scale),
                    "width": Int(frame.width * scale), "height": Int(frame.height * scale)]
        }
        let menuBar = Int(NSStatusBar.system.thickness * scale)
        var out = ["scale": scale, "menuBarHeight": menuBar, "windows": frames] as [String: Any]
        // The menu bar item: its button's window.
        if let item = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBar") }) {
            let frame = item.frame
            out["statusItem"] = ["x": Int(frame.minX * scale), "y": Int((screen.frame.height - frame.maxY) * scale),
                                 "width": Int(frame.width * scale), "height": Int(frame.height * scale)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("oss-fixture-windows.json"))
        }
    }
}
