import Foundation
import OSSClient

#if canImport(Virtualization)
import AppKit
import Virtualization

/// What a macOS VM's helper runs: the machine (its folder) and its socket.
struct MacHelperSpec: Codable, Sendable {
    var name: String
    var path: String
    var socket: String
}

/// A macOS lease's VM in a process of its own (`oss-machine macos
/// <helper.json>`, a launchd job of OS Server's): it outlives OS Server's
/// restarts and updates, as containers do. Its socket answers `status`,
/// `screen` (its live view in a window of the helper's own: Virtualization's
/// view needs the machine in its process) and `stop`. TERM powers it off;
/// a guest that shuts itself down ends the helper too.
public enum MacVMHelper {
    @MainActor private static var machine: MacVM?
    @MainActor private static var window: NSWindow?
    @MainActor private static var kept: [DispatchSourceSignal] = []

    public static func main(_ arguments: [String]) -> Never {
        guard arguments.count >= 3, let data = FileManager.default.contents(atPath: arguments[2]),
              let spec = try? JSONDecoder().decode(MacHelperSpec.self, from: data) else {
            FileHandle.standardError.write(Data("oss-machine macos <helper.json>: no spec to run\n".utf8))
            exit(2)
        }
        MainActor.assumeIsolated {
            // No Dock icon; its window shows only when asked for.
            NSApplication.shared.setActivationPolicy(.accessory)
            for signal in [SIGTERM, SIGINT] {
                Foundation.signal(signal, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
                source.setEventHandler { Task { @MainActor in await end("stopping") } }
                source.resume()
                kept.append(source)
            }
            Task { @MainActor in
                do {
                    let vm = try MacVM(name: spec.name, path: spec.path)
                    try await vm.start()
                    machine = vm
                    try ControlServer(socket: spec.socket).start()
                    log("\(spec.name): running")
                    // A guest that shuts itself down ends its helper.
                    _ = await vm.waitUntilStopped(seconds: 10 * 365 * 86400)
                    await end("its guest shut down")
                } catch {
                    log("\(spec.name): \(error)")
                    exit(1)
                }
            }
            NSApplication.shared.run()
        }
        exit(0)
    }

    @MainActor static func end(_ why: String) async {
        log("\(machine?.name ?? "machine"): \(why)")
        await machine?.stop()
        exit(0)
    }

    /// Its live view, in a window of this helper's (brought forward).
    @MainActor static func showScreen() {
        guard let machine else { return }
        if window == nil {
            let view = VZVirtualMachineView()
            view.virtualMachine = machine.machine
            view.capturesSystemKeys = true
            if #available(macOS 14, *) { view.automaticallyReconfiguresDisplay = false }
            let size = NSSize(width: CGFloat(machine.spec.displayWidth) / 2, height: CGFloat(machine.spec.displayHeight) / 2)
            let made = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                backing: .buffered, defer: false)
            made.title = "\(machine.name) — Screen"
            made.contentView = view
            made.isReleasedWhenClosed = false
            made.center()
            window = made
        }
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApplication.shared.activate() } else { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    @MainActor static var state: String { machine.map { $0.stopped ? "stopped" : "running" } ?? "starting" }

    /// The helper's socket: a JSON line in, one out, a connection each.
    final class ControlServer: @unchecked Sendable {
        let socket: String
        init(socket: String) { self.socket = socket }

        func start() throws {
            let folder = (socket as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            unlink(socket)
            let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socket.utf8)
            guard listener >= 0, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw ShellError(description: "no socket at \(socket)")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes)
                buffer[bytes.count] = 0
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
            }
            guard bound, listen(listener, 8) == 0 else { throw ShellError(description: "can't listen at \(socket)") }
            chmod(socket, 0o600)
            Thread.detachNewThread {
                while true {
                    let connection = accept(listener, nil, nil)
                    guard connection >= 0 else { continue }
                    Self.serve(connection)
                }
            }
        }

