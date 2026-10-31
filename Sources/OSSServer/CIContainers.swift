import Foundation
import OSSClient

#if canImport(Network)
import CryptoKit

/// CI's runners in OS Server's own containers: each a container lease
/// (kind `ci`, labelled with its repository, run and job) of the agent
/// image, GitHub's runner and the Linux `oss` put in it through its exec
/// socket, `run.sh --jitconfig` run there with the job's grant in its
/// environment and no token of the server's, and the lease released when
/// it exits, with whatever the job leased and stored.
struct CIContainers: CIRunnerHost {
    let machines: MachineManager
    let storage: StorageStore
    let grants: GrantKey
    let jobGrants: JobGrants
    let plan: CIPlan
    /// The API's port, where a job's container reaches the server.
    let port: Int
    let kit: CIRunnerKit

    /// Where the runner runs: `run.sh` in its folder, given the job's
    /// configuration as its argument (not in its environment, which the
    /// job's steps inherit), with oss on its PATH.
    static let runScript = """
        export PATH="$HOME/.local/bin:$PATH"
        cd "$HOME/actions-runner" && exec ./run.sh --jitconfig "$1"
        """

    func releaseLeftovers() async {
        for lease in await machines.all() where lease.labels?[CINames.runnerLabel] != nil && lease.state != .returning && lease.state != .failed {
            log("ci: lease \(lease.id) was a runner's when OS Server last stopped (its job ended with it); released")
            await release(lease: lease.id, holder: lease.labels?[CINames.holderLabel] ?? "")
        }
    }

    func start(_ job: CIJob, holder: String, runnerHolder: String) async throws -> String {
        let runner = try await kit.runner()
        let client = await kit.client(using: self)
        var labels = ["oss.ci.repository": job.repository, "oss.ci.run": "\(job.runID)", "oss.ci.job": "\(job.id)"]
        labels[CINames.runnerLabel] = "\(job.repository)#\(job.id)"
        labels[CINames.holderLabel] = holder
        let lease = try await self.lease(holder: runnerHolder, label: "\(job.repository) · \(job.workflow ?? "a workflow") #\(job.runID) · \(job.name)",
                                    link: job.url ?? job.runURL, labels: labels)
        do {
            try await put(runner, into: lease, "mkdir -p \"$HOME/actions-runner\" && tar -xz -C \"$HOME/actions-runner\"")
            if let client {
                try await put(client, into: lease, "mkdir -p \"$HOME/.local/bin\" && cat > \"$HOME/.local/bin/oss\" && chmod 755 \"$HOME/.local/bin/oss\"")
            } else {
                log("ci: lease \(lease.id): no Linux oss to put in it (its job's scripts find none)")
            }
        } catch {
            await machines.release(lease.id, reason: "its runner couldn't be put in it")
            throw error
        }
        return lease.id
    }

    func environment(lease: String, holder: String) async throws -> [String: String] {
        let servers = await serverURLs(lease)
        guard let first = servers.first else { throw APIError(error: "no address the job's container reaches the server by") }
        let grant = try grants.issueJob(holder: holder, runner: lease, base: first, live: jobGrants)
        return ["OSS_GRANT": grant.absoluteString, "OSS_SERVERS": servers.joined(separator: ",")]
    }

    func run(lease: String, jitConfig: String, environment: [String: String],
             line: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        guard let socket = await machines.lease(lease)?.execSocket else { throw APIError(error: "lease \(lease) has no container") }
        // The runner runs as the image's user, root in the agent image: it
        // refuses that unless told it may.
        let request = ExecRequest(arguments: ["/bin/sh", "-c", Self.runScript, "oss-ci-runner", jitConfig],
                                  environment: environment.merging(["RUNNER_ALLOW_RUNASROOT": "1"]) { $1 })
        let lines = LineBuffer()
        let command = try await ContainerCommand.start(socket, request) { data in
            lines.add(data).forEach(line)
            return true
        }
        try? await command.write(.closeStdin)
        let result = await command.finish()
        if let rest = lines.rest() { line(rest) }
        if result.status != 0 {
            let said = result.error.split(separator: "\n").suffix(3).joined(separator: " / ")
            if !said.isEmpty { log("ci: lease \(lease): its runner exited \(result.status): \(said)") }
        }
        return result.status
    }

