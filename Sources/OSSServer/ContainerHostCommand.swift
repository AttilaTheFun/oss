import Foundation
import OSSClient

/// `oss container-host <operation>`: OS Server as a container host for
/// Visor (Visor's docs/container-host.md, version 1 of its contract). Each
/// container is a container lease held until released, made with this
/// computer's client settings (its servers, its key or token) unless its
/// arguments name others, and found again by its labels: the request's own (Visor's session and server)
/// and two of the host's, the container's name and its request's digest.
///
///   oss container-host [--server=URL] [--key-file=FILE] <operation>
///   operations: health | create < request | exec <id> [--tty] [--workdir=DIR] [--env-file=FILE] -- program…
///               | put <id> <path> [--mode=600] < bytes | rm <id> [--volumes] | ls | network <id>
///
/// A container that mounts this Mac's folders (a Visor session's always
/// does) comes from this Mac's own OS Server: where the client settings
/// name another first, `--server=http://127.0.0.1:7480` says so, and
/// `--key-file` names the key for it.
///
/// Every operation but `exec` answers one JSON object on stdout, and exits
/// 0, or 1 with `{"error", "code"?}`. `exec` is `oss machine exec`: its
/// standard streams, signals and status the command's.
struct ContainerHostCommand {
    /// The contract's version this host speaks.
    static let api = 1
    static let name = "oss container-host"
    /// The labels the host finds its own containers by.
    static let nameLabel = "oss.container-host.name"
    static let specLabel = "oss.container-host.spec"
    /// The server's API that keeps labels with a lease.
    static let labelsAPI = 12

    let client: OSSClient
    /// What a container's network is checked with: a public name resolved,
    /// and reached over HTTPS.
    var resolve = ["sh", "-c", "getent hosts github.com > /dev/null"]
    var reach = ["sh", "-c", "curl -s -o /dev/null --max-time 8 https://github.com"]
    /// How often, and how far apart, a new container's network is tried
    /// before it is given up.
    var tries = 15
    var pause: Duration = .seconds(1)
    /// How long a container's lease is waited on while it is made, and
    /// while it goes.
    var step: Duration = .seconds(2)
    var patience: Duration = .seconds(180)

    /// What `create` is given: the container's image, size, this Mac's
    /// folders and its own disks; read field by field, a field left out its
    /// default.
    struct Request: Codable, Equatable {
        var name: String
        var image: String
        var cpus: Int?
        var memoryBytes: Int64?
        var mounts: [Mount] = []
        var volumes: [Volume] = []
        var environment: [String: String] = [:]
        var rosetta = false
        var labels: [String: String] = [:]

        struct Mount: Codable, Equatable {
            var source: String
            var destination: String
            var readOnly: Bool?
        }

        struct Volume: Codable, Equatable {
            var name: String
            var destination: String
            var sizeBytes: Int64
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            image = try c.decode(String.self, forKey: .image)
            cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
            memoryBytes = try c.decodeIfPresent(Int64.self, forKey: .memoryBytes)
            mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts) ?? []
            volumes = try c.decodeIfPresent([Volume].self, forKey: .volumes) ?? []
            environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
            rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
            labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        }

