import Foundation
import OSSClient

// A Mac slot's commands and files (API 18, docs/primary-vms.md, "Apps on a
// slot"): the routes a container lease's take (ContainerAPI.swift), run on
// the slot's primary over SSH as the slot's user (`oss-<lease>`), in its
// home. The request's arguments are the program and its arguments: each
// reaches the primary as one single-quoted word of the SSH command line,
// and the slot's shell takes them as positional parameters, never as text
// of a script. A `gui` command runs in the primary's console session (its
// logged-in user's, `launchctl asuser`), one at a time on the primary,
// sharing `oss machine xctest --gui`'s turn.

/// The command lines a slot's commands and files send its primary: pure, so
/// tests can hold them to what the primary's shell reads.
enum SlotCommand {
    /// One word for a POSIX shell (and zsh, the primary's guest user's
    /// login shell, which reads SSH's command line): single-quoted, its own
    /// single quotes closed, escaped and reopened. Newlines, `$`, quotes
    /// and backslashes all survive.
    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func words(_ arguments: [String]) -> String { arguments.map(quote).joined(separator: " ") }

    /// A slot's home on the primary.
    static func home(_ lease: String) -> String { "/Users/\(SlotUser.name(lease))" }

    /// The SSH command line that runs `arguments` as `user` (sudo, with its
    /// home as HOME), from `/` (the guest user's home is no other user's to
    /// read); with `console`, as that user in its GUI session. Its status
    /// is the command's (a signal's 128 + n, as a shell gives it, not SSH's
    /// own 255).
    static func asUser(_ user: String, console: String? = nil, _ arguments: [String]) -> String {
        if let console {
            return "cd / && sudo launchctl asuser \"$(id -u \(quote(console)))\" sudo -u \(quote(console)) -H \(words(arguments)); exit $?"
        }
        return "cd / && sudo -u \(quote(user)) -H \(words(arguments)); exit $?"
    }

    /// The script a command starts in: `bash -l` (the profile's PATH),
    /// then `<pid file> <dir> [NAME=VALUE]… -- <program> [arguments]…`: the
    /// request's environment exported over the profile's, its directory
    /// entered, its pid written where a signal finds it, and the program
    /// exec'd in a process group of its own (Perl's setpgrp: a signal for
    /// the command reaches everything it started, and nothing of SSH's or
    /// sudo's). Not found: 127; a directory that can't be entered: 126.
    static let wrapper = """
        f=$1; d=$2; shift 2
        while [ "$#" -gt 0 ] && [ "$1" != -- ]; do export "$1"; shift; done
        [ "$#" -gt 0 ] && shift
        cd -- "$d" || exit 126
        echo $$ > "$f"
        exec /usr/bin/perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or do { print STDERR "oss: $ARGV[0]: $!\\n"; exit($!{ENOENT} ? 127 : 126) }' -- "$@"
        """

    /// Where a command's pid is kept on the primary while it runs.
    static func pidFile(lease: String, run: String) -> String { "/tmp/oss-exec-\(lease)-\(run).pid" }

    /// An environment variable's name: a shell's (letters, digits and `_`,
    /// not first a digit).
    static func validName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 256 else { return false }
        return (first == "_" || (first.isASCII && CharacterSet.letters.contains(first)))
            && name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// A path on the slot as the request gives it, made absolute: `~` and
    /// `~/…` its home, a relative one under its home; it must stay under
    /// the home or /tmp, and no `..` is taken.
    static func resolve(_ path: String, lease: String, what: String = "a path") throws -> String {
        let home = home(lease)
        guard !path.isEmpty, path.count <= 4096, !path.contains("\0") else { throw APIError(error: "\(what) on a slot is a path of its home or /tmp") }
        var full = path
        if full == "~" { full = home } else if full.hasPrefix("~/") { full = home + "/" + full.dropFirst(2) } else if !full.hasPrefix("/") { full = home + "/" + full }
        let parts = full.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !parts.contains("..") else { throw APIError(error: "\(what) on a slot can't climb out with `..`: \(path)") }
        let normal = "/" + parts.joined(separator: "/")
        let roots = [home, "/tmp", "/private/tmp"]
        guard roots.contains(where: { normal == $0 || normal.hasPrefix($0 + "/") }) else {
            throw APIError(error: "\(what) on a slot is under its home (\(home), ~/…, or relative) or /tmp: not \(path)")
        }
        return normal
    }