    func release(lease: String, holder: String) async {
        jobGrants.close(lease)
        await machines.release(lease, reason: "its CI job ended")
        guard !holder.isEmpty else { return }
        // What the job leased and stored goes with it. Each lease on its own:
        // a failed one's release waits a while for its holder to read why.
        for other in await machines.all() where other.holder == holder && other.state != .returning && other.state != .failed {
            Task { await machines.release(other.id, reason: "its CI job ended") }
        }
        for object in await storage.leases(of: holder) { try? await storage.release(object.id, holder: holder) }
    }

    // MARK: Containers

    /// A container leased (held until released) and ready, for a runner or
    /// for building oss.
    func lease(holder: String, label: String, link: URL?, labels: [String: String], cpus: Int? = nil) async throws -> Lease {
        let spec = ContainerSpec(image: plan.image, cpus: cpus ?? plan.cpus, memoryBytes: Int64(plan.memoryGigabytes) << 30, rosetta: true)
        let request = LeaseRequest(platform: .container, minutes: 0, holder: holder, container: spec, kind: .ci, label: label, link: link,
                                   labels: labels)
        let made: Lease
        do {
            made = try await machines.lease(request, local: true)
        } catch let error as APIError where error.code == "busy" {
            throw CIBusy(description: error.error)
        }
        let deadline = Date().addingTimeInterval(1800)
        while Date() < deadline {
            let now = await machines.lease(made.id)
            guard let lease = now, lease.state != .failed, lease.state != .returning else {
                throw APIError(error: "its container didn't start: \(now?.error ?? "released")")
            }
            if lease.state == .ready, lease.execSocket != nil { return lease }
            try await Task.sleep(for: .seconds(1))
        }
        await machines.release(made.id, reason: "its container didn't start in 30 minutes")
        throw APIError(error: "its container didn't start in 30 minutes (its image pulled the first time)")
    }

