#if canImport(Network)
import Foundation
import OSSClient

/// `oss machine exec <id> [--tty] [--env=K=V]… [--workdir=DIR] -- command…`:
/// a command in a container lease, this terminal's standard streams its
/// own. With `--tty` it gets a terminal of this one's size (raw, resized
/// with it) and its output comes on stdout alone.
enum ExecCommand {
    static func run(_ lease: Lease, _ client: OSSClient, _ arguments: Arguments) async throws -> Int32 {
        guard lease.platform == .container else { fail("exec is for container leases: a VM takes ssh, a simulator simctl, an emulator adb") }
        guard !arguments.rest.isEmpty else { fail("oss machine exec <id> [--tty] -- command…") }
        let tty = arguments.flags.contains("tty")
        var environment: [String: String] = [:]
        for pair in arguments.all["env"] ?? [] {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("--env=NAME=VALUE") }
            environment[parts[0]] = parts[1]
        }
        let size = tty ? terminalSize() : nil
        let request = ExecRequest(arguments: arguments.rest, tty: tty, columns: size?.columns, rows: size?.rows,
                                  environment: environment, workingDirectory: arguments.options["workdir"])

        let (input, continuation) = AsyncStream<ExecFrame>.makeStream()
        let restore = tty && isatty(STDIN_FILENO) != 0 ? rawMode() : nil
        defer { restore?() }
        if tty {
            signal(SIGWINCH, SIG_IGN)
            let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
            resize.setEventHandler {
                if let size = terminalSize() { continuation.yield(.resize(columns: size.columns, rows: size.rows)) }
            }
            resize.resume()
            Resize.source = resize
        }
        // stdin, read on a thread of its own until it ends.
        Thread.detachNewThread {
            while true {
                let data = FileHandle.standardInput.availableData
                if data.isEmpty { continuation.yield(.closeStdin); continuation.finish(); return }
                continuation.yield(.stdin(data))
            }
        }
        return try await client.exec(lease.id, request, input: input) { frame in
            switch frame {
            case .stdout(let data): FileHandle.standardOutput.write(data)
            case .stderr(let data): FileHandle.standardError.write(data)
            default: break
            }
        }
    }

    /// Kept for the command's life.
    private enum Resize { nonisolated(unsafe) static var source: DispatchSourceSignal? }

    private static func terminalSize() -> (columns: Int, rows: Int)? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    /// This terminal raw (what's typed goes to the container's, keys and
    /// all); returns what puts it back.
    private static func rawMode() -> () -> Void {
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        return { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
    }
}
#endif
