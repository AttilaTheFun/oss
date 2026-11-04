import Foundation
import Testing
import OSSClient
@testable import OSSServer

// An iOS lease's files and its app's environment (API 20): the folder its
// files are in where its simulator runs, the paths a holder may give, `@name`
// in simctl's arguments and environment values, the environment simctl is
// given (here and on the primary), and the command line's `--env`. Nothing
// here runs simctl or reaches a primary.

/// The lease's folder: on the primary, its folder's `files` (where `@name`
/// has always been copied); here, its uploads.
@Test func anIOSLeasesFilesAreInAFolderOfItsOwnWhereItsSimulatorRuns() throws {
    #expect(SimulatorFiles.root(lease: "ab12", inPrimary: true) == "/Users/Shared/oss-ios/ab12/files")
    #expect(SimulatorFiles.root(lease: "ab12", inPrimary: false, uploads: "/u") == "/u/ab12")
    #expect(SimulatorFiles.root(lease: "ab12", inPrimary: false) == "\(Paths.uploads)/ab12")

    let root = "/Users/Shared/oss-ios/ab12/files"
    #expect(try SimulatorFiles.resolve("ctl.json", root: root) == "\(root)/ctl.json")
    #expect(try SimulatorFiles.resolve("runs//1/./ctl.json", root: root) == "\(root)/runs/1/ctl.json")
    // Nothing outside it: absolute, a home, climbing out, nothing at all, a NUL.
    for path in ["/etc/hosts", "~/x", "~", "../ab13/files/x", "runs/../../x", "", ".", "./", "a\0b"] {
        #expect(throws: APIError.self, "\(path)") { try SimulatorFiles.resolve(path, root: root) }
    }
}

/// `@name` in an argument is that file's path in the folder, on whichever
/// machine; the names taken once each; other arguments as given.
@Test func atNameIsTheFilesPathOnTheSimulatorsMachine() throws {
    let (arguments, files) = try SimulatorFiles.mapNames(["addmedia", "booted", "@a.png", "@dir/b.png", "@a.png", "@", "x@y"], root: "/r")
    #expect(arguments == ["addmedia", "booted", "/r/a.png", "/r/dir/b.png", "/r/a.png", "@", "x@y"])
    #expect(files == ["a.png", "dir/b.png"])
    #expect(throws: APIError.self) { try SimulatorFiles.mapNames(["@../token"], root: "/r") }
    #expect(throws: APIError.self) { try SimulatorFiles.mapNames(["@/etc/hosts"], root: "/r") }
}

/// A launch's environment: each name simctl's `SIMCTL_CHILD_` one (a name
/// with it already kept so), an `@name` value the file's path; names a
/// shell takes, no NUL.
@Test func aLaunchsEnvironmentIsSimctlsChildEnvironment() throws {
    let root = "/Users/Shared/oss-ios/ab12/files"
    let (environment, files) = try SimulatorFiles.childEnvironment(
        ["ISO_STORYBOOK_STORY": "text.basics", "ISO_STORYBOOK_CONTROL": "@control.json", "SIMCTL_CHILD_KEPT": "it's here", "EMPTY": ""],
        root: root)
    #expect(environment == ["SIMCTL_CHILD_ISO_STORYBOOK_STORY": "text.basics",
                            "SIMCTL_CHILD_ISO_STORYBOOK_CONTROL": "\(root)/control.json",
                            "SIMCTL_CHILD_KEPT": "it's here",
                            "SIMCTL_CHILD_EMPTY": ""])
    #expect(files == ["control.json"])
    for bad in ["1ABC", "A-B", "A B", "", "A=B", "É"] {
        #expect(throws: APIError.self, "\(bad)") { try SimulatorFiles.childEnvironment([bad: "x"], root: root) }
    }
    #expect(throws: APIError.self) { try SimulatorFiles.childEnvironment(["A": "x\0y"], root: root) }
    #expect(throws: APIError.self) { try SimulatorFiles.childEnvironment(["A": "@../../token"], root: root) }
    #expect(SimulatorFiles.takesEnvironment == ["launch", "spawn"])
}

/// On the primary, the environment rides SSH's command line before simctl:
/// `env NAME=value… xcrun simctl …`, the names sorted, every word quoted
/// whole, so a value's spaces, quotes, `$` and newlines reach the app as given.
@Test func onThePrimaryTheEnvironmentGoesByEnvWithEveryValueQuoted() {
    let environment = ["SIMCTL_CHILD_B": "two words $HOME `x`", "SIMCTL_CHILD_A": "it's\nhere"]
    let (program, words) = SimulatorHost.primaryInvocation(["launch", "U-1", "com.example.App"], environment: environment)
    #expect(program == "/usr/bin/env")
    #expect(words == ["SIMCTL_CHILD_A=it's\nhere", "SIMCTL_CHILD_B=two words $HOME `x`", "/usr/bin/xcrun", "simctl", "launch", "U-1",
                      "com.example.App"])
    #expect(SimulatorHost.remoteLine(program, words)
                == "'/usr/bin/env' 'SIMCTL_CHILD_A=it'\\''s\nhere' 'SIMCTL_CHILD_B=two words $HOME `x`' '/usr/bin/xcrun' 'simctl' "
                    + "'launch' 'U-1' 'com.example.App'")
    // None: simctl as before.
    let (plain, plainWords) = SimulatorHost.primaryInvocation(["listapps", "U-1"], environment: [:])
    #expect(plain == "/usr/bin/xcrun" && plainWords == ["simctl", "listapps", "U-1"])
}

