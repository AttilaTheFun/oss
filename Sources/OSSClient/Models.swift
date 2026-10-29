import Foundation

/// What a machine lease can be: a whole machine (a VM: macOS, Linux,
/// Windows), an iOS simulator or an Android emulator on the server's Mac.
public enum Platform: String, Codable, CaseIterable, Sendable {
    case macos, ios, android, linux, windows
    /// A Linux container on the server's own Mac (API 6), lent to a client
    /// on that Mac until API 9, to one anywhere since (but its mounts,
    /// which share the Mac's folders).
    case container

    public var isVM: Bool { self == .macos || self == .linux || self == .windows }
}

/// What a container lease runs: an image from a registry, what it's given,
/// the server Mac's folders shared into it, volumes of its own, ports
/// forwarded to it, and its main process (by default one that waits, so
/// commands are run in it with `exec`). It runs in a process of its own on
/// the server's Mac, so it and its execs outlive the server's restarts;
/// after the Mac's, it is started again from its own disk. Everything but
/// `mounts` may be asked for from another computer (API 9).
public struct ContainerSpec: Codable, Sendable, Hashable {
    /// An image reference: `ghcr.io/owner/name:tag`, `alpine:3.20` (Docker
    /// Hub's). Pulled once, kept by digest.
    public var image: String
    public var cpus: Int?
    public var memoryBytes: Int64?
    /// Its root filesystem's size.
    public var diskBytes: Int64?
    /// Folders of the server's Mac: only a client on that Mac may ask for them.
    public var mounts: [ContainerMount]
    public var volumes: [ContainerVolume]
    /// x86_64 Linux programs run under Rosetta (where the Mac has it).
    public var rosetta: Bool
    public var environment: [String: String]
    public var workingDirectory: String?
    /// Its main process; nil: one that waits until the lease ends.
    public var command: [String]?
    /// Its TCP ports to forward (API 9): each gets a port on the server's
    /// Mac, from the range VMs' ports come from, reached from this Mac, the
    /// LAN and the tailnet (`Lease.ports`), until the lease ends.
    public var ports: [Int]

    public init(image: String, cpus: Int? = nil, memoryBytes: Int64? = nil, diskBytes: Int64? = nil, mounts: [ContainerMount] = [],
                volumes: [ContainerVolume] = [], rosetta: Bool = false, environment: [String: String] = [:],
                workingDirectory: String? = nil, command: [String]? = nil, ports: [Int] = []) {
        self.image = image
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.mounts = mounts
        self.volumes = volumes
        self.rosetta = rosetta
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.command = command
        self.ports = ports
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decode(String.self, forKey: .image)
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
        memoryBytes = try c.decodeIfPresent(Int64.self, forKey: .memoryBytes)
        diskBytes = try c.decodeIfPresent(Int64.self, forKey: .diskBytes)
        mounts = try c.decodeIfPresent([ContainerMount].self, forKey: .mounts) ?? []
        volumes = try c.decodeIfPresent([ContainerVolume].self, forKey: .volumes) ?? []
        rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        command = try c.decodeIfPresent([String].self, forKey: .command)
        ports = try c.decodeIfPresent([Int].self, forKey: .ports) ?? []
    }
}

/// A container's port forwarded on its server's Mac (API 9): the
/// container's own (TCP), and where it is reached, on every interface of
/// the Mac (this Mac, the LAN, the tailnet). `host` is the server as the
/// asker reached it, filled in with each answer.
public struct ForwardedPort: Codable, Sendable, Hashable, CustomStringConvertible {
    public var port: Int
    public var host: String?
    public var hostPort: Int

    public init(port: Int, host: String? = nil, hostPort: Int) {
        self.port = port
        self.host = host
        self.hostPort = hostPort
    }

    /// `8080 → server.local:47512`.
    public var description: String { "\(port) → \(host ?? "<server>"):\(hostPort)" }
}

