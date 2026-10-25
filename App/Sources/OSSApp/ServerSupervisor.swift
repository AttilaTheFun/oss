import AppKit
import Foundation
import Observation

/// The server, run as this app's helper: `Contents/Helpers/oss serve`, the
/// same binary as the command line's. Restarted when it ends unasked (a
/// second later, then waiting longer each time, at most a minute); its
/// output goes to ~/Library/Logs/oss.log, as the launch agent's did, and the
/// last lines are kept for the window. Emulators the server starts keep
/// running when it stops: they are not in its process group.
@MainActor @Observable
final class ServerSupervisor {
    enum State: Equatable {
        case stopped
        case starting
        case running(pid: Int32, since: Date)
        /// Another server answers on the port (the launch agent's, or one
        /// run by hand): this app leaves it be.
        case elsewhere
        case failed(String)
    }

    private(set) var state: State = .stopped
    private(set) var lines: [String] = []
    private var process: Process?
    private var wanted = false
    private var failures = 0

    let helper: URL
    let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/oss.log")
    static let launchAgent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/oss.server.plist")

    init(helper: URL) {
        self.helper = helper
    }

    /// Canned, for the proof's screens (Fixture.swift): no process.
    func pretend(_ state: State, lines: [String]) {
        self.state = state
        self.lines = lines
    }

    func start() async {
        wanted = true
        guard process == nil else { return }
        state = .starting
        if await Self.anotherServerAnswers(port: ServerSettings.load().port) {
            state = .elsewhere
            return
        }
        launch()
    }

    func stop() {
        wanted = false
        guard let process else {
            state = .stopped
            return
        }
        process.terminate()
    }

    func restart() async {
        stop()
        while process != nil { try? await Task.sleep(for: .milliseconds(100)) }
        await start()
    }

    /// Takes over from the launch agent: unloads it, keeps its plist beside
    /// it as `.disabled` (so a login doesn't start it again), and starts.
    func takeOver() async {
        let uid = getuid()
        await (try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["bootout", "gui/\(uid)/oss.server"]))?.waitUntilExitAsync()
        let disabled = Self.launchAgent.appendingPathExtension("disabled")
        if FileManager.default.fileExists(atPath: Self.launchAgent.path) {
            try? FileManager.default.removeItem(at: disabled)
            try? FileManager.default.moveItem(at: Self.launchAgent, to: disabled)
        }
        // The port is the old server's until it has gone.
        for _ in 0..<50 where await Self.anotherServerAnswers(port: ServerSettings.load().port) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await start()
    }

    private func launch() {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        // What the launch agent gave it: Homebrew's tools (AXe) on PATH.
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        let repository = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/oss").path
        if environment["OSS_REPO"] == nil, FileManager.default.fileExists(atPath: repository) {
            environment["OSS_REPO"] = repository
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let file = LogFile(logFile)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            file.append(data)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in self?.ended(status) }
        }
        do {
            try process.run()
            self.process = process
            state = .running(pid: process.processIdentifier, since: Date())
        } catch {
            state = .failed("couldn't start \(helper.path): \(error.localizedDescription)")
        }
    }

    private func append(_ text: String) {
        lines += text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    private func ended(_ status: Int32) {
        process = nil
        guard wanted else {
            state = .stopped
            return
        }
        failures += 1
        let delay = min(60, 1 << min(failures - 1, 6))
        state = .failed("The server ended (status \(status)); starting it again in \(delay) s.")
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if wanted, process == nil { launch() }
        }
    }

    static func anotherServerAnswers(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/hello") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// What the app reads of the server's settings (~/.config/oss/server.json):
/// its port; the token beside it.
struct ServerSettings: Decodable {
    var port: Int = 7480

    static var directory: URL {
        let home = ProcessInfo.processInfo.environment["OSS_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/oss")
    }

    static func load() -> ServerSettings {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("server.json")),
              let settings = try? JSONDecoder().decode(ServerSettings.self, from: data) else { return ServerSettings() }
        return settings
    }

    static func token() -> String? {
        (try? String(contentsOf: directory.appendingPathComponent("token"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 7480
    }

    enum CodingKeys: String, CodingKey { case port }
}

extension Process {
    /// Waits for it without blocking the main actor.
    func waitUntilExitAsync() async {
        while isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

/// The log file the server's output is appended to, written from the
/// pipe's reading thread.
final class LogFile: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()

    init(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: data)
    }
}
