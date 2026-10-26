import Foundation
import OSSClient

#if os(macOS)

/// Linux and Windows VMs run by OS Server itself, on the QEMU inside it
/// (Contents/Helpers/qemu: Homebrew's, made to stand alone): no UTM. A
/// machine is a folder (`<name>.vm`): its disk (`Disk.qcow2`), its UEFI
/// variables (`EFIVars.fd`) and `machine.json`. Bases are
/// `Machines/<platform>/<config>.vm`; a lease's clone is
/// `Machines/leases/<lease name>.vm`, an APFS clone of its base, deleted
/// with the lease.
///
/// Each runs in a QEMU process of its own, daemonized (`qemu.pid` in its
/// folder), so it outlives OS Server's restarts as UTM's VMs did. Its
/// network is QEMU's own NAT (vmnet needs root or an entitlement Apple
/// keeps for itself): the guest is 10.0.2.15, the Mac 10.0.2.2, and its SSH
/// is forwarded to a loopback port. Its screen and input are QEMU's VNC
/// server, its controls QMP, both on loopback: for a lease with VNC port V,
/// QMP is at V-1000, SSH at V-2000 and the guest agent's channel at V-3000.
enum QEMUStore {
    static func bases(_ platform: Platform) -> String { "\(Paths.machines)/\(platform.rawValue)" }
    static func basePath(_ platform: Platform, _ config: String) -> String { "\(bases(platform))/\(config).vm" }
    static func leasePath(_ name: String) -> String { "\(Paths.machines)/leases/\(name).vm" }

    static func configs(_ platform: Platform) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bases(platform))) ?? []
        return names.filter { $0.hasSuffix(".vm") && hasBase(platform, String($0.dropLast(3))) }.map { String($0.dropLast(3)) }.sorted()
    }

    static func hasBase(_ platform: Platform, _ config: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(basePath(platform, config))/machine.json")
            && FileManager.default.fileExists(atPath: "\(basePath(platform, config))/Disk.qcow2")
    }
}

/// What `machine.json` holds for a QEMU machine: what it's given and the
/// devices its guest was installed with (a Windows guest boots only from
/// the disk controller it was installed on).
struct QEMUMachineSpec: Codable, Sendable {
    var platform: Platform
    var cpus: Int
    var memoryBytes: UInt64
    var mac: String
    /// `virtio` (virtio-blk), `nvme` or `usb`.
    var diskInterface: String = "virtio"
    var networkCard: String = "virtio-net-pci"
    /// `virtio-gpu-pci` (Linux), `ramfb` (Windows: no driver needed).
    var display: String = "virtio-gpu-pci"
    var displayWidth: Int = 1920
    var displayHeight: Int = 1080
    /// What it was made from: an image, UTM's VM, or the base it was built on.
    var origin: String?

    static func load(_ machine: String) throws -> QEMUMachineSpec {
        guard let data = FileManager.default.contents(atPath: "\(machine)/machine.json") else {
            throw ShellError(description: "no machine.json in \(machine)")
        }
        return try JSONDecoder().decode(QEMUMachineSpec.self, from: data)
    }

    func save(_ machine: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: "\(machine)/machine.json"))
    }
}

