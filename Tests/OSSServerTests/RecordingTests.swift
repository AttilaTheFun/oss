import Foundation
import Testing
import OSSClient
@testable import OSSServer

// Pictures and recordings of a lease's screen (Recording.swift, API 19):
// the command lines each platform's recorder runs, a window's crop in a
// framebuffer's pixels, the parts a recording is joined from, one
// recording a lease, a slot's GUI turn, and the routes' and grants'
// answers. The recorders themselves need an emulator, a simulator or a
// VNC server: their command lines are held here, the rest is checked
// against leases (docs/primary-vms.md, "Pictures and recordings").

private func frame(window: ScreenRect, screen: ScreenRect = ScreenRect(x: 0, y: 0, width: 1440, height: 900)) -> WindowFrame {
    WindowFrame(owner: "Storybook", bundle: "com.example.Storybook", window: window, screen: screen)
}

@Test func aWindowsCropIsItsFrameInTheFramebuffersPixels() {
    // A Retina-sized display: 1440×900 points, 2880×1800 pixels; edges rounded outward.
    let retina = ScreenMedia.crop(frame(window: ScreenRect(x: 100.5, y: 50, width: 800, height: 600)), framebufferWidth: 2880, framebufferHeight: 1800)
    #expect(retina == PixelRect(x: 201, y: 100, width: 1600, height: 1200))
    // At 1×, points are pixels.
    let plain = ScreenMedia.crop(frame(window: ScreenRect(x: 10, y: 20, width: 300, height: 200)), framebufferWidth: 1440, framebufferHeight: 900)
    #expect(plain == PixelRect(x: 10, y: 20, width: 300, height: 200))
    // Partly off the screen: kept to what is on it.
    let edge = ScreenMedia.crop(frame(window: ScreenRect(x: -50, y: 850, width: 200, height: 200)), framebufferWidth: 1440, framebufferHeight: 900)
    #expect(edge == PixelRect(x: 0, y: 850, width: 150, height: 50))
    // Wholly off it: none.
    #expect(ScreenMedia.crop(frame(window: ScreenRect(x: 2000, y: 0, width: 100, height: 100)), framebufferWidth: 1440, framebufferHeight: 900) == nil)
    // For a video: even sides.
    let odd = ScreenMedia.crop(frame(window: ScreenRect(x: 0, y: 0, width: 301, height: 201)), framebufferWidth: 1440, framebufferHeight: 900, even: true)
    #expect(odd == PixelRect(x: 0, y: 0, width: 300, height: 200))
    // A display that isn't at the origin.
    let moved = ScreenMedia.crop(frame(window: ScreenRect(x: 110, y: 120, width: 100, height: 100), screen: ScreenRect(x: 100, y: 100, width: 720, height: 450)),
                                 framebufferWidth: 1440, framebufferHeight: 900)
    #expect(moved == PixelRect(x: 20, y: 40, width: 200, height: 200))
}

@Test func aCropTakesThoseRowsAndColumns() {
    // 4×3 pixels, each pixel's four bytes its own index.
    let pixels = (0..<12).flatMap { index in [UInt8](repeating: UInt8(index), count: 4) }
    let cropped = ScreenMedia.cropped(pixels, width: 4, crop: PixelRect(x: 1, y: 1, width: 2, height: 2))
    #expect(cropped == [5, 5, 5, 5, 6, 6, 6, 6, 9, 9, 9, 9, 10, 10, 10, 10])
}

@Test func aVideosSizeIsEvenAndWithinTheEncoders() {
    #expect(ScreenMedia.videoSize(width: 1920, height: 1200) == (1920, 1200))
    #expect(ScreenMedia.videoSize(width: 1601, height: 1201) == (1600, 1200))
    #expect(ScreenMedia.videoSize(width: 5120, height: 2880) == (4096, 2304))
    #expect(ScreenMedia.videoSize(width: 1, height: 1) == (2, 2))
}