/// A file put in a container lease, or the one asked for (API 9): its
/// path in the container (absolute) and its size.
public struct MachineFile: Codable, Sendable, Hashable {
    public var path: String
    public var size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

/// A disk of its own for a container, by name (an ext4 filesystem of
/// `sizeBytes`, allocated as it fills): one already there at that size is
/// used again, at another size it is made anew. Deleted with the lease
/// unless `keep`; a kept one is listed (`GET /v1/volumes`) until deleted.
public struct ContainerVolume: Codable, Sendable, Hashable {
    public var name: String
    public var destination: String
    public var sizeBytes: Int64
    public var keep: Bool

    public init(name: String, destination: String, sizeBytes: Int64, keep: Bool = false) {
        self.name = name
        self.destination = destination
        self.sizeBytes = sizeBytes
        self.keep = keep
    }
}

/// A container volume on the server's Mac: its size, the disk it takes
/// now, and the lease using it and that lease's kind (API 8).
public struct VolumeInfo: Codable, Sendable, Identifiable {
    public var name: String
    public var sizeBytes: Int64
    public var allocatedBytes: Int64
    public var lease: String?
    public var kind: LeaseKind?
    public var id: String { name }

    public init(name: String, sizeBytes: Int64, allocatedBytes: Int64, lease: String? = nil, kind: LeaseKind? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.allocatedBytes = allocatedBytes
        self.lease = lease
        self.kind = kind
    }
}

/// A folder of the server's Mac shared into a container.
public struct ContainerMount: Codable, Sendable, Hashable {
    public var source: String
    public var destination: String
    public var readOnly: Bool

    public init(source: String, destination: String, readOnly: Bool = false) {
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
    }
}

/// A command run in a container lease: the first frame on its exec socket
/// (`Lease.execSocket`), then a stream of `ExecFrame`s both ways; or, from
/// any computer, the body of `POST /v1/machines/<id>/exec` (API 9), whose
/// connection then carries the same frames.
public struct ExecRequest: Codable, Sendable, Hashable {
    public var arguments: [String]
    /// A terminal of `columns` × `rows`, its output on stdout alone.
    public var tty: Bool
    public var columns: Int?
    public var rows: Int?
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(arguments: [String], tty: Bool = false, columns: Int? = nil, rows: Int? = nil,
                environment: [String: String] = [:], workingDirectory: String? = nil) {
        self.arguments = arguments
        self.tty = tty
        self.columns = columns
        self.rows = rows
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// One frame of an exec's stream: a byte saying what it is, its length as
/// four bytes (big-endian), then that many bytes. The client's first is
/// `start`; the container's last is `exit`. A connection that closes before
/// that ends the command (TERM, then KILL ten seconds on).
public enum ExecFrame: Sendable, Equatable {
    /// Client to container.
    case start(ExecRequest)
    case stdin(Data)
    case closeStdin
    case resize(columns: Int, rows: Int)
    /// A signal for the command, by its Linux number (TERM 15, INT 2, HUP 1,
    /// QUIT 3, USR1 10, USR2 12).
    case signal(Int32)
    /// Container to client.
    case stdout(Data)
    case stderr(Data)
    case exit(Int32)

    public var encoded: Data {
        func frame(_ kind: UInt8, _ payload: Data) -> Data {
            var data = Data([kind])
            let count = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: count) { data.append(contentsOf: $0) }
            return data + payload
        }
        func int32(_ value: Int32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        switch self {
        case .stdin(let data): return frame(0, data)
        case .closeStdin: return frame(1, Data())
        case .resize(let columns, let rows): return frame(2, int32(Int32(columns)) + int32(Int32(rows)))
        case .stdout(let data): return frame(3, data)
        case .stderr(let data): return frame(4, data)
        case .exit(let code): return frame(5, int32(code))
        case .signal(let number): return frame(6, int32(number))
        case .start(let request): return frame(7, (try? JSONEncoder().encode(request)) ?? Data())
        }
    }

    /// The frames at the start of `buffer`, which keeps what's left of an
    /// unfinished one.
    public static func decode(_ buffer: inout Data) -> [ExecFrame] {
        var frames: [ExecFrame] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let kind = buffer[start]
            let count = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
            guard buffer.count >= 5 + count else { break }
            let payload = Data(buffer[(start + 5)..<(start + 5 + count)])
            buffer = Data(buffer[(start + 5 + count)...])
            func int32(_ data: Data, at offset: Int) -> Int32 {
                let b = [UInt8](data)
                guard b.count >= offset + 4 else { return 0 }
                return Int32(bitPattern: UInt32(b[offset]) << 24 | UInt32(b[offset + 1]) << 16 | UInt32(b[offset + 2]) << 8 | UInt32(b[offset + 3]))
            }
            switch kind {
            case 0: frames.append(.stdin(payload))
            case 1: frames.append(.closeStdin)
            case 2: frames.append(.resize(columns: Int(int32(payload, at: 0)), rows: Int(int32(payload, at: 4))))
            case 3: frames.append(.stdout(payload))
            case 4: frames.append(.stderr(payload))
            case 5: frames.append(.exit(int32(payload, at: 0)))
            case 6: frames.append(.signal(int32(payload, at: 0)))
            case 7: if let request = try? JSONDecoder().decode(ExecRequest.self, from: payload) { frames.append(.start(request)) }
            default: break
            }
        }
        return frames
    }
}

/// A base a lease is cloned from, named `oss-<platform>-<config>`: a stopped
/// VM (macOS, Linux, Windows), a shut-down simulator (iOS) or an AVD with a
/// saved boot snapshot (Android). Never used directly.
public struct Base: Codable, Sendable, Hashable {
    public var platform: Platform
    public var config: String
    public var name: String

