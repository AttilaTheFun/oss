import Foundation
import OSSClient

// Pictures and recordings of a lease's screen (API 19, docs/primary-vms.md,
// "Pictures and recordings"): every lease that shows something takes the
// same verbs, whatever is behind them.
//
// - An emulator (Android): `adb shell screenrecord`, H.264 on the device,
//   ended by SIGINT (`pkill -INT screenrecord` there: it finishes its file),
//   pulled back. Where screenrecord stops itself (three minutes, unless its
//   `--time-limit 0` is there: Android 14 and later), the next part begins
//   at once, and the parts are joined here on the server's Mac (ffmpeg's
//   concat where ffmpeg is installed, else AVFoundation's composition,
//   passed through: no frame encoded again).
// - A simulator (iOS): `xcrun simctl io <udid> recordVideo --codec=h264`,
//   its corners masked as its screenshots' are, ended by SIGINT.
// - A VM, or a Mac slot (its primary's screen, only while the slot holds
//   the primary's GUI session): the guest's VNC frames at up to 30 a
//   second, encoded here by AVFoundation (VideoToolbox's H.264), cropped
//   to an app's window where a slot asks for one (its frame read in the
//   primary's console session by `ScreenMedia.windowScript`).
//
// One recording at a time a lease; one left running ends with the lease,
// its file discarded.

/// A rectangle: CGWindowList's (points, from the top left of the main
/// display), or a framebuffer's (pixels).
struct ScreenRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// What `ScreenMedia.windowScript` reads in a Mac's console session: the
/// app's frontmost window's frame and the main display's, in points.
struct WindowFrame: Codable, Equatable, Sendable {
    var owner: String
    var bundle: String?
    var window: ScreenRect
    var screen: ScreenRect
}

/// A crop in a framebuffer's pixels.
struct PixelRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/// The pure parts of pictures and recordings: command lines, crop
/// arithmetic, the parts a recording is joined from.
enum ScreenMedia {
    // MARK: A window's crop

    /// A window's frame (points) as a framebuffer's pixels: scaled by the
    /// framebuffer's size over the display's (the screen's backing factor,
    /// as VNC sees it: 2 on a Retina-sized display, 1 otherwise), its edges
    /// rounded outward, kept within the framebuffer. `even`: its width and
    /// height made even (H.264 wants them so). Nil when no pixel of it is
    /// on the screen.
    static func crop(_ frame: WindowFrame, framebufferWidth: Int, framebufferHeight: Int, even: Bool = false) -> PixelRect? {
        guard frame.screen.width > 0, frame.screen.height > 0, framebufferWidth > 0, framebufferHeight > 0 else { return nil }
        let sx = Double(framebufferWidth) / frame.screen.width, sy = Double(framebufferHeight) / frame.screen.height
        let left = max(0, Int(((frame.window.x - frame.screen.x) * sx).rounded(.down)))
        let top = max(0, Int(((frame.window.y - frame.screen.y) * sy).rounded(.down)))
        let right = min(framebufferWidth, Int(((frame.window.x + frame.window.width - frame.screen.x) * sx).rounded(.up)))
        let bottom = min(framebufferHeight, Int(((frame.window.y + frame.window.height - frame.screen.y) * sy).rounded(.up)))
        var width = right - left, height = bottom - top
        if even {
            width -= width % 2
            height -= height % 2
        }
        guard width > 0, height > 0 else { return nil }
        return PixelRect(x: left, y: top, width: width, height: height)
    }

