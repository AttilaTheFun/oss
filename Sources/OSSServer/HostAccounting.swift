import Foundation
import OSSClient

// What the server's Mac is doing, by process (API 14): OS Server's own
// leases and itself, every other VM on the Mac by the app that runs it
// (Visor's, Podman's, Apple's `container`'s, UTM's), and everything else.
// Each Virtualization VM runs in an XPC service of its own
// (`com.apple.Virtualization.VirtualMachine`), and each QEMU VM in a
// `qemu-system-*` process: so every VM is found in the process table,
// whatever framework or app made it, and told to its owner by the process
// macOS holds responsible for it (an XPC service's is the app that asked
// for it), else by its parents. What isn't OS Server's leases' takes its
// memory out of what OS Server lends (Admission.swift's `outside`).
//
// The table is read through `ProcessTable` (LibprocTable.swift on a Mac);
// what is made of it here is pure, and tested on Linux with a fake table
// (HostAccountingTests).

/// A process as the table reads it.
struct ProcessRow: Sendable, Equatable {
    var pid: Int32
    var ppid: Int32
    /// The process macOS holds responsible for it (an XPC service's app);
    /// nil where it is itself, or can't be told.
    var responsible: Int32?
    /// Its executable.
    var path: String
    /// Its physical footprint (what Activity Monitor's Memory counts), and
    /// its CPU time so far (user and system, nanoseconds).
    var footprint: Int64
    var cpuNanoseconds: UInt64
    /// Its arguments: read only for a simulator's `launchd_sim` (its
    /// device's UDID is among them).
    var arguments: [String] = []
    /// The files it has open: read only for VMs (their disks, and the
    /// bundle a lease's VM runs from).
    var openFiles: [String] = []

    var executable: String { (path as NSString).lastPathComponent }

    /// A VM: Virtualization's XPC service, or QEMU.
    var isVM: Bool { executable == "com.apple.Virtualization.VirtualMachine" || executable.hasPrefix("qemu-system") }
}

/// Where the process table comes from: the Mac's (libproc), or a test's.
protocol ProcessTable: Sendable {
    /// Every process it can see, VMs' open files and `launchd_sim`'s
    /// arguments read.
    func snapshot() async -> [ProcessRow]
    /// The memory the Mac uses as Activity Monitor counts it (app memory,
    /// wired and compressed): every process's, the ones it can't read too.
    func memoryUsed() -> Int64
    /// A file's size as allocated on disk.
    func allocatedBytes(_ path: String) -> Int64?
}

/// No process table: Linux, where OS Server lends nothing.
struct NoProcessTable: ProcessTable {
    func snapshot() async -> [ProcessRow] { [] }
    func memoryUsed() -> Int64 { 0 }
    func allocatedBytes(_ path: String) -> Int64? { nil }
}

/// What the accounting needs of a lease to find its processes.
struct LeaseHint: Sendable {
    var lease: Lease
    /// Its memory as granted (its size).
    var allocatedBytes: Int64
    /// Its disk on the Mac, as measured (DiskSizes).
    var diskBytes: Int64?
}

/// The Mac's processes made into the breakdown.
enum HostAccounting {
    /// Each process's CPU time at the last look, and when: CPU use is what
    /// changed since.
    struct CPUSample: Sendable {
        var at: Date
        var times: [Int32: UInt64]
    }

    struct Result: Sendable {
        var host: HostBreakdown
        var sample: CPUSample
        /// Each lease's processes' footprint.
        var leaseFootprints: [String: Int64]
    }

    /// The file a VM's disk is: an image by its extension.
    static let diskExtensions: Set<String> = ["img", "raw", "qcow2", "asif", "ext4", "vmdk", "vhdx", "dmg", "iso"]