    public init(platform: Platform, config: String) {
        self.platform = platform
        self.config = config
        self.name = "oss-\(platform.rawValue)-\(config)"
    }

    public init?(name: String) {
        let parts = name.split(separator: "-", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "oss", let platform = Platform(rawValue: parts[1]),
              !parts[2].hasPrefix("lease") else { return nil }
        self.init(platform: platform, config: parts[2])
    }
}

public enum LeaseState: String, Codable, Sendable {
    /// `failed`: kept a while so its holder can read why; it holds no place.
    case creating, ready, returning, failed
}

/// Who a lease is for (API 8), so whoever looks at a server can tell a CI
/// job's machines from a session's and an agent's.
public enum LeaseKind: String, Codable, CaseIterable, Sendable {
    /// A CI job's (`oss` fills it in from GitHub Actions' variables).
    case ci
    /// A Visor session's own machine: the container it runs in.
    case session
    /// A machine an agent in a session leased for its work.
    case agent
    /// Someone's at a terminal, or a program's that said nothing else.
    case manual

    /// A kind this build doesn't know (a newer server's) reads as `manual`:
    /// an unknown value would otherwise fail the whole status it came in
    /// (OS Monitor reading a newer server), or a server's saved leases.
    public init(from decoder: Decoder) throws {
        self = LeaseKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .manual
    }
}

/// A machine lent to one holder until it is released or its time runs out.
public struct Lease: Codable, Sendable {
    public var id: String
    public var platform: Platform
    public var config: String
    /// The clone's name: `oss-lease-<platform>-<id>`.
    public var name: String
    public var holder: String
    public var state: LeaseState
    public var created: Date
    public var expires: Date
    public var error: String?

    /// Who it is for (API 8; nil from an older server): what the request
    /// said, or, where it said nothing, what the server took its holder
    /// for (`visor:` holders' containers are sessions, their other
    /// machines agents', any other holder's manual).
    public var kind: LeaseKind?
    /// A short line saying what it's for (a session's title, a CI job's
    /// repository, workflow, run and job), and a page about it (the run's).
    public var label: String?
    public var link: URL?

    // VMs
    /// The guest's address on the VMs' network (reached from the server's Mac only).
    public var guestAddress: String?
    /// Ports on the server's Mac forwarded to the guest's SSH and VNC.
    public var sshPort: Int?
    public var vncPort: Int?
    public var sshUser: String?
    public var vncPassword: String?
    /// QEMU's VNC server for the clone, on the server's loopback (Windows, Linux).
    public var qemuVNCPort: Int?
    /// The clone's MAC address (its own, given by the server).
    public var mac: String?