    /// The program a slot's command runs as on the primary: the wrapper's
    /// bash with the request's environment, directory (its home unless it
    /// names one) and arguments as its parameters. Refused: a terminal (not
    /// yet a slot's), no program, a NUL anywhere, a name no shell takes.
    static func execArguments(_ request: ExecRequest, lease: String, run: String) throws -> [String] {
        guard !request.tty else {
            throw APIError(error: "a Mac slot's command has no terminal (yet): run it without --tty, its output on stdout and stderr")
        }
        guard !request.arguments.isEmpty, request.arguments.count <= 10_000 else { throw APIError(error: "which command? arguments: [program, …]") }
        guard !request.arguments.contains(where: { $0.contains("\0") }), !request.arguments[0].isEmpty else {
            throw APIError(error: "a command's arguments can't hold a NUL, and its program has a name")
        }
        var environment: [String] = []
        for (name, value) in request.environment.sorted(by: { $0.key < $1.key }) {
            guard validName(name) else { throw APIError(error: "an environment variable's name is letters, digits and _: not \(name)") }
            guard !value.contains("\0") else { throw APIError(error: "\(name)'s value can't hold a NUL") }
            environment.append("\(name)=\(value)")
        }
        let directory = try request.workingDirectory.map { try resolve($0, lease: lease, what: "the working directory") } ?? home(lease)
        return ["/bin/bash", "-lc", wrapper, "oss-exec", pidFile(lease: lease, run: run), directory] + environment + ["--"] + request.arguments
    }

    /// The SSH command line of a slot's command: as its user, or (`gui`) as
    /// the primary's console user in its session.
    static func execLine(_ request: ExecRequest, lease: String, run: String, console: String) throws -> String {
        let arguments = try execArguments(request, lease: lease, run: run)
        return request.gui == true ? asUser(console, console: console, arguments) : asUser(SlotUser.name(lease), arguments)
    }

    /// Who a slot's command runs as on the primary.
    static func runner(_ request: ExecRequest, lease: String, console: String) -> String {
        request.gui == true ? console : SlotUser.name(lease)
    }

    /// The script (the guest user's, by Guest.run) that signals a running
    /// command's process group, as its own user (so it reaches nothing that
    /// isn't that user's): its pid file waited for a moment (a signal sent
    /// as it starts), then the group, else the process alone (a signal
    /// before its group was made).
    static func signalScript(lease: String, run: String, user: String, signal: String) -> String {
        """
        f=\(quote(pidFile(lease: lease, run: run)))
        i=0
        while [ ! -s "$f" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
        p=$(cat "$f" 2>/dev/null)
        case $p in ''|*[!0-9]*|0|1) exit 0;; esac
        sudo -u \(quote(user)) /bin/kill -s \(signal) -- "-$p" 2>/dev/null || sudo -u \(quote(user)) /bin/kill -s \(signal) "$p" 2>/dev/null || true
        """
    }

    /// A signal's name on the primary from its Linux number (ExecFrame's);
    /// nil for one a command isn't sent.
    static func signalName(linux: Int32) -> String? {
        [1: "HUP", 2: "INT", 3: "QUIT", 9: "KILL", 10: "USR1", 12: "USR2", 15: "TERM", 18: "CONT", 19: "STOP", 20: "TSTP", 28: "WINCH"][linux]
    }

    /// A file command of ContainerAPI's (`/bin/sh -c <script> oss-files …`)
    /// as the slot's user.
    static func filesLine(lease: String, _ arguments: [String]) -> String { asUser(SlotUser.name(lease), arguments) }
}

#if canImport(Network)

/// A slot's routes (ContainerAPI dispatches them).
enum SlotAPI {
    /// The slot's primary, or `notReady`.
    static func slot(_ lease: Lease, api: API) async throws -> MacXCTest.Slot {
        guard let slot = await api.machines.slotRun(lease.id) else {
            throw APIError(error: "lease \(lease.id)'s primary macOS VM is gone (or not ready)", code: "notReady")
        }
        return slot
    }

