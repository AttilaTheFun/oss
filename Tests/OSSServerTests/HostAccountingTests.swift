import Foundation
import Testing
import OSSClient
@testable import OSSServer

// The Mac by whom (API 14), from a fake process table: OS Server's leases
// found by their processes, OS Server itself, every other VM by the app it
// is for, everything else, and what isn't the leases' (which comes out of
// the budget). Runs on Linux: the table is the only part that's the Mac's.

private let mb: Int64 = 1 << 20
private let gb: Int64 = 1 << 30
private let vz = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
    + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
private let support = "/Users/someone/Library/Application Support"

private func row(_ pid: Int32, _ path: String, ppid: Int32 = 1, responsible: Int32? = nil, footprint: Int64, cpu seconds: Double = 0,
                 arguments: [String] = [], openFiles: [String] = []) -> ProcessRow {
    ProcessRow(pid: pid, ppid: ppid, responsible: responsible, path: path, footprint: footprint,
               cpuNanoseconds: UInt64(seconds * 1_000_000_000), arguments: arguments, openFiles: openFiles)
}

/// A Mac with OS Server's leases (a macOS VM, a simulator, an emulator), a
/// base OS Server is building, an app's VMs, Podman's, a bare QEMU, Xcode,
/// and a shell; `seconds` of CPU time each so far, times `scale`.
private func table(cpu scale: Double) -> [ProcessRow] {
    [
        row(1, "/sbin/launchd", ppid: 0, footprint: 20 * mb),
        row(100, "/Applications/OS Server.app/Contents/MacOS/OS Server", footprint: 400 * mb, cpu: 1 * scale),
        row(101, "/Applications/OS Server.app/Contents/Helpers/oss-machine", footprint: 50 * mb),
        row(102, vz, responsible: 101, footprint: 12 * gb, cpu: 4 * scale,
            openFiles: ["\(support)/OS Server/Machines/leases/oss-lease-macos-ab12.vm/Disk.img"]),
        row(103, vz, responsible: 101, footprint: 4 * gb, openFiles: ["\(support)/OS Server/Machines/macos/xcode.vm/Disk.img"]),
        row(104, vz, responsible: 101, footprint: 3 * gb,
            openFiles: ["\(support)/OS Server/Machines/macos/oss-build-macos-tools-gh78.building/Disk.img"]),
        row(200, "/Applications/Visor Server.app/Contents/MacOS/Visor Server", footprint: 300 * mb),
        row(201, vz, responsible: 200, footprint: 6 * gb, cpu: 5 * scale, openFiles: ["\(support)/Visor/containers/s1/rootfs.ext4"]),
        row(202, vz, responsible: 200, footprint: 2 * gb, openFiles: ["\(support)/Visor/containers/s2/rootfs.ext4"]),
        row(301, "/opt/homebrew/bin/podman", footprint: 30 * mb),
        row(300, "/opt/homebrew/bin/vfkit", ppid: 301, footprint: 20 * mb),
        row(302, vz, responsible: 300, footprint: 2 * gb, openFiles: ["/Users/someone/.local/share/containers/podman/machine/applehv/default.raw"]),
        row(400, "/opt/homebrew/bin/qemu-system-aarch64", footprint: 1 * gb),
        row(500, "/Applications/Xcode.app/Contents/MacOS/Xcode", footprint: 3 * gb, cpu: 2 * scale),
        row(501, "/Applications/Xcode.app/Contents/SharedFrameworks/SourceKitService", footprint: 1 * gb),
        row(600, "/Library/Developer/CoreSimulator/launchd_sim", footprint: 100 * mb,
            arguments: ["/Users/someone/Library/Developer/CoreSimulator/Devices/UDID-1/data/var/run/launchd_bootstrap.plist"]),
        row(601, "/Library/Developer/CoreSimulator/SpringBoard", ppid: 600, footprint: 400 * mb),
        row(700, "/Users/someone/android-sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64", ppid: 100, footprint: 3 * gb),
        row(800, "/bin/zsh", footprint: 10 * mb),
    ]
}

private func lease(_ id: String, _ platform: Platform, udid: String? = nil, emulator: Int32? = nil) -> Lease {
    var lease = Lease(id: id, platform: platform, config: "vanilla", name: "oss-lease-\(platform.rawValue)-\(id)", holder: "alice",
                      state: .ready, created: Date(timeIntervalSince1970: 0), expires: .distantFuture)
    lease.udid = udid
    lease.emulatorPID = emulator
    return lease
}