    // iOS simulators
    public var udid: String?
    /// Its device type's and runtime's names (API 11): `iPad Pro 13-inch
    /// (M5)`, `iOS 27.0`; a clone of its config's base has the base's.
    public var device: String?
    public var runtime: String?

    // Android emulators
    /// The emulator's console port on the server's Mac (its adb port is one more).
    public var consolePort: Int?
    /// A port on the server's Mac forwarded to the emulator's adb: `adb connect <host>:<adbPort>`.
    public var adbPort: Int?
    public var emulatorPID: Int32?

    // What it was given (VMs, emulators; a simulator has no allotment)
    public var cpus: Int?
    public var memoryLimitBytes: Int64?
    /// The guest's `runner` password, where the server knows it (VMs): to
    /// log in at its screen, or unlock it.
    public var guestPassword: String?
    /// A container lease's spec, and the Unix socket its commands are run
    /// through on the server's Mac (`ExecFrame`s; API 6).
    public var container: ContainerSpec?
    public var execSocket: String?
    /// A container's forwarded ports, once it is ready (API 9).
    public var ports: [ForwardedPort]?

    public init(id: String, platform: Platform, config: String, name: String, holder: String, state: LeaseState,
                created: Date, expires: Date, error: String? = nil, kind: LeaseKind? = nil, label: String? = nil, link: URL? = nil) {
        self.id = id
        self.platform = platform
        self.config = config
        self.name = name
        self.holder = holder
        self.state = state
        self.created = created
        self.expires = expires
        self.error = error
        self.kind = kind
        self.label = label
        self.link = link
    }
}

public struct LeaseRequest: Codable, Sendable {
    public var platform: Platform
    public var config: String?
    public var minutes: Int?
    public var holder: String?
    /// The holder's public key, let into a VM for the lease.
    public var sshPublicKey: String?
    /// A container lease's image and what it's given (API 6). A container
    /// may ask for `minutes: 0`: held until it is released. From another
    /// computer than the server's Mac (API 9), it may ask for anything but
    /// mounts.
    public var container: ContainerSpec?
    /// Who it is for, a line saying what for, and a page about it (API 8;
    /// each optional: a server takes a lease with no kind by its holder).
    /// The label is kept to one line of at most 200 characters; the link
    /// must be http or https.
    public var kind: LeaseKind?
    public var label: String?
    public var link: URL?
    /// An iOS lease's device type, by its name (`iPad Pro 13-inch (M5)`) or
    /// its identifier (`com.apple.CoreSimulator.SimDeviceType.…`), either
    /// in any case, and its runtime (`iOS 27.0`, its identifier, or `27.0`)
    /// (API 11). Either given, its simulator is made of that type on that
    /// runtime (the config's base's for the one not given) and set up as
    /// the base was; neither, a clone of the base. A type or runtime the
    /// server's Xcode hasn't got is refused (400), naming the close ones.
    public var device: String?
    public var runtime: String?

    public init(platform: Platform, config: String? = nil, minutes: Int? = nil, holder: String? = nil, sshPublicKey: String? = nil,
                container: ContainerSpec? = nil, kind: LeaseKind? = nil, label: String? = nil, link: URL? = nil,
                device: String? = nil, runtime: String? = nil) {
        self.platform = platform
        self.config = config
        self.minutes = minutes
        self.holder = holder
        self.sshPublicKey = sshPublicKey
        self.container = container
        self.kind = kind
        self.label = label
        self.link = link
        self.device = device
        self.runtime = runtime
    }
}

/// A GitHub Actions job, from the variables its runner sets: what `oss`
/// says of a lease taken in one that says nothing of itself (kind `ci`,
/// this label and link). Nil unless every one it reads is set.
public struct GitHubActionsJob: Sendable, Equatable {
    /// `owner/name`.
    public var repository: String
    /// The workflow's name, the run's id, which attempt at the run this is
    /// (1, or more for a run re-run: its page shows the latest), and the
    /// job's id in the workflow.
    public var workflow: String
    public var runID: String
    public var attempt: String
    public var job: String
    /// `https://github.com`, or a GitHub Enterprise server's.
    public var server: String