    static func breakdown(_ rows: [ProcessRow], memoryUsed: Int64, physicalMemory: Int64, cpus: Int, ourPID: Int32,
                          leases: [LeaseHint], previous: CPUSample?, now: Date, disk: DiskSpace?,
                          allocatedBytes: (String) -> Int64?) -> Result {
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for row in rows where row.ppid != row.pid { children[row.ppid, default: []].append(row.pid) }
        func tree(_ roots: [Int32]) -> Set<Int32> {
            var found = Set<Int32>(), queue = roots
            while let next = queue.popLast() {
                guard found.insert(next).inserted else { continue }
                queue += children[next] ?? []
            }
            return found
        }
        // CPU since the last look, a percentage of one core.
        func cpu(_ pids: some Sequence<Int32>) -> Double {
            guard let previous, now > previous.at else { return 0 }
            let elapsed = now.timeIntervalSince(previous.at) * 1_000_000_000
            let used = pids.reduce(0.0) { total, pid in
                guard let row = byPID[pid], let before = previous.times[pid], row.cpuNanoseconds >= before else { return total }
                return total + Double(row.cpuNanoseconds - before)
            }
            return (used / elapsed * 1000).rounded() / 10
        }
        func memory(_ pids: some Sequence<Int32>) -> Int64 { pids.reduce(0) { $0 + (byPID[$1]?.footprint ?? 0) } }
        let ourApp = byPID[ourPID].map(appName)

        // OS Server's leases: a VM's or a container's process by its bundle
        // among its open files, a simulator's launchd_sim by its UDID, an
        // emulator by its pid; each with every process under it.
        var leasePIDs: [String: Set<Int32>] = [:]
        for hint in leases {
            let lease = hint.lease
            var roots: [Int32] = []
            switch lease.platform {
            case .macos, .linux, .windows, .container:
                roots = rows.filter { row in
                    row.isVM && row.openFiles.contains { file in
                        file.contains("/\(lease.name).vm/") || file.contains("/\(lease.name).utm/") || file.contains("/containers/\(lease.name)/")
                            // An image build's place: the clone its build names after it.
                            || file.contains("/\(lease.name).building/")
                    }
                }.map(\.pid)
            case .ios:
                if let udid = lease.udid {
                    roots = rows.filter { $0.executable == "launchd_sim" && $0.arguments.contains { $0.contains(udid) } }.map(\.pid)
                }
            case .android:
                if let pid = lease.emulatorPID { roots = [pid] }
            }
            leasePIDs[lease.id] = tree(roots)
        }
        let allLeasePIDs = leasePIDs.values.reduce(into: Set<Int32>()) { $0.formUnion($1) }
        // OS Server itself: its process and those under it, whatever runs
        // from its app (its helpers, launchd's children; its QEMU), and a VM
        // of its own that is no lease's (a base being built), but for its
        // leases'.
        let own = rows.filter { row in
            ourApp != nil && (appName(row) == ourApp || (row.isVM && owner(of: row.pid, in: byPID) == ourApp))
        }
        let server = tree([ourPID] + own.map(\.pid)).subtracting(allLeasePIDs)

        let machines = leases.map { hint -> MachineUsage in
            let pids = leasePIDs[hint.lease.id] ?? []
            let lease = hint.lease
            return MachineUsage(id: lease.id, platform: lease.platform, config: lease.config, holder: lease.holder, kind: lease.kind,
                                cpus: lease.size?.cpus ?? lease.cpus, memoryLimitBytes: hint.allocatedBytes,
                                cpuPercent: pids.isEmpty ? nil : cpu(pids), memoryBytes: pids.isEmpty ? nil : memory(pids),
                                diskBytes: hint.diskBytes)
        }

        // Every other VM, by the app it is for; its disks from its open
        // files, where they can be read.
        var groups: [String: (machines: Int, pids: Set<Int32>, disks: Set<String>)] = [:]
        for row in rows where row.isVM && !allLeasePIDs.contains(row.pid) && !server.contains(row.pid) {
            let name = owner(of: row.pid, in: byPID)
            var group = groups[name] ?? (0, [], [])
            group.machines += 1
            group.pids.formUnion(tree([row.pid]))
            group.disks.formUnion(row.openFiles.filter { diskExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
            groups[name] = group
        }
        let otherVMs = groups.map { name, group -> VMGroup in
            let sizes = group.disks.compactMap(allocatedBytes)
            return VMGroup(owner: name, machines: group.machines, memoryBytes: memory(group.pids), cpuPercent: cpu(group.pids),
                           diskBytes: sizes.isEmpty ? nil : sizes.reduce(0, +))
        }.sorted { ($0.memoryBytes, $0.owner) > ($1.memoryBytes, $1.owner) }
        let otherVMPIDs = groups.values.reduce(into: Set<Int32>()) { $0.formUnion($1.pids) }

        // Everything else: what the Mac uses less what's above (so what the
        // table can't read, root's processes, counts here too), and the
        // apps using the most, a helper counted with its app.
        let leaseMemory = memory(allLeasePIDs), serverMemory = memory(server), otherVMMemory = memory(otherVMPIDs)
        let restPIDs = Set(rows.map(\.pid)).subtracting(allLeasePIDs).subtracting(server).subtracting(otherVMPIDs)
        let restMemory = max(memory(restPIDs), memoryUsed - leaseMemory - serverMemory - otherVMMemory)
        var apps: [String: ProcessUsage] = [:]
        for pid in restPIDs {
            guard let row = byPID[pid] else { continue }
            let name = appName(row)
            var app = apps[name] ?? ProcessUsage(name: name, processes: 0, cpuPercent: 0, memoryBytes: 0)
            app.processes += 1
            app.memoryBytes += row.footprint
            apps[name] = app
        }
        let top = apps.values.sorted { ($0.memoryBytes, $0.name) > ($1.memoryBytes, $1.name) }.prefix(5).map { app -> ProcessUsage in
            var app = app
            app.cpuPercent = cpu(restPIDs.filter { byPID[$0].map(appName) == app.name })
            return app
        }

        let host = HostBreakdown(sampledAt: now, memoryBytes: physicalMemory, memoryUsedBytes: memoryUsed, cpus: cpus,
                                 leases: machines, server: ResourceShare(cpuPercent: cpu(server), memoryBytes: serverMemory),
                                 otherVMs: otherVMs, rest: ResourceShare(cpuPercent: cpu(restPIDs), memoryBytes: restMemory),
                                 restTop: Array(top), disk: disk,
                                 outsideMemoryBytes: max(0, serverMemory + otherVMMemory + restMemory))
        return Result(host: host, sample: CPUSample(at: now, times: Dictionary(rows.map { ($0.pid, $0.cpuNanoseconds) }, uniquingKeysWith: { a, _ in a })),
                      leaseFootprints: leasePIDs.mapValues(memory))
    }

    /// What a process is for a person: the app its executable is in (the
    /// first `.app` in its path, so an app's helpers are the app), or its
    /// executable's name.
    static func appName(_ row: ProcessRow) -> String {
        if let app = row.path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return row.executable
    }

    /// Whom a VM is for: the app of the process responsible for it (an XPC
    /// service's is the app that asked for it), or of its parents; else
    /// what that process is (`container`'s runtime helpers are `container`,
    /// Podman's vfkit `podman`, a QEMU of no app's `QEMU`).
    static func owner(of pid: Int32, in byPID: [Int32: ProcessRow]) -> String {
        guard let row = byPID[pid] else { return "pid \(pid)" }
        let start = row.responsible.flatMap { byPID[$0] } ?? row
        var seen = Set<Int32>(), current: ProcessRow? = start
        while let process = current, process.pid > 1, seen.insert(process.pid).inserted {
            if process.path.split(separator: "/").contains(where: { $0.hasSuffix(".app") }) { return appName(process) }
            if process.path.contains("/libexec/container/") || process.executable.hasPrefix("container-") { return "container" }
            if process.executable == "vfkit" || process.executable == "podman" || process.path.contains("/podman/") { return "podman" }
            current = byPID[process.ppid]
        }
        if start.executable.hasPrefix("qemu-system") { return "QEMU" }
        return start.executable
    }
}