    /// File commands on the slot: ContainerAPI's own script, over SSH as the
    /// slot's user, its paths made absolute and kept to its home and /tmp.
    static func files(_ lease: Lease, api: API) async throws -> FileCommands {
        let slot = try await slot(lease, api: api)
        let id = lease.id
        return FileCommands(start: { arguments, stdout in
            try RemoteProcess.start("/usr/bin/ssh", slot.guest.sshArguments(SlotCommand.filesLine(lease: id, arguments)), stdout: stdout)
        }, resolve: { try SlotCommand.resolve($0, lease: id) })
    }

    /// What the exec's client sends, as it comes.
    private enum Upstream: Sendable {
        case frame(ExecFrame)
        case gone
    }

    /// `POST …/exec` on a slot: its command run on the primary, frames
    /// relayed as a container's are; the client going (or a signal frame)
    /// signals the command's process group there: TERM, then KILL ten
    /// seconds on.
    static func exec(_ request: HTTPRequest, _ peer: CachePeer, lease: Lease, api: API) async throws {
        guard let exec = try await ContainerAPI.execRequest(request, peer) else { return }
        let slot = try await slot(lease, api: api)
        let run = Random.hex(6)
        let line = try SlotCommand.execLine(exec, lease: lease.id, run: run, console: slot.console)
        let user = SlotCommand.runner(exec, lease: lease.id, console: slot.console)
        let gui = exec.gui == true
        let guest = slot.guest
        let upgraded = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: \(OSSExecProtocol.name)\r\n\r\n"
        guard await peer.send(Data(upgraded.utf8)) else { return }
        log("lease \(lease.id): exec \(exec.arguments[0]) on its primary" + (gui ? " (GUI)" : ""))

        // The client's frames, kept from the start (stdin may come before the command does).
        let (frames, feed) = AsyncStream<Upstream>.makeStream()
        let gone = Flag()
        let reader = Task {
            var buffer = Data()
            while let data = await peer.next() {
                buffer.append(data)
                for frame in ExecFrame.decode(&buffer) { feed.yield(.frame(frame)) }
            }
            gone.set()
            feed.yield(.gone)
            feed.finish()
        }
        defer { reader.cancel() }

        // A GUI command waits its turn for the primary's session.
        let runs = api.machines.xctests
        let turn = "exec-\(run)"
        if gui, !(await runs.takeGUI(turn)) {
            _ = await peer.send(ExecFrame.stderr(Data("oss: waiting for the primary's GUI session (another --gui command or run has it)\n".utf8)).encoded)
            while !(await runs.takeGUI(turn)) {
                guard !gone.value else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { if gui { Task { await runs.giveGUI(turn) } } }
        guard !gone.value else { return }
        if !gui {
            // The slot's keychain unlocked, as for its tests.
            _ = try? await guest.run(SlotUser.unlockScript(lease: lease.id, password: slot.keychainPassword), timeout: 60)
        }

        let process: RemoteProcess
        do {
            process = try RemoteProcess.start("/usr/bin/ssh", guest.sshArguments(line),
                                              stdout: { data in _ = await peer.send(ExecFrame.stdout(data).encoded); return true },
                                              stderr: { data in _ = await peer.send(ExecFrame.stderr(data).encoded); return true })
        } catch {
            _ = await peer.send(ExecFrame.stderr(Data("oss: ssh to the primary: \(error)\n".utf8)).encoded)
            _ = await peer.send(ExecFrame.exit(127).encoded)
            peer.close()
            return
        }
        @Sendable func signal(_ name: String) async {
            _ = try? await guest.run(SlotCommand.signalScript(lease: lease.id, run: run, user: user, signal: name), timeout: 30)
        }
        // The client's frames to the command; its going ends it.
        let downstream = Task {
            for await event in frames {
                switch event {
                case .frame(.stdin(let data)): try? await process.write(.stdin(data))
                case .frame(.closeStdin): try? await process.write(.closeStdin)
                case .frame(.signal(let number)):
                    if let name = SlotCommand.signalName(linux: number) { Task { await signal(name) } }
                case .frame: break
                case .gone:
                    guard process.isRunning else { return }
                    await signal("TERM")
                    for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
                    if process.isRunning { await signal("KILL") }
                    process.close()
                    return
                }
            }
        }
        let result = await process.finish()
        downstream.cancel()
        Task { _ = try? await guest.run("sudo rm -f \(SlotCommand.quote(SlotCommand.pidFile(lease: lease.id, run: run)))", timeout: 60) }
        log("lease \(lease.id): exec \(exec.arguments[0]) ended (\(result.status))")
        if !gone.value { _ = await peer.send(ExecFrame.exit(result.status).encoded) }
        peer.close()
    }
}

/// A flag set once, read from anywhere.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() { lock.withLock { isSet = true } }
    var value: Bool { lock.withLock { isSet } }
}

/// A program on the server's Mac (`ssh` to a slot's primary) as a
/// `MachineCommand`: frames to its standard input, its stdout and stderr
/// handed to `stdout` and `stderr` as they come (else kept, as a
/// container's command's are: a megabyte of stdout, 64 KB of stderr), its
/// exit status (128 + n for a signal). A slow reader holds the program
/// back: each pipe's next read waits until its last piece was handed on.
final class RemoteProcess: MachineCommand, @unchecked Sendable {
    typealias Sink = @Sendable (Data) async -> Bool

