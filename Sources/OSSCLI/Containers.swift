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

    /// A detached container, kept running by oss's own command: the image's
    /// entrypoint set aside for a shell that waits until it's told to stop.
    /// Its home is its own; only `folder` (oss's: the runner, processes'
    /// output, files in transit) is shared into it, at /oss. A shared folder
    /// costs the server a file handle for every file the container looks at
    /// in it, so nothing big or many-filed goes there.
    func create(name: String, image: String, folder: String, environmentFile: String?, variables: [String: String],
                cpus: Int, memory: String) async throws {
        var arguments = ["run", "-d", "--name", name, self.name == "container" ? "-c" : "--cpus", String(cpus), "-m", memory,
                         "-v", "\(folder):/oss"]
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
    /// Removes the container, forcibly; true once the runtime says it is
    /// gone. A guest that answers nothing (one thrashing for memory) can
    /// outlast a delete: it is killed and deleted again.
    @discardableResult
    func remove(_ name: String) async -> Bool {
        let delete = self.name == "container" ? ["delete", "--force", name] : ["rm", "-f", name]
        _ = try? await run(delete, timeout: 120)
        if await exists(name) == false { return true }
        _ = try? await run(["kill", name], timeout: 60)
        _ = try? await run(delete, timeout: 120)
        return await exists(name) == false
    }

    /// Whether the runtime has a container of that name; nil when it didn't
    /// answer.
    func exists(_ name: String) async -> Bool? {
        let arguments = self.name == "container" ? ["list", "--all", "--quiet"] : ["ps", "-a", "--format", "{{.Names}}"]
        guard let result = try? await run(arguments, timeout: 30), result.ok else { return nil }
        return result.output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == name }
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

/// Containers, each `oss-container-<id>`, whose home is on its own disk:
/// stopped and restarted as is, archived as a tarball of its home (the
/// container deleted), and restarted from the archive into a new one. Of
/// the server's, only the container's own folder
/// (`~/.local/state/oss/containers/<id>`) is shared into it, at /oss; files
/// in and out pass through it one at a time, made and read by the container.
///
/// What runs in one runs as a process: each in the container on its own
/// (oss's runner, `/oss/run`), its input a FIFO in the container, its
/// output and errors files in the folder (`/oss/processes/<id>/`) read from
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

    /// The container's own folder on the server, shared into it at /oss.
    private static func folder(_ id: String) -> String { "\(Paths.containerFolders)/\(id)" }

    /// The container for one: its variables (the request's) in an env file
    /// deleted once it's made, its folder (only the server's user can read
    /// it) with the runner in it.
    private func createContainer(_ container: Container, environment: [String: String]?) async throws {
        let runtime = try requireRuntime()
        let file = try Self.environmentFile(environment)
        defer { if let file { try? FileManager.default.removeItem(atPath: file) } }
        let folder = Self.folder(container.id)
        Paths.ensure(folder)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        try Self.writeRunner(folder)
        try await runtime.create(name: container.name, image: container.image ?? config.containerImage, folder: folder, environmentFile: file,
                                 variables: ["OSS_HOLDER": "container-\(container.id)"],
                                 cpus: container.cpus ?? config.containerCPUs, memory: container.memory ?? config.containerMemory)
    }

    /// The templates' files, by their path in a home: never archived (a
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

    /// The home made ready once its container runs: an archive's files
    /// unpacked into it (a restore); the templates' files (the image's, then
    /// the server's) copied in where it lacks them, so what the container
    /// changed of its own stays; and its oss settings written (its token, and
    /// this server as the container reaches it), so `oss` and `oss mcp` there
    /// lease machines. They pass through the folder (/oss/incoming), which
    /// the container empties.
    private func prepareHome(_ id: String, archive: String? = nil) async throws {
        let runtime = try requireRuntime()
        let container = try require(id)
        let incoming = "\(Self.folder(id))/incoming"
        try? FileManager.default.removeItem(atPath: incoming)
        Paths.ensure(incoming)
        defer { try? FileManager.default.removeItem(atPath: incoming) }
        if let archive { try FileManager.default.copyItem(atPath: archive, toPath: "\(incoming)/home.tar.gz") }
        for template in Self.templates(image: container.image ?? config.containerImage) {
            guard let enumerator = FileManager.default.enumerator(atPath: template) else { continue }
            while let relative = enumerator.nextObject() as? String {
                let source = "\(template)/\(relative)", target = "\(incoming)/template/\(relative)"
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: source, isDirectory: &directory), !directory.boolValue,
                      (try? FileManager.default.attributesOfItem(atPath: target)) == nil else { continue }
                Paths.ensure((target as NSString).deletingLastPathComponent)
                try? FileManager.default.copyItem(atPath: source, toPath: target)
            }
        }
        if let token = container.token, let host = container.hostAddress {
            Paths.ensure("\(incoming)/settings")
            FileManager.default.createFile(atPath: "\(incoming)/settings/token", contents: Data("\(token)\n".utf8),
                                           attributes: [.posixPermissions: 0o600])
            let servers = ["servers": ["http://\(host):\(config.port)"]]
            if let data = try? JSONEncoder().encode(servers) {
                FileManager.default.createFile(atPath: "\(incoming)/settings/client.json", contents: data)
            }
        }
        let script = """
            set -e
            cd /oss/incoming
            if [ -f home.tar.gz ]; then tar -xzf home.tar.gz -C /root; fi
            if [ -d template ]; then
              (cd template && find . -type f) | while IFS= read -r f; do
                t="/root/${f#./}"
                [ -e "$t" ] || { mkdir -p "$(dirname "$t")"; cp -p "template/$f" "$t"; }
              done
            fi
            if [ -d settings ]; then
              mkdir -p /root/.config/oss
              cp settings/* /root/.config/oss/
              chmod 600 /root/.config/oss/token
            fi
            """
        let result = try await runtime.exec(container.name, ["/bin/sh", "-c", script], timeout: 3600)
        guard result.ok else { throw APIError(error: "preparing container \(id)'s home: \(result.error)\(result.output)") }
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
        if let archive, !FileManager.default.fileExists(atPath: archive) { throw APIError(error: "no archive \(archive)") }
        containers[id] = container
        save()
        do {
            try await createContainer(container, environment: request.environment)
            containers[id]?.state = .running
            containers[id]?.hostAddress = await runtime.hostAddress(container.name)
            try await prepareHome(id, archive: archive)
        } catch {
            // A container that didn't start leaves nothing behind: the answer says why.
            await runtime.remove(container.name)
            try? FileManager.default.removeItem(atPath: Self.folder(id))
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
                                                             "/oss/processes/\(process.id)/pid"], timeout: 30)
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
        var restoring: String?
        switch container.state {
        case .stopped, .running:
            if container.state == .running { await runtime.stop(container.name) }
            markLost(container)
            try Self.writeRunner(Self.folder(id))
            try await runtime.start(container.name)
        case .archived:
            guard let archive = container.archive, FileManager.default.fileExists(atPath: archive) else {
                throw APIError(error: "container \(id)'s archive is gone")
            }
            if container.token == nil { container.token = Random.hex(24) }
            containers[id] = container
            try await createContainer(container, environment: environment)
            restoring = archive
        default:
            throw APIError(error: "container \(id) is \(container.state.rawValue)")
        }
        containers[id]?.state = .running
        containers[id]?.hostAddress = await runtime.hostAddress(container.name)
        if containers[id]?.token == nil { containers[id]?.token = Random.hex(24) }
        save()
        try await prepareHome(id, archive: restoring)
        return containers[id]!
    }

    /// The container's home as a tarball (its path is the answer's `archive`),
    /// its container and folder deleted. The container packs it (started
    /// again if it was stopped) into its folder; left out: its token, the
    /// templates' files and the secrets (a restore writes the first two again).
    func archive(_ id: String) async throws -> Container {
        let runtime = try requireRuntime()
        guard let container = containers[id], container.state == .running || container.state == .stopped else {
            throw APIError(error: "no container \(id) to archive")
        }
        if container.state == .stopped {
            try Self.writeRunner(Self.folder(id))
            try await runtime.start(container.name)
        }
        await endProcesses(container)
        let excluded = Self.ownSecrets + Self.templateFiles(image: container.image ?? config.containerImage)
            + (container.secretFiles ?? [])
        // `./path`: the members are named from `.`, so a pattern so written
        // matches at the home's root only (GNU tar and BusyBox's alike).
        let packed = "\(Self.folder(id))/home.tar.gz"
        let tar = try await runtime.exec(container.name, ["tar", "-czf", "/oss/home.tar.gz", "-C", "/root"]
                                             + excluded.map { "--exclude=./\($0)" } + ["."], timeout: 3600)
        guard tar.ok else {
            try? FileManager.default.removeItem(atPath: packed)
            if container.state == .stopped { await runtime.stop(container.name) }
            throw APIError(error: "archiving \(id): \(tar.error)")
        }
        Paths.ensure(Paths.archives)
        let archive = "\(Paths.archives)/\(id).tar.gz"
        try? FileManager.default.removeItem(atPath: archive)
        try FileManager.default.moveItem(atPath: packed, toPath: archive)
        guard await runtime.remove(container.name) else {
            try? FileManager.default.removeItem(atPath: archive)
            log("container \(id): \(runtime.name) didn't remove \(container.name); not archived")
            throw APIError(error: "\(runtime.name) didn't remove \(container.name) (its guest may not be answering): not archived")
        }
        try? FileManager.default.removeItem(atPath: Self.folder(id))
        containers[id]?.state = .archived
        containers[id]?.archive = archive
        containers[id]?.hostAddress = nil
        save()
        log("container \(id): archived to \(archive)")
        return containers[id]!
    }

    /// The container gone: its container, its folder and its archive.
    func remove(_ id: String) async throws {
        let runtime = try requireRuntime()
        let container = try require(id)
        // Its folder goes only with it: a container still running (a remove
        // that timed out) would have oss's files pulled away under it.
        guard await runtime.remove(container.name) else {
            log("container \(id): \(runtime.name) didn't remove \(container.name)")
            throw APIError(error: "\(runtime.name) didn't remove \(container.name) (its guest may not be answering): try again")
        }
        try? FileManager.default.removeItem(atPath: Self.folder(id))
        if let archive = container.archive { try? FileManager.default.removeItem(atPath: archive) }
        containers[id] = nil
        save()
        log("container \(id): removed")
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

    /// oss's runner, written into each container's folder (so any image
    /// works): the command's input is a FIFO in the container, held open by a
    /// placeholder writer until oss closes it; its output, errors, pid and
    /// exit status are files in the folder.
    static let runner = """
        #!/bin/sh
        # oss's process runner: run <id> <command...>
        id="$1"; shift
        dir="/oss/processes/$id"; run="/tmp/oss/$id"
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

    private static func writeRunner(_ folder: String) throws {
        Paths.ensure("\(folder)/processes")
        try Data(runner.utf8).write(to: URL(fileURLWithPath: "\(folder)/run"))
    }

    private struct ProcessRecord: Codable {
        var command: [String]
        var directory: String?
        var started: Date
    }

    private static func processDirectory(_ id: String, _ process: String) -> String { "\(folder(id))/processes/\(process)" }

    /// Processes with no exit status whose container stopped: they're gone.
    private func markLost(_ container: Container) {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: "\(Self.folder(container.id))/processes") else { return }
        for id in ids {
            let directory = Self.processDirectory(container.id, id)
            if !FileManager.default.fileExists(atPath: "\(directory)/status") {
                FileManager.default.createFile(atPath: "\(directory)/lost", contents: Data())
            }
        }
    }

    private func running(_ id: String) throws -> (Container, ContainerRuntime, String) {
        let runtime = try requireRuntime()
        let container = try require(id)
        guard container.state == .running else { throw APIError(error: "container \(id) isn't running") }
        return (container, runtime, Self.folder(id))
    }

    private static func validProcessID(_ process: String) throws {
        guard !process.isEmpty, process.allSatisfy({ $0.isHexDigit }) else { throw APIError(error: "no process \(process)") }
    }

    func startProcess(_ id: String, _ request: ProcessRequest) async throws -> ContainerProcess {
        let (container, runtime, folder) = try running(id)
        guard !request.command.isEmpty else { throw APIError(error: "no command") }
        let process = Random.hex(4)
        let directory = Self.processDirectory(id, process)
        Paths.ensure(directory)
        try JSONEncoder.oss.encode(ProcessRecord(command: request.command, directory: request.directory, started: Date()))
            .write(to: URL(fileURLWithPath: "\(directory)/command.json"))
        try Self.writeRunner(folder)
        // The server's container.env, then the request's own variables over it.
        let image = container.image ?? config.containerImage
        let file = try Self.environmentFile(Self.serverEnvironment(image: image).merging(request.environment ?? [:]) { $1 })
        defer { if let file { try? FileManager.default.removeItem(atPath: file) } }
        let result = try await runtime.exec(container.name, ["/bin/sh", "/oss/run", process] + request.command,
                                            detach: true, environmentFile: file, directory: request.directory)
        guard result.ok else {
            try? FileManager.default.removeItem(atPath: directory)
            throw APIError(error: "starting the process: \(result.error)\(result.output)")
        }
        return try self.process(id, process)
    }

    func processes(_ id: String) throws -> [ContainerProcess] {
        let container = try require(id)
        guard container.state != .archived,
              let ids = try? FileManager.default.contentsOfDirectory(atPath: "\(Self.folder(id))/processes") else { return [] }
        return ids.compactMap { try? process(id, $0) }.sorted { $0.started < $1.started }
    }

    func process(_ id: String, _ process: String) throws -> ContainerProcess {
        try Self.validProcessID(process)
        let container = try require(id)
        guard container.state != .archived else { throw APIError(error: "container \(id) is archived") }
        let directory = Self.processDirectory(id, process)
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
            let data = Self.read("\(Self.processDirectory(id, process))/\(stream)", from: offset, limit: limit)
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
                                                                "/oss/processes/\(process)/pid"])
        guard result.ok else { throw APIError(error: "signalling process \(process): \(result.error)") }
        return try self.process(id, process)
    }

    // MARK: Files

    private static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else { throw APIError(error: "a path in the home can't hold ..") }
        return parts
    }

    /// A path in the container's home as the container names it: relative to
    /// the home, or absolute under /root. The container reads and writes it
    /// itself, so where its symlinks lead is its own business: nothing of the
    /// server's is in reach.
    private static func guestPath(_ path: String) throws -> String {
        var parts = try components(path)
        if path.hasPrefix("/") {
            guard parts.first == "root" else { throw APIError(error: "\(path) is outside the container's home (/root)") }
            parts.removeFirst()
        }
        return "/" + (["root"] + parts).joined(separator: "/")
    }

    /// A name in the container's folder for one file on its way in or out.
    private static func transfer() -> String { "transfer-\(Random.hex(8))" }

    /// A file's bytes, or a directory as a gzipped tarball (`isDirectory`):
    /// the container copies (or packs) it into its folder, read from there.
    func readFile(_ id: String, _ path: String) async throws -> (Data, isDirectory: Bool) {
        let (container, runtime, folder) = try running(id)
        let target = try Self.guestPath(path), name = Self.transfer()
        defer { try? FileManager.default.removeItem(atPath: "\(folder)/\(name)") }
        let result = try await runtime.exec(container.name, ["/bin/sh", "-c", """
            if [ -d "$1" ]; then tar -czf "$2" -C "$1" . && echo directory
            elif [ -e "$1" ]; then cp "$1" "$2" && echo file
            else exit 3; fi
            """, "sh", target, "/oss/\(name)"], timeout: 3600)
        guard result.ok else { throw APIError(error: result.status == 3 ? "no file \(path)" : "reading \(path): \(result.error)") }
        guard let data = FileManager.default.contents(atPath: "\(folder)/\(name)") else { throw APIError(error: "can't read \(path)") }
        return (data, result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "directory")
    }

    /// A file followed as it grows (a transcript being written): its bytes
    /// from `offset`, at most `limit`, waiting up to `wait` seconds while it
    /// has nothing past `offset`; with its size now. A size below `offset`
    /// means it shrank or was replaced: read it again from 0. The container
    /// waits and reads (one call however long the wait), its answer the size
    /// on a line, then the bytes.
    func followFile(_ id: String, _ path: String, from offset: Int, limit: Int, wait: Double) async throws -> (Data, size: Int) {
        let (container, runtime, _) = try running(id)
        let target = try Self.guestPath(path)
        let tries = Int(min(max(wait, 0), 60) / 0.15)
        let result = try await runtime.exec(container.name, ["/bin/sh", "-c", """
            [ -f "$1" ] || exit 3
            i=0
            while :; do
              s=$(wc -c < "$1" | tr -d ' ')
              [ "$s" -ne "$2" ] && break
              [ "$i" -ge "$4" ] && break
              i=$((i + 1)); sleep 0.15
            done
            echo "$s"
            if [ "$s" -gt "$2" ]; then tail -c +$(($2 + 1)) "$1" | head -c "$3"; fi
            """, "sh", target, String(max(offset, 0)), String(max(1, min(limit, 16 << 20))), String(tries)], timeout: 120)
        guard result.ok else { throw APIError(error: result.status == 3 ? "no file \(path)" : "reading \(path): \(result.error)") }
        guard let newline = result.data.firstIndex(of: UInt8(ascii: "\n")),
              let size = Int(String(decoding: result.data[..<newline], as: UTF8.self)) else {
            throw APIError(error: "reading \(path): no size")
        }
        return (Data(result.data[result.data.index(after: newline)...]), size)
    }

    /// A file written (its directories made; replaced whole, never seen half
    /// written), or with `unpack` a gzipped tarball unpacked into the
    /// directory `path`: the bytes go to the container's folder, the
    /// container puts them in place.
    func writeFile(_ id: String, _ path: String, data: Data, unpack: Bool) async throws {
        let (container, runtime, folder) = try running(id)
        let target = try Self.guestPath(path), name = Self.transfer()
        if !unpack, try Self.components(path).isEmpty || target == "/root" { throw APIError(error: "which file?") }
        guard FileManager.default.createFile(atPath: "\(folder)/\(name)", contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw APIError(error: "can't write \(path)")
        }
        defer { try? FileManager.default.removeItem(atPath: "\(folder)/\(name)") }
        let script = unpack
            ? "mkdir -p \"$1\" && tar -xzf \"$2\" -C \"$1\""
            : "mkdir -p \"$(dirname \"$1\")\" && cp \"$2\" \"$1.oss-new\" && mv -f \"$1.oss-new\" \"$1\""
        let result = try await runtime.exec(container.name, ["/bin/sh", "-c", script, "sh", target, "/oss/\(name)"], timeout: 3600)
        guard result.ok else { throw APIError(error: "\(unpack ? "unpacking into" : "writing") \(path): \(result.error)") }
    }

    /// A file or directory removed (a symlink itself, not what it names).
    func deleteFile(_ id: String, _ path: String) async throws {
        let (container, runtime, _) = try running(id)
        let target = try Self.guestPath(path)
        guard target != "/root" else { throw APIError(error: "not the whole home: remove the container") }
        let result = try await runtime.exec(container.name, ["/bin/sh", "-c",
            "[ -e \"$1\" ] || [ -L \"$1\" ] || exit 3; rm -rf -- \"$1\"", "sh", target], timeout: 600)
        guard result.ok else { throw APIError(error: result.status == 3 ? "no file \(path)" : "removing \(path): \(result.error)") }
    }
}