        /// Its container lease: held until released, its volumes kept when
        /// it goes (a container made again finds them), labelled.
        func lease(spec: String) -> LeaseRequest {
            let container = ContainerSpec(image: image, cpus: cpus, memoryBytes: memoryBytes,
                                          mounts: mounts.map { ContainerMount(source: $0.source, destination: $0.destination, readOnly: $0.readOnly ?? false) },
                                          volumes: volumes.map { ContainerVolume(name: $0.name, destination: $0.destination, sizeBytes: $0.sizeBytes, keep: true) },
                                          rosetta: rosetta, environment: environment)
            return LeaseRequest(platform: .container, minutes: 0, holder: name, container: container, kind: .session,
                                labels: labels.merging([ContainerHostCommand.nameLabel: name, ContainerHostCommand.specLabel: spec]) { $1 })
        }
    }

    /// What an operation answers: its exit status, and its JSON object.
    struct Answer {
        var status: Int32
        var json: [String: Any]

        var text: String {
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func failure(_ message: String, code: String? = nil) -> Answer {
        var json: [String: Any] = ["error": message]
        if let code { json["code"] = code }
        return Answer(status: 1, json: json)
    }

    /// A refusal of the server's, in the contract's words.
    static func failure(_ error: Error) -> Answer {
        guard let error = error as? OSSError else { return failure("\(error)") }
        if error.status == 404 { return failure(error.message, code: "notFound") }
        if error.code == "busy" { return failure(error.message, code: "busy") }
        let words = error.message.lowercased()
        if words.contains("image"), ["not found", "pull", "manifest", "unauthorized"].contains(where: words.contains) {
            return failure(error.message, code: "noImage")
        }
        return failure(error.message, code: error.code)
    }

    // MARK: The operations

    func health() async -> Answer {
        var json: [String: Any] = ["name": Self.name, "version": OSS.version, "api": Self.api]
        do {
            let capabilities = try await client.capabilities()
            json["server"] = capabilities.version
            guard capabilities.api >= Self.labelsAPI else {
                json["ok"] = false
                json["error"] = "OS Server \(capabilities.version) (API \(capabilities.api)) keeps no labels with a lease: "
                    + "that's OS Server 0.14's (API \(Self.labelsAPI))"
                return Answer(status: 0, json: json)
            }
            guard capabilities.platforms.contains(.container) else {
                json["ok"] = false
                json["error"] = "this OS Server lends no containers"
                return Answer(status: 0, json: json)
            }
            // The most a container may have: the server's Mac.
            if let usage = try? await client.usage() {
                json["limits"] = ["cpus": usage.host.cpus, "memoryBytes": usage.host.memoryBytes]
            }
            json["ok"] = true
        } catch {
            json["ok"] = false
            json["error"] = (error as? OSSError)?.message ?? "\(error)"
        }
        return Answer(status: 0, json: json)
    }

    func create(_ input: Data) async -> Answer {
        guard let request = try? JSONDecoder().decode(Request.self, from: input) else { return Self.failure("create is given the container as JSON") }
        guard !request.name.isEmpty, request.name.count <= 100,
              request.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            return Self.failure("\(request.name) can't name a container")
        }
        let spec = Self.spec(of: request)
        do {
            var lease: Lease
            if let had = try await mine(named: request.name) {
                // Asked again for one it made: that one.
                guard had.labels?[Self.specLabel] == spec else {
                    return Self.failure("There is already a container \(request.name), made otherwise", code: "exists")
                }
                lease = had
            } else {
                lease = try await leased(request.lease(spec: spec))
            }
            lease = try await ready(lease)
            // Handed over only once it resolves names.
            for attempt in 0..<tries {
                if await run(resolve, in: lease).status == 0 {
                    var json: [String: Any] = ["id": lease.id, "name": request.name, "image": request.image, "api": Self.api]
                    if let cpus = request.cpus { json["cpus"] = cpus }
                    if let memory = request.memoryBytes { json["memoryBytes"] = memory }
                    return Answer(status: 0, json: json)
                }
                if attempt < tries - 1 { try await Task.sleep(for: pause) }
            }
            try? await client.release(lease.id)
            return Self.failure("\(request.name) was made but resolves no names: its network doesn't work", code: "network")
        } catch {
            return Self.failure(error)
        }
    }

    func put(_ id: String, path: String, mode: String, data: Data) async -> Answer {
        do {
            let lease = try await client.lease(id)
            let file = try await client.uploadFile(id, holder: lease.holder, data: data, to: path, mode: mode)
            return Answer(status: 0, json: ["path": file.path, "size": file.size])
        } catch {
            return Self.failure(error)
        }
    }

    func remove(_ id: String, volumes: Bool) async -> Answer {
        // One already gone is no error.
        guard let lease = try? await client.lease(id) else { return Answer(status: 0, json: ["removed": id]) }
        do {
            if lease.state != .returning && lease.state != .failed { try await client.release(id) }
            // Gone before this answers: a container made again by its name
            // next finds its volumes free.
            let clock = ContinuousClock(), start = clock.now
            while clock.now - start < patience, let now = try? await client.lease(id), now.state != .failed {
                try await Task.sleep(for: step)
            }
            if volumes {
                for volume in lease.container?.volumes ?? [] { try? await client.deleteVolume(volume.name) }
            }
            return Answer(status: 0, json: ["removed": id])
        } catch {
            return Self.failure(error)
        }
    }

    func list() async -> Answer {
        do {
            let containers: [[String: Any]] = try await client.leases().compactMap { lease in
                guard lease.platform == .container, lease.state != .returning, let labels = lease.labels,
                      let name = labels[Self.nameLabel] else { return nil }
                return ["id": lease.id, "name": name, "image": lease.container?.image ?? "", "state": lease.state.rawValue,
                        "labels": labels.filter { !$0.key.hasPrefix("oss.container-host.") }, "created": ISO8601DateFormatter().string(from: lease.created)]
            }
            return Answer(status: 0, json: ["containers": containers])
        } catch {
            return Self.failure(error)
        }
    }

    func network(_ id: String) async -> Answer {
        do {
            let lease = try await client.lease(id)
            let dns = await run(resolve, in: lease).status == 0
            let reached = dns ? await run(reach, in: lease).status == 0 : false
            let detail = dns && reached ? "resolves and reaches github.com" : !dns ? "resolves no names (github.com)" : "resolves, but reaches nothing (github.com)"
            return Answer(status: 0, json: ["ok": dns && reached, "dns": dns, "reach": reached, "detail": detail])
        } catch {
            return Self.failure(error)
        }
    }

    // MARK: Helpers

    /// A request's digest: FNV-1a over its JSON, keys sorted. Told apart
    /// from another request, not kept secret.
    static func spec(of request: Request) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(request)) ?? Data()
        let hash = data.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// The host's container of that name, if there is one (not one going).
    func mine(named name: String) async throws -> Lease? {
        try await client.leases().first { $0.platform == .container && $0.labels?[Self.nameLabel] == name && $0.state != .returning }
    }

    /// A lease asked for; while one going still has its volumes, asked
    /// again until they are free.
    func leased(_ request: LeaseRequest) async throws -> Lease {
        let clock = ContinuousClock(), start = clock.now
        while true {
            do {
                return try await client.requestLease(request)
            } catch let error as OSSError where error.code == "volumeInUse" && clock.now - start < patience {
                try await Task.sleep(for: step)
            }
        }
    }

    /// The lease once it is made: ready, or what went wrong thrown.
    func ready(_ lease: Lease) async throws -> Lease {
        var lease = lease
        let clock = ContinuousClock(), start = clock.now
        while lease.state == .creating, clock.now - start < patience {
            try await Task.sleep(for: step)
            lease = try await client.lease(lease.id)
        }
        if let error = lease.error { throw OSSError(status: 0, message: "lease \(lease.id) failed: \(error)") }
        guard lease.state == .ready else { throw OSSError(status: 0, message: "lease \(lease.id) is \(lease.state.rawValue)") }
        return lease
    }

    /// A command run in the lease's container to its end, its input none:
    /// its status (-1 where it couldn't be run) and its output.
    func run(_ arguments: [String], in lease: Lease) async -> (status: Int32, output: String) {
        let (input, continuation) = AsyncStream<ExecFrame>.makeStream()
        continuation.yield(.closeStdin)
        let output = Collected()
        let path = ExecCommand.path(lease, client: client, holder: lease.holder)
        let status = (try? await path(ExecRequest(arguments: arguments), input, output.take)) ?? -1
        continuation.finish()
        return (status, output.text)
    }

    /// A command's standard output, as it comes.
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func take(_ frame: ExecFrame) {
            guard case .stdout(let chunk) = frame else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: The command line

    /// A client of the server `--server` names (with the key `--key-file`
    /// holds), else of this computer's client settings'.
    static func connect(_ arguments: Arguments) async throws -> OSSClient {
        guard arguments.options["server"] != nil || arguments.options["key-file"] != nil else { return try await OSSClient.connect() }
        let token: String?
        if let file = arguments.options["key-file"] {
            let path = (file as NSString).expandingTildeInPath
            token = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard token?.isEmpty == false else { throw OSSError(status: 0, message: "no key in \(path)") }
        } else {
            token = Token.read()
        }
        guard let token else { throw OSSError(status: 0, message: "no key or token") }
        let servers = arguments.options["server"].map { [$0] } ?? ClientConfig.load().servers
        return try await OSSClient.connect(servers: servers.compactMap(URL.init(string:)), token: token, transport: cliTransport())
    }

    /// `oss container-host …`: the operation's answer printed and its
    /// status the process's, or, for `exec`, the command's.
    static func run(_ arguments: Arguments) async -> Never {
        let operation = arguments.positional.count > 1 ? arguments.positional[1] : nil
        let id = arguments.positional.count > 2 ? arguments.positional[2] : nil
        func answer(_ answer: Answer) -> Never {
            print(answer.text)
            exit(answer.status)
        }
        guard let client = try? await connect(arguments) else {
            if operation == "health" {
                answer(Answer(status: 0, json: ["ok": false, "name": name, "version": OSS.version, "api": api,
                                                "error": "no OS Server answers (oss's client settings: ~/.config/oss/client.json, its key or token)"]))
            }
            answer(failure("no OS Server answers (oss's client settings: ~/.config/oss/client.json, its key or token)"))
        }
        var used = client
        // Its leases are in their containers' names alone.
        used.clientID = nil
        let host = ContainerHostCommand(client: used)
        switch operation {
        case "health":
            answer(await host.health())
        case "create":
            answer(await host.create(FileHandle.standardInput.readDataToEndOfFile()))
        case "exec":
            guard let id, !arguments.rest.isEmpty else {
                answer(failure("exec <id> [--tty] [--workdir=DIR] [--env-file=FILE] -- program…"))
            }
            let lease: Lease
            do { lease = try await used.lease(id) } catch { answer(failure(error)) }
            do {
                exit(try await ExecCommand.run(arguments, through: ExecCommand.path(lease, client: used, holder: lease.holder)))
            } catch {
                answer(failure(error))
            }
        case "put":
            guard let id, arguments.positional.count > 3 else { answer(failure("put <id> <path> [--mode=600] < bytes")) }
            answer(await host.put(id, path: arguments.positional[3], mode: arguments.options["mode"] ?? "600",
                                  data: FileHandle.standardInput.readDataToEndOfFile()))
        case "rm":
            guard let id else { answer(failure("rm <id> [--volumes]")) }
            answer(await host.remove(id, volumes: arguments.flags.contains("volumes")))
        case "ls":
            answer(await host.list())
        case "network":
            guard let id else { answer(failure("network <id>")) }
            answer(await host.network(id))
        default:
            answer(failure("\(name) health | create | exec | put | rm | ls | network", code: "unsupported"))
        }
    }
}
