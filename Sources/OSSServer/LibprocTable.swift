import Foundation

#if os(macOS)
import Darwin

/// The Mac's process table (HostAccounting.swift), read with libproc: every
/// process (`proc_listallpids`), its executable (`proc_pidpath`), parent
/// (`PROC_PIDTBSDINFO`), the process responsible for it, its footprint and
/// CPU time (`proc_pid_rusage`, RUSAGE_INFO_V6; another user's, which that
/// refuses, by `PROC_PIDTASKINFO`'s resident size and times), a VM's open
/// files (`PROC_PIDLISTFDS`, `PROC_PIDFDVNODEPATHINFO`) and a
/// `launchd_sim`'s arguments (`KERN_PROCARGS2`). A process it may not read
/// at all (root's) is left out: the Mac's memory as a whole still counts it.
struct LibprocTable: ProcessTable {
    func snapshot() async -> [ProcessRow] { Self.read() }

    func memoryUsed() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        } == KERN_SUCCESS
        guard ok else { return 0 }
        // As Activity Monitor counts it: app memory, wired and compressed.
        let page = Int64(sysconf(_SC_PAGESIZE))
        return (Int64(stats.internal_page_count) - Int64(stats.purgeable_count) + Int64(stats.wire_count)
                + Int64(stats.compressor_page_count)) * page
    }

    func allocatedBytes(_ path: String) -> Int64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Int64(info.st_blocks) * 512
    }

    /// Mach time to nanoseconds (on Apple silicon a tick isn't one).
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    /// libquarantine's `responsibility_get_pid_responsible_for_pid`, part
    /// of libSystem but in no header: found at run time, nil where it
    /// isn't (then a VM is told by its parents alone).
    nonisolated(unsafe) private static let responsibleFor: Responsible? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Responsible.self)
    }()

    static func read() -> [ProcessRow] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let listed = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard listed > 0 else { return [] }
        return pids.prefix(Int(listed)).compactMap { pid in pid > 0 ? row(pid) : nil }
    }

    private static func row(_ pid: pid_t) -> ProcessRow? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ppid: Int32 = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize ? Int32(bitPattern: bsd.pbi_ppid) : 0

        var footprint: Int64 = 0, ticks: UInt64 = 0
        var usage = rusage_info_v6()
        let used = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        if used == 0 {
            footprint = Int64(usage.ri_phys_footprint)
            ticks = usage.ri_user_time + usage.ri_system_time
        } else {
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { return nil }
            footprint = Int64(task.pti_resident_size)
            ticks = task.pti_total_user + task.pti_total_system
        }

        var responsible: Int32?
        if let lookup = responsibleFor {
            let found = lookup(pid)
            if found > 0, found != pid { responsible = found }
        }
        var row = ProcessRow(pid: pid, ppid: ppid, responsible: responsible, path: path, footprint: footprint,
                             cpuNanoseconds: ticks * timebase.numer / timebase.denom)
        if row.isVM { row.openFiles = openFiles(pid) }
        // A simulator's device (its UDID), and a machine helper's lease (its
        // helper.json's path) are in their arguments.
        if row.executable == "launchd_sim" || row.executable == "oss-machine" { row.arguments = arguments(pid) }
        return row
    }

    /// The paths of a process's open files.
    private static func openFiles(_ pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// A process's arguments (`KERN_PROCARGS2`: its argument count, its
    /// executable's path, then the arguments, each ended by a NUL).
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let parts = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return Array(parts.dropFirst().prefix(Int(max(0, count))))
    }
}
#endif