/// An image build's place: its clone is named after it.
private let buildPlace: Lease = {
    var lease = Lease(id: "gh78", platform: .macos, config: "vanilla", name: "oss-build-macos-tools-gh78", holder: "alice", state: .ready,
                      created: Date(timeIntervalSince1970: 0), expires: .distantFuture)
    lease.build = "tools"
    return lease
}()

private let hints = [
    LeaseHint(lease: lease("ab12", .macos), allocatedBytes: 16 * gb, diskBytes: 40 * gb),
    LeaseHint(lease: lease("cd34", .ios, udid: "UDID-1"), allocatedBytes: 2 * gb, diskBytes: nil),
    LeaseHint(lease: lease("ef56", .android, emulator: 700), allocatedBytes: 4 * gb, diskBytes: nil),
    LeaseHint(lease: buildPlace, allocatedBytes: 16 * gb, diskBytes: nil),
]

private func account(_ rows: [ProcessRow], previous: HostAccounting.CPUSample? = nil, now: Date = Date(timeIntervalSince1970: 1_000)) -> HostAccounting.Result {
    HostAccounting.breakdown(rows, memoryUsed: 48 * gb, physicalMemory: 64 * gb, cpus: 12, ourPID: 100, leases: hints, previous: previous,
                             now: now, disk: DiskSpace(totalBytes: 1000 * gb, freeBytes: 400 * gb),
                             allocatedBytes: { path in path.hasSuffix(".ext4") ? 10 * gb : path.hasSuffix(".raw") ? 20 * gb : nil })
}

@Test func leasesAreFoundByTheirProcesses() {
    let result = account(table(cpu: 1))
    let leases = Dictionary(uniqueKeysWithValues: result.host.leases.map { ($0.id, $0) })
    // The macOS VM by its bundle among its open files, the simulator by its
    // UDID with what it started, the emulator by its pid.
    #expect(leases["ab12"]?.memoryBytes == 12 * gb && leases["ab12"]?.memoryLimitBytes == 16 * gb && leases["ab12"]?.diskBytes == 40 * gb)
    #expect(leases["cd34"]?.memoryBytes == 500 * mb)
    #expect(leases["ef56"]?.memoryBytes == 3 * gb)
    // An image build's place by the clone named after it.
    #expect(leases["gh78"]?.memoryBytes == 3 * gb)
    #expect(result.leaseFootprints == ["ab12": 12 * gb, "cd34": 500 * mb, "ef56": 3 * gb, "gh78": 3 * gb])
}

@Test func osServerItselfIsItsAppAndItsOwnVMsButItsLeases() {
    // Its process, its helper, and the base it is building (a VM its helper
    // is responsible for), not the emulator under it, which is a lease.
    let host = account(table(cpu: 1)).host
    #expect(host.server.memoryBytes == 400 * mb + 50 * mb + 4 * gb)
}

@Test func otherVMsAreGroupedByTheAppTheyAreFor() {
    let host = account(table(cpu: 1)).host
    #expect(host.otherVMs == [
        VMGroup(owner: "Visor Server", machines: 2, memoryBytes: 8 * gb, cpuPercent: 0, diskBytes: 20 * gb),
        VMGroup(owner: "podman", machines: 1, memoryBytes: 2 * gb, cpuPercent: 0, diskBytes: 20 * gb),
        VMGroup(owner: "QEMU", machines: 1, memoryBytes: 1 * gb, cpuPercent: 0, diskBytes: nil),
    ])
}

@Test func everythingElseIsWhatTheMacUsesLessTheRest() {
    let host = account(table(cpu: 1)).host
    let leases: Int64 = 12 * gb + 500 * mb + 3 * gb + 3 * gb
    let server: Int64 = 450 * mb + 4 * gb
    let others: Int64 = 11 * gb
    // What the Mac uses, less what's above: root's processes the table
    // can't read count here too.
    #expect(host.rest.memoryBytes == 48 * gb - leases - server - others)
    #expect(host.outsideMemoryBytes == 48 * gb - leases)
    #expect(host.restTop.first?.name == "Xcode" && host.restTop.first?.processes == 2 && host.restTop.first?.memoryBytes == 4 * gb)
    #expect(host.restTop.map(\.name).prefix(2) == ["Xcode", "Visor Server"])
    #expect(host.disk == DiskSpace(totalBytes: 1000 * gb, freeBytes: 400 * gb))
}

