import Foundation
import Testing
import OSSClient
@testable import OSSServer

// A Mac slot's commands and files (SlotAPI.swift, API 18): the command
// lines sent to its primary, held to what a shell makes of them. The
// primary's own parts (sudo, launchctl) can't run here; the rest of each
// line, the slot's wrapper with the request's words, runs in this
// computer's shell and must give the command back exactly as asked.

private let lease = "ab12"

/// The words a slot's command line gives its program, as this computer's
/// shell reads them (no sudo: the wrapper and its parameters alone), and
/// what it writes and its status.
private func runHere(_ request: ExecRequest, input: String = "") async throws -> ProcessResult {
    let id = "t" + String(UUID().uuidString.prefix(8)).lowercased()
    let run = "r1"
    defer { try? FileManager.default.removeItem(atPath: SlotCommand.pidFile(lease: id, run: run)) }
    let arguments = try SlotCommand.execArguments(request, lease: id, run: run)
    return try await Shell.run("/bin/sh", ["-c", "cd / && " + SlotCommand.words(arguments) + "; exit $?"], input: Data(input.utf8), timeout: 60)
}

/// Whether this computer has what the primary's wrapper uses.
private var wrapperRunsHere: Bool {
    FileManager.default.isExecutableFile(atPath: "/bin/bash") && FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")
}