/// The QEMU inside OS Server.app (or, run from a checkout, Homebrew's).
enum QEMU {
    private static func first(_ paths: [String?]) -> String? {
        paths.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    static var system: String? {
        first([Paths.bundled("Helpers/qemu/bin/qemu-system-aarch64"), "/opt/homebrew/bin/qemu-system-aarch64"])
    }
    static var img: String? { first([Paths.bundled("Helpers/qemu/bin/qemu-img"), "/opt/homebrew/bin/qemu-img"]) }
    static var firmware: String? {
        first([Paths.bundled("Resources/qemu/edk2-aarch64-code.fd"), "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"])
    }
    /// Its data: firmware, option ROMs, keymaps (`-L`).
    static var data: String? { first([Paths.bundled("Resources/qemu"), "/opt/homebrew/share/qemu"]) }
    static var variablesTemplate: String? {
        first([Paths.bundled("Resources/qemu/edk2-arm-vars.fd"), "/opt/homebrew/share/qemu/edk2-arm-vars.fd"])
    }

    /// The ports a machine's VNC port V brings: QMP and SSH below it.
    static func qmpPort(vnc: Int) -> Int { vnc - 1000 }
    static func sshPort(vnc: Int) -> Int { vnc - 2000 }
    /// The guest agent's channel (qemu-guest-agent in Linux guests).
    static func agentPort(vnc: Int) -> Int { vnc - 3000 }

    static func run(_ tool: String?, _ arguments: [String], timeout: TimeInterval = 600) async throws -> ProcessResult {
        guard let tool else { throw ShellError(description: "no QEMU here: OS Server.app brings its own") }
        return try await Shell.run(tool, arguments, timeout: timeout)
    }
}

/// A machine's QEMU process: started daemonized, found again by its pid
/// file, stopped through QMP (or a signal).
enum QEMUVMs {
    struct Ports: Sendable {
        var vnc: Int
        var qmp: Int { QEMU.qmpPort(vnc: vnc) }
        var ssh: Int { QEMU.sshPort(vnc: vnc) }
        var agent: Int { QEMU.agentPort(vnc: vnc) }
    }

    /// Started, and its pid. `media`: images attached as removable USB
    /// drives (an installer, a cloud-init seed).
    @discardableResult
    static func start(name: String, path: String, ports: Ports, media: [String] = []) async throws -> Int32 {
        guard let system = QEMU.system, let firmware = QEMU.firmware else {
            throw ShellError(description: "no QEMU here: OS Server.app brings its own")
        }
        let spec = try QEMUMachineSpec.load(path)
        let variables = "\(path)/EFIVars.fd"
        if !FileManager.default.fileExists(atPath: variables), let template = QEMU.variablesTemplate {
            try FileManager.default.copyItem(atPath: template, toPath: variables)
        }
        try? FileManager.default.removeItem(atPath: "\(path)/qemu.pid")
        var arguments = [
            "-name", name, "-L", QEMU.data ?? (firmware as NSString).deletingLastPathComponent,
            "-machine", "virt,highmem=on", "-accel", "hvf", "-cpu", "host",
            // No wait for a key at the firmware's boot (a key then stops the boot).
            "-boot", "menu=on,splash-time=0",
            "-smp", "\(spec.cpus)", "-m", "\(spec.memoryBytes >> 20)",
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(firmware)",
            "-drive", "if=pflash,format=raw,unit=1,file=\(variables)",
            // Ports enough for every USB device without a hub: the firmware, which
            // doesn't wait, sees a drive behind a hub too late to boot it.
            "-device", "qemu-xhci,id=usb,p2=8,p3=8",
            // A tablet, not a mouse: VNC's pointer is absolute.
            "-device", "usb-kbd", "-device", "usb-tablet",
            "-device", spec.display == "ramfb" ? "ramfb" : "\(spec.display),xres=\(spec.displayWidth),yres=\(spec.displayHeight)",
            "-drive", "if=none,id=disk0,format=qcow2,discard=unmap,detect-zeroes=unmap,file=\(path)/Disk.qcow2",
            "-device", diskDevice(spec.diskInterface),
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(ports.ssh)-:22",
            "-device", "\(spec.networkCard),netdev=net0,mac=\(spec.mac)",
            "-device", "virtio-rng-pci",
            // The guest agent's channel, on a loopback port.
            "-device", "virtio-serial-pci",
            "-chardev", "socket,id=agent,host=127.0.0.1,port=\(ports.agent),server=on,wait=off",
            "-device", "virtserialport,chardev=agent,name=org.qemu.guest_agent.0",
            "-vnc", "127.0.0.1:\(ports.vnc - 5900)",
            "-qmp", "tcp:127.0.0.1:\(ports.qmp),server=on,wait=off",
            "-display", "none", "-daemonize", "-pidfile", "\(path)/qemu.pid", "-D", "\(path)/qemu.log",
        ]
        // In the boot order after the disk (the firmware connects only what
        // is in it): an empty disk boots the installer.
        for (index, image) in media.enumerated() {
            arguments += ["-drive", "if=none,id=media\(index),media=cdrom,readonly=on,file=\(image)",
                          "-device", "usb-storage,drive=media\(index),removable=on,bootindex=\(index + 1)"]
        }
        let result = try await Shell.run(system, arguments, timeout: 120)
        guard result.ok, let pid = pid(path) else {
            let log = (try? String(contentsOfFile: "\(path)/qemu.log", encoding: .utf8)) ?? ""
            throw ShellError(description: "QEMU didn't start \(name): \(result.error)\(log.suffix(400))")
        }
        log("\(name): QEMU \(pid), VNC :\(ports.vnc), SSH :\(ports.ssh)")
        return pid
    }