@Test func eachPlatformsRecordingIsItsOwnTool() {
    // Android: screenrecord on the lease's emulator, its parts on the device; SIGINT ends it.
    #expect(ScreenMedia.androidRecord(serial: "emulator-5554", path: "/sdcard/oss-ab12-0.mp4", unlimited: false)
            == ["-s", "emulator-5554", "shell", "screenrecord", "--bit-rate", "6000000", "/sdcard/oss-ab12-0.mp4"])
    #expect(ScreenMedia.androidRecord(serial: "emulator-5554", path: "/sdcard/oss-ab12-1.mp4", unlimited: true)
            == ["-s", "emulator-5554", "shell", "screenrecord", "--bit-rate", "6000000", "--time-limit", "0", "/sdcard/oss-ab12-1.mp4"])
    #expect(ScreenMedia.androidStop(serial: "emulator-5554") == ["-s", "emulator-5554", "shell", "pkill", "-INT", "screenrecord"])
    #expect(ScreenMedia.androidPart(lease: "ab12", part: 3) == "/sdcard/oss-ab12-3.mp4")
    // API 35's help (a lease's): no limit with 0; an older one's: three minutes at most.
    #expect(ScreenMedia.androidUnlimited(help: """
        --time-limit TIME
            Set the maximum recording time, in seconds.  Default is 180. Set to 0
            to remove the time limit.
        """))
    #expect(!ScreenMedia.androidUnlimited(help: "--time-limit TIME\n    Set the maximum recording time, in seconds.  Default / maximum is 180."))
    // iOS: simctl's recordVideo, H.264, masked as screenshots are.
    #expect(ScreenMedia.simulatorRecord(udid: "U", path: "/tmp/a.mp4")
            == ["simctl", "io", "U", "recordVideo", "--codec=h264", "--mask=black", "--force", "/tmp/a.mp4"])
}

@Test func aWindowIsReadInTheConsoleSession() throws {
    let line = ScreenMedia.windowLine(app: "Storybook", console: "runner")
    #expect(line.hasPrefix(#"cd / && sudo launchctl asuser "$(id -u 'runner')" sudo -u 'runner' -H '/usr/bin/osascript' '-l' 'JavaScript' '-e' '"#))
    #expect(line.hasSuffix("'Storybook'; exit $?"))
    #expect(ScreenMedia.windowScript.contains("CGWindowListCopyWindowInfo"))
    // Its answer, and its refusal (osascript's decoration trimmed).
    let json = #"{"owner":"Storybook","bundle":"com.example.Storybook","window":{"x":10,"y":38,"width":800,"height":600},"screen":{"x":0,"y":0,"width":1440,"height":900}}"#
    let read = try ScreenMedia.window(fromOutput: json + "\n", error: "", status: 0, app: "Storybook")
    #expect(read == WindowFrame(owner: "Storybook", bundle: "com.example.Storybook", window: ScreenRect(x: 10, y: 38, width: 800, height: 600),
                                screen: ScreenRect(x: 0, y: 0, width: 1440, height: 900)))
    let refused = #expect(throws: APIError.self) {
        try ScreenMedia.window(fromOutput: "", error: "execution error: Error: Error: no window of Foo on the screen (windows there: Finder, Dock) (-2700)\n",
                               status: 1, app: "Foo")
    }
    #expect(refused?.error == "no window of Foo on the screen (windows there: Finder, Dock)")
    #expect(refused?.code == "noWindow")
    #expect(ScreenMedia.validApp("com.example.App") && ScreenMedia.validApp("Storybook Beta"))
    #expect(!ScreenMedia.validApp("") && !ScreenMedia.validApp("a\nb"))
}

@Test func aRecordingsPartsAreJoinedOnlyWhenThereAreSeveral() {
    #expect(ScreenMedia.join(parts: []) == .nothing)
    #expect(ScreenMedia.join(parts: [("/a/0.mp4", 0)]) == .nothing)
    #expect(ScreenMedia.join(parts: [("/a/0.mp4", 10), ("/a/1.mp4", 0)]) == .one("/a/0.mp4"))
    #expect(ScreenMedia.join(parts: [("/a/0.mp4", 10), ("/a/1.mp4", 0), ("/a/2.mp4", 5)]) == .several(["/a/0.mp4", "/a/2.mp4"]))
    #expect(ScreenMedia.concatList(["/a/0.mp4", "/b/it's.mp4"]) == "file '/a/0.mp4'\nfile '/b/it'\\''s.mp4'\n")
    #expect(ScreenMedia.ffmpegJoin(list: "/a/parts.txt", output: "/a/out.mp4")
            == ["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", "/a/parts.txt", "-c", "copy",
                "-movflags", "+faststart", "/a/out.mp4"])
    #expect(ScreenMedia.ffmpeg(candidates: ["/nonexistent/ffmpeg"]) == nil)
}

/// A recorder that does nothing, for the registry.
private final class NoRecorder: ScreenRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var discarded = false
    var wasDiscarded: Bool { lock.withLock { discarded } }
    func stop() async throws -> String { "/dev/null" }
    func discard() async { lock.withLock { discarded = true } }
}

@Test func aLeaseRecordsOneAtATimeAndItsRecordingEndsWithIt() async throws {
    let recordings = Recordings()
    try await recordings.reserve("a")
    let busy = await #expect(throws: APIError.self) { try await recordings.reserve("a") }
    #expect(busy?.code == "busy")
    let first = NoRecorder()
    #expect(await recordings.attach("a", first))
    await #expect(throws: APIError.self) { try await recordings.reserve("a") }
    #expect(await recordings.take("a") === first)
    #expect(await recordings.take("a") == nil)
    // Another lease's is its own; a cancelled start gives its place back.
    try await recordings.reserve("b")
    await recordings.cancel("b")
    try await recordings.reserve("b")
    // The lease ends while its recording starts: the recording is refused, the caller discards it.
    await recordings.discard("b")
    #expect(await !recordings.attach("b", NoRecorder()))
    // A running one is discarded with its lease.
    try await recordings.reserve("c")
    let running = NoRecorder()
    #expect(await recordings.attach("c", running))
    await recordings.discard("c")
    #expect(running.wasDiscarded)
    #expect(await !recordings.isRecording("c"))
}

@Test func theGUISessionSaysWhichLeaseHasIt() async {
    let runs = XCTestRuns(root: NSTemporaryDirectory() + "oss-gui-\(UUID().uuidString)")
    #expect(await runs.guiLease() == nil)
    #expect(await runs.takeGUI("exec-1", lease: "m1"))
    #expect(await !runs.takeGUI("exec-2", lease: "m2"))
    #expect(await runs.guiLease() == "m1")
    // Taken again by the same run (a wait's next try), it stays its lease's.
    #expect(await runs.takeGUI("exec-1"))
    #expect(await runs.guiLease() == "m1")
    await runs.giveGUI("exec-2")
    #expect(await runs.guiLease() == "m1")
    await runs.giveGUI("exec-1")
    #expect(await runs.guiLease() == nil)
}

@Test func screenshotsAndRecordingsHaveGrants() {
    func use(_ method: String, _ path: String) -> String? {
        GrantKey.use(method, path.split(separator: "/").map(String.init)).map { "\($0.verb) \($0.resource)" }
    }
    #expect(use("GET", "/v1/machines/ab12/screenshot") == "machine.screenshot machines/ab12")
    #expect(use("POST", "/v1/machines/ab12/record") == "machine.record machines/ab12")
    #expect(use("POST", "/v1/machines/ab12/record/stop") == "machine.record machines/ab12")
    #expect(use("POST", "/v1/machines/ab12/record/other") == nil)
    #expect(GrantKey.verbs.contains("machine.screenshot") && GrantKey.verbs.contains("machine.record"))
    // A CI job's grant records its own leases, as it takes their screenshots.
    func allows(_ method: String, _ path: String) -> Bool { JobGrantRoutes.allows(method, path.split(separator: "/").map(String.init)) }
    #expect(allows("POST", "/v1/machines/ab12/record"))
    #expect(allows("POST", "/v1/machines/ab12/record/stop"))
    #expect(allows("GET", "/v1/machines/ab12/screenshot"))
    #expect(!allows("POST", "/v1/machines/ab12/record/other"))
    #expect(OSS.apiLevel >= 19 && OSS.features.contains("recordings"))
    // Older clients' requests and answers still decode.
    #expect((try? JSONDecoder.oss.decode(RecordRequest.self, from: Data("{}".utf8)))?.window == nil)
}

#if canImport(Network)

/// Through a real server: a slot's screen is pictured and recorded only
/// while it holds its primary's GUI session; `--window` is a slot's alone;
/// a lease with no screen, or no recording, says so.
@Test func aSlotsScreenWaitsForItsGUITurn() async throws {
    try await withXCTestServer { server in
        let slot = await server.lease("m1", platform: .mac)
        let shot = await #expect(throws: OSSError.self) { try await server.client.screenshot(slot.id) }
        #expect(shot?.status == 409 && shot?.code == "noGUI", "\(String(describing: shot))")
        let record = await #expect(throws: OSSError.self) { try await server.client.startRecording(slot.id, RecordRequest(window: "Storybook")) }
        #expect(record?.status == 409 && record?.code == "noGUI", "\(String(describing: record))")
        // Its turn taken (an exec --gui running): now only its primary is missing here.
        #expect(await server.machines.xctests.takeGUI("exec-t", lease: slot.id))
        let noPrimary = await #expect(throws: OSSError.self) { try await server.client.screenshot(slot.id) }
        #expect(noPrimary?.code == "notReady", "\(String(describing: noPrimary))")
        let recordNoPrimary = await #expect(throws: OSSError.self) { try await server.client.startRecording(slot.id) }
        #expect(recordNoPrimary?.code == "notReady", "\(String(describing: recordNoPrimary))")
        // Another slot's turn isn't this one's.
        let other = await server.lease("m2", platform: .mac)
        let notIts = await #expect(throws: OSSError.self) { try await server.client.screenshot(other.id) }
        #expect(notIts?.code == "noGUI")
        await server.machines.xctests.giveGUI("exec-t")

        // A window is a slot's; a container has no screen; no recording, nothing to stop.
        let ios = await server.lease("i1")
        let window = await #expect(throws: OSSError.self) { try await server.client.screenshot(ios.id, window: "Safari") }
        #expect(window?.status == 400 && window?.message.contains("Mac slot") == true, "\(String(describing: window))")
        let recordWindow = await #expect(throws: OSSError.self) { try await server.client.startRecording(ios.id, RecordRequest(window: "Safari")) }
        #expect(recordWindow?.status == 400)
        let container = await server.lease("c1", platform: .container)
        let none = await #expect(throws: OSSError.self) { try await server.client.startRecording(container.id) }
        #expect(none?.message.contains("no screen") == true)
        let file = URL(fileURLWithPath: server.root + "/none.mp4")
        let stop = await #expect(throws: OSSError.self) { try await server.client.stopRecording(ios.id, to: file) }
        #expect(stop?.status == 404, "\(String(describing: stop))")

        // Their grants are issued for a lease with a screen, not a container.
        let grant = try await server.client.grant(GrantRequest(verb: "machine.record", lease: slot.id), holder: "alice")
        #expect(grant.path.hasPrefix("/v1/machines/m1/record?grant="))
        let picture = try await server.client.grant(GrantRequest(verb: "machine.screenshot", lease: ios.id), holder: "alice")
        #expect(picture.path.hasPrefix("/v1/machines/i1/screenshot?grant="))
        await #expect(throws: OSSError.self) { try await server.client.grant(GrantRequest(verb: "machine.record", lease: container.id), holder: "alice") }
        // A grant's stop reaches the stop route (and finds no recording).
        let granted = OSSGrantClient(url: URL(string: server.url.absoluteString + grant.path)!)
        let grantStop = await #expect(throws: OSSError.self) { try await granted.stopRecording(to: file) }
        #expect(grantStop?.status == 404, "\(String(describing: grantStop))")
        let grantStart = await #expect(throws: OSSError.self) { try await granted.startRecording() }
        #expect(grantStart?.code == "noGUI", "\(String(describing: grantStart))")

        // The MCP tool takes both actions.
        #expect(MCPServer.tools.contains { ($0["name"] as? String) == "oss_record" })
        let context = MCPServer.Context(client: server.client, holder: "alice", sshPublicKey: nil, sshIdentity: nil, localFiles: false)
        let called = await MCPServer.call("oss_record", ["id": "m1", "action": "start"], context: context)
        let said = ((called["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(said.contains("GUI session"), "\(said)")
    }
}

#endif

#if canImport(AVFoundation)
import AVFoundation

/// A short H.264 MP4 of one colour, as a recording's part.
private func makePart(_ path: String, seconds: Double) async throws {
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let frames = Int(seconds * 10)
    for i in 0...frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
}

@Test func aRecordingsPartsJoinIntoOneVideo() async throws {
    let folder = NSTemporaryDirectory() + "oss-join-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    try await makePart("\(folder)/0.mp4", seconds: 1)
    try await makePart("\(folder)/1.mp4", seconds: 1)
    try await AVJoin.join(["\(folder)/0.mp4", "\(folder)/1.mp4"], to: "\(folder)/joined.mp4")
    let duration = try await AVURLAsset(url: URL(fileURLWithPath: "\(folder)/joined.mp4")).load(.duration).seconds
    #expect(abs(duration - 2) < 0.3, "\(duration)")
}
#endif
