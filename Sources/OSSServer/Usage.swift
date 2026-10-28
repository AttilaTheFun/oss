import Foundation
import OSSClient

#if canImport(Darwin)
import Darwin

/// What the server's Mac and each lease use, from its processes: `ps`'s
/// CPU (a decaying average, 100 one core) and each process's physical
/// footprint, a lease's summed over its own processes. A VM's are those with files open in its
/// `.utm` bundle or OS Server's `.vm` folder (UTM's QEMU, or Virtualization's VM service); a simulator's
/// its `launchd_sim` and what that started; an emulator's its process and
/// what that started.
enum UsageProbe {
    struct Process {
        var pid: Int
        var ppid: Int
        var cpu: Double
        var rss: Int64
        var command: String
    }

    static func processes() async -> [Process] {
        // Numbers and commands asked apart: a command's spaces can't shift a column.
        guard let numbers = try? await Shell.run("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,rss="], timeout: 30),
              let commands = try? await Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="], timeout: 30) else { return [] }
        var command: [Int: String] = [:]
        for line in commands.output.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int(trimmed[..<space]) else { continue }
            command[pid] = String(trimmed[trimmed.index(after: space)...])
        }
        return numbers.output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int(f[0]), let ppid = Int(f[1]), let cpu = Double(f[2]), let rss = Int64(f[3]) else { return nil }
            return Process(pid: pid, ppid: ppid, cpu: cpu, rss: rss * 1024, command: command[pid] ?? "")
        }
    }

    /// A process's physical footprint, as Activity Monitor's Memory counts
    /// it (resident size counts every shared library once a process: a
    /// simulator's hundred processes added up to many times its memory).
    static func footprint(_ pid: Int) -> Int64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(Int32(pid), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? Int64(info.ri_phys_footprint) : nil
    }

    /// A process and every process under it.
    static func tree(_ root: Int, in all: [Process]) -> [Process] {
        var children: [Int: [Process]] = [:]
        for process in all { children[process.ppid, default: []].append(process) }
        var found: [Process] = [], queue = all.filter { $0.pid == root }
        while let next = queue.popLast() {
            found.append(next)
            queue += children[next.pid] ?? []
        }
        return found
    }

    static func host(_ all: [Process]) -> HostUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        } == KERN_SUCCESS
        let page = Int64(sysconf(_SC_PAGESIZE))
        // As Activity Monitor counts it: app memory, wired and compressed.
        let used = ok ? (Int64(stats.internal_page_count) - Int64(stats.purgeable_count) + Int64(stats.wire_count)
                         + Int64(stats.compressor_page_count)) * page : 0
        return HostUsage(name: localHostName, cpus: ProcessInfo.processInfo.activeProcessorCount,
                         cpuPercent: (all.reduce(0) { $0 + $1.cpu } * 10).rounded() / 10,
                         memoryBytes: Int64(ProcessInfo.processInfo.physicalMemory), memoryUsedBytes: used)
    }

    /// Each VM lease's processes: those with a file open in its bundle.
    static func vmProcesses(_ leases: [Lease], in all: [Process]) async -> [String: [Int]] {
        guard !leases.isEmpty else { return [:] }
        let candidates = all.filter { p in
            ["QEMULauncher", "qemu-system", "com.apple.Virtualization.VirtualMachine"].contains { p.command.contains($0) }
        }.map(\.pid)
        guard !candidates.isEmpty,
              let open = try? await Shell.run("/usr/sbin/lsof", ["-nP", "-Fpn", "-p", candidates.map(String.init).joined(separator: ",")],
                                              timeout: 30) else { return [:] }
        var found: [String: Set<Int>] = [:]
        var pid = 0
        for line in open.output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int(line.dropFirst()) ?? 0; continue }
            guard line.hasPrefix("n") else { continue }
            // A VM's bundle (UTM's .utm, OS Server's .vm), or a container's
            // folder (its root filesystem, in Containerization's store).
            for lease in leases where line.contains("/\(lease.name).utm/") || line.contains("/\(lease.name).vm/")
                || line.contains("/containers/\(lease.name)/") {
                found[lease.id, default: []].insert(pid)
            }
        }
        return found.mapValues { Array($0) }
    }

    /// `folders`: where each lease's disk goes (Server's `folder(of:)`).
    static func usage(of leases: [Lease], folders: [String: String?] = [:]) async -> Usage {
        let all = await processes()
        let disks = await DiskSizes.shared.leases(folders)
        let vms = await vmProcesses(leases.filter { $0.platform.isVM || $0.platform == .container }, in: all)
        var ourPIDs = Set(tree(Int(getpid()), in: all).map(\.pid))
        let machines = leases.map { lease -> MachineUsage in
            var roots: [Int] = []
            switch lease.platform {
            case .macos, .linux, .windows, .container: roots = vms[lease.id] ?? []
            case .ios:
                if let udid = lease.udid {
                    roots = all.filter { $0.command.contains("launchd_sim") && $0.command.contains(udid) }.map(\.pid)
                }
            case .android:
                if let pid = lease.emulatorPID { roots = [Int(pid)] }
            }
            let processes = Dictionary(roots.flatMap { tree($0, in: all) }.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a }).values
            ourPIDs.formUnion(processes.map(\.pid))
            return MachineUsage(id: lease.id, platform: lease.platform, config: lease.config, holder: lease.holder,
                                cpus: lease.cpus, memoryLimitBytes: lease.memoryLimitBytes,
                                cpuPercent: processes.isEmpty ? nil : (processes.reduce(0) { $0 + $1.cpu } * 10).rounded() / 10,
                                memoryBytes: processes.isEmpty ? nil : processes.reduce(0) { $0 + (footprint($1.pid) ?? $1.rss) },
                                diskBytes: disks[lease.id])
        }
        let host = host(all)
        let memory = Dictionary(all.map { ($0.pid, footprint($0.pid) ?? $0.rss) }, uniquingKeysWith: { a, _ in a })
        let ours = all.filter { ourPIDs.contains($0.pid) }
        let ourShare = ResourceShare(cpuPercent: (ours.reduce(0) { $0 + $1.cpu } * 10).rounded() / 10,
                                     memoryBytes: ours.reduce(0) { $0 + (memory[$1.pid] ?? 0) })
        let otherShare = ResourceShare(cpuPercent: max(0, ((host.cpuPercent - ourShare.cpuPercent) * 10).rounded() / 10),
                                       memoryBytes: max(0, host.memoryUsedBytes - ourShare.memoryBytes))
        // Everything else, an app's helpers counted with it.
        var apps: [String: ProcessUsage] = [:]
        for process in all where !ourPIDs.contains(process.pid) {
            let name = appName(process.pid, command: process.command)
            var entry = apps[name] ?? ProcessUsage(name: name, processes: 0, cpuPercent: 0, memoryBytes: 0)
            entry.processes += 1
            entry.cpuPercent += process.cpu
            entry.memoryBytes += memory[process.pid] ?? 0
            apps[name] = entry
        }
        let top = apps.values.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(8).map { app -> ProcessUsage in
            var app = app
            app.cpuPercent = (app.cpuPercent * 10).rounded() / 10
            return app
        }
        return Usage(sampledAt: Date(), host: host, machines: machines, ours: ourShare, others: otherShare,
                     disk: await DiskSizes.shared.usage(), topProcesses: Array(top))
    }

    /// What a process is for a person: the app it belongs to (the first
    /// `.app` in its executable's path, so Chrome's helpers are Chrome), or
    /// its executable's name.
    static func appName(_ pid: Int, command: String) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let executable = (path as NSString).lastPathComponent
        // What their executables don't say: another app's VMs (Apple's
        // container, UTM's own), and Bazel's servers (a JVM).
        if executable == "com.apple.Virtualization.VirtualMachine" { return "Virtual machines" }
        if executable == "java", command.contains("bazel") { return "Bazel" }
        if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return executable
    }
}