    /// A file into the container, on the standard input of `script`.
    func put(_ file: String, into lease: Lease, _ script: String) async throws {
        guard let socket = lease.execSocket, let handle = FileHandle(forReadingAtPath: file) else {
            throw APIError(error: "\(file) can't be put in lease \(lease.id)")
        }
        defer { try? handle.close() }
        let command = try await ContainerCommand.start(socket, ["/bin/sh", "-c", script])
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { try await command.write(.stdin(chunk)) }
            try await command.write(.closeStdin)
        } catch {
            command.close()
            _ = await command.finish()
            throw APIError(error: "putting \((file as NSString).lastPathComponent) in lease \(lease.id): \(error)")
        }
        let result = await command.finish()
        guard result.status == 0 else {
            throw APIError(error: "putting \((file as NSString).lastPathComponent) in lease \(lease.id): "
                                + result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The server as the job's container reaches it: server.json's
    /// `ci.serverURL`, else this Mac's address on the container's network,
    /// then its name.
    private func serverURLs(_ id: String) async -> [String] {
        if let given = plan.serverURL { return [given.hasSuffix("/") ? String(given.dropLast()) : given] }
        var hosts: [String] = []
        if let guest = await machines.lease(id)?.guestAddress, let address = LocalNetworks.hostAddress(facing: guest) { hosts.append(address) }
        hosts.append(localHostName)
        return hosts.map { "http://\($0):\(port)" }
    }
}

/// What every runner's container gets: GitHub's runner (downloaded once,
/// checked against its pinned SHA-256) and `oss` for Linux (built once for
/// each version of its sources, in a container of the jobs' image: OS
/// Server.app carries its own sources, `Resources/oss-source`), both kept
/// in OS Server's folder (`CI/`).
actor CIRunnerKit {
    let directory: String
    private var runnerTask: Task<String, Error>?
    private var clientTask: Task<String?, Never>?
    /// The sources' digest a build of failed, and when: not tried again for half an hour.
    private var failed: (digest: String, at: Date)?

    init(directory: String = Paths.ci) {
        self.directory = directory
    }

    /// The runner's archive, downloaded and checked the first time.
    func runner() async throws -> String {
        if let runnerTask, let path = try? await runnerTask.value { return path }
        let directory = directory
        let task = Task<String, Error> {
            let path = "\(directory)/actions-runner-linux-arm64-\(CIDefaults.runnerVersion).tar.gz"
            if FileManager.default.fileExists(atPath: path), (try? Self.sha256(path)) == CIDefaults.runnerSHA256 { return path }
            Paths.ensure(directory)
            log("ci: downloading GitHub's runner \(CIDefaults.runnerVersion) for Linux (arm64)")
            let (download, _) = try await URLSession.shared.download(from: CIDefaults.runnerURL)
            defer { try? FileManager.default.removeItem(at: download) }
            let found = try Self.sha256(download.path)
            guard found == CIDefaults.runnerSHA256 else {
                throw APIError(error: "GitHub's runner \(CIDefaults.runnerVersion) isn't the one expected (sha256 \(found))")
            }
            try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: download.path, toPath: path)
            return path
        }
        runnerTask = task
        do {
            return try await task.value
        } catch {
            runnerTask = nil
            throw error
        }
    }

    /// `oss` for Linux, built the first time its sources are new (nil when
    /// there are none here, or its build failed: the job runs without it).
    func client(using containers: CIContainers) async -> String? {
        if let clientTask { return await clientTask.value }
        let task = Task<String?, Never> { await self.build(using: containers) }
        clientTask = task
        let path = await task.value
        clientTask = nil
        return path
    }

    /// The sources OS Server.app carries, or a checkout's (OSS_REPO).
    static var sources: String? {
        Paths.bundled("Resources/oss-source") ?? ProcessInfo.processInfo.environment["OSS_REPO"]
    }

    private func build(using containers: CIContainers) async -> String? {
        guard let sources = Self.sources else { return nil }
        guard let digest = try? Self.digest(sources) else { return nil }
        let path = "\(directory)/oss-linux-arm64-\(digest.prefix(16))"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
        if let failed, failed.digest == digest, Date().timeIntervalSince(failed.at) < 1800 { return nil }
        log("ci: building oss for Linux from \(sources), in a container of \(containers.plan.image)")
        Paths.ensure(directory)
        let archive = "\(directory)/oss-source-\(Random.hex(4)).tar", partial = "\(path).partial"
        defer {
            try? FileManager.default.removeItem(atPath: archive)
            try? FileManager.default.removeItem(atPath: partial)
        }
        var builder: Lease?
        do {
            let tar = try await Shell.run("/usr/bin/tar", ["-c", "-f", archive, "--exclude", ".build", "-C", sources, "."], timeout: 120)
            guard tar.ok else { throw APIError(error: "archiving its sources: \(tar.error)") }
            builder = try await containers.lease(holder: "oss-build@ci", label: "OS Server: oss for Linux, for CI's jobs", link: nil,
                                                 labels: [CINames.runnerLabel: "oss build"], cpus: max(containers.plan.cpus, 6))
            guard let builder, let socket = builder.execSocket else { throw APIError(error: "no builder") }
            _ = FileManager.default.createFile(atPath: partial, contents: nil, attributes: [.posixPermissions: 0o755])
            guard let out = FileHandle(forWritingAtPath: partial), let input = FileHandle(forReadingAtPath: archive) else {
                throw APIError(error: "its files can't be opened")
            }
            defer {
                try? out.close()
                try? input.close()
            }
            let script = """
                set -e
                rm -rf /tmp/oss-source && mkdir -p /tmp/oss-source && tar -x -C /tmp/oss-source && cd /tmp/oss-source
                swift build -c release --product oss --static-swift-stdlib >&2
                cat .build/release/oss
                """
            let command = try await ContainerCommand.start(socket, ["/bin/sh", "-c", script]) { data in
                (try? out.write(contentsOf: data)) != nil
            }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try await command.write(.stdin(chunk)) }
            try await command.write(.closeStdin)
            let result = await command.finish()
            guard result.status == 0, (try? FileManager.default.attributesOfItem(atPath: partial)[.size] as? Int) ?? 0 > 0 else {
                throw APIError(error: "its build exited \(result.status): "
                                    + result.error.split(separator: "\n").suffix(5).joined(separator: " / "))
            }
            try out.close()
            try FileManager.default.moveItem(atPath: partial, toPath: path)
            await containers.machines.release(builder.id, reason: "oss for Linux built")
            log("ci: oss for Linux built (\(digest.prefix(16)))")
            return path
        } catch {
            if let builder { await containers.machines.release(builder.id, reason: "oss for Linux didn't build") }
            failed = (digest, Date())
            log("ci: oss for Linux didn't build: \(error)")
            return nil
        }
    }