@Test func cpuIsWhatChangedSinceTheLastLook() {
    let first = account(table(cpu: 1), now: Date(timeIntervalSince1970: 1_000))
    #expect(first.host.server.cpuPercent == 0)
    // Ten seconds later each has used its seconds again: the VM's 5 s is
    // half a core, the lease's 4 s 40%.
    let second = account(table(cpu: 2), previous: first.sample, now: Date(timeIntervalSince1970: 1_010))
    #expect(second.host.otherVMs.first { $0.owner == "Visor Server" }?.cpuPercent == 50)
    #expect(second.host.leases.first { $0.id == "ab12" }?.cpuPercent == 40)
    #expect(second.host.server.cpuPercent == 10)
    #expect(second.host.rest.cpuPercent == 20)
}

@Test func aVMsOwnerIsTheAppResponsibleForItOrItsParents() {
    let rows = [
        row(10, "/usr/local/bin/container", footprint: 0),
        row(11, "/usr/local/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux", footprint: 0),
        row(12, vz, responsible: 11, footprint: 0),
        row(20, "/Applications/UTM.app/Contents/MacOS/UTM", footprint: 0),
        row(21, "/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMUHelper", ppid: 20, footprint: 0),
        row(22, "/opt/qemu/bin/qemu-system-x86_64", ppid: 21, footprint: 0),
        row(30, vz, footprint: 0),
    ]
    let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
    #expect(HostAccounting.owner(of: 12, in: byPID) == "container")
    #expect(HostAccounting.owner(of: 22, in: byPID) == "UTM")
    // Nothing to tell it by: what it is.
    #expect(HostAccounting.owner(of: 30, in: byPID) == "com.apple.Virtualization.VirtualMachine")
}

@Test func theMacKeepsItsReserveWhateverTheBudget() {
    // A budget set above what the Mac can spare: the reserve still holds.
    let limits = LeasePolicy(caps: [:], memoryBytes: 100 * gb, maxCPUs: 12, estimates: LeasePolicy.defaultEstimates, hostLimitBytes: 48 * gb)
    let lease = LeaseDemand(platform: .container, size: LeaseSize(cpus: 4, memoryBytes: 4 * gb))
    let refusal = limits.refusal(lease, held: [], outside: 15 * gb, leasesInUse: 30 * gb)
    #expect(refusal == .reserve(inUse: 45 * gb, needs: 4 * gb, limit: 48 * gb))
    #expect(refusal?.message == "busy: memory 45 of the Mac's 48 GB in use (it keeps the rest for itself); this needs 4")
    #expect(limits.refusal(lease, held: [], outside: 14 * gb, leasesInUse: 30 * gb) == nil)
    // Unmeasured, it isn't checked.
    #expect(limits.refusal(lease, held: [], outside: 15 * gb) == nil)
    // The server's own policy keeps it: a 64 GB Mac lends at most 48.
    #expect(ServerConfig().leasePolicy(memoryBytes: 64 << 30, cores: 12).hostLimitBytes == 48 * gb)
}

@Test func theStatusSaysTheMacByWhom() throws {
    let host = account(table(cpu: 1)).host
    let lines = hostLines(host)
    #expect(lines.first == "  host: 64 GB, 12 cores, 48 GB in use; disk 400 of 1000 GB free")
    #expect(lines.contains("    OS Server's leases: 4, 38 GB given, 18.5 GB used, 0% cpu"))
    #expect(lines.contains("      ab12 macos/vanilla: 16 GB given, 12 GB used, 0% cpu, 40 GB disk"))
    #expect(lines.contains("    other VMs: Visor Server: 2 VMs, 8 GB, 0% cpu, 20 GB disk"))
    #expect(lines.contains("    other VMs: QEMU: 1 VM, 1 GB, 0% cpu"))
    #expect(lines.last?.hasPrefix("    everything else: ") == true)
    #expect(lines.last?.contains("; most: Xcode 4 GB, Visor Server 0.3 GB") == true)
    // Through the wire and back, in the status.
    let status = Status(server: "s", bases: [], capacity: [], leases: [], host: host)
    let decoded = try JSONDecoder.oss.decode(Status.self, from: try JSONEncoder.oss.encode(status))
    #expect(decoded.host?.otherVMs.map(\.owner) == ["Visor Server", "podman", "QEMU"])
    #expect(decoded.host?.outsideMemoryBytes == host.outsideMemoryBytes)
}