    static func diskDevice(_ interface: String) -> String {
        switch interface {
        case "nvme": return "nvme,drive=disk0,serial=oss0,bootindex=0"
        case "usb": return "usb-storage,drive=disk0,bootindex=0"
        default: return "virtio-blk-pci,drive=disk0,bootindex=0"
        }
    }

    /// Its QEMU's pid, while it runs.
    static func pid(_ path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: "\(path)/qemu.pid", encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 else { return nil }
        return pid
    }

    static func isRunning(_ path: String) -> Bool { pid(path) != nil }

    /// Powered off: QMP's quit, then TERM, then KILL.
    static func stop(_ path: String, ports: Ports?) async {
        guard let pid = pid(path) else { return }
        if let ports { try? await Task.detached { try QMPConnection(port: ports.qmp).execute("quit"); return () }.value }
        for signal in [Int32(0), SIGTERM, SIGKILL] {
            if signal != 0 { kill(pid, signal) }
            for _ in 0..<40 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(250)) }
            if kill(pid, 0) != 0 { return }
        }
    }

    /// Until the guest has shut itself down (QEMU exits), or `seconds` pass.
    static func waitUntilStopped(_ path: String, seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isRunning(path) { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return !isRunning(path)
    }

    /// A base cloned for a lease or a layer, with a network card of its own.
    static func clone(_ platform: Platform, _ config: String, to path: String) throws {
        try MacVMStore.clone(QEMUStore.basePath(platform, config), to: path)
        for leftover in ["qemu.pid", "qemu.log"] { try? FileManager.default.removeItem(atPath: "\(path)/\(leftover)") }
        var spec = try QEMUMachineSpec.load(path)
        spec.mac = Random.mac()
        spec.origin = config
        try spec.save(path)
    }

    /// The guest, reached over its forwarded SSH.
    static func guest(_ platform: Platform, ports: Ports, config: ServerConfig) -> Guest {
        Guest(platform: platform, address: "127.0.0.1", user: config.guestUser, key: config.managementKey, port: ports.ssh)
    }

    /// The Mac, as a QEMU guest reaches it (QEMU's NAT).
    static let hostAddress = "10.0.2.2"
}

#endif

#if os(macOS)
/// Linux bases made from nothing but a download: Ubuntu's arm64 cloud image
/// (checked against Ubuntu's SHA256SUMS), grown to the base's disk, booted
/// once with a cloud-init seed (an ISO labelled CIDATA, made with hdiutil)
/// that makes `runner` with the guest password and OS Server's key and
/// installs GNOME (`ubuntu-desktop-minimal`). Then, over SSH, what makes it
/// a base: its network found by interface name, not by the address of the
/// card it was installed with (each clone has its own), cloud-init off, the
/// desktop up after a restart, and shut down from inside. What makes it a
/// lab machine (SSH by key alone, runner logged in, no sleep) is the
/// vanilla layer's, built on it.
enum LinuxInstaller {
    static let release = "26.04"
    static var imageName: String { "ubuntu-\(release)-server-cloudimg-arm64.img" }
    static var releaseURL: String { "https://cloud-images.ubuntu.com/releases/\(release)/release" }