    public init?(environment: [String: String]) {
        guard environment["GITHUB_ACTIONS"] == "true" else { return nil }
        func value(_ name: String) -> String? {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        guard let repository = value("GITHUB_REPOSITORY"), let workflow = value("GITHUB_WORKFLOW"), let runID = value("GITHUB_RUN_ID"),
              let attempt = value("GITHUB_RUN_ATTEMPT"), let job = value("GITHUB_JOB"), let server = value("GITHUB_SERVER_URL")
        else { return nil }
        self.repository = repository
        self.workflow = workflow
        self.runID = runID
        self.attempt = attempt
        self.job = job
        self.server = server.hasSuffix("/") ? String(server.dropLast()) : server
    }

    /// `owner/name · Workflow #<run id> · job`.
    public var label: String { "\(repository) · \(workflow) #\(runID) · \(job)" }
    /// The run's page.
    public var link: URL? { URL(string: "\(server)/\(repository)/actions/runs/\(runID)") }
}

public struct RenewRequest: Codable, Sendable {
    public var minutes: Int?
    public init(minutes: Int? = nil) { self.minutes = minutes }
}

/// A command for a lease's simulator (`simctl`) or emulator (`adb`), run on
/// the server's Mac against that device only. `@name` arguments are files
/// uploaded to the lease first.
public struct DeviceCommand: Codable, Sendable {
    public var arguments: [String]
    public init(arguments: [String]) { self.arguments = arguments }
}

public struct DeviceCommandResult: Codable, Sendable {
    public var status: Int32
    public var output: String
    public var error: String

    public init(status: Int32, output: String, error: String) {
        self.status = status
        self.output = output
        self.error = error
    }
}

// MARK: The server

public struct Capacity: Codable, Sendable {
    public var platform: Platform
    public var limit: Int
    public var leased: Int

    public init(platform: Platform, limit: Int, leased: Int) {
        self.platform = platform
        self.limit = limit
        self.leased = leased
    }
}

public struct Status: Codable, Sendable {
    public var server: String
    public var bases: [Base]
    public var capacity: [Capacity]
    public var leases: [Lease]
    /// The store's use (API 7; nil from an older server).
    public var storage: StorageInfo?

    public init(server: String, bases: [Base], capacity: [Capacity], leases: [Lease], storage: StorageInfo? = nil) {
        self.server = server
        self.bases = bases
        self.capacity = capacity
        self.leases = leases
        self.storage = storage
    }
}

/// What a server is and offers (`GET /v1/capabilities`), for a client to
/// check before it relies on something.
public struct Capabilities: Codable, Sendable {
    /// oss's version (MAJOR.MINOR.PATCH).
    public var version: String
    /// The API's level: raised when something changes that a client can see.
    public var api: Int
    /// What this server does: `machines`, `screenshots`.
    public var features: [String]
    /// The platforms it can lend machines of (those it has bases for).
    public var platforms: [Platform]

    public init(version: String, api: Int, features: [String], platforms: [Platform]) {
        self.version = version
        self.api = api
        self.features = features
        self.platforms = platforms
    }
}

/// A tap, a swipe, text typed or a key pressed on a lease's screen
/// (`POST /v1/machines/<id>/input`). Positions are its screenshot's pixels.
public struct InputRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case tap, swipe, type, key }
    public var action: Action
    /// Where a tap is, or a swipe starts.
    public var x: Double?
    public var y: Double?
    /// Where a swipe ends, and how long it takes (default 300 ms).
    public var toX: Double?
    public var toY: Double?
    public var milliseconds: Int?
    /// What `type` types.
    public var text: String?
    /// What `key` presses: a name (return, tab, escape, backspace, delete,
    /// space, up, down, left, right, pageup, pagedown, home, back), on a VM
    /// with modifiers (`cmd+a`, `ctrl+shift+t`); or the platform's own code
    /// (an Android keycode, an iOS HID usage, a VNC keysym as 0x…).
    public var key: String?

