import Foundation
import OSSClient

#if canImport(Darwin)
import Darwin

/// What the server's Mac and each lease use, from its processes: `ps`'s
/// CPU (a decaying average, 100 one core) and resident memory, a lease's
/// summed over its own processes. A VM's are those with files open in its
/// `.utm` bundle (UTM's QEMU, or Virtualization's VM service); a simulator's
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
            for lease in leases where line.contains("/\(lease.name).utm/") { found[lease.id, default: []].insert(pid) }
        }
        return found.mapValues { Array($0) }
    }

    static func usage(of leases: [Lease]) async -> Usage {
        let all = await processes()
        let vms = await vmProcesses(leases.filter { $0.platform.isVM }, in: all)
        let machines = leases.map { lease -> MachineUsage in
            var roots: [Int] = []
            switch lease.platform {
            case .macos, .linux, .windows: roots = vms[lease.id] ?? []
            case .ios:
                if let udid = lease.udid {
                    roots = all.filter { $0.command.contains("launchd_sim") && $0.command.contains(udid) }.map(\.pid)
                }
            case .android:
                if let pid = lease.emulatorPID { roots = [Int(pid)] }
            }
            let processes = Dictionary(roots.flatMap { tree($0, in: all) }.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a }).values
            return MachineUsage(id: lease.id, platform: lease.platform, config: lease.config, holder: lease.holder,
                                cpus: lease.cpus, memoryLimitBytes: lease.memoryLimitBytes,
                                cpuPercent: processes.isEmpty ? nil : (processes.reduce(0) { $0 + $1.cpu } * 10).rounded() / 10,
                                memoryBytes: processes.isEmpty ? nil : processes.reduce(0) { $0 + $1.rss })
        }
        return Usage(sampledAt: Date(), host: host(all), machines: machines)
    }
}
#endif