    /// The sources' SHA-256: every file's path and bytes, in order of path,
    /// but a build's.
    static func digest(_ root: String) throws -> String {
        let manager = FileManager.default
        guard let walker = manager.enumerator(atPath: root) else { throw APIError(error: "no sources at \(root)") }
        var files: [String] = []
        while let relative = walker.nextObject() as? String {
            if relative == ".build" || relative.hasPrefix(".build/") || relative.hasPrefix(".git") {
                walker.skipDescendants()
                continue
            }
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: "\(root)/\(relative)", isDirectory: &isDirectory), !isDirectory.boolValue { files.append(relative) }
        }
        var hasher = SHA256()
        for relative in files.sorted() {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: manager.contents(atPath: "\(root)/\(relative)") ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw APIError(error: "\(path) can't be read") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ServerHost {
    /// CI, where this server runs it: the App's files and server.json's
    /// `ci` read (nil and why where it doesn't), its service made over this
    /// server's containers. Started once the leases a restart left are
    /// taken up again (`CIService.start`).
    static func makeCI(config: ServerConfig, machines: MachineManager, storage: StorageStore, grants: GrantKey,
                       jobGrants: JobGrants) -> (CIService?, String?) {
        let files: CIAppFiles.Loaded
        do {
            guard let loaded = try CIAppFiles.load() else { return (nil, "no GitHub App (\(Paths.clientDirectory)/\(CIAppFiles.configName))") }
            files = loaded
        } catch {
            log("ci: off: \(error)")
            return (nil, "\(error)")
        }
        guard machines.containers != nil, config.lends(.container) else {
            log("ci: off: this server runs no containers")
            return (nil, "this server runs no containers (OS Server's app does)")
        }
        // Half the containers it lends at most: its cap, or as many of a
        // job's as the budget holds.
        let containerCapacity = config.cap(.container)
            ?? config.leasePolicy().count(of: Int64(CIDefaults.memoryGigabytes) << 30)
        let (made, why) = CIPlan.make(settings: config.ci, app: files.config, containerCapacity: containerCapacity)
        guard let plan = made else {
            log("ci: off: \(why ?? "")")
            return (nil, why)
        }
        let key: RSAPrivateKey
        do {
            key = try RSAPrivateKey(pem: files.pem)
        } catch {
            log("ci: off: \(error)")
            return (nil, "\(error)")
        }
        let transport = URLSessionTransport()
        let app = GitHubApp(appID: plan.appID, sign: { try key.sign($0) }, transport: transport)
        let host = CIContainers(machines: machines, storage: storage, grants: grants, jobGrants: jobGrants, plan: plan,
                                port: config.port, kit: CIRunnerKit())
        return (CIService(plan: plan, github: GitHubREST(app: app, transport: transport), host: host), nil)
    }
}
#endif
