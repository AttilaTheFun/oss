import Foundation
import OSSClient

/// `oss machine exec <id> [--tty] [--env=K=V]… [--env-file=F] [--workdir=DIR] -- command…`
/// (or `--socket=PATH` for `<id>`: the lease's exec socket, no server asked;
/// or `--url=GRANT`: a `machine.exec` grant's URL, no token): a command in a
/// container lease, this process's standard streams its own, its exit
/// status this one's. On the server's Mac it goes to the container directly
/// (its exec socket), so it outlives the server's restarts; from anywhere
/// else, through the server (`POST /v1/machines/<id>/exec`). TERM, INT, HUP,
/// QUIT, USR1 and USR2 sent to this process go to the command; if this
/// process ends first, so does the command. With `--tty` it gets a terminal
/// of this one's size (raw, resized with it) and its output comes on stdout
/// alone.
enum ExecCommand {
    /// How a command reaches its container: the request, what goes in, what comes out; its status.
    typealias Path = @Sendable (ExecRequest, AsyncStream<ExecFrame>, @escaping @Sendable (ExecFrame) -> Void) async throws -> Int32

    static func run(_ arguments: Arguments, through route: Path) async throws -> Int32 {
        guard !arguments.rest.isEmpty else { fail("oss machine exec <id> [--tty] -- command…") }
        let tty = arguments.flags.contains("tty")
        var environment: [String: String] = [:]
        // A file of NAME=VALUE lines (tokens stay out of the command line).
        if let path = arguments.options["env-file"] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { fail("\(path): a line isn't NAME=VALUE") }
                environment[parts[0]] = parts[1]
            }
        }
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
        // Signals for the command, by Linux's numbers.
        var sources: [DispatchSourceSignal] = []
        for (number, linux) in [(SIGTERM, 15), (SIGINT, 2), (SIGHUP, 1), (SIGQUIT, 3), (SIGUSR1, 10), (SIGUSR2, 12)] as [(Int32, Int32)] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { continuation.yield(.signal(linux)) }
            source.resume()
            sources.append(source)
        }
        if tty {
            signal(SIGWINCH, SIG_IGN)
            let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
            resize.setEventHandler {
                if let size = terminalSize() { continuation.yield(.resize(columns: size.columns, rows: size.rows)) }
            }
            resize.resume()
            sources.append(resize)
        }
        // stdin, read on a thread of its own until it ends.
        Thread.detachNewThread {
            while true {
                let data = FileHandle.standardInput.availableData
                if data.isEmpty { continuation.yield(.closeStdin); return }
                continuation.yield(.stdin(data))
            }
        }
        let status = try await route(request, input) { frame in
            switch frame {
            case .stdout(let data): FileHandle.standardOutput.write(data)
            case .stderr(let data): FileHandle.standardError.write(data)
            default: break
            }
        }
        sources.forEach { $0.cancel() }
        continuation.finish()
        return status
    }

    #if canImport(Network)
    /// Straight to the container's exec socket (on the server's Mac).
    static func run(socket: String, _ arguments: Arguments) async throws -> Int32 {
        try await run(arguments) { request, input, output in
            try await OSSClient.exec(socket: socket, request, input: input, output: output)
        }
    }
    #endif

    /// A lease's command by the nearest way: its exec socket where that is
    /// on this computer, else through the server in `holder`'s name.
    static func path(_ lease: Lease, client: OSSClient, holder: String) -> Path {
        { request, input, output in
            #if canImport(Network)
            if let socket = lease.execSocket, FileManager.default.fileExists(atPath: socket) {
                return try await OSSClient.exec(socket: socket, request, input: input, output: output)
            }
            #endif
            return try await client.exec(lease.id, holder: holder, request, input: input, output: output)
        }
    }

    private static func terminalSize() -> (columns: Int, rows: Int)? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return nil }
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
