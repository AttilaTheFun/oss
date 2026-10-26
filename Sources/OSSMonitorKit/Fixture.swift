import Foundation
import OSSClient

/// A server's state, made up and always the same: what the proof's screens
/// and previews show. A Mac Studio lending five machines, its own share of
/// the CPU and memory beside everyone else's, its files, its cache.
@available(macOS 15, iOS 18, *)
public enum MonitorFixture {
    public static let connection = MonitorConnection(name: "Mac Studio", servers: [URL(string: "http://192.168.4.20:7480")!], token: "fixture")

    @MainActor
    public static func monitor(name: String = "Mac Studio") -> ServerMonitor {
        var connection = connection
        connection.name = name
        let monitor = ServerMonitor(connection: connection)
        let now = ServerMonitor.fixtureNow
        let gb: Int64 = 1_073_741_824
        func lease(_ id: String, _ platform: Platform, _ config: String, _ holder: String, minutesAgo: Double,
                   minutesLeft: Double, cpus: Int?, memory: Int64?) -> Lease {
            var lease = Lease(id: id, platform: platform, config: config, name: "oss-lease-\(platform.rawValue)-\(id)",
                              holder: holder, state: .ready, created: now.addingTimeInterval(-minutesAgo * 60),
                              expires: now.addingTimeInterval(minutesLeft * 60))
            lease.cpus = cpus
            lease.memoryLimitBytes = memory
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
        let machines = [
            MachineUsage(id: "3f2a91c0", platform: .macos, config: "xcode-27.0", holder: "visor:session-a", cpus: 6,
                         memoryLimitBytes: 16 * gb, cpuPercent: 412, memoryBytes: 17 * gb, diskBytes: 38 * gb),
            MachineUsage(id: "7b1e04d2", platform: .windows, config: "swift-6.3.2", holder: "visor:session-a", cpus: 6,
                         memoryLimitBytes: 16 * gb, cpuPercent: 538, memoryBytes: 19 * gb, diskBytes: 46 * gb),
            MachineUsage(id: "a90c3e17", platform: .linux, config: "dev", holder: "ci@runner", cpus: 6,
                         memoryLimitBytes: 16 * gb, cpuPercent: 96, memoryBytes: 7 * gb, diskBytes: 12 * gb),
            MachineUsage(id: "c44d8a20", platform: .ios, config: "iphone", holder: "visor:session-b", cpuPercent: 64, memoryBytes: 3 * gb,
                         diskBytes: 4 * gb),
            MachineUsage(id: "e5f61b39", platform: .android, config: "phone", holder: "visor:session-b", cpus: 4,
                         memoryLimitBytes: 4 * gb, cpuPercent: 38, memoryBytes: 5 * gb, diskBytes: 9 * gb),
            MachineUsage(id: "0d9c27f4", platform: .container, config: "linux", holder: "visor:session-c", cpus: 6,
                         memoryLimitBytes: 16 * gb, cpuPercent: 214, memoryBytes: 9 * gb, diskBytes: 7 * gb),
        ]
        let usage = Usage(
            sampledAt: now,
            host: HostUsage(name: name, cpus: 32, cpuPercent: 1484, memoryBytes: 512 * gb, memoryUsedBytes: 171 * gb),
            machines: machines,
            ours: ResourceShare(cpuPercent: 1162, memoryBytes: 52 * gb),
            others: ResourceShare(cpuPercent: 322, memoryBytes: 119 * gb),
            disk: DiskUsage(totalBytes: 4_000 * gb, freeBytes: 2_710 * gb, parts: [
                DiskPart(name: "macOS bases", bytes: 412 * gb), DiskPart(name: "macOS leases", bytes: 96 * gb),
                DiskPart(name: "Bazel cache", bytes: 61 * gb), DiskPart(name: "Android SDK", bytes: 14 * gb),
                DiskPart(name: "Android emulators", bytes: 22 * gb), DiskPart(name: "Containers", bytes: 18 * gb),
            ], measuredAt: now),
            topProcesses: [
                ProcessUsage(name: "Visor Server", processes: 14, cpuPercent: 118, memoryBytes: 38 * gb),
                ProcessUsage(name: "Bazel", processes: 6, cpuPercent: 96, memoryBytes: 31 * gb),
                ProcessUsage(name: "Virtual machines", processes: 2, cpuPercent: 54, memoryBytes: 24 * gb),
                ProcessUsage(name: "Xcode", processes: 9, cpuPercent: 12, memoryBytes: 6 * gb),
                ProcessUsage(name: "Safari", processes: 7, cpuPercent: 4, memoryBytes: 3 * gb),
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
        let history = (0..<150).map { i -> ServerMonitor.Sample in
            let t = Double(i)
            return ServerMonitor.Sample(date: now.addingTimeInterval(Double(i - 149) * 3),
                                        ourCPU: 0.30 + 0.10 * sin(t / 9) + 0.04 * sin(t / 2.3),
                                        otherCPU: 0.10 + 0.03 * sin(t / 5),
                                        ourMemory: 0.10 + 0.01 * sin(t / 17),
                                        otherMemory: 0.23 + 0.01 * sin(t / 11))
        }
        // A day of the disk: filling with leases' clones in the afternoon, a cache trim at night.
        let day = (0..<1440).map { i -> UsageSample in
            let t = Double(i)
            let used = 1_190 * gb + Int64((60 + 40 * sin(t / 230) + 8 * sin(t / 37)) * Double(gb))
            let ours = 650 * gb + Int64((40 + 30 * sin(t / 230)) * Double(gb))
            return UsageSample(date: now.addingTimeInterval(Double(i - 1439) * 60), cpus: 32, ourCPU: 1100, otherCPU: 300,
                               memoryBytes: 512 * gb, ourMemory: 52 * gb, otherMemory: 119 * gb,
                               diskBytes: 4_000 * gb, diskFreeBytes: 4_000 * gb - used, ourDiskBytes: ours)
        }
        let volumes = [VolumeInfo(name: "visor-session-c-build", sizeBytes: 128 * gb, allocatedBytes: 21 * gb, lease: "0d9c27f4"),
                       VolumeInfo(name: "visor-session-a-build", sizeBytes: 128 * gb, allocatedBytes: 34 * gb)]
        monitor.pretend(
            capabilities: Capabilities(version: OSS.version, api: OSS.apiLevel, features: ["machines", "screenshots", "input", "usage", "cache"],
                                       platforms: Platform.allCases),
            status: Status(server: name, bases: bases, capacity: capacity, leases: leases),
            usage: usage,
            cache: CacheInfo(port: 7490, readToken: "", bytes: 61 * gb, maxBytes: 200 * gb, freeBytes: 2_710 * gb,
                             hits: 48_213, misses: 3_907, writes: 11_542, evicted: 0),
            history: history, day: day, volumes: volumes)
        return monitor
    }
}