    static func install(config: String, image: String?, cpus: Int, memoryGB: Int, diskGB: Int) async throws {
        let server = ServerConfig.load()
        guard let password = ProcessInfo.processInfo.environment["OSS_GUEST_PASSWORD"]
                ?? GuestPasswords.password(for: .linux, config: config), !password.isEmpty else {
            throw ShellError(description: "set OSS_GUEST_PASSWORD (or guest-passwords.json's \"linux\") to the password runner gets")
        }
        guard let publicKey = try? String(contentsOfFile: server.managementKey + ".pub", encoding: .utf8) else {
            throw ShellError(description: "no public key at \(server.managementKey).pub")
        }
        let source: URL
        if let image { source = URL(fileURLWithPath: image) } else { source = try await download() }
        let path = QEMUStore.basePath(.linux, config)
        let work = path + ".installing"
        MacVMStore.remove(work)
        Paths.ensure(work)
        log("making Linux \(config) from \(source.lastPathComponent)")
        let convert = try await QEMU.run(QEMU.img, ["convert", "-O", "qcow2", source.path, "\(work)/Disk.qcow2"], timeout: 1800)
        guard convert.ok else { throw ShellError(description: "qemu-img convert: \(convert.error)") }
        let resize = try await QEMU.run(QEMU.img, ["resize", "\(work)/Disk.qcow2", "\(diskGB)G"])
        guard resize.ok else { throw ShellError(description: "qemu-img resize: \(resize.error)") }
        try QEMUMachineSpec(platform: .linux, cpus: cpus, memoryBytes: UInt64(memoryGB) << 30, mac: Random.mac(),
                            origin: source.lastPathComponent).save(work)
        let seed = try await makeSeed(in: work, user: server.guestUser, password: password,
                                      publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let ports = QEMUVMs.freePorts() else { throw ShellError(description: "no free loopback ports for its QEMU") }
        let name = "build-linux-\(config)"
        try await QEMUVMs.start(name: name, path: work, ports: ports, media: [seed])
        do {
            let guest = QEMUVMs.guest(.linux, ports: ports, config: server)
            log("\(name): first boot, cloud-init installing the desktop (a while)")
            guard await guest.waitUntilReachable(seconds: 900) else { throw ShellError(description: "\(name): no SSH") }
            let finished = try await guest.run("cloud-init status --wait --long; sudo cloud-init status", timeout: 7200)
            guard finished.output.contains("status: done") else {
                throw ShellError(description: "\(name): cloud-init didn't finish: \(finished.output.suffix(600))")
            }
            // A base's: no card's address in its network, no cloud-init at a clone's boot.
            let settle = try await guest.run("""
                set -e
                sudo rm -f /etc/netplan/*.yaml
                printf 'network:\\n  version: 2\\n  renderer: NetworkManager\\n  ethernets:\\n    lan:\\n      match: {name: "en*"}\\n      dhcp4: true\\n' | sudo tee /etc/netplan/01-oss.yaml >/dev/null
                sudo chmod 600 /etc/netplan/01-oss.yaml
                sudo touch /etc/cloud/cloud-init.disabled
                sudo cloud-init clean --logs --seed >/dev/null 2>&1 || true
                sudo systemctl set-default graphical.target >/dev/null
                """, timeout: 300)
            guard settle.ok else { throw ShellError(description: "\(name): \(settle.error)") }
            _ = try? await guest.run("sudo reboot", timeout: 30)
            try await Task.sleep(for: .seconds(15))
            guard await guest.waitUntilReachable(seconds: 600) else { throw ShellError(description: "\(name): no SSH after its restart") }
            _ = try? await guest.run("sudo poweroff", timeout: 30)
            guard await QEMUVMs.waitUntilStopped(work, seconds: 300) else { throw ShellError(description: "\(name) did not shut down") }
        } catch {
            await QEMUVMs.stop(work, ports: ports)
            throw error
        }
        try? FileManager.default.removeItem(atPath: seed)
        for leftover in ["qemu.pid", "qemu.log"] { try? FileManager.default.removeItem(atPath: "\(work)/\(leftover)") }
        MacVMStore.remove(path)
        try FileManager.default.moveItem(atPath: work, toPath: path)
        log("Linux base \(config) is ready: Ubuntu \(release) with GNOME, \(server.guestUser) made, the server's key let in")
    }

    /// Ubuntu's cloud image, downloaded beside the bases once (kept for the
    /// next install) and checked against its SHA256SUMS.
    static func download() async throws -> URL {
        let directory = "\(Paths.machines)/images"
        Paths.ensure(directory)
        let destination = URL(fileURLWithPath: "\(directory)/\(imageName)")
        let (sums, _) = try await URLSession.shared.data(from: URL(string: "\(releaseURL)/SHA256SUMS")!)
        guard let line = String(decoding: sums, as: UTF8.self).split(separator: "\n").first(where: { $0.hasSuffix(imageName) }),
              let expected = line.split(separator: " ").first.map(String.init) else {
            throw ShellError(description: "Ubuntu's SHA256SUMS names no \(imageName)")
        }
        if FileManager.default.fileExists(atPath: destination.path), try await sha256(destination) == expected { return destination }
        log("downloading \(releaseURL)/\(imageName)")
        let (temporary, response) = try await URLSession.shared.download(from: URL(string: "\(releaseURL)/\(imageName)")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ShellError(description: "downloading \(imageName): \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard try await sha256(temporary) == expected else { throw ShellError(description: "\(imageName) isn't what Ubuntu's SHA256SUMS says") }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    static func sha256(_ file: URL) async throws -> String {
        let result = try await Shell.run("/usr/bin/shasum", ["-a", "256", file.path], timeout: 600)
        return String(result.output.split(separator: " ").first ?? "")
    }

    /// cloud-init's NoCloud seed: an ISO labelled CIDATA with its user-data
    /// and meta-data. The password is in it only until the install ends.
    static func makeSeed(in directory: String, user: String, password: String, publicKey: String) async throws -> String {
        let folder = "\(directory)/seed"
        Paths.ensure(folder)
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let userData = """
            #cloud-config
            hostname: oss-linux
            users:
              - name: \(user)
                gecos: \(user)
                groups: [adm, sudo]
                shell: /bin/bash
                sudo: "ALL=(ALL) NOPASSWD:ALL"
                lock_passwd: false
                ssh_authorized_keys: [\(quoted(publicKey))]
            chpasswd:
              expire: false
              users:
                - {name: \(user), password: \(quoted(password)), type: text}
            ssh_pwauth: false
            package_update: true
            packages: [ubuntu-desktop-minimal, openssh-server, qemu-guest-agent]
            """
        try Data(userData.utf8).write(to: URL(fileURLWithPath: "\(folder)/user-data"), options: [])
        chmod("\(folder)/user-data", 0o600)
        try Data("instance-id: oss-\(Random.hex(4))\nlocal-hostname: oss-linux\n".utf8).write(to: URL(fileURLWithPath: "\(folder)/meta-data"))
        let iso = "\(directory)/seed.iso"
        let made = try await Shell.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-iso-volume-name", "CIDATA",
                                                            "-joliet-volume-name", "CIDATA", "-o", iso, folder], timeout: 120)
        try? FileManager.default.removeItem(atPath: folder)
        guard made.ok else { throw ShellError(description: "making cloud-init's seed: \(made.error)") }
        return iso
    }
}

extension QEMUVMs {
    /// Loopback ports for a machine built outside any lease (a base being
    /// made): the top of the QEMU range, free now.
    static func freePorts() -> Ports? {
        let config = ServerConfig.load()
        for vnc in stride(from: config.lastQEMUVNCPort, through: config.lastQEMUVNCPort - 40, by: -1) {
            let ports = Ports(vnc: vnc)
            if [ports.vnc, ports.qmp, ports.ssh, ports.agent].allSatisfy(isFree) { return ports }
        }
        return nil
    }