@Test func aQuotedWordIsOneWordWhateverItHolds() async throws {
    #expect(SlotCommand.quote("plain") == "'plain'")
    #expect(SlotCommand.quote("it's") == #"'it'\''s'"#)
    #expect(SlotCommand.quote("") == "''")
    let hard = ["with space", "it's", "\"double\"", "$HOME and $(echo no) `echo no`", "line\nbreak", #"back\slash"#, "-n", "*", "", "; rm -rf /"]
    let echoed = try await Shell.run("/bin/sh", ["-c", "printf '[%s]' " + SlotCommand.words(hard)], timeout: 30)
    #expect(echoed.output == hard.map { "[\($0)]" }.joined())
}

@Test func aSlotsCommandRunsAsItsUserFromRootAndGivesItsStatus() throws {
    let line = try SlotCommand.execLine(ExecRequest(arguments: ["swift", "--version"]), lease: lease, run: "r1", console: "runner")
    #expect(line.hasPrefix("cd / && sudo -u 'oss-ab12' -H '/bin/bash' '-lc' '"))
    #expect(line.hasSuffix("'oss-exec' '/tmp/oss-exec-ab12-r1.pid' '/Users/oss-ab12' '--' 'swift' '--version'; exit $?"))
    // In the GUI session: the console user's, by launchctl asuser.
    let gui = try SlotCommand.execLine(ExecRequest(arguments: ["open", "-W", "App.app"], gui: true), lease: lease, run: "r2", console: "runner")
    #expect(gui.hasPrefix(#"cd / && sudo launchctl asuser "$(id -u 'runner')" sudo -u 'runner' -H '/bin/bash' '-lc' '"#))
    #expect(gui.hasSuffix("'oss-exec' '/tmp/oss-exec-ab12-r2.pid' '/Users/oss-ab12' '--' 'open' '-W' 'App.app'; exit $?"))
    #expect(SlotCommand.runner(ExecRequest(arguments: ["x"], gui: true), lease: lease, console: "runner") == "runner")
    #expect(SlotCommand.runner(ExecRequest(arguments: ["x"]), lease: lease, console: "runner") == "oss-ab12")
    // A file's command, ContainerAPI's script, as the slot's user.
    let files = SlotCommand.filesLine(lease: lease, ContainerAPIFiles.arguments("size", "/Users/oss-ab12/a b"))
    #expect(files.hasPrefix("cd / && sudo -u 'oss-ab12' -H '/bin/sh' '-c' '"))
    #expect(files.hasSuffix("'oss-files' 'size' '/Users/oss-ab12/a b'; exit $?"))
}

@Test func theArgumentsEnvironmentAndInputArriveAsGiven() async throws {
    guard wrapperRunsHere else { return }
    let hard = ["with space", "it's", "\"double\"", "$HOME and $(echo no) `echo no`", "line\nbreak", #"back\slash"#, "-n", "*", ""]
    let echoed = try await runHere(ExecRequest(arguments: ["/bin/sh", "-c", #"printf '[%s]' "$@"; echo; pwd; printf '%s' "$A_B""#, "sh"] + hard,
                                               environment: ["A_B": "x $(echo no) 'q'\n"], workingDirectory: "/tmp"))
    #expect(echoed.status == 0, "\(echoed.error)")
    let lines = echoed.output.components(separatedBy: "\n")
    #expect(echoed.output.hasPrefix(hard.map { "[\($0)]" }.joined() + "\n"))
    #expect(lines.contains("/tmp") || lines.contains("/private/tmp"))
    #expect(echoed.output.hasSuffix("x $(echo no) 'q'\n"))
    // Standard input reaches the program; a program found on PATH, by name.
    let catted = try await runHere(ExecRequest(arguments: ["cat"], workingDirectory: "/tmp"), input: "through\nstdin")
    #expect(catted.output == "through\nstdin")
}

@Test func aCommandsStatusIsItsOwn() async throws {
    guard wrapperRunsHere else { return }
    #expect(try await runHere(ExecRequest(arguments: ["sh", "-c", "exit 7"], workingDirectory: "/tmp")).status == 7)
    let missing = try await runHere(ExecRequest(arguments: ["oss-no-such-program"], workingDirectory: "/tmp"))
    #expect(missing.status == 127)
    #expect(missing.error.contains("oss: oss-no-such-program:"))
    // Its own process group, its pid where a signal finds it.
    guard FileManager.default.isExecutableFile(atPath: "/bin/ps") else { return }
    let id = "t" + String(UUID().uuidString.prefix(8)).lowercased()
    defer { try? FileManager.default.removeItem(atPath: SlotCommand.pidFile(lease: id, run: "r1")) }
    let arguments = try SlotCommand.execArguments(ExecRequest(arguments: ["sh", "-c", "ps -o pgid= -p $$"], workingDirectory: "/tmp"),
                                                  lease: id, run: "r1")
    let grouped = try await Shell.run("/bin/sh", ["-c", SlotCommand.words(arguments)], timeout: 30)
    let pid = try String(contentsOfFile: SlotCommand.pidFile(lease: id, run: "r1"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(grouped.output.trimmingCharacters(in: .whitespacesAndNewlines) == pid)
}

@Test func aSlotsPathsStayInItsHomeOrTmp() throws {
    #expect(try SlotCommand.resolve("~", lease: lease) == "/Users/oss-ab12")
    #expect(try SlotCommand.resolve("~/a b/c.txt", lease: lease) == "/Users/oss-ab12/a b/c.txt")
    #expect(try SlotCommand.resolve("build/./out//App.zip", lease: lease) == "/Users/oss-ab12/build/out/App.zip")
    #expect(try SlotCommand.resolve("/Users/oss-ab12/x", lease: lease) == "/Users/oss-ab12/x")
    #expect(try SlotCommand.resolve("/tmp/x", lease: lease) == "/tmp/x")
    #expect(try SlotCommand.resolve("/private/tmp/x", lease: lease) == "/private/tmp/x")
    #expect(try SlotCommand.resolve("it's $HOME", lease: lease) == "/Users/oss-ab12/it's $HOME")
    for refused in ["../x", "a/../../runner", "/Users/oss-ab12/../runner/.ssh", "/etc/passwd", "/Users/oss-ab120/x", "/tmpx", "/Users",
                    "", "a\0b", "~runner/x/../.."] {
        #expect(throws: APIError.self, "\(refused)") { try SlotCommand.resolve(refused, lease: lease) }
    }
}

@Test func aSlotsCommandRefusesWhatItCantRun() throws {
    func refused(_ request: ExecRequest) -> Bool {
        (try? SlotCommand.execArguments(request, lease: lease, run: "r1")) == nil
    }
    #expect(refused(ExecRequest(arguments: ["sh"], tty: true)), "no terminal yet")
    #expect(refused(ExecRequest(arguments: [])))
    #expect(refused(ExecRequest(arguments: [""])))
    #expect(refused(ExecRequest(arguments: ["echo", "a\0b"])))
    #expect(refused(ExecRequest(arguments: ["env"], environment: ["A\0": "x"])))
    #expect(refused(ExecRequest(arguments: ["env"], environment: ["A": "x\0y"])))
    #expect(refused(ExecRequest(arguments: ["pwd"], workingDirectory: "/Users/runner")))
    #expect(refused(ExecRequest(arguments: ["pwd"], workingDirectory: "../runner")))
    for name in ["1A", "A-B", "A=B", "", "-n", "A B", "Ä"] {
        #expect(refused(ExecRequest(arguments: ["env"], environment: [name: "x"])), "\(name)")
    }
    for name in ["A", "_x", "PATH", "A_1"] {
        #expect(!refused(ExecRequest(arguments: ["env"], environment: [name: "x"])), "\(name)")
    }
    // The environment in a steady order, after the wrapper's own two.
    let arguments = try SlotCommand.execArguments(ExecRequest(arguments: ["env"], environment: ["B": "2", "A": "1 2"], workingDirectory: "/tmp"),
                                                  lease: lease, run: "r1")
    #expect(Array(arguments.dropFirst(4)) == ["/tmp/oss-exec-ab12-r1.pid", "/tmp", "A=1 2", "B=2", "--", "env"])
}

@Test func aSignalReachesTheCommandsGroupAsItsUser() {
    #expect(SlotCommand.signalName(linux: 15) == "TERM")
    #expect(SlotCommand.signalName(linux: 2) == "INT")
    #expect(SlotCommand.signalName(linux: 10) == "USR1")   // 30 on macOS
    #expect(SlotCommand.signalName(linux: 12) == "USR2")
    #expect(SlotCommand.signalName(linux: 99) == nil)
    let script = SlotCommand.signalScript(lease: lease, run: "r1", user: "oss-ab12", signal: "TERM")
    #expect(script.contains("f='/tmp/oss-exec-ab12-r1.pid'"))
    #expect(script.contains(#"sudo -u 'oss-ab12' /bin/kill -s TERM -- "-$p""#))
    // Never a pid of 0 or 1 (kill's "every process" and launchd), nor anything but digits.
    #expect(script.contains("case $p in ''|*[!0-9]*|0|1) exit 0;; esac"))
    #expect(SlotUser.deleteScript(lease: lease).contains("sudo rm -f /tmp/oss-exec-ab12-*.pid"))
}

@Test func slotsTakeCommandsAndFilesAsContainersDo() {
    #expect(Platform.container.takesExec && Platform.mac.takesExec)
    for platform in [Platform.macos, .linux, .windows, .ios, .android] { #expect(!platform.takesExec, "\(platform)") }
    // A request without `gui` (an older client's) decodes; one with it says so.
    let old = try? JSONDecoder().decode(ExecRequest.self, from: Data(#"{"arguments":["true"],"tty":false,"environment":{}}"#.utf8))
    #expect(old?.gui == nil)
    let encoded = String(decoding: (try? JSONEncoder().encode(ExecRequest(arguments: ["true"]))) ?? Data(), as: UTF8.self)
    #expect(!encoded.contains("gui"), "nothing new for an older server to read")
    #expect(OSS.apiLevel >= 18)
}

/// ContainerAPI's file script's arguments, as the routes build them.
private enum ContainerAPIFiles {
    static func arguments(_ what: String, _ path: String) -> [String] {
        #if canImport(Network)
        ContainerAPI.files(what, path)
        #else
        ["/bin/sh", "-c", "", "oss-files", what, path]
        #endif
    }
}

#if canImport(Network)

/// Through a real server: a slot's routes, grants and MCP tool are no longer
/// a container's alone. With no primary here, each answers that the slot's
/// primary is gone (`notReady`), not that it isn't a container.
@Test func aSlotsRoutesGrantsAndToolTakeIt() async throws {
    let server = try await XCTestServer.start()
    defer { server.stop() }
    let slot = await server.lease("m1", platform: .mac)
    let (input, feed) = AsyncStream<ExecFrame>.makeStream()
    feed.yield(.closeStdin)
    let exec = await #expect(throws: OSSError.self) {
        try await server.client.exec(slot.id, holder: "alice", ExecRequest(arguments: ["true"]), input: input) { _ in }
    }
    #expect(exec?.code == "notReady", "\(String(describing: exec))")
    let put = await #expect(throws: OSSError.self) {
        try await server.client.uploadFile(slot.id, holder: "alice", data: Data("x".utf8), to: "a.txt")
    }
    #expect(put?.code == "notReady")
    let get = await #expect(throws: OSSError.self) { try await server.client.downloadFile(slot.id, holder: "alice", path: "a.txt") }
    #expect(get?.code == "notReady")
    // Its grants are issued.
    for verb in ["machine.exec", "machine.upload", "machine.download"] {
        let grant = try await server.client.grant(GrantRequest(verb: verb, lease: slot.id), holder: "alice")
        #expect(grant.path.hasPrefix("/v1/machines/m1/" + (verb == "machine.exec" ? "exec" : "files")))
    }
    // A whole VM still takes SSH.
    let vm = await server.lease("v1", platform: .macos)
    let refused = await #expect(throws: OSSError.self) {
        try await server.client.downloadFile(vm.id, holder: "alice", path: "a.txt")
    }
    #expect(refused?.message.contains("a container lease's or a Mac slot's") == true)
    // The MCP tool runs it (and so meets its missing primary), rather than refusing a slot.
    let context = MCPServer.Context(client: server.client, holder: "alice", sshPublicKey: nil, sshIdentity: nil, localFiles: false)
    let called = await MCPServer.call("oss_exec", ["id": "m1", "command": "true"], context: context)
    let said = ((called["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    #expect(!said.contains("oss_exec runs in containers"), "\(said)")
    #expect(said.contains("primary macOS VM"), "\(said)")
}

/// The program a slot's commands go through, on this computer: frames in,
/// its streams out apart, its status.
@Test func aRemoteProcessCarriesStdinAndBothStreams() async throws {
    let process = try RemoteProcess.start("/bin/sh", ["-c", "cat; echo to-stderr >&2; exit 3"])
    try await process.write(.stdin(Data("one ".utf8)))
    try await process.write(.stdin(Data("two".utf8)))
    try await process.write(.closeStdin)
    let result = await process.finish()
    #expect(result.status == 3)
    #expect(String(decoding: result.output, as: UTF8.self) == "one two")
    #expect(result.error == "to-stderr\n")

    let seen = Written()
    let streamed = try RemoteProcess.start("/bin/sh", ["-c", "echo out; echo err >&2"],
                                           stdout: { seen.take(.stdout($0)); return true }, stderr: { seen.take(.stderr($0)); return true })
    try await streamed.write(.closeStdin)
    #expect(await streamed.finish().status == 0)
    #expect(seen.stdout == "out\n" && seen.stderr == "err\n")
}

#endif