    public init(action: Action, x: Double? = nil, y: Double? = nil, toX: Double? = nil, toY: Double? = nil,
                milliseconds: Int? = nil, text: String? = nil, key: String? = nil) {
        self.action = action
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.milliseconds = milliseconds
        self.text = text
        self.key = key
    }
}

/// What the server's Mac and each lease use (`GET /v1/usage`), as sampled
/// at `sampledAt`. A CPU percentage is of one core: 100 is one core busy.
public struct Usage: Codable, Sendable {
    public var sampledAt: Date
    public var host: HostUsage
    public var machines: [MachineUsage]
    /// What OS Server uses, its own process and every machine it lends
    /// together, and what every other process on its Mac does (API 5; nil
    /// from an older server). With `host`, the rest is free.
    public var ours: ResourceShare?
    public var others: ResourceShare?
    /// The disk OS Server keeps its files on (API 5).
    public var disk: DiskUsage?
    /// The other processes using the most memory, an app's helpers counted
    /// with it (API 5).
    public var topProcesses: [ProcessUsage]?

    public init(sampledAt: Date, host: HostUsage, machines: [MachineUsage], ours: ResourceShare? = nil, others: ResourceShare? = nil,
                disk: DiskUsage? = nil, topProcesses: [ProcessUsage]? = nil) {
        self.sampledAt = sampledAt
        self.host = host
        self.machines = machines
        self.ours = ours
        self.others = others
        self.disk = disk
        self.topProcesses = topProcesses
    }
}

/// One minute of the server's Mac, as the server keeps it for a day
/// (`GET /v1/usage/history`, API 6): CPU (100 a core) and memory, OS
/// Server's and everyone else's, and the disk.
public struct UsageSample: Codable, Sendable {
    public var date: Date
    public var cpus: Int
    public var ourCPU: Double
    public var otherCPU: Double
    public var memoryBytes: Int64
    public var ourMemory: Int64
    public var otherMemory: Int64
    public var diskBytes: Int64?
    public var diskFreeBytes: Int64?
    /// OS Server's own files, as last measured.
    public var ourDiskBytes: Int64?

    public init(date: Date, cpus: Int, ourCPU: Double, otherCPU: Double, memoryBytes: Int64, ourMemory: Int64, otherMemory: Int64,
                diskBytes: Int64? = nil, diskFreeBytes: Int64? = nil, ourDiskBytes: Int64? = nil) {
        self.date = date
        self.cpus = cpus
        self.ourCPU = ourCPU
        self.otherCPU = otherCPU
        self.memoryBytes = memoryBytes
        self.ourMemory = ourMemory
        self.otherMemory = otherMemory
        self.diskBytes = diskBytes
        self.diskFreeBytes = diskFreeBytes
        self.ourDiskBytes = ourDiskBytes
    }

    public init(_ usage: Usage) {
        let host = usage.host
        self.init(date: usage.sampledAt, cpus: host.cpus, ourCPU: usage.ours?.cpuPercent ?? 0,
                  otherCPU: usage.others?.cpuPercent ?? host.cpuPercent, memoryBytes: host.memoryBytes,
                  ourMemory: usage.ours?.memoryBytes ?? 0, otherMemory: usage.others?.memoryBytes ?? host.memoryUsedBytes,
                  diskBytes: usage.disk?.totalBytes, diskFreeBytes: usage.disk?.freeBytes,
                  ourDiskBytes: usage.disk.flatMap { $0.parts.isEmpty ? nil : $0.parts.reduce(0) { $0 + $1.bytes } })
    }
}

/// A share of the Mac's CPU (100 a core) and memory (physical footprint).
public struct ResourceShare: Codable, Sendable {
    public var cpuPercent: Double
    public var memoryBytes: Int64

    public init(cpuPercent: Double, memoryBytes: Int64) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// The volume OS Server's folder is on: its size, what's free (as `df`
/// counts it), and OS Server's own files by kind. A
/// part's size is as allocated, with an APFS clone counted whole, though it
/// shares its blocks with what it was cloned from: the parts can add up to
/// more than they take.
public struct DiskUsage: Codable, Sendable {
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var parts: [DiskPart]
    /// When the parts were last measured (they're measured every few
    /// minutes, not with every sample).
    public var measuredAt: Date?