/// `oss machine simctl <id> --env=NAME=VALUE… [--] <command>`: `--env`
/// before the command only (also before the id), a value may be empty or
/// hold `=`; after the command (or `--`), everything is simctl's.
@Test func theCommandLinesEnvComesBeforeTheCommand() throws {
    let (environment, command) = try DeviceCommandLine.split(["EARLY=1"], ["--env=A=x=y", "--env", "B=", "--", "launch", "com.example.App",
                                                                           "--env=C=z"])
    #expect(environment == ["EARLY": "1", "A": "x=y", "B": ""])
    #expect(command == ["launch", "com.example.App", "--env=C=z"])
    let (none, plain) = try DeviceCommandLine.split([], ["launch", "--", "x"])
    #expect(none.isEmpty && plain == ["launch", "--", "x"])
    let (_, bare) = try DeviceCommandLine.split([], ["--env=A=1", "launch", "app"])
    #expect(bare == ["launch", "app"])
    #expect(throws: OSSError.self) { try DeviceCommandLine.split([], ["--env=NOVALUE", "launch"]) }
    #expect(throws: OSSError.self) { try DeviceCommandLine.split(["=x"], ["launch"]) }
}

#if canImport(Network)

/// The files routes and their grants take an iOS lease (its own folder),
/// not exec; its launch's environment is refused for other commands and
/// other platforms before anything runs.
@Test func anIOSLeasesFilesGoThroughTheServerAndItsGrants() async throws {
    let server = try await XCTestServer.start()
    defer { server.stop() }
    // On this Mac: its uploads' folder, through the server and back.
    let id = "f" + Random.hex(3)
    let local = await server.lease(id)
    defer { try? FileManager.default.removeItem(atPath: "\(Paths.uploads)/\(id)") }
    let put = try await server.client.uploadFile(local.id, holder: "alice", data: Data("{\"story\": 1}".utf8), to: "control.json")
    #expect(put.path == "\(Paths.uploads)/\(id)/control.json")
    #expect(FileManager.default.contents(atPath: put.path) == Data("{\"story\": 1}".utf8))
    _ = try await server.client.uploadFile(local.id, holder: "alice", data: Data("2".utf8), to: "control.json")
    #expect(try await server.client.downloadFile(local.id, holder: "alice", path: "control.json") == Data("2".utf8))
    for path in ["../x", "/etc/hosts", "~/x"] {
        let out = await #expect(throws: OSSError.self, "\(path)") { try await server.client.downloadFile(local.id, holder: "alice", path: path) }
        #expect(out?.status == 400)
    }
    let theirs = await #expect(throws: OSSError.self) { try await server.client.downloadFile(local.id, holder: "bob", path: "control.json") }
    #expect(theirs?.status == 404)
    // Its grants: upload and download, not exec.
    let upload = try await server.client.grant(GrantRequest(verb: "machine.upload", lease: local.id), holder: "alice")
    let download = try await server.client.grant(GrantRequest(verb: "machine.download", lease: local.id), holder: "alice")
    #expect(upload.path.hasPrefix("/v1/machines/\(id)/files"))
    #expect(try await OSSGrantClient(url: upload.url).uploadFile(Data("granted".utf8), to: "g.txt").size == 7)
    #expect(try await OSSGrantClient(url: download.url).downloadFile("g.txt") == Data("granted".utf8))
    await #expect(throws: OSSError.self) { try await server.client.grant(GrantRequest(verb: "machine.exec", lease: local.id), holder: "alice") }
    let (input, feed) = AsyncStream<ExecFrame>.makeStream()
    feed.yield(.closeStdin)
    let exec = await #expect(throws: OSSError.self) {
        try await server.client.exec(local.id, holder: "alice", ExecRequest(arguments: ["true"]), input: input) { _ in }
    }
    #expect(exec?.message.contains("simctl, not exec") == true, "\(String(describing: exec))")

    // In a primary that's gone: not ready, as a slot's.
    var inPrimary = await server.lease("p" + Random.hex(3))
    inPrimary.primary = "gone"
    await server.machines.adopt(inPrimary)
    let missing = await #expect(throws: OSSError.self) {
        try await server.client.uploadFile(inPrimary.id, holder: "alice", data: Data("x".utf8), to: "control.json")
    }
    #expect(missing?.code == "notReady", "\(String(describing: missing))")

    // An environment is a launch's or a spawn's, and a simulator's.
    await #expect(throws: APIError.self) { try await server.machines.command(local.id, ["listapps"], environment: ["A": "1"]) }
    let emulator = await server.lease("a" + Random.hex(3), platform: .android)
    await #expect(throws: APIError.self) { try await server.machines.command(emulator.id, ["shell", "true"], environment: ["A": "1"]) }
}

#endif