    /// A video's size for frames of this size: within `most` on its longer
    /// side (H.264's encoders stop at 4096), its aspect kept, both even.
    static func videoSize(width: Int, height: Int, most: Int = 4096) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (2, 2) }
        let scale = min(1, Double(most) / Double(max(width, height)))
        func even(_ value: Double) -> Int { max(2, Int(value.rounded(.down)) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// The JavaScript for Automation `osascript -l JavaScript` runs in the
    /// console session: the frontmost on-screen window (layer 0, front to
    /// back as CGWindowList gives them) of the app named by its first
    /// argument (its name, or its bundle identifier; any case), as a
    /// `WindowFrame`'s JSON. Window bounds and owners need no Screen
    /// Recording permission (titles would). None: an error naming the apps
    /// that have windows, and status 1.
    static let windowScript = """
        ObjC.import('CoreGraphics');
        ObjC.import('AppKit');
        function run(argv) {
          var want = (argv[0] || '').toLowerCase();
          var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1 | 16, 0))) || [];
          var seen = [];
          for (var i = 0; i < list.length; i++) {
            var w = list[i];
            var b = w.kCGWindowBounds;
            if (w.kCGWindowLayer !== 0 || !b || b.Width < 2 || b.Height < 2) continue;
            var owner = w.kCGWindowOwnerName || '';
            var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(w.kCGWindowOwnerPID);
            var bundle = (app && !app.isNil()) ? (ObjC.unwrap(app.bundleIdentifier) || '') : '';
            if (owner.toLowerCase() === want || bundle.toLowerCase() === want) {
              var d = $.CGDisplayBounds($.CGMainDisplayID());
              return JSON.stringify({owner: owner, bundle: bundle,
                window: {x: b.X, y: b.Y, width: b.Width, height: b.Height},
                screen: {x: d.origin.x, y: d.origin.y, width: d.size.width, height: d.size.height}});
            }
            if (owner && seen.indexOf(owner) < 0) seen.push(owner);
          }
          throw new Error('no window of ' + argv[0] + ' on the screen' + (seen.length ? ' (windows there: ' + seen.join(', ') + ')' : ''));
        }
        """

    /// The SSH command line that reads `app`'s window on a primary, in its
    /// console user's session.
    static func windowLine(app: String, console: String) -> String {
        SlotCommand.asUser(console, console: console, ["/usr/bin/osascript", "-l", "JavaScript", "-e", windowScript, app])
    }

    /// `windowScript`'s answer, or why there is none (osascript's error,
    /// its decoration trimmed).
    static func window(fromOutput output: String, error: String, status: Int32, app: String) throws -> WindowFrame {
        if status == 0, let frame = try? JSONDecoder().decode(WindowFrame.self, from: Data(output.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) {
            return frame
        }
        var said = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = said.range(of: "Error: ", options: .backwards) { said = String(said[range.upperBound...]) }
        if let range = said.range(of: #" \(-\d+\)$"#, options: .regularExpression) { said.removeSubrange(range) }
        throw APIError(error: said.isEmpty ? "no window of \(app) on the primary's screen" : said, code: "noWindow")
    }

    /// An app named for `--window`: a name or bundle identifier, nothing a
    /// line can't carry.
    static func validApp(_ app: String) -> Bool {
        !app.isEmpty && app.count <= 256 && !app.contains(where: { $0.isNewline || $0 == "\0" })
    }

    // MARK: Emulators

    /// The bit rate an emulator records at.
    static let androidBitRate = 6_000_000

    /// Where an emulator keeps a recording's part while it records.
    static func androidPart(lease: String, part: Int) -> String { "/sdcard/oss-\(lease)-\(part).mp4" }

    /// adb's arguments that record a part (`unlimited`: screenrecord takes
    /// `--time-limit 0`, so it records until it is stopped).
    static func androidRecord(serial: String, path: String, unlimited: Bool) -> [String] {
        ["-s", serial, "shell", "screenrecord", "--bit-rate", String(androidBitRate)] + (unlimited ? ["--time-limit", "0"] : []) + [path]
    }

    /// adb's arguments that end a recording: SIGINT, on which screenrecord
    /// finishes its file. The emulator is the lease's own: no one else's
    /// screenrecord is there.
    static func androidStop(serial: String) -> [String] { ["-s", serial, "shell", "pkill", "-INT", "screenrecord"] }

    /// Whether screenrecord's help says it takes `--time-limit 0` (no limit).
    static func androidUnlimited(help: String) -> Bool { help.contains("Set to 0") }

    // MARK: Simulators

    /// simctl's arguments (after `xcrun`) that record a simulator's screen,
    /// its corners and Dynamic Island masked black as its screenshots are.
    static func simulatorRecord(udid: String, path: String) -> [String] {
        ["simctl", "io", udid, "recordVideo", "--codec=h264", "--mask=black", "--force", path]
    }

    /// Where a simulator in the primary records: a file of its own in the
    /// primary's /tmp, named by the recording.
    static func primaryRecordingPath(_ name: String) -> String { "/tmp/oss-recording-\(name).mp4" }

    /// pkill's pattern for that recording's simctl (its path, which no
    /// other command line has; a regular expression: its dots escaped).
    static func primaryRecordingPattern(_ path: String) -> String {
        "recordVideo.*" + path.replacingOccurrences(of: ".", with: "\\.")
    }

    /// A file of the primary's (`$1`) on standard output, then deleted.
    static let fetchAndDeleteScript = #"cat -- "$1"; s=$?; rm -f -- "$1"; exit $s"#

    // MARK: Joining parts

    /// What a recording's parts become: none recorded, one that is the
    /// recording, or several to join (each with something in it, in order).
    enum Join: Equatable {
        case nothing
        case one(String)
        case several([String])
    }

    static func join(parts: [(path: String, bytes: Int64)]) -> Join {
        let kept = parts.filter { $0.bytes > 0 }.map(\.path)
        switch kept.count {
        case 0: return .nothing
        case 1: return .one(kept[0])
        default: return .several(kept)
        }
    }

    /// ffmpeg's concat list for these files.
    static func concatList(_ files: [String]) -> String {
        files.map { "file '" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'\n" }.joined()
    }

    /// ffmpeg's arguments that join the files a concat list names into one
    /// MP4, their frames copied, not encoded again.
    static func ffmpegJoin(list: String, output: String) -> [String] {
        ["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", "-movflags", "+faststart", output]
    }

    /// ffmpeg, where the server's Mac has one.
    static func ffmpeg(candidates: [String] = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The longest a recording runs: then it is ended, as if asked, and
    /// kept for its stop.
    static let longest: TimeInterval = 60 * 60
}

// MARK: The recordings under way

/// A recording under way.
protocol ScreenRecorder: AnyObject, Sendable {
    /// Ended (if it hasn't ended itself): the MP4's path, the caller's to
    /// delete; or why there is none.
    func stop() async throws -> String
    /// Ended, its files deleted.
    func discard() async
}

/// Each lease's recording: one at a time a lease.
actor Recordings {
    private var active: [String: any ScreenRecorder] = [:]
    private var starting: Set<String> = []
    /// Leases that ended while their recording was starting.
    private var forgotten: Set<String> = []

    /// A place for `lease`'s recording, or `busy`.
    func reserve(_ lease: String) throws {
        guard active[lease] == nil, !starting.contains(lease) else {
            throw APIError(error: "busy: lease \(lease) is recording already (one recording at a time a lease): stop it first", code: "busy")
        }
        starting.insert(lease)
        forgotten.remove(lease)
    }

    /// Its place given back: it didn't start.
    func cancel(_ lease: String) { starting.remove(lease) }

    /// The recording started: kept, unless its lease ended meanwhile (false:
    /// the caller discards it).
    func attach(_ lease: String, _ recorder: any ScreenRecorder) -> Bool {
        starting.remove(lease)
        guard !forgotten.contains(lease) else {
            forgotten.remove(lease)
            return false
        }
        active[lease] = recorder
        return true
    }

    /// The lease's recording, taken to be stopped.
    func take(_ lease: String) -> (any ScreenRecorder)? { active.removeValue(forKey: lease) }

    func isRecording(_ lease: String) -> Bool { active[lease] != nil || starting.contains(lease) }

    /// The lease ended: its recording discarded (one still starting, as it
    /// attaches).
    func discard(_ lease: String) async {
        if starting.contains(lease) { forgotten.insert(lease) }
        guard let recorder = active.removeValue(forKey: lease) else { return }
        await recorder.discard()
    }
}

#if os(macOS)

/// A program run to its end in the background: its exit awaited, its
/// standard error kept (the last 16 KB).
final class BackgroundProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var errorText = Data()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            self.lock.withLock {
                self.errorText.append(data)
                if self.errorText.count > 16 << 10 { self.errorText = self.errorText.suffix(16 << 10) }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let code = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
            let waiting = self.lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
                self.status = code
                defer { self.waiters = [] }
                return self.waiters
            }
            waiting.forEach { $0.resume(returning: code) }
        }
        try process.run()
    }

    var error: String { lock.withLock { String(decoding: errorText, as: UTF8.self) } }
    var isRunning: Bool { lock.withLock { status == nil } }

    /// Its exit status, once it has exited.
    func exited() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Int32? in
                if let status { return status }
                waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    /// Its exit status, or nil if it is still running after `seconds`.
    func exited(within seconds: Double) async -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let status = lock.withLock({ status }) { return status }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return lock.withLock { status }
    }

    func interrupt() { if isRunning { process.interrupt() } }
    func terminate() { if isRunning { process.terminate() } }
}

/// A simulator's screen, recorded by `simctl io recordVideo` into a file
/// of the server's until SIGINT; a simulator in the primary's, into a file
/// of the primary's /tmp (simctl over SSH, ended by `pkill -INT` there),
/// brought back when it ends.
final class SimulatorRecorder: ScreenRecorder, @unchecked Sendable {
    private let recording: BackgroundProcess
    private let path: String
    private let host: SimulatorHost
    /// Its file on the primary, where it records there.
    private let remotePath: String?

    private init(recording: BackgroundProcess, path: String, host: SimulatorHost, remotePath: String?) {
        self.recording = recording
        self.path = path
        self.host = host
        self.remotePath = remotePath
    }

    /// Begun: answers once simctl says it is recording (or within ten
    /// seconds); its failing to start, thrown.
    static func start(udid: String, folder: String, on host: SimulatorHost = .local) async throws -> SimulatorRecorder {
        Paths.ensure(folder)
        let path = "\(folder)/simulator.mp4"
        let process: BackgroundProcess
        var remotePath: String?
        if let guest = host.guest {
            let remote = ScreenMedia.primaryRecordingPath(Random.hex(6))
            remotePath = remote
            process = try BackgroundProcess("/usr/bin/ssh", guest.sshArguments(SimulatorHost.remoteLine("/usr/bin/xcrun",
                                                                                                         ScreenMedia.simulatorRecord(udid: udid, path: remote))))
        } else {
            process = try BackgroundProcess("/usr/bin/xcrun", ScreenMedia.simulatorRecord(udid: udid, path: path))
        }
        for _ in 0..<100 {
            if !process.isRunning {
                throw APIError(error: "simctl io recordVideo ended at once: \(process.error.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if process.error.contains("Recording started") { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return SimulatorRecorder(recording: process, path: path, host: host, remotePath: remotePath)
    }

    func stop() async throws -> String {
        if let remotePath {
            // SSH's SIGINT reaches no remote command without a terminal: simctl's own, there.
            _ = try? await host.run("/usr/bin/pkill", ["-INT", "-f", ScreenMedia.primaryRecordingPattern(remotePath)], timeout: 60)
            if await recording.exited(within: 30) == nil {
                _ = try? await host.run("/usr/bin/pkill", ["-KILL", "-f", ScreenMedia.primaryRecordingPattern(remotePath)], timeout: 60)
                recording.terminate()
                _ = await recording.exited(within: 5)
            }
            // Straight into its file here (an hour's is gigabytes: not through memory).
            let fetched = try await Shell.run("/bin/bash", ["-c", "/usr/bin/ssh \"${@:2}\" > \"$1\"", "bash", path]
                                               + (host.guest?.sshArguments(SimulatorHost.remoteLine("/bin/sh", ["-c", ScreenMedia.fetchAndDeleteScript, "sh", remotePath])) ?? []),
                                              timeout: 1800)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            guard fetched.ok, size > 0 else {
                throw APIError(error: "the simulator's recording made no file on the primary: "
                                    + "\(recording.error.trimmingCharacters(in: .whitespacesAndNewlines)) \(fetched.error.suffix(300))")
            }
            return path
        }
        recording.interrupt()
        if await recording.exited(within: 30) == nil {
            recording.terminate()
            _ = await recording.exited(within: 5)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        guard size > 0 else {
            throw APIError(error: "the simulator's recording made no file: \(recording.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return path
    }

    func discard() async {
        if let remotePath {
            _ = try? await host.run("/usr/bin/pkill", ["-KILL", "-f", ScreenMedia.primaryRecordingPattern(remotePath)], timeout: 60)
            _ = try? await host.run("/bin/rm", ["-f", remotePath], timeout: 60)
        }
        recording.terminate()
        _ = await recording.exited(within: 5)
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// An emulator's screen, recorded by `screenrecord` on the device in parts
/// (each until screenrecord stops itself, or is stopped), pulled back and
/// joined when it ends.
final class EmulatorRecorder: ScreenRecorder, @unchecked Sendable {
    private let config: ServerConfig
    private let serial: String
    private let lease: String
    private let folder: String
    private let unlimited: Bool
    private let lock = NSLock()
    private var parts: [String] = []
    private var current: BackgroundProcess?
    private var stopping = false
    private var failure: String?
    private var loop: Task<Void, Never>?
    private let began = Date()

    private init(config: ServerConfig, port: Int, lease: String, folder: String, unlimited: Bool) {
        self.config = config
        self.serial = "emulator-\(port)"
        self.lease = lease
        self.folder = folder
        self.unlimited = unlimited
    }

    private func adb(_ arguments: [String], timeout: TimeInterval = 120) async -> ProcessResult? {
        try? await Emulators.adb(config, arguments, timeout: timeout)
    }

    /// Begun: its first part started (and still recording a moment on).
    static func start(config: ServerConfig, port: Int, lease: String, folder: String) async throws -> EmulatorRecorder {
        Paths.ensure(folder)
        let help = try? await Emulators.adb(config, ["-s", "emulator-\(port)", "shell", "screenrecord", "--help"], timeout: 30)
        let recorder = EmulatorRecorder(config: config, port: port, lease: lease, folder: folder,
                                        unlimited: ScreenMedia.androidUnlimited(help: (help?.output ?? "") + (help?.error ?? "")))
        try recorder.startPart()
        try? await Task.sleep(for: .milliseconds(800))
        if let first = recorder.lock.withLock({ recorder.current }), !first.isRunning {
            let said = first.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError(error: "screenrecord ended at once" + (said.isEmpty ? "" : ": \(said)"))
        }
        recorder.loop = Task { await recorder.keepRecording() }
        return recorder
    }

    private func startPart() throws {
        let path = lock.withLock { ScreenMedia.androidPart(lease: lease, part: parts.count) }
        let process = try BackgroundProcess(Emulators.adbPath(config), ScreenMedia.androidRecord(serial: serial, path: path, unlimited: unlimited),
                                            environment: Emulators.environment(config))
        lock.withLock {
            parts.append(path)
            current = process
        }
    }

    /// Each part to its end; the next begun if it ended by itself (its time
    /// limit), until the recording is stopped or has run its longest.
    private func keepRecording() async {
        while true {
            guard let part = lock.withLock({ current }) else { return }
            let status = await part.exited()
            let (stopped, count) = lock.withLock { (stopping, parts.count) }
            if stopped { return }
            guard status == 0 else {
                lock.withLock { failure = "screenrecord ended (\(status)): \(part.error.trimmingCharacters(in: .whitespacesAndNewlines))" }
                return
            }
            guard Date().timeIntervalSince(began) < ScreenMedia.longest, count < 1000 else {
                log("lease \(lease): its recording has run its longest (\(Int(ScreenMedia.longest / 60)) min); kept for its stop")
                lock.withLock { stopping = true }
                return
            }
            do { try startPart() } catch {
                lock.withLock { failure = "screenrecord's next part: \(error)" }
                return
            }
        }
    }

    /// screenrecord stopped on the device (SIGINT, again until it has gone:
    /// a part just begun may not have been running yet), the loop ended.
    private func end() async {
        lock.withLock { stopping = true }
        for attempt in 0..<6 {
            _ = await adb(ScreenMedia.androidStop(serial: serial), timeout: 30)
            if let part = lock.withLock({ current }), await part.exited(within: attempt < 5 ? 5 : 2) == nil {
                continue
            }
            break
        }
        if let part = lock.withLock({ current }), part.isRunning {
            part.terminate()
            _ = await adb(["-s", serial, "shell", "pkill", "-KILL", "screenrecord"], timeout: 30)
        }
        await loop?.value
    }

    func stop() async throws -> String {
        await end()
        let names = lock.withLock { parts }
        var pulled: [(path: String, bytes: Int64)] = []
        for (index, remote) in names.enumerated() {
            let local = "\(folder)/part-\(index).mp4"
            let result = await adb(["-s", serial, "pull", remote, local], timeout: 600)
            if result?.ok != true { log("lease \(lease): pulling \(remote) failed: \(result?.error ?? "no answer")") }
            pulled.append((local, (try? FileManager.default.attributesOfItem(atPath: local)[.size] as? Int64) ?? 0))
        }
        _ = await adb(["-s", serial, "shell", "rm", "-f"] + names, timeout: 60)
        let output = "\(folder)/emulator.mp4"
        switch ScreenMedia.join(parts: pulled) {
        case .nothing:
            throw APIError(error: "the emulator's recording made no file" + (lock.withLock { failure }.map { ": \($0)" } ?? ""))
        case .one(let path):
            try? FileManager.default.removeItem(atPath: output)
            try FileManager.default.moveItem(atPath: path, toPath: output)
        case .several(let paths):
            try await MediaJoin.join(paths, to: output, folder: folder)
        }
        return output
    }

    func discard() async {
        await end()
        _ = await adb(["-s", serial, "shell", "rm", "-f"] + lock.withLock { parts }, timeout: 60)
        try? FileManager.default.removeItem(atPath: folder)
    }
}

/// Parts of one recording joined into one MP4.
enum MediaJoin {
    static func join(_ parts: [String], to output: String, folder: String) async throws {
        try? FileManager.default.removeItem(atPath: output)
        if let ffmpeg = ScreenMedia.ffmpeg() {
            let list = "\(folder)/parts.txt"
            try ScreenMedia.concatList(parts).write(toFile: list, atomically: true, encoding: .utf8)
            let joined = try await Shell.run(ffmpeg, ScreenMedia.ffmpegJoin(list: list, output: output), timeout: 900)
            if joined.ok, FileManager.default.fileExists(atPath: output) { return }
            log("ffmpeg didn't join a recording's parts (\(joined.error.suffix(300))); AVFoundation joins them")
            try? FileManager.default.removeItem(atPath: output)
        }
        #if canImport(AVFoundation)
        try await AVJoin.join(parts, to: output)
        #else
        throw APIError(error: "no ffmpeg to join a recording's parts")
        #endif
    }
}

#endif

#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import CoreVideo

/// Parts joined by AVFoundation: a composition of each in turn, exported
/// as it is (passthrough: nothing encoded again).
enum AVJoin {
    static func join(_ parts: [String], to output: String) async throws {
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: URL(fileURLWithPath: part))
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration > .zero else { continue }
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: cursor)
            cursor = cursor + duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw APIError(error: "AVFoundation can't export the recording's parts")
        }
        let url = URL(fileURLWithPath: output)
        if #available(macOS 15, *) {
            try await export.export(to: url, as: .mp4)
        } else {
            export.outputURL = url
            export.outputFileType = .mp4
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                nonisolated(unsafe) let session = export
                session.exportAsynchronously { continuation.resume() }
            }
            if let error = export.error { throw APIError(error: "joining the recording's parts: \(error.localizedDescription)") }
        }
    }
}

#if canImport(CommonCrypto)

/// A guest's screen recorded from its VNC: each frame RFBSession draws
/// (raw and CopyRect updates, asked for again as soon as one comes), taken
/// at up to 30 a second, cropped where asked, encoded to H.264 by
/// AVAssetWriter. A frame is written only when the screen changed (an MP4's
/// frames may come at any time); the last is written again at the end, so
/// the video lasts as long as the recording did.
final class RFBRecorder: ScreenRecorder, @unchecked Sendable {
    private let session: RFBSession
    private let path: String
    private let queue = DispatchQueue(label: "oss.record.rfb")
    private let lock = NSLock()
    private var latest: CGImage?
    private var changed = false
    private var ended: String?
    private var finished = false
    private var finishing: [CheckedContinuation<Void, Never>] = []
    // The writer's, on `queue` alone.
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let crop: PixelRect?
    private let size: (width: Int, height: Int)
    private var timer: DispatchSourceTimer?
    private var startedAt: Date?
    private var lastWritten: CMTime = .invalid
    private var frames = 0
    private var watcher: Task<Void, Never>?

    /// The frames' size (the crop's, else the screen's) as recorded.
    var width: Int { size.width }
    var height: Int { size.height }

    /// Connected and recording. `window`: a Mac's app window, cropped to;
    /// `allowed`: asked every second, and the recording ends (kept for its
    /// stop) once it says no (a slot that lost the primary's GUI session).
    init(host: String, port: Int, password: String, window: WindowFrame?, folder: String,
         allowed: (@Sendable () async -> Bool)? = nil) throws {
        Paths.ensure(folder)
        path = "\(folder)/screen.mp4"
        try? FileManager.default.removeItem(atPath: path)
        let box = FrameBox()
        session = try RFBSession(host: host, port: port, password: password, frame: { box.frame?($0) }, ended: { box.ended?($0) })
        let screen = session.size
        if let window {
            guard let rect = ScreenMedia.crop(window, framebufferWidth: Int(screen.width), framebufferHeight: Int(screen.height), even: true) else {
                session.close()
                throw APIError(error: "\(window.owner)'s window isn't on the primary's screen", code: "noWindow")
            }
            crop = rect
        } else {
            crop = nil
        }
        size = ScreenMedia.videoSize(width: crop?.width ?? Int(screen.width), height: crop?.height ?? Int(screen.height))
        writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoMaxKeyFrameIntervalKey: 60,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        guard writer.canAdd(input) else { session.close(); throw APIError(error: "AVAssetWriter won't take H.264 at \(size.width)×\(size.height)") }
        writer.add(input)
        guard writer.startWriting() else {
            session.close()
            throw APIError(error: "AVAssetWriter didn't start: \(writer.error.map { "\($0)" } ?? "no reason")")
        }
        writer.startSession(atSourceTime: .zero)
        box.frame = { [weak self] image in self?.received(image) }
        box.ended = { [weak self] reason in self?.lock.withLock { self?.ended = "the VNC connection ended: \(reason)" } }
        session.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        if let allowed {
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    if !(await allowed()) {
                        log("a slot's recording ended: the slot no longer holds its primary's GUI session")
                        await self.finish()
                        return
                    }
                }
            }
        }
    }

    /// The RFB session's callbacks, set once the recorder is whole.
    private final class FrameBox: @unchecked Sendable {
        var frame: (@Sendable (CGImage) -> Void)?
        var ended: (@Sendable (String) -> Void)?
    }

    private func received(_ image: CGImage) {
        lock.withLock {
            latest = image
            changed = true
        }
    }

    /// Every 33 ms: the screen's frame written if it changed.
    private func tick() {
        let (image, fresh) = lock.withLock { () -> (CGImage?, Bool) in
            defer { changed = false }
            return (latest, changed)
        }
        guard fresh, let image else { return }
        if startedAt == nil { startedAt = Date() }
        append(image, at: CMTime(seconds: Date().timeIntervalSince(startedAt!), preferredTimescale: 600))
        if Date().timeIntervalSince(startedAt!) > ScreenMedia.longest {
            log("a recording has run its longest (\(Int(ScreenMedia.longest / 60)) min); kept for its stop")
            Task { await self.finish() }
        }
    }

    private func append(_ image: CGImage, at time: CMTime) {
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if lastWritten.isValid, time <= lastWritten { return }
        guard let pool = adaptor.pixelBufferPool else { return }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let source: CGImage
        if let crop, let cropped = image.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)) {
            source = cropped
        } else {
            source = image
        }
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        if adaptor.append(buffer, withPresentationTime: time) {
            lastWritten = time
            frames += 1
        }
    }

    /// Ended and its file finished (once; later callers wait for it).
    private func finish() async {
        let first = lock.withLock { () -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        guard first else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let done = lock.withLock { () -> Bool in
                    if writer.status != .writing { return true }
                    finishing.append(continuation)
                    return false
                }
                if done { continuation.resume() }
            }
            return
        }
        watcher?.cancel()
        session.close()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                // The last frame held to the end: the video lasts as the recording did.
                if let startedAt, let image = lock.withLock({ latest }) {
                    let end = CMTime(seconds: Date().timeIntervalSince(startedAt), preferredTimescale: 600)
                    if !lastWritten.isValid || CMTimeSubtract(end, lastWritten).seconds > 0.04 { append(image, at: end) }
                }
                guard writer.status == .writing else { return continuation.resume() }
                input.markAsFinished()
                if frames == 0 {
                    writer.cancelWriting()
                    return continuation.resume()
                }
                writer.finishWriting { continuation.resume() }
            }
        }
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { finishing = [] }
            return finishing
        }
        waiting.forEach { $0.resume() }
    }

    func stop() async throws -> String {
        await finish()
        guard writer.status == .completed, FileManager.default.fileExists(atPath: path) else {
            let why = lock.withLock { ended }
            throw APIError(error: "the recording made no video" + (frames == 0 ? ": no frame came from VNC" : "")
                                + (why.map { " (\($0))" } ?? "") + (writer.error.map { ": \($0)" } ?? ""))
        }
        return path
    }

    func discard() async {
        await finish()
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}

/// One frame of a guest's screen cropped and saved as a PNG.
extension RFBScreenshot {
    func capture(to path: String, window: WindowFrame?) throws {
        let (pixels, width, height) = try capturePixels()
        guard let window else { return try Self.writePNG(pixels: pixels, width: width, height: height, to: path) }
        guard let crop = ScreenMedia.crop(window, framebufferWidth: width, framebufferHeight: height) else {
            throw APIError(error: "\(window.owner)'s window isn't on the primary's screen", code: "noWindow")
        }
        try Self.writePNG(pixels: ScreenMedia.cropped(pixels, width: width, crop: crop), width: crop.width, height: crop.height, to: path)
    }
}

#endif
#endif

extension ScreenMedia {
    /// A crop of raw 32-bit pixels (rows top down).
    static func cropped(_ pixels: [UInt8], width: Int, crop: PixelRect) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(crop.width * crop.height * 4)
        for row in crop.y..<(crop.y + crop.height) {
            let start = (row * width + crop.x) * 4
            out.append(contentsOf: pixels[start..<(start + crop.width * 4)])
        }
        return out
    }
}