    public init(totalBytes: Int64, freeBytes: Int64, parts: [DiskPart], measuredAt: Date? = nil) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.parts = parts
        self.measuredAt = measuredAt
    }
}

public struct DiskPart: Codable, Sendable, Identifiable {
    public var name: String
    public var bytes: Int64
    public var id: String { name }

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

/// A process (or an app with its helpers) that isn't OS Server's.
public struct ProcessUsage: Codable, Sendable, Identifiable {
    public var name: String
    public var processes: Int
    public var cpuPercent: Double
    public var memoryBytes: Int64
    public var id: String { name }

    public init(name: String, processes: Int, cpuPercent: Double, memoryBytes: Int64) {
        self.name = name
        self.processes = processes
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

public struct HostUsage: Codable, Sendable {
    public var name: String
    public var cpus: Int
    public var cpuPercent: Double
    public var memoryBytes: Int64
    public var memoryUsedBytes: Int64

    public init(name: String, cpus: Int, cpuPercent: Double, memoryBytes: Int64, memoryUsedBytes: Int64) {
        self.name = name
        self.cpus = cpus
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryUsedBytes = memoryUsedBytes
    }
}

/// A lease's use: its processes on the server's Mac (a VM's, a simulator's,
/// an emulator's), against what it was given where it was given anything.
/// A value the server couldn't measure is left out.
public struct MachineUsage: Codable, Sendable {
    public var id: String
    public var platform: Platform
    public var config: String
    public var holder: String
    /// The lease's kind (API 8).
    public var kind: LeaseKind?
    public var cpus: Int?
    public var memoryLimitBytes: Int64?
    public var cpuPercent: Double?
    /// Resident memory.
    public var memoryBytes: Int64?
    /// The disk it takes on the server's Mac (a VM's clone, a container's
    /// root filesystem, a simulator's or an emulator's data), as allocated
    /// (API 6).
    public var diskBytes: Int64?

    public init(id: String, platform: Platform, config: String, holder: String, kind: LeaseKind? = nil, cpus: Int? = nil,
                memoryLimitBytes: Int64? = nil, cpuPercent: Double? = nil, memoryBytes: Int64? = nil, diskBytes: Int64? = nil) {
        self.diskBytes = diskBytes
        self.id = id
        self.platform = platform
        self.config = config
        self.holder = holder
        self.kind = kind
        self.cpus = cpus
        self.memoryLimitBytes = memoryLimitBytes
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// The server's Bazel cache (`GET /v1/cache`): its port on the server's
/// addresses, the token that reads it (`Authorization: Bearer <token>`;
/// writing takes another, kept on the server's Mac), and how it is doing
/// since the server started.
public struct CacheInfo: Codable, Sendable {
    public var port: Int
    public var readToken: String
    public var bytes: Int64
    public var maxBytes: Int64
    /// The disk's free space, which the cache keeps above its floor.
    public var freeBytes: Int64
    /// Action cache lookups answered, and not.
    public var hits: Int
    public var misses: Int
    public var writes: Int
    public var evicted: Int

    public init(port: Int, readToken: String, bytes: Int64, maxBytes: Int64, freeBytes: Int64,
                hits: Int, misses: Int, writes: Int, evicted: Int) {
        self.port = port
        self.readToken = readToken
        self.bytes = bytes
        self.maxBytes = maxBytes
        self.freeBytes = freeBytes
        self.hits = hits
        self.misses = misses
        self.writes = writes
        self.evicted = evicted
    }
}

/// An error the server answers with (any status but 2xx).
public struct APIError: Codable, Error, Sendable, CustomStringConvertible {
    public var error: String
    /// What kind of refusal, for a program to tell them apart (API 6):
    /// `busy` (no room: 409), `notLocal` (what only a client on the
    /// server's Mac may ask for: a container before API 9, a container's
    /// mounts from API 9, a volume's deletion: 403), `noContainers` (this
    /// server runs none), `volumeInUse`; from API 7 `notFound` (no such
    /// lease or object of the holder's: 404), `noObject` (a put with no body
    /// for an object the store hasn't got: 404) and `quota` (past the
    /// holder's or the store's cap: 413); from API 9 `notReady` (a
    /// container lease not running yet, or not running again yet: 409) and
    /// `noFile` (a container's file that isn't there: 404); from API 10
    /// `busy` also for an xctest on a lease running one, `notReady` for a
    /// run's results while it runs, `noFile` for a run's JUnit or result
    /// bundle that wasn't made; from API 11 `noDevice` (an iOS lease's
    /// device type or runtime the server's Xcode hasn't got, or a type
    /// that runtime doesn't run: 400).
    public var code: String?
    public var description: String { error }
    public init(error: String, code: String? = nil) {
        self.error = error
        self.code = code
    }
}

public enum OSS {
    /// This build's version, and the API level it speaks.
    public static let version = "0.12.1"
    /// 8 from 0.13.0: who a lease is for (`Lease.kind`: `ci`, `session`,
    /// `agent` or `manual`, with a `label` and a `link`), asked for in a
    /// `LeaseRequest` or taken from its holder, and carried by a lease's
    /// usage (`MachineUsage.kind`) and its volumes (`VolumeInfo.kind`).
    /// 9 from 0.13.0: a container from any computer (mounts still the
    /// server Mac's own), its commands through the API
    /// (`POST /v1/machines/<id>/exec`, upgraded to `oss-exec`: the exec
    /// socket's frames), its files (`PUT` and `GET
    /// /v1/machines/<id>/files?path=…`), its ports forwarded
    /// (`ContainerSpec.ports`, `Lease.ports`), and grants for each
    /// (`machine.exec`, `machine.upload`, `machine.download`).
    /// 10 from 0.13.0: iOS tests on a lease's simulator
    /// (`POST /v1/machines/<id>/xctest`, upgraded to `oss-exec` like an
    /// exec: rules_apple's test bundle and host from storage, run by
    /// xcodebuild; `GET …/xctest/<run>/junit` and `/result`), and their
    /// grant (`machine.xctest`).
    /// 11 from 0.13.0: an iOS lease of a device type and runtime of its
    /// own (`LeaseRequest.device` and `runtime`), and every iOS lease's
    /// (`Lease.device`, `Lease.runtime`).
    /// 7 from 0.13.0: storage (`/v1/storage/…`: objects by their SHA-256,
    /// kept while a holder's lease on them lasts), grants (`/v1/grants`: a
    /// URL that does one thing without the token), an iOS lease's app
    /// installed from the store (`/v1/machines/<id>/install`), and the
    /// store's use in `Status.storage`.
    /// 6 from 0.9.0: container leases (`platform: container`, a
    /// `ContainerSpec`, commands over `Lease.execSocket`), their volumes
    /// (`/v1/volumes`), a lease's disk (`MachineUsage.diskBytes`), a day of
    /// usage a minute at a time (`/v1/usage/history`). A client
    /// says its level in an `OSS-API` header: one below 6 is shown no
    /// containers.
    /// 5 from 0.8.0: usage says what is OS Server's, what is other
    /// processes', the disk, and the biggest other processes; a read-only
    /// token for OS Monitor (`MonitorConnection`).
    /// 4 from 0.5.0: input (`POST /v1/machines/<id>/input`), usage
    /// (`GET /v1/usage`), and a lease's `cpus`, `memoryLimitBytes` and
    /// `guestPassword`.
    /// 3 from 0.4.0: the Bazel cache (`GET /v1/cache`, the `cache` feature).
    /// 2 from 0.3.0: containers (`/v1/containers`) are gone, and Status and
    /// Capabilities no longer carry them.
    public static let apiLevel = 11
    /// What every server does; one that keeps a Bazel cache adds `cache`.
    public static let features = ["machines", "screenshots", "input", "usage", "storage", "grants"]
}

extension JSONEncoder {
    /// Dates as ISO 8601: what the API sends and takes.
    public static let oss: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    public static let oss: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