/// The disk OS Server's folder is on, and OS Server's own files by kind:
/// measured with `du` every ten minutes in the background (a few hundred
/// gigabytes of bases take a while), the volume's size and free space at
/// every sample. Each lease's folder is measured every two minutes, and as
/// soon as a new one is there.
actor DiskSizes {
    static let shared = DiskSizes()
    private var parts: [DiskPart] = []
    private var measuredAt: Date?
    private var measuring = false
    private var leaseBytes: [String: Int64] = [:]
    private var leasesMeasuredAt: Date?
    private var measuringLeases = false

    func leases(_ folders: [String: String?]) -> [String: Int64] {
        let unmeasured = folders.contains { id, path in
            leaseBytes[id] == nil && path.map { FileManager.default.fileExists(atPath: $0) } == true
        }
        if !measuringLeases, unmeasured || leasesMeasuredAt.map({ Date().timeIntervalSince($0) > 120 }) ?? true {
            measuringLeases = true
            Task { await self.measureLeases(folders) }
        }
        return leaseBytes.filter { folders[$0.key] != nil }
    }

    private func measureLeases(_ folders: [String: String?]) async {
        var measured: [String: Int64] = [:]
        for case let (id, path?) in folders where FileManager.default.fileExists(atPath: path) {
            if let bytes = await Self.du(path) { measured[id] = bytes }
        }
        leaseBytes = measured
        leasesMeasuredAt = Date()
        measuringLeases = false
    }

    private static func du(_ path: String) async -> Int64? {
        guard let result = try? await Shell.run("/usr/bin/du", ["-sk", path], timeout: 300), result.ok,
              let kilobytes = Int64(result.output.split(separator: "\t").first ?? "") else { return nil }
        return kilobytes * 1024
    }

    func usage() -> DiskUsage? {
        if !measuring, measuredAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            measuring = true
            Task { await self.measure() }
        }
        // Free as `df` counts it: what macOS calls available "for important
        // use" adds what it could purge (local snapshots), which isn't free.
        let values = try? URL(fileURLWithPath: Paths.support).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity else { return nil }
        return DiskUsage(totalBytes: Int64(total), freeBytes: Int64(free), parts: parts, measuredAt: measuredAt)
    }

    private func measure() async {
        let config = ServerConfig.load()
        var places: [(String, String)] = [("macOS bases", "\(Paths.machines)/macos"), ("macOS leases", "\(Paths.machines)/leases"),
                                          ("Android SDK", config.androidSDK), ("Android emulators", config.androidAVDHome),
                                          ("Linux bases", "\(Paths.machines)/linux"), ("Windows bases", "\(Paths.machines)/windows"),
                                          ("Containers", Paths.containers), ("Served and stored files", Paths.files)]
        if let cache = config.cache { places.append(("Bazel cache", cache.directory)) }
        var measured: [DiskPart] = []
        for (name, path) in places where FileManager.default.fileExists(atPath: path) {
            if let bytes = await Self.du(path) { measured.append(DiskPart(name: name, bytes: bytes)) }
        }
        parts = measured
        measuredAt = Date()
        measuring = false
    }
}
#endif
