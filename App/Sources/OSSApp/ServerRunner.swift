import AppKit
import Foundation
import Observation
import OSSServer

/// The server, run in this app's own process (`ServerHost`): started at
/// launch, its log appended to ~/Library/Logs/OS Server.log and its last
/// lines kept for the window. The macOS VMs it lends run in this process
/// too, so quitting the app ends them (the other machines' leases are
/// taken up again at the next launch). If another server answers on the
/// port (the launch agent's, before 0.7), the app leaves it be until asked
/// to take over.
@MainActor @Observable
final class ServerRunner {
    enum State: Equatable {
        case stopped
        case starting
        case running(since: Date)
        /// Another server answers on the port (the launch agent's, or one
        /// run by hand): this app leaves it be.
        case elsewhere
        case failed(String)
    }

    private(set) var state: State = .stopped
    private(set) var lines: [String] = []
    private var host: ServerHost?

    let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OS Server.log")
    static let launchAgent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/oss.server.plist")
    /// The command line inside the app (its link in ~/.local/bin is Settings').
    let commandLine = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/oss")

    /// Canned, for the proof's screens (Fixture.swift): nothing started.
    func pretend(_ state: State, lines: [String]) {
        self.state = state
        self.lines = lines
    }

    func start() async {
        guard host == nil else { return }
        state = .starting
        if await Self.anotherServerAnswers(port: ServerSettings.load().port) {
            state = .elsewhere
            return
        }
        // What the launch agent gave the server: Homebrew's tools (AXe) on
        // PATH, and this checkout's provisioning scripts when it's there.
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", 1)
        let repository = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/oss").path
        if ProcessInfo.processInfo.environment["OSS_REPO"] == nil, FileManager.default.fileExists(atPath: repository) {
            setenv("OSS_REPO", repository, 1)
        }
        let file = LogFile(logFile)
        ServerLog.sink = { [weak self] line in
            file.append(Data((line + "\n").utf8))
            Task { @MainActor in self?.append(line) }
        }
        do {
            // Containers where this Mac can run them (Containerization's network needs macOS 26).
            var containers: ContainerBackend?
            if #available(macOS 26, *) { containers = ContainerEngine() }
            host = try ServerHost.start(containers: containers)
            state = .running(since: Date())
        } catch {
            state = .failed("The server couldn't start: \(error.localizedDescription)")
        }
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

    /// Everything OS Server put on this Mac taken away, so that removing the
    /// app leaves the Mac as it was: every lease ended, its folder in
    /// Application Support (settings, the machines' bases), the files an
    /// earlier oss kept (~/.config/oss, ~/.local/state/oss,
    /// ~/.local/share/oss: the Android SDK it set up), its log, the launch
    /// agent's plist, the command line's link and the login item; UTM's
    /// `oss-` VMs too when asked. Then the app quits.
    func removeEverything(includingUTMMachines: Bool) async {
        state = .starting
        await host?.removeEverything(includingUTMMachines: includingUTMMachines)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let uid = getuid()
        await (try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["bootout", "gui/\(uid)/oss.server"]))?.waitUntilExitAsync()
        let link = home.appendingPathComponent(".local/bin/oss")
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
           destination.contains(".app/Contents/Helpers/oss") {
            try? FileManager.default.removeItem(at: link)
        }
        for path in [Self.launchAgent.path, Self.launchAgent.path + ".disabled", logFile.path,
                     home.appendingPathComponent("Library/Logs/oss.log").path] {
            try? FileManager.default.removeItem(atPath: path)
        }
        try? await LoginItem.unregister()
        NSApp.terminate(nil)
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    static func anotherServerAnswers(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/hello") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// What the app reads of the server's settings: its port, and the token
/// beside it. The server's folder (Application Support/OS Server), or before
/// 0.7's first start ~/.config/oss, where the launch agent's server kept them.
struct ServerSettings: Decodable {
    var port: Int = 7480

    static var home: URL {
        ProcessInfo.processInfo.environment["OSS_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static var directories: [URL] {
        [home.appendingPathComponent("Library/Application Support/OS Server"), home.appendingPathComponent(".config/oss")]
    }

    static func load() -> ServerSettings {
        for directory in directories {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("server.json")),
               let settings = try? JSONDecoder().decode(ServerSettings.self, from: data) { return settings }
        }
        return ServerSettings()
    }

    static func token() -> String? {
        for directory in directories {
            if let token = (try? String(contentsOf: directory.appendingPathComponent("token"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty { return token }
        }
        return nil
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

/// The log file the server's lines are appended to, from whatever thread
/// logs them.
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