    private let process: Process
    private let input: FileHandle
    private let writes = DispatchQueue(label: "oss.remote.stdin")
    private let result: Task<ContainerCommand.Result, Never>

    private init(process: Process, input: FileHandle, result: Task<ContainerCommand.Result, Never>) {
        self.process = process
        self.input = input
        self.result = result
    }

    private enum Event: Sendable {
        case out(Data), err(Data), end, exit(Int32)
    }

    /// Started. A sink answering false (its reader gone) ends the program
    /// (SIGTERM; what it held is drained, not handed on).
    static func start(_ executable: String, _ arguments: [String], stdout: Sink? = nil, stderr: Sink? = nil) throws -> RemoteProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let (inPipe, outPipe, errPipe) = (Pipe(), Pipe(), Pipe())
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        let (events, feed) = AsyncStream<Event>.makeStream()
        process.terminationHandler = { process in
            feed.yield(.exit(process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus))
        }
        try process.run()
        let outGate = DispatchSemaphore(value: 0), errGate = DispatchSemaphore(value: 0)
        for (handle, gate, isOut) in [(outPipe.fileHandleForReading, outGate, true), (errPipe.fileHandleForReading, errGate, false)] {
            let descriptor = handle.fileDescriptor
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    let data = Data(buffer[0..<count])
                    feed.yield(isOut ? .out(data) : .err(data))
                    gate.wait()
                }
                try? handle.close()
                feed.yield(.end)
            }
        }
        let result = Task {
            var output = Data(), error = Data()
            var ends = 0, status: Int32?
            var readerGone = false
            for await event in events {
                switch event {
                case .out(let data), .err(let data):
                    let isOut: Bool
                    if case .out = event { isOut = true } else { isOut = false }
                    if let sink = isOut ? stdout : stderr {
                        if !readerGone, !(await sink(data)) {
                            readerGone = true
                            if process.isRunning { process.terminate() }
                        }
                    } else if isOut, output.count < 1 << 20 {
                        output.append(data)
                    } else if !isOut, error.count < 64 << 10 {
                        error.append(data)
                    }
                    (isOut ? outGate : errGate).signal()
                case .end: ends += 1
                case .exit(let code): status = code
                }
                if ends == 2, status != nil { break }
            }
            return ContainerCommand.Result(status: status ?? -1, output: output, error: String(decoding: error, as: UTF8.self))
        }
        return RemoteProcess(process: process, input: inPipe.fileHandleForWriting, result: result)
    }

    var isRunning: Bool { process.isRunning }

    /// Standard input's bytes, or its end; nothing else reaches a program.
    func write(_ frame: ExecFrame) async throws {
        let input = input
        switch frame {
        case .stdin(let data):
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writes.async {
                    do { try input.write(contentsOf: data); continuation.resume() } catch { continuation.resume(throwing: error) }
                }
            }
        case .closeStdin:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writes.async { try? input.close(); continuation.resume() }
            }
        default:
            break
        }
    }

    func finish() async -> ContainerCommand.Result {
        let done = await result.value
        writes.async { [input] in try? input.close() }
        return done
    }

    /// Ended (SIGTERM): `ssh` gone, what it ran on the primary sees its
    /// streams close.
    func close() {
        if process.isRunning { process.terminate() }
        writes.async { [input] in try? input.close() }
    }
}

#endif
