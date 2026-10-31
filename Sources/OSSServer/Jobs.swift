import Foundation

#if os(macOS)
/// A machine's helper as a launchd job of this user's (OS Server's
/// containers and macOS VMs): not OS Server's child, so it goes on while
/// OS Server quits, restarts or is updated. Its plist is written beside the
/// machine; the job lasts until it's booted out or the Mac restarts.
public enum LaunchdJobs {
    /// Started (any job of that label before booted out first). A
    /// `keepAlive` job (the containers' network's owner) is started again by
    /// launchd whenever it ends, until it's booted out.
    public static func start(label: String, plist: String, program: [String], log: String, keepAlive: Bool = false) async throws {
        var job: [String: Any] = [
            "Label": label,
            "ProgramArguments": program,
            "RunAtLoad": true,
            // Not throttled as a background job is: a machine works.
            "ProcessType": "Interactive",
            "ExitTimeOut": 30,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        if keepAlive {
            job["KeepAlive"] = true
            // launchd's default is 10 seconds between starts; a helper waits 30 for it.
            job["ThrottleInterval"] = 5
        }
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: URL(fileURLWithPath: plist))
        await stop(label: label)
        let bootstrap = try await launchctl(["bootstrap", "gui/\(getuid())", plist])
        guard bootstrap.status == 0 else { throw ShellError(description: "launchctl bootstrap: \(bootstrap.output)") }
    }

    /// Ended (TERM, then KILL after its ExitTimeOut) and removed.
    public static func stop(label: String) async {
        let target = "gui/\(getuid())/\(label)"
        guard (try? await launchctl(["print", target]))?.status == 0 else { return }
        _ = try? await launchctl(["bootout", target])
        for _ in 0..<160 {
            guard (try? await launchctl(["print", target]))?.status == 0 else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Whether launchd has it and it hasn't ended.
    public static func isRunning(label: String) async -> Bool {
        guard let state = try? await launchctl(["print", "gui/\(getuid())/\(label)"]), state.status == 0 else { return false }
        return !state.output.contains("state = not running")
    }

    public static func launchctl(_ arguments: [String]) async throws -> (status: Int32, output: String) {
        let result = try await Shell.run("/bin/launchctl", arguments, timeout: 60)
        return (result.status, result.output + result.error)
    }
}

/// A helper's Unix socket: whether it answers, and a request of one JSON
/// line answered by one. Sockets are in the user's temporary folder
/// (`oss/`): a Unix socket's path has at most 104 bytes.
public enum HelperSocket {
    public static func path(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("oss").appendingPathComponent("\(name).sock").path
    }

    private static func connect(_ path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(descriptor); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { close(descriptor); return nil }
        return descriptor
    }

    /// Whether something takes connections on it.
    public static func isAnswering(_ path: String) -> Bool {
        guard let descriptor = connect(path) else { return false }
        close(descriptor)
        return true
    }

    /// One request (a JSON object) and its answer, or nil when nothing answers.
    public static func request(_ path: String, _ message: [String: String], timeout: TimeInterval = 10) async -> [String: String]? {
        await Task.detached {
            guard let descriptor = connect(path) else { return nil }
            defer { close(descriptor) }
            var seconds = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
            guard var line = try? JSONSerialization.data(withJSONObject: message) else { return nil }
            line.append(0x0A)
            let sent = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard sent == line.count else { return nil }
            var answer = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !answer.contains(0x0A) {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                answer.append(contentsOf: buffer[0..<count])
            }
            return (try? JSONSerialization.jsonObject(with: answer)) as? [String: String]
        }.value
    }
}
#endif