        private static func serve(_ connection: Int32) {
            defer { close(connection) }
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !request.contains(0x0A) {
                let count = read(connection, &buffer, buffer.count)
                guard count > 0 else { return }
                request.append(contentsOf: buffer[0..<count])
            }
            let message = (try? JSONSerialization.jsonObject(with: request)) as? [String: String] ?? [:]
            let answer: [String: String]
            switch message["op"] {
            case "status":
                answer = ["state": DispatchQueue.main.sync { MainActor.assumeIsolated { MacVMHelper.state } }, "pid": String(getpid())]
            case "screen":
                DispatchQueue.main.async { MainActor.assumeIsolated { MacVMHelper.showScreen() } }
                answer = ["done": "screen"]
            case "stop":
                DispatchQueue.main.async { Task { @MainActor in await MacVMHelper.end("asked to stop") } }
                answer = ["done": "stop"]
            default:
                answer = ["error": "no such op"]
            }
            if var line = try? JSONSerialization.data(withJSONObject: answer) {
                line.append(0x0A)
                _ = line.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            }
        }
    }
}

/// OS Server's side of macOS VMs in helpers: started as launchd jobs
/// (`oss.machine.<name>`), asked through their sockets, booted out.
/// Without the helper (`oss serve` run on its own), VMs run in the server's
/// process as before.
enum MacVMJobs {
    static var helper: String? { Paths.bundled("Helpers/oss-machine") }
    static func label(_ name: String) -> String { "oss.machine.\(name)" }

    /// Started from its folder (a clone of a base); returns once it runs.
    static func start(name: String, path: String) async throws {
        guard let helper else { throw ShellError(description: "no oss-machine beside this server") }
        let spec = MacHelperSpec(name: name, path: path, socket: HelperSocket.path(name))
        try JSONEncoder().encode(spec).write(to: URL(fileURLWithPath: "\(path)/helper.json"))
        try? FileManager.default.removeItem(atPath: spec.socket)
        try await LaunchdJobs.start(label: label(name), plist: "\(path)/launchd.plist",
                                    program: [helper, "macos", "\(path)/helper.json"], log: "\(path)/helper.log")
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if await isRunning(name) { return }
            if !(await LaunchdJobs.isRunning(label: label(name))) {
                let log = (try? String(contentsOfFile: "\(path)/helper.log", encoding: .utf8)) ?? ""
                await stop(name)
                throw ShellError(description: "its VM didn't start: \(log.split(separator: "\n").suffix(3).joined(separator: " / "))")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        await stop(name)
        throw ShellError(description: "its VM didn't start in 2 minutes")
    }

    static func isRunning(_ name: String) async -> Bool {
        await HelperSocket.request(HelperSocket.path(name), ["op": "status"])?["state"] == "running"
    }

    /// Powered off and its job removed (the helper stops the VM on TERM).
    static func stop(_ name: String) async {
        await LaunchdJobs.stop(label: label(name))
        try? FileManager.default.removeItem(atPath: HelperSocket.path(name))
    }
}

/// The app's Screen button for a lease's macOS VM: its helper's window, or
/// (a VM this process runs) the app's own.
public enum MachineScreens {
    /// Asked of the lease's helper; false when it has none answering. The
    /// app yields its activation to the helper first, so the window comes
    /// forward.
    @MainActor public static func showInHelper(_ name: String) async -> Bool {
        let socket = HelperSocket.path(name)
        if #available(macOS 14, *), let pid = await HelperSocket.request(socket, ["op": "status"])?["pid"].flatMap(Int32.init),
           let helper = NSRunningApplication(processIdentifier: pid) {
            NSApplication.shared.yieldActivation(to: helper)
        }
        return await HelperSocket.request(socket, ["op": "screen"])?["done"] == "screen"
    }

    /// Whether OS Server runs this lease's macOS VM (in a helper or here).
    public static func isOwn(_ lease: Lease) -> Bool {
        lease.platform == .macos && FileManager.default.fileExists(atPath: MacVMStore.leasePath(lease.name))
    }
}
#endif