    static func isFree(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
#endif

#if os(macOS)
/// Windows bases made from Microsoft's ISO (Windows 11 on Arm, which you
/// give it: Microsoft hands it out only from its page), installed with no
/// one at the screen by an answer file (`autounattend.xml` on a drive of
/// its own, which Setup looks for). Only what Windows has drivers for out
/// of the box: an NVMe disk, the ramfb display, USB keyboard and tablet, a
/// USB network card (RNDIS). The answer file passes over Windows 11's TPM
/// and Secure Boot checks, the online account, and makes `runner` (logged
/// in at boot); its first sign-in adds OpenSSH Server with OS Server's
/// key. Then it is shut down; the vanilla layer is built on it. The ISO's
/// loader asks for a key to boot: QMP presses one.
enum WindowsInstaller {
    /// Windows 11 Pro's generic key (Microsoft's, for installing; it
    /// doesn't activate).
    static let genericProKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"

    static func install(config: String, iso: String, edition: String = "Windows 11 Pro", cpus: Int, memoryGB: Int,
                        diskGB: Int) async throws {
        let server = ServerConfig.load()
        guard let password = ProcessInfo.processInfo.environment["OSS_GUEST_PASSWORD"]
                ?? GuestPasswords.password(for: .windows, config: config), !password.isEmpty else {
            throw ShellError(description: "set OSS_GUEST_PASSWORD (or guest-passwords.json's \"windows\") to the password runner gets")
        }
        guard let publicKey = try? String(contentsOfFile: server.managementKey + ".pub", encoding: .utf8) else {
            throw ShellError(description: "no public key at \(server.managementKey).pub")
        }
        guard FileManager.default.fileExists(atPath: iso) else { throw ShellError(description: "no ISO at \(iso)") }
        let path = QEMUStore.basePath(.windows, config)
        let work = path + ".installing"
        MacVMStore.remove(work)
        Paths.ensure(work)
        let created = try await QEMU.run(QEMU.img, ["create", "-f", "qcow2", "\(work)/Disk.qcow2", "\(diskGB)G"])
        guard created.ok else { throw ShellError(description: "qemu-img create: \(created.error)") }
        try QEMUMachineSpec(platform: .windows, cpus: cpus, memoryBytes: UInt64(memoryGB) << 30, mac: Random.mac(),
                            diskInterface: "nvme", networkCard: "usb-net", display: "ramfb",
                            origin: URL(fileURLWithPath: iso).lastPathComponent).save(work)
        let answers = try await answerFile(in: work, edition: edition, user: server.guestUser, password: password,
                                           publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let ports = QEMUVMs.freePorts() else { throw ShellError(description: "no free loopback ports for its QEMU") }
        let name = "build-windows-\(config)"
        log("installing \(edition) into \(config) from \(URL(fileURLWithPath: iso).lastPathComponent)")
        try await QEMUVMs.start(name: name, path: work, ports: ports, media: [iso, answers])
        do {
            // The ISO's loader waits a few seconds for a key ("Press any key to
            // boot from CD or DVD"), two to four seconds in; the firmware waits
            // for none, so keys sent from the start reach it. Not for long: a
            // key that reaches Setup's window presses its Cancel.
            try await pressKeys(port: ports.qmp, seconds: 8)
            let guest = QEMUVMs.guest(.windows, ports: ports, config: server)
            log("\(name): Setup installing (a while)")
            guard await guest.waitUntilReachable(seconds: 3 * 3600) else {
                throw ShellError(description: "\(name): no SSH after three hours (Setup stopped? see its screen at VNC :\(ports.vnc))")
            }
            guard await guest.waitForDesktop(seconds: 1800) else { throw ShellError(description: "\(name): no desktop") }
            _ = try? await guest.run("Stop-Computer -Force", timeout: 60)
            guard await QEMUVMs.waitUntilStopped(work, seconds: 600) else { throw ShellError(description: "\(name) did not shut down") }
        } catch {
            await QEMUVMs.stop(work, ports: ports)
            throw error
        }
        try? FileManager.default.removeItem(atPath: answers)
        for leftover in ["qemu.pid", "qemu.log"] { try? FileManager.default.removeItem(atPath: "\(work)/\(leftover)") }
        MacVMStore.remove(path)
        try FileManager.default.moveItem(atPath: work, toPath: path)
        log("Windows base \(config) is ready: \(edition), \(server.guestUser) made, SSH with the server's key")
    }

    /// Space pressed every 300 ms for a while, through QMP.
    static func pressKeys(port: Int, seconds: Int) async throws {
        try await Task.detached {
            let qmp = try QMPConnection(port: port)
            for _ in 0..<(seconds * 10 / 3) {
                _ = try? qmp.execute("send-key", ["keys": [["type": "qcode", "data": "spc"]]])
                usleep(300_000)
            }
            qmp.close()
            return ()
        }.value
    }

    /// `autounattend.xml` on an ISO of its own (Setup searches removable
    /// drives for it). runner's password is in it until the install ends.
    static func answerFile(in directory: String, edition: String, user: String, password: String, publicKey: String) async throws -> String {
        func xml(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let arch = "processorArchitecture=\"arm64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\""
        // runner's first sign-in: the SSH server, OS Server's key, its firewall
        // rule. A script on the answer drive: a first-logon command is at most
        // 1024 characters.
        let ssh = """
            Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
            Set-Service sshd -StartupType Automatic
            Start-Service sshd
            Set-Content -Path C:\\ProgramData\\ssh\\administrators_authorized_keys -Value '\(publicKey)'
            icacls.exe C:\\ProgramData\\ssh\\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
            if (-not (Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 }
            Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Profile Any
            """
        let firstLogon = "powershell -NoProfile -ExecutionPolicy Bypass -Command \"foreach ($d in [char[]]'DEFGHIJ') { if (Test-Path ($d + ':\\oss-ssh.ps1')) { & ($d + ':\\oss-ssh.ps1'); break } }\""
        let answers = """
            <?xml version="1.0" encoding="utf-8"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <settings pass="windowsPE">
                <component name="Microsoft-Windows-International-Core-WinPE" \(arch)>
                  <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
                  <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
                </component>
                <component name="Microsoft-Windows-Setup" \(arch)>
                  <RunSynchronous>
                    <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                    <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                    <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                  </RunSynchronous>
                  <DiskConfiguration>
                    <Disk wcm:action="add">
                      <DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
                      <CreatePartitions>
                        <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
                        <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                        <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                      </CreatePartitions>
                      <ModifyPartitions>
                        <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                        <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                      </ModifyPartitions>
                    </Disk>
                  </DiskConfiguration>
                  <ImageInstall>
                    <OSImage>
                      <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>\(xml(edition))</Value></MetaData></InstallFrom>
                      <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                    </OSImage>
                  </ImageInstall>
                  <UserData>
                    <ProductKey><Key>\(genericProKey)</Key></ProductKey>
                    <AcceptEula>true</AcceptEula>
                  </UserData>
                </component>
              </settings>
              <settings pass="specialize">
                <component name="Microsoft-Windows-Shell-Setup" \(arch)>
                  <ComputerName>oss-windows</ComputerName>
                </component>
                <component name="Microsoft-Windows-Deployment" \(arch)>
                  <RunSynchronous>
                    <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                  </RunSynchronous>
                </component>
              </settings>
              <settings pass="oobeSystem">
                <component name="Microsoft-Windows-Shell-Setup" \(arch)>
                  <OOBE>
                    <HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                    <HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                    <ProtectYourPC>3</ProtectYourPC>
                  </OOBE>
                  <UserAccounts>
                    <LocalAccounts>
                      <LocalAccount wcm:action="add">
                        <Name>\(xml(user))</Name><Group>Administrators</Group><DisplayName>\(xml(user))</DisplayName>
                        <Password><Value>\(xml(password))</Value><PlainText>true</PlainText></Password>
                      </LocalAccount>
                    </LocalAccounts>
                  </UserAccounts>
                  <AutoLogon>
                    <Username>\(xml(user))</Username><Enabled>true</Enabled><LogonCount>9999999</LogonCount>
                    <Password><Value>\(xml(password))</Value><PlainText>true</PlainText></Password>
                  </AutoLogon>
                  <FirstLogonCommands>
                    <SynchronousCommand wcm:action="add"><Order>1</Order>
                      <CommandLine>\(xml(firstLogon))</CommandLine>
                      <Description>OpenSSH Server with OS Server's key</Description>
                    </SynchronousCommand>
                  </FirstLogonCommands>
                </component>
              </settings>
            </unattend>
            """
        let folder = "\(directory)/answers"
        Paths.ensure(folder)
        try Data(answers.utf8).write(to: URL(fileURLWithPath: "\(folder)/autounattend.xml"))
        chmod("\(folder)/autounattend.xml", 0o600)
        try Data(ssh.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: URL(fileURLWithPath: "\(folder)/oss-ssh.ps1"))
        let iso = "\(directory)/answers.iso"
        let made = try await Shell.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-iso-volume-name", "ANSWERS",
                                                            "-joliet-volume-name", "ANSWERS", "-o", iso, folder], timeout: 120)
        try? FileManager.default.removeItem(atPath: folder)
        guard made.ok else { throw ShellError(description: "making the answer file's drive: \(made.error)") }
        return iso
    }
}
#endif
