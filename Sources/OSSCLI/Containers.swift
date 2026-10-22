import Foundation
import OSSClient

/// The container tool on this computer: Apple's `container` on a Mac,
/// Podman or Docker on Linux. The few commands oss uses mean the same in all three.
struct ContainerRuntime: Sendable {
    var path: String
    var name: String

    static func detect() -> ContainerRuntime? {
        let candidates: [(String, String)]
        #if os(macOS)
        candidates = [("/opt/homebrew/bin/container", "container"), ("/usr/local/bin/container", "container")]
        #else
        candidates = [("/usr/bin/podman", "podman"), ("/usr/local/bin/podman", "podman"),
                      ("/usr/bin/docker", "docker"), ("/usr/local/bin/docker", "docker")]
        #endif
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.0) }
            .map { ContainerRuntime(path: $0.0, name: $0.1) }
    }

    func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 600) async throws -> ProcessResult {
        try await Shell.run(path, arguments, input: input, timeout: timeout)
    }

    func build(tag: String, file: String, context: String) async throws -> Int32 {
        let status = try Shell.passthrough(path, ["build", "-t", tag, "-f", file, context])
        // Apple's builder is a container of its own (2 GB): not kept between builds.
        if name == "container" { _ = try? await run(["builder", "stop"], timeout: 120) }
        return status
    }

    /// A detached container with its home at /root, kept running by oss's
    /// own command: the image's entrypoint set aside for a shell that waits
    /// until it's told to stop (all an image needs is /bin/sh).
    func create(name: String, image: String, home: String, environmentFile: String?, variables: [String: String],
                cpus: Int, memory: String) async throws {
        var arguments = ["run", "-d", "--name", name, self.name == "container" ? "-c" : "--cpus", String(cpus), "-m", memory,
                         "-v", "\(home):/root"]
        // Docker has no name for the host unless asked; Podman's is host.containers.internal.
        if self.name == "docker" { arguments += ["--add-host", "host.docker.internal:host-gateway"] }
        if let environmentFile { arguments += ["--env-file", environmentFile] }
        for (key, value) in variables.sorted(by: { $0.key < $1.key }) { arguments += ["-e", "\(key)=\(value)"] }
        arguments += ["--entrypoint", "/bin/sh", image, "-c", "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done"]
        let result = try await run(arguments)
        guard result.ok else { throw APIError(error: "\(self.name) run: \(result.error)\(result.output)") }
    }

    func stop(_ name: String) async { _ = try? await run(["stop", name], timeout: 120) }
    func start(_ name: String) async throws {
        let result = try await run(["start", name])
        guard result.ok else { throw APIError(error: "\(self.name) start: \(result.error)") }
    }
    func remove(_ name: String) async {
        _ = try? await run(self.name == "container" ? ["delete", "--force", name] : ["rm", "-f", name], timeout: 120)
    }

    /// A command in the container: detached (it runs on after this returns),
    /// or to completion with `input` as its standard input.
    func exec(_ name: String, _ command: [String], detach: Bool = false, input: Data? = nil, environmentFile: String? = nil,
              directory: String? = nil, timeout: TimeInterval = 120) async throws -> ProcessResult {
        var arguments = ["exec"]
        if detach { arguments.append("-d") }
        if input != nil { arguments.append("-i") }
        if let environmentFile { arguments += ["--env-file", environmentFile] }
        if let directory { arguments += ["-w", directory] }
        return try await run(arguments + [name] + command, input: input, timeout: timeout)
    }

    private func inspect(_ name: String) async -> [String: Any]? {
        guard let result = try? await run(["inspect", name], timeout: 30), result.ok,
              let list = try? JSONSerialization.jsonObject(with: result.data) as? [[String: Any]] else { return nil }
        return list.first
    }

    /// running, stopped, or nil when there's no such container.
    func state(_ name: String) async -> String? {
        if self.name == "container" {
            guard let info = await inspect(name) else { return nil }
            // `status` is an object (its `state`) in container 1.x, a string before.
            return ((info["status"] as? [String: Any])?["state"] as? String) ?? (info["status"] as? String) ?? "unknown"
        }
        guard let result = try? await run(["inspect", "-f", "{{.State.Status}}", name], timeout: 30), result.ok else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The host (the server's computer) as the container reaches it.
    func hostAddress(_ name: String) async -> String? {
        switch self.name {
        case "container":
            let networks = ((await inspect(name))?["status"] as? [String: Any])?["networks"] as? [[String: Any]]
            return networks?.first?["ipv4Gateway"] as? String
        case "podman": return "host.containers.internal"
        default: return "host.docker.internal"
        }
    }

    func interactive(_ arguments: [String]) throws -> Int32 { try Shell.passthrough(path, arguments) }
}

/// Containers, each `oss-container-<id>`, whose home is a directory on the
/// host (`~/.local/state/oss/containers/<id>`): stopped and restarted as
/// is, archived as a tarball of that directory (the container deleted), and
/// restarted from the archive into a new one.
///
/// What runs in one runs as a process: each in the container on its own
/// (oss's runner, `~/.oss/run`), its input a FIFO in the container, its
/// output and errors files in the home (`~/.oss/processes/<id>/`) read from
/// any offset.
actor ContainerManager {
    let config: ServerConfig
    let runtime: ContainerRuntime?
    private var containers: [String: Container] = [:]
    /// Each process's writes, one after another.
    private var inputs: [String: Task<Void, Error>] = [:]

    /// The container's own oss token: never archived.
    static let ownSecrets = [".config/oss/token"]

    init(config: ServerConfig) {
        self.config = config
        runtime = ContainerRuntime.detect()
        let saved = FileManager.default.contents(atPath: Paths.containers)
            .flatMap { try? JSONDecoder.oss.decode([Container].self, from: $0) } ?? []
        for container in saved { containers[container.id] = container }
    }

    func list() -> [Container] { containers.values.sorted { $0.created < $1.created } }
    func container(_ id: String) -> Container? { containers[id] }

    private func save() {
        Paths.ensure(Paths.state)
        if let data = try? JSONEncoder.oss.encode(Array(containers.values)) {
            FileManager.default.createFile(atPath: Paths.containers, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    private func requireRuntime() throws -> ContainerRuntime {
        guard let runtime else {
            throw APIError(error: "no container tool: install Apple's container (macOS) or Podman/Docker (Linux)")
        }
        return runtime
    }

    private func require(_ id: String) throws -> Container {
        guard let container = containers[id] else { throw APIError(error: "no container \(id)") }
        return container
    }

    /// The variables every process in a container of `image` gets unless a
    /// request says otherwise: the server's container.env, then the image's
    /// own (`~/.config/oss/images/<image>.env`) over it. KEY=VALUE lines;
    /// blank lines and # comments skipped.
    private static func serverEnvironment(image: String) -> [String: String] {
        [Paths.containerEnvironment, "\(Paths.imageSettings)/\(imageKey(image)).env"].reduce(into: [:]) { variables, file in
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
                variables[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
            }
        }
    }

    /// An image's name as a file name: `my-image`, `docker.io_library_ubuntu_24.04`.
    static func imageKey(_ image: String) -> String {
        String(image.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
    }

    /// The home templates for a container of `image`: the image's own
    /// (`~/.config/oss/images/<image>.home`) first, then the server's
    /// (`~/.config/oss/container-home`).
    private static func templates(image: String) -> [String] {
        ["\(Paths.imageSettings)/\(imageKey(image)).home", Paths.containerHomeTemplate]
    }

    /// Variables as an env file only the server's user can read, for one
    /// command; the caller deletes it. Nil when there are none.
    private static func environmentFile(_ variables: [String: String]?) throws -> String? {
        guard let variables, !variables.isEmpty else { return nil }
        for key in variables.keys where key.isEmpty || key.contains("=") || key.contains("\n") {
            throw APIError(error: "not a variable name: \(key)")
        }
        for value in variables.values where value.contains("\n") { throw APIError(error: "a variable's value can't hold a newline") }
        Paths.ensure(Paths.state)
        let file = "\(Paths.state)/env-\(Random.hex(8))"
        let text = variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined()
        guard FileManager.default.createFile(atPath: file, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw APIError(error: "can't write \(file)")
        }
        return file
    }

    /// The container for one: its variables (the request's) in an env file
    /// deleted once it's made, its home prepared.
    private func createContainer(_ container: Container, home: String, environment: [String: String]?) async throws {
        let runtime = try requireRuntime()
        let file = try Self.environmentFile(environment)
        defer { if let file { try? FileManager.default.removeItem(atPath: file) } }
        try Self.writeRunner(home)
        Self.overlayTemplate(home, image: container.image ?? config.containerImage)
        try await runtime.create(name: container.name, image: container.image ?? config.containerImage, home: home, environmentFile: file,
                                 variables: ["OSS_HOLDER": "container-\(container.id)"],
                                 cpus: container.cpus ?? config.containerCPUs, memory: container.memory ?? config.containerMemory)
    }

    /// The server's home template (~/.config/oss/container-home) copied in,
    /// file by file, where the home lacks it: archives leave these out, and a
    /// restore takes them again; what the container changed of its own stays.
    /// The template's files, by their path in a home: never archived (a
    /// restore copies them in again).
    private static func templateFiles(image: String) -> [String] {
        var files: [String] = []
        for template in templates(image: image) {
            guard let enumerator = FileManager.default.enumerator(atPath: template) else { continue }
            while let relative = enumerator.nextObject() as? String {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: "\(template)/\(relative)", isDirectory: &directory), !directory.boolValue {
                    files.append(relative)
                }
            }
        }
        return files
    }

    private static func overlayTemplate(_ home: String, image: String) {
        for template in templates(image: image) {
            guard let enumerator = FileManager.default.enumerator(atPath: template) else { continue }
            while let relative = enumerator.nextObject() as? String {
                let source = "\(template)/\(relative)", target = "\(home)/\(relative)"
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: source, isDirectory: &directory), !directory.boolValue,
                      (try? FileManager.default.attributesOfItem(atPath: target)) == nil else { continue }
                Paths.ensure((target as NSString).deletingLastPathComponent)
                try? FileManager.default.copyItem(atPath: source, toPath: target)
            }
        }
    }

    /// The container's oss settings in its home: its token, and this server
    /// as its container reaches it, so `oss` and `oss mcp` there lease machines.
    private func writeClientSettings(_ id: String) {
        guard let container = containers[id], let home = container.home, let token = container.token,
              let host = container.hostAddress else { return }
        let directory = "\(home)/.config/oss"
        Paths.ensure(directory)
        FileManager.default.createFile(atPath: "\(directory)/token", contents: Data("\(token)\n".utf8),
                                       attributes: [.posixPermissions: 0o600])
        let servers = ["servers": ["http://\(host):\(config.port)"]]
        if let data = try? JSONEncoder().encode(servers) { FileManager.default.createFile(atPath: "\(directory)/client.json", contents: data) }
    }

    /// The container a scoped token belongs to (compared in constant time).
    func container(forToken token: String) -> String? {
        guard !token.isEmpty else { return nil }
        var found: String?
        for container in containers.values where container.state == .running || container.state == .stopped || container.state == .starting {
            if let own = container.token, constantTimeEqual(own, token) { found = container.id }
        }
        return found
    }

    /// A new container, or (with `archive`) one restored from an archive made
    /// here or elsewhere (a container migrated in).
    func start(_ request: ContainerRequest, archive: String? = nil) async throws -> Container {
        let runtime = try requireRuntime()
        let running = containers.values.filter { $0.state == .running || $0.state == .starting }.count
        guard running < config.containerLimit else { throw APIError(error: "busy: \(running) of \(config.containerLimit) containers are running") }
        for path in request.secretFiles ?? [] { _ = try Self.components(path) }
        if let cpus = request.cpus, !(1...64).contains(cpus) { throw APIError(error: "cpus is 1 to 64") }
        if let memory = request.memory, memory.range(of: "^[0-9]+[kmgKMG]?$", options: .regularExpression) == nil {
            throw APIError(error: "memory is a size such as 4g or 512m")
        }
        if let image = request.image, image.range(of: "^[A-Za-z0-9][A-Za-z0-9._/:@-]*$", options: .regularExpression) == nil {
            throw APIError(error: "not an image name: \(image)")
        }
        let id = Random.hex(4)
        var container = Container(id: id, holder: request.holder ?? "unknown", state: .starting, created: Date(),
                                  name: "oss-container-\(id)")
        container.image = request.image
        container.secretFiles = request.secretFiles
        container.labels = request.labels
        container.cpus = request.cpus
        container.memory = request.memory
        container.token = Random.hex(24)
        let home = "\(Paths.containerHomes)/\(id)"
        Paths.ensure(home)
        if let archive { try await unpack(archive, into: home) }
        container.home = home
        containers[id] = container
        save()
        do {
            try await createContainer(container, home: home, environment: request.environment)
            containers[id]?.state = .running
            containers[id]?.hostAddress = await runtime.hostAddress(container.name)
            writeClientSettings(id)
        } catch {
            // A container that didn't start leaves nothing behind: the answer says why.
            await runtime.remove(container.name)
            try? FileManager.default.removeItem(atPath: home)
            containers[id] = nil
            save()
            log("container \(id): didn't start: \(error)")
            throw error
        }
        save()
        log("container \(id): \(container.image ?? config.containerImage) for \(container.holder) as \(container.name)")
        return containers[id]!
    }

    /// Its running processes asked to end (SIGTERM: a program writes out its
    /// transcript), and given up to `grace` seconds, before the container stops.
    private func endProcesses(_ container: Container, grace: TimeInterval = 10) async {
        guard container.state == .running, let runtime,
              let running = try? processes(container.id).filter({ $0.state == .running }), !running.isEmpty else { return }
        for process in running {
            _ = try? await runtime.exec(container.name, ["/bin/sh", "-c", "kill -s TERM \"$(cat \"$1\")\"", "sh",
                                                             "/root/.oss/processes/\(process.id)/pid"], timeout: 30)
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline,
              (try? processes(container.id).contains { $0.state == .running }) == true {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func stop(_ id: String) async throws -> Container {
        let runtime = try requireRuntime()
        guard let container = containers[id], container.state == .running else { throw APIError(error: "no running container \(id)") }
        await endProcesses(container)
        await runtime.stop(container.name)
        markLost(container)
        containers[id]?.state = .stopped
        save()
        return containers[id]!
    }

    /// A stopped container's container started again; an archived container
    /// restored into a new one (which takes its variables again).
    func restart(_ id: String, environment: [String: String]? = nil) async throws -> Container {
        let runtime = try requireRuntime()
        var container = try require(id)
        switch container.state {
        case .stopped, .running:
            if container.state == .running { await runtime.stop(container.name) }
            markLost(container)
            if let home = container.home { try Self.writeRunner(home) }
            try await runtime.start(container.name)
        case .archived:
            guard let archive = container.archive, FileManager.default.fileExists(atPath: archive) else {
                throw APIError(error: "container \(id)'s archive is gone")
            }
            let home = "\(Paths.containerHomes)/\(id)"
            Paths.ensure(home)
            try await unpack(archive, into: home)
            container.home = home
            containers[id] = container
            try await createContainer(container, home: home, environment: environment)
        default:
            throw APIError(error: "container \(id) is \(container.state.rawValue)")
        }
        containers[id]?.state = .running
        containers[id]?.hostAddress = await runtime.hostAddress(container.name)
        if containers[id]?.token == nil { containers[id]?.token = Random.hex(24) }
        writeClientSettings(id)
        save()
        return containers[id]!
    }

    /// The container's home as a tarball (its path is the answer's `archive`),
    /// its container and directory deleted. Left out: oss's own files
    /// (`~/.oss`: the runner, processes' output) and the secrets.
    func archive(_ id: String) async throws -> Container {
        let runtime = try requireRuntime()
        guard let container = containers[id], let home = container.home, container.state != .archived else {
            throw APIError(error: "no container \(id) to archive")
        }
        await endProcesses(container)
        await runtime.stop(container.name)
        Paths.ensure(Paths.archives)
        let archive = "\(Paths.archives)/\(id).tar.gz"
        // Left out: oss's own files, its token, the server's template files and its secrets.
        let excluded = [".oss"] + Self.ownSecrets + Self.templateFiles(image: container.image ?? config.containerImage)
            + (container.secretFiles ?? [])
        #if os(macOS)
        // bsdtar: `^` anchors a pattern at the archive's root.
        let exclusions = excluded.flatMap { ["--exclude", "^./\($0)"] }
        #else
        let exclusions = ["--anchored"] + excluded.flatMap { ["--exclude", "./\($0)"] }
        #endif
        let tar = try await Shell.run("/usr/bin/tar", ["-czf", archive, "-C", home] + exclusions + ["."], timeout: 3600)
        guard tar.ok else { throw APIError(error: "archiving \(id): \(tar.error)") }
        await runtime.remove(container.name)
        try? FileManager.default.removeItem(atPath: home)
        containers[id]?.state = .archived
        containers[id]?.archive = archive
        containers[id]?.home = nil
        containers[id]?.hostAddress = nil
        save()
        log("container \(id): archived to \(archive)")
        return containers[id]!
    }

    /// The container gone: its container, its directory and its archive.
    func remove(_ id: String) async throws {
        let runtime = try requireRuntime()
        let container = try require(id)
        await runtime.remove(container.name)
        if let home = container.home { try? FileManager.default.removeItem(atPath: home) }
        if let archive = container.archive { try? FileManager.default.removeItem(atPath: archive) }
        containers[id] = nil
        save()
        log("container \(id): removed")
    }

    private func unpack(_ archive: String, into home: String) async throws {
        let tar = try await Shell.run("/usr/bin/tar", ["-xzf", archive, "-C", home], timeout: 3600)
        guard tar.ok else { throw APIError(error: "restoring \(archive): \(tar.error)") }
    }

    /// After a restart: containers whose containers are gone are marked so.
    func reconcile() async {
        guard let runtime else { return }
        for container in containers.values where container.state == .running || container.state == .stopped {
            let state = await runtime.state(container.name)
            if state == nil { containers[container.id]?.state = .failed; containers[container.id]?.error = "its container is gone" }
            else if state == "stopped" || state == "exited" { containers[container.id]?.state = .stopped; markLost(container) }
        }
        save()
    }

    // MARK: Processes

    /// oss's runner, written into each container's home (so any image works):
    /// the command's input is a FIFO in the container, held open by a
    /// placeholder writer until oss closes it; its output, errors, pid and
    /// exit status are files in the home.
    static let runner = """
        #!/bin/sh
        # oss's process runner: run <id> <command...>
        id="$1"; shift
        dir="/root/.oss/processes/$id"; run="/tmp/oss/$id"
        mkdir -p "$dir" "$run"
        mkfifo "$run/in"
        tail -f /dev/null > "$run/in" &
        echo $! > "$run/holder"
        "$@" < "$run/in" >> "$dir/out" 2>> "$dir/err" &
        echo $! > "$dir/pid"
        wait $!
        status=$?
        kill "$(cat "$run/holder")" 2>/dev/null
        echo $status > "$dir/status.new" && mv "$dir/status.new" "$dir/status"

        """

    private static func writeRunner(_ home: String) throws {
        Paths.ensure("\(home)/.oss/processes")
        try Data(runner.utf8).write(to: URL(fileURLWithPath: "\(home)/.oss/run"))
    }

    private struct ProcessRecord: Codable {
        var command: [String]
        var directory: String?
        var started: Date
    }

    private static func processDirectory(_ home: String, _ process: String) -> String { "\(home)/.oss/processes/\(process)" }

    /// Processes with no exit status whose container stopped: they're gone.
    private func markLost(_ container: Container) {
        guard let home = container.home,
              let ids = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.oss/processes") else { return }
        for id in ids {
            let directory = Self.processDirectory(home, id)
            if !FileManager.default.fileExists(atPath: "\(directory)/status") {
                FileManager.default.createFile(atPath: "\(directory)/lost", contents: Data())
            }
        }
    }

    private func running(_ id: String) throws -> (Container, ContainerRuntime, String) {
        let runtime = try requireRuntime()
        let container = try require(id)
        guard container.state == .running, let home = container.home else { throw APIError(error: "container \(id) isn't running") }
        return (container, runtime, home)
    }

    private static func validProcessID(_ process: String) throws {
        guard !process.isEmpty, process.allSatisfy({ $0.isHexDigit }) else { throw APIError(error: "no process \(process)") }
    }

    func startProcess(_ id: String, _ request: ProcessRequest) async throws -> ContainerProcess {
        let (container, runtime, home) = try running(id)
        guard !request.command.isEmpty else { throw APIError(error: "no command") }
        let process = Random.hex(4)
        let directory = Self.processDirectory(home, process)
        Paths.ensure(directory)
        try JSONEncoder.oss.encode(ProcessRecord(command: request.command, directory: request.directory, started: Date()))
            .write(to: URL(fileURLWithPath: "\(directory)/command.json"))
        try Self.writeRunner(home)
        // The server's container.env, then the request's own variables over it.
        let image = container.image ?? config.containerImage
        let file = try Self.environmentFile(Self.serverEnvironment(image: image).merging(request.environment ?? [:]) { $1 })
        defer { if let file { try? FileManager.default.removeItem(atPath: file) } }
        let result = try await runtime.exec(container.name, ["/bin/sh", "/root/.oss/run", process] + request.command,
                                            detach: true, environmentFile: file, directory: request.directory)
        guard result.ok else {
            try? FileManager.default.removeItem(atPath: directory)
            throw APIError(error: "starting the process: \(result.error)\(result.output)")
        }
        return try self.process(id, process)
    }

    func processes(_ id: String) throws -> [ContainerProcess] {
        let container = try require(id)
        guard let home = container.home,
              let ids = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.oss/processes") else { return [] }
        return ids.compactMap { try? process(id, $0) }.sorted { $0.started < $1.started }
    }

    func process(_ id: String, _ process: String) throws -> ContainerProcess {
        try Self.validProcessID(process)
        let container = try require(id)
        guard let home = container.home else { throw APIError(error: "container \(id) is archived") }
        let directory = Self.processDirectory(home, process)
        guard let data = FileManager.default.contents(atPath: "\(directory)/command.json"),
              let record = try? JSONDecoder.oss.decode(ProcessRecord.self, from: data) else {
            throw APIError(error: "no process \(process) in container \(id)")
        }
        func size(_ name: String) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: "\(directory)/\(name)"))?[.size] as? Int) ?? 0
        }
        let status = FileManager.default.contents(atPath: "\(directory)/status")
            .flatMap { Int32(String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        let state: ProcessState = status != nil ? .exited
            : (container.state != .running || FileManager.default.fileExists(atPath: "\(directory)/lost")) ? .lost : .running
        let pid = FileManager.default.contents(atPath: "\(directory)/pid")
            .flatMap { Int32(String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return ContainerProcess(id: process, container: id, command: record.command, directory: record.directory, started: record.started,
                            state: state, status: status, pid: pid, outputSize: size("out"), errorSize: size("err"))
    }

    /// Its output (`out`) or errors (`err`) from `offset`, at most `limit`
    /// bytes; while it runs and has nothing new, waiting up to `wait` seconds
    /// for more.
    func output(_ id: String, _ process: String, stream: String, from offset: Int, limit: Int, wait: Double) async throws
        -> (Data, ContainerProcess) {
        guard stream == "out" || stream == "err" else { throw APIError(error: "stream is out or err") }
        let deadline = Date().addingTimeInterval(min(max(wait, 0), 60))
        while true {
            let info = try self.process(id, process)
            let home = try require(id).home!
            let data = Self.read("\(Self.processDirectory(home, process))/\(stream)", from: offset, limit: limit)
            if !data.isEmpty || info.state != .running || Date() >= deadline { return (data, info) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func read(_ path: String, from offset: Int, limit: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(offset, 0)))
            return try handle.read(upToCount: max(1, min(limit, 16 << 20))) ?? Data()
        } catch {
            return Data()
        }
    }

    /// Bytes for its input, in order with the other writes; `close` then ends
    /// its input (it reads end of file).
    func input(_ id: String, _ process: String, data: Data, close: Bool) async throws {
        let (container, runtime, _) = try running(id)
        let info = try self.process(id, process)
        guard info.state == .running else {
            // Its input is closed already.
            if data.isEmpty && close { return }
            throw APIError(error: "process \(process) has \(info.state.rawValue)")
        }
        let fifo = "/tmp/oss/\(process)/in"
        let key = "\(id)/\(process)"
        let previous = inputs[key]
        let task = Task {
            _ = try? await previous?.value
            if !data.isEmpty {
                // Opened read-write, so a gone reader can't block the open; the FIFO may not be made yet.
                let result = try await runtime.exec(container.name, ["/bin/sh", "-c",
                    "i=0; while [ ! -p \"$1\" ]; do i=$((i+1)); [ $i -gt 100 ] && exit 3; sleep 0.05; done; cat 1<>\"$1\"", "sh", fifo],
                    input: data, timeout: 300)
                guard result.ok else { throw APIError(error: "writing to process \(process): \(result.error)") }
            }
            if close {
                let result = try await runtime.exec(container.name, ["/bin/sh", "-c",
                    "i=0; while [ ! -s \"$1\" ]; do i=$((i+1)); [ $i -gt 100 ] && exit 3; sleep 0.05; done; kill \"$(cat \"$1\")\" 2>/dev/null; exit 0", "sh",
                    "/tmp/oss/\(process)/holder"])
                guard result.ok else { throw APIError(error: "closing process \(process)'s input: \(result.error)") }
            }
        }
        inputs[key] = task
        defer { if inputs[key] == task { inputs[key] = nil } }
        try await task.value
    }

    func signal(_ id: String, _ process: String, signal: String) async throws -> ContainerProcess {
        let (container, runtime, _) = try running(id)
        try Self.validProcessID(process)
        guard ["TERM", "KILL", "INT", "HUP"].contains(signal) else { throw APIError(error: "signal is TERM, KILL, INT or HUP") }
        let result = try await runtime.exec(container.name, ["/bin/sh", "-c", "kill -s \(signal) \"$(cat \"$1\")\"", "sh",
                                                                "/root/.oss/processes/\(process)/pid"])
        guard result.ok else { throw APIError(error: "signalling process \(process): \(result.error)") }
        return try self.process(id, process)
    }

    // MARK: Files

    private static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else { throw APIError(error: "a path in the home can't hold ..") }
        return parts
    }

    /// A path in the container's home, its symlinks resolved as the container
    /// sees them (an absolute target is the container's: /root is the home),
    /// refused when one leads out of it: a symlink the container made can't
    /// lead oss's own reads and writes elsewhere on the host.
    private func resolve(_ id: String, _ path: String) throws -> String {
        let container = try require(id)
        guard let home = container.home else { throw APIError(error: "container \(id) is archived: restart it first") }
        guard let root = Self.realPath(home) else { throw APIError(error: "container \(id)'s home is gone") }
        let out = APIError(error: "\(path) leads out of the container's home")
        var resolved: [String] = [], pending = try Self.components(path), hops = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                guard !resolved.isEmpty else { throw out }
                resolved.removeLast()
                continue
            }
            let candidate = ([root] + resolved + [part]).joined(separator: "/")
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else {
                resolved.append(part)
                continue
            }
            hops += 1
            guard hops <= 40 else { throw APIError(error: "\(path): too many symlinks") }
            var parts = target.split(separator: "/").map(String.init)
            if target.hasPrefix("/") {
                guard parts.first == "root" else { throw out }
                parts.removeFirst()
                resolved = []
            }
            pending = parts + pending
        }
        return ([root] + resolved).joined(separator: "/")
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A file's bytes, or a directory as a gzipped tarball (`isDirectory`).
    func readFile(_ id: String, _ path: String) async throws -> (Data, isDirectory: Bool) {
        let full = try resolve(id, path)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &directory) else { throw APIError(error: "no file \(path)") }
        if directory.boolValue {
            let tar = try await Shell.run("/usr/bin/tar", ["-czf", "-", "-C", full, "."], timeout: 3600)
            guard tar.ok else { throw APIError(error: "packing \(path): \(tar.error)") }
            return (tar.data, true)
        }
        guard let data = FileManager.default.contents(atPath: full) else { throw APIError(error: "can't read \(path)") }
        return (data, false)
    }

    /// A file followed as it grows (a transcript being written): its bytes
    /// from `offset`, at most `limit`, waiting up to `wait` seconds while it
    /// has nothing past `offset`; with its size now. A size below `offset`
    /// means it shrank or was replaced: read it again from 0.
    func followFile(_ id: String, _ path: String, from offset: Int, limit: Int, wait: Double) async throws -> (Data, size: Int) {
        let deadline = Date().addingTimeInterval(min(max(wait, 0), 60))
        while true {
            let full = try resolve(id, path)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &directory), !directory.boolValue else {
                throw APIError(error: "no file \(path)")
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int) ?? 0
            if size > offset {
                return (Self.read(full, from: offset, limit: limit), size)
            }
            if size < offset || Date() >= deadline { return (Data(), size) }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// A file written (its directories made), or with `unpack` a gzipped
    /// tarball unpacked into the directory `path`.
    func writeFile(_ id: String, _ path: String, data: Data, unpack: Bool) async throws {
        let full = try resolve(id, path)
        if unpack {
            Paths.ensure(full)
            _ = try resolve(id, path)
            let tar = try await Shell.run("/usr/bin/tar", ["-xzf", "-", "-C", full], input: data, timeout: 3600)
            guard tar.ok else { throw APIError(error: "unpacking into \(path): \(tar.error)") }
            return
        }
        guard !(try Self.components(path)).isEmpty else { throw APIError(error: "which file?") }
        Paths.ensure((full as NSString).deletingLastPathComponent)
        _ = try resolve(id, path)
        try data.write(to: URL(fileURLWithPath: full), options: .atomic)
    }

    /// A file or directory removed (a symlink itself, not what it names).
    func deleteFile(_ id: String, _ path: String) throws {
        let parts = try Self.components(path)
        guard let name = parts.last else { throw APIError(error: "not the whole home: remove the container") }
        let full = try resolve(id, parts.dropLast().joined(separator: "/")) + "/" + name
        guard (try? FileManager.default.attributesOfItem(atPath: full)) != nil else { throw APIError(error: "no file \(path)") }
        try FileManager.default.removeItem(atPath: full)
    }
}
