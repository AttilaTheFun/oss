import Foundation
import OSSClient

/// Android emulators on the server's Mac. A base is an AVD named
/// `oss-android-<config>` with a saved boot snapshot (`default_boot`); a
/// lease is an APFS clone of its directory (`cp -c`: seconds, no disk until
/// it changes), started from that snapshot with nothing saved back, and
/// deleted when the lease ends. oss sets up its own SDK (`oss setup
/// android`) and runs its own adb server, on its own port, so it never
/// meets another tool's adb on the same Mac.
enum Emulators {
    static let adbServerPort = "5137"

    static func emulator(_ c: ServerConfig) -> String { "\(c.androidSDK)/emulator/emulator" }
    static func adbPath(_ c: ServerConfig) -> String { "\(c.androidSDK)/platform-tools/adb" }

    static func environment(_ c: ServerConfig) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_SDK_ROOT"] = c.androidSDK
        environment["ANDROID_HOME"] = c.androidSDK
        environment["ANDROID_AVD_HOME"] = c.androidAVDHome
        environment["ANDROID_ADB_SERVER_PORT"] = adbServerPort
        return environment
    }

    static func adb(_ c: ServerConfig, _ arguments: [String], timeout: TimeInterval = 120) async throws -> ProcessResult {
        try await Shell.run(adbPath(c), arguments, environment: environment(c), timeout: timeout)
    }

    static func bases(_ c: ServerConfig) -> [Base] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: c.androidAVDHome)) ?? []
        return names.filter { $0.hasSuffix(".avd") }.compactMap { Base(name: String($0.dropLast(4))) }
            .filter { $0.platform == .android }
    }

    // MARK: Setup

    /// The emulator, platform-tools and a system image, from Google's
    /// repository (checked against its SHA-1s): no Java, no sdkmanager.
    static func setup(api: Int, tag: String) async throws {
        let c = ServerConfig.load()
        Paths.ensure(c.androidSDK)
        let base = "https://dl.google.com/android/repository/"
        #if os(macOS)
        let (hostOS, hostArch) = ("macosx", "aarch64")
        #else
        let (hostOS, hostArch) = ("linux", "x64")
        #endif
        let repository = try await fetch(base + "repository2-3.xml")
        for (path, folder) in [("emulator", "emulator"), ("platform-tools", "platform-tools")] {
            guard let (url, sha1) = archive(in: repository, path: path, os: hostOS, arch: path == "emulator" ? hostArch : nil) else {
                throw ShellError(description: "no \(path) for \(hostOS) in Google's repository")
            }
            try await install(base + url, sha1: sha1, into: c.androidSDK, replacing: folder)
        }
        let images = try await fetch(base + "sys-img/\(tag)/sys-img2-3.xml")
        let package = "system-images;android-\(api);\(tag);arm64-v8a"
        guard let (url, sha1) = archive(in: images, path: package, os: nil, arch: nil) else {
            throw ShellError(description: "no \(package) in Google's repository")
        }
        let destination = "\(c.androidSDK)/system-images/android-\(api)/\(tag)"
        Paths.ensure(destination)
        try await install(base + "sys-img/\(tag)/" + url, sha1: sha1, into: destination, replacing: "arm64-v8a")
        log("Android SDK ready in \(c.androidSDK): emulator, platform-tools, \(package)")
    }

    static func fetch(_ url: String) async throws -> String {
        let result = try await Shell.run("/usr/bin/curl", ["-fsSL", url], timeout: 120)
        guard result.ok else { throw ShellError(description: "\(url): \(result.error)") }
        return result.output
    }

    /// An archive's URL and SHA-1 in a repository XML, for this host.
    static func archive(in xml: String, path: String, os: String?, arch: String?) -> (String, String)? {
        guard let start = xml.range(of: "<remotePackage path=\"\(path)\">"),
              let end = xml.range(of: "</remotePackage>", range: start.upperBound..<xml.endIndex) else { return nil }
        let package = String(xml[start.upperBound..<end.lowerBound])
        for piece in package.components(separatedBy: "<archive>").dropFirst() {
            func value(_ tag: String) -> String? {
                guard let a = piece.range(of: "<\(tag)>"), let b = piece.range(of: "</\(tag)>", range: a.upperBound..<piece.endIndex) else { return nil }
                return String(piece[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let os, value("host-os") != os { continue }
            if let arch, let found = value("host-arch"), found != arch { continue }
            guard let url = value("url"),
                  let sha = piece.range(of: "<checksum type=\"sha1\">").flatMap({ r in
                      piece.range(of: "</checksum>", range: r.upperBound..<piece.endIndex).map { String(piece[r.upperBound..<$0.lowerBound]) }
                  }) else { continue }
            return (url, sha)
        }
        return nil
    }

    static func install(_ url: String, sha1: String, into directory: String, replacing folder: String) async throws {
        let zip = NSTemporaryDirectory() + "oss-\(Random.hex(4)).zip"
        defer { try? FileManager.default.removeItem(atPath: zip) }
        log("downloading \(url)")
        let download = try await Shell.run("/usr/bin/curl", ["-fsSL", "-o", zip, url], timeout: 3600)
        guard download.ok else { throw ShellError(description: "\(url): \(download.error)") }
        let sum = try await Shell.run("/usr/bin/shasum", ["-a", "1", zip])
        guard sum.output.hasPrefix(sha1) else { throw ShellError(description: "\(url): SHA-1 isn't \(sha1)") }
        try? FileManager.default.removeItem(atPath: "\(directory)/\(folder)")
        let unzip = try await Shell.run("/usr/bin/unzip", ["-q", "-o", zip, "-d", directory], timeout: 1800)
        guard unzip.ok else { throw ShellError(description: "unzip \(url): \(unzip.error)") }
    }

    // MARK: Bases

    /// A base made: an AVD (a phone: 1080×2400, 4 GB, 4 cores), booted cold
    /// once, `script` run with ANDROID_SERIAL and ADB set (install apps,
    /// change settings), its state saved as the `default_boot` snapshot.
    static func build(config: String, api: Int, tag: String, script: String?) async throws {
        let c = ServerConfig.load()
        let base = Base(platform: .android, config: config)
        Paths.ensure(c.androidAVDHome)
        let avd = "\(c.androidAVDHome)/\(base.name).avd"
        try? FileManager.default.removeItem(atPath: avd)
        try? FileManager.default.removeItem(atPath: "\(c.androidAVDHome)/\(base.name).ini")
        Paths.ensure(avd)
        try """
            avd.ini.encoding=UTF-8
            AvdId=\(base.name)
            avd.ini.displayname=\(base.name)
            abi.type=arm64-v8a
            hw.cpu.arch=arm64
            hw.cpu.ncore=4
            hw.ramSize=4096
            hw.lcd.width=1080
            hw.lcd.height=2400
            hw.lcd.density=420
            hw.keyboard=yes
            hw.mainKeys=no
            hw.gpu.enabled=yes
            hw.gpu.mode=swiftshader_indirect
            image.sysdir.1=system-images/android-\(api)/\(tag)/arm64-v8a/
            tag.id=\(tag)
            disk.dataPartition.size=6G
            fastboot.forceColdBoot=no
            PlayStore.enabled=false

            """.write(toFile: "\(avd)/config.ini", atomically: true, encoding: .utf8)
        try writeIni(c, name: base.name, api: api)
        let port = c.firstEmulatorPort
        log("\(base.name): first (cold) boot on port \(port)")
        let process = try start(c, avd: base.name, port: port, snapshot: false)
        do {
            try await waitForBoot(c, port: port, seconds: 900)
            if let script {
                log("running \(script)")
                var environment = Emulators.environment(c)
                environment["ANDROID_SERIAL"] = "emulator-\(port)"
                environment["ADB"] = adbPath(c)
                let status = try Shell.passthrough("/bin/bash", [script], environment: environment)
                guard status == 0 else { throw ShellError(description: "\(script) failed (\(status))") }
            }
            let saved = try await adb(c, ["-s", "emulator-\(port)", "emu", "avd", "snapshot", "save", "default_boot"], timeout: 600)
            guard saved.ok, !saved.output.contains("KO") else { throw ShellError(description: "saving the snapshot: \(saved.output)\(saved.error)") }
        } catch {
            process.terminate()
            throw error
        }
        _ = try? await adb(c, ["-s", "emulator-\(port)", "emu", "kill"])
        process.waitUntilExit()
        log("\(base.name) is ready")
    }

    static func writeIni(_ c: ServerConfig, name: String, api: Int?) throws {
        let target = api.map { "target=android-\($0)\n" } ?? ""
        try "avd.ini.encoding=UTF-8\npath=\(c.androidAVDHome)/\(name).avd\n\(target)"
            .write(toFile: "\(c.androidAVDHome)/\(name).ini", atomically: true, encoding: .utf8)
    }

    /// The emulator, headless, left running on its own (it outlives a
    /// restart of the server: launchd's job keeps its process group apart).
    @discardableResult
    static func start(_ c: ServerConfig, avd: String, port: Int, snapshot: Bool) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: emulator(c))
        process.arguments = ["-avd", avd, "-port", String(port), "-no-window", "-no-audio", "-no-boot-anim",
                             "-gpu", "swiftshader_indirect"]
            // A clone loads its base's snapshot though its own path differs (the feature exists for copied AVDs).
            + (snapshot ? ["-snapshot", "default_boot", "-no-snapshot-save", "-feature", "AllowSnapshotMigration"] : ["-no-snapshot-load"])
        process.environment = environment(c)
        Paths.ensure(Paths.state)
        let log = FileHandle(forWritingAtPath: "\(Paths.state)/emulator-\(port).log")
            ?? { FileManager.default.createFile(atPath: "\(Paths.state)/emulator-\(port).log", contents: nil); return FileHandle(forWritingAtPath: "\(Paths.state)/emulator-\(port).log")! }()
        log.truncateFile(atOffset: 0)
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    static func waitForBoot(_ c: ServerConfig, port: Int, seconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            let booted = try? await adb(c, ["-s", "emulator-\(port)", "shell", "getprop", "sys.boot_completed"], timeout: 20)
            if booted?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return }
            try await Task.sleep(for: .seconds(3))
        }
        throw APIError(error: "emulator-\(port) didn't finish booting in \(seconds) s (log: \(Paths.state)/emulator-\(port).log)")
    }

    // MARK: Leases

    /// A clone of the base, started from its snapshot: its process.
    static func lease(base: Base, name: String, port: Int) async throws -> Int32 {
        let c = ServerConfig.load()
        let source = "\(c.androidAVDHome)/\(base.name).avd"
        let clone = "\(c.androidAVDHome)/\(name).avd"
        guard FileManager.default.fileExists(atPath: source) else { throw APIError(error: "no emulator base \(base.name)") }
        let copy = try await Shell.run("/bin/cp", ["-c", "-R", source, clone], timeout: 600)
        guard copy.ok else { throw APIError(error: "cloning \(base.name): \(copy.error)") }
        for lock in (try? FileManager.default.contentsOfDirectory(atPath: clone)) ?? [] where lock.hasSuffix(".lock") {
            try? FileManager.default.removeItem(atPath: "\(clone)/\(lock)")
        }
        let config = "\(clone)/config.ini"
        if let text = try? String(contentsOfFile: config, encoding: .utf8) {
            let renamed = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                if line.hasPrefix("AvdId=") { return "AvdId=\(name)" }
                if line.hasPrefix("avd.ini.displayname=") { return "avd.ini.displayname=\(name)" }
                return String(line)
            }.joined(separator: "\n")
            try renamed.write(toFile: config, atomically: true, encoding: .utf8)
        }
        let target = (try? String(contentsOfFile: "\(c.androidAVDHome)/\(base.name).ini", encoding: .utf8))?
            .split(separator: "\n").first { $0.hasPrefix("target=android-") }.flatMap { Int($0.dropFirst(15)) }
        try writeIni(c, name: name, api: target)
        let process = try start(c, avd: name, port: port, snapshot: true)
        try await waitForBoot(c, port: port, seconds: 300)
        return process.processIdentifier
    }

    static func release(name: String, port: Int?, pid: Int32?) async {
        let c = ServerConfig.load()
        if let port { _ = try? await adb(c, ["-s", "emulator-\(port)", "emu", "kill"], timeout: 30) }
        if let pid {
            for _ in 0..<20 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(500)) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(atPath: "\(c.androidAVDHome)/\(name).avd")
        try? FileManager.default.removeItem(atPath: "\(c.androidAVDHome)/\(name).ini")
    }

    static func stopADB() async {
        _ = try? await adb(ServerConfig.load(), ["kill-server"], timeout: 30)
    }

    /// What a holder may run against its own emulator (the server's adb, its serial).
    static let allowed: Set<String> = ["install", "install-multiple", "uninstall", "shell", "logcat", "exec-out", "push", "reverse", "forward"]

    static func run(_ arguments: [String], port: Int) async throws -> ProcessResult {
        guard let command = arguments.first, allowed.contains(command) else {
            throw APIError(error: "adb \(arguments.first ?? ""): not allowed (allowed: \(allowed.sorted().joined(separator: ", ")))")
        }
        return try await adb(ServerConfig.load(), ["-s", "emulator-\(port)"] + arguments, timeout: 600)
    }

    static func screenshot(port: Int) async throws -> Data {
        let path = NSTemporaryDirectory() + "oss-emu-\(Random.hex(4)).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let c = ServerConfig.load()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath(c))
        process.arguments = ["-s", "emulator-\(port)", "exec-out", "screencap", "-p"]
        process.environment = environment(c)
        FileManager.default.createFile(atPath: path, contents: nil)
        process.standardOutput = FileHandle(forWritingAtPath: path)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            throw APIError(error: "adb screencap failed")
        }
        return data
    }
}
