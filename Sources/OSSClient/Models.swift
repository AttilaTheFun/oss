import Foundation

/// What a machine lease can be: a whole machine (a VM: macOS, Linux,
/// Windows), an iOS simulator or an Android emulator on the server's Mac.
public enum Platform: String, Codable, CaseIterable, Sendable {
    case macos, ios, android, linux, windows
    /// A Linux container on the server's own Mac (API 6), lent only to a
    /// client on that Mac: it shares the Mac's folders.
    case container

    public var isVM: Bool { self == .macos || self == .linux || self == .windows }
}

/// What a container lease runs: an image from a registry, what it's given,
/// the server Mac's folders shared into it, and its main process (by
/// default one that waits, so commands are run in it with `exec`).
public struct ContainerSpec: Codable, Sendable, Hashable {
    /// An image reference: `ghcr.io/owner/name:tag`, `docker.io/library/alpine:3.20`.
    public var image: String
    public var cpus: Int?
    public var memoryBytes: Int64?
    /// Its root filesystem's size.
    public var diskBytes: Int64?
    public var mounts: [ContainerMount]
    public var environment: [String: String]
    public var workingDirectory: String?
    /// Its main process; nil: one that waits until the lease ends.
    public var command: [String]?

    public init(image: String, cpus: Int? = nil, memoryBytes: Int64? = nil, diskBytes: Int64? = nil, mounts: [ContainerMount] = [],
                environment: [String: String] = [:], workingDirectory: String? = nil, command: [String]? = nil) {
        self.image = image
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.mounts = mounts
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.command = command
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

/// A command run in a container lease (`POST /v1/machines/<id>/exec`, then
/// a stream of `ExecFrame`s both ways).
public struct ExecRequest: Codable, Sendable {
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
/// four bytes (big-endian), then that many bytes.
public enum ExecFrame: Sendable, Equatable {
    /// Client to server.
    case stdin(Data)
    case closeStdin
    case resize(columns: Int, rows: Int)
    /// Server to client.
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
    /// A container lease's spec (API 6).
    public var container: ContainerSpec?

    public init(id: String, platform: Platform, config: String, name: String, holder: String, state: LeaseState,
                created: Date, expires: Date, error: String? = nil) {
        self.id = id
        self.platform = platform
        self.config = config
        self.name = name
        self.holder = holder
        self.state = state
        self.created = created
        self.expires = expires
        self.error = error
    }
}

public struct LeaseRequest: Codable, Sendable {
    public var platform: Platform
    public var config: String?
    public var minutes: Int?
    public var holder: String?
    /// The holder's public key, let into a VM for the lease.
    public var sshPublicKey: String?
    /// A container lease's image and what it's given (API 6).
    public var container: ContainerSpec?

    public init(platform: Platform, config: String? = nil, minutes: Int? = nil, holder: String? = nil, sshPublicKey: String? = nil,
                container: ContainerSpec? = nil) {
        self.platform = platform
        self.config = config
        self.minutes = minutes
        self.holder = holder
        self.sshPublicKey = sshPublicKey
        self.container = container
    }
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

    public init(server: String, bases: [Base], capacity: [Capacity], leases: [Lease]) {
        self.server = server
        self.bases = bases
        self.capacity = capacity
        self.leases = leases
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
    public var cpus: Int?
    public var memoryLimitBytes: Int64?
    public var cpuPercent: Double?
    /// Resident memory.
    public var memoryBytes: Int64?
    /// The disk it takes on the server's Mac (a VM's clone, a container's
    /// root filesystem, a simulator's or an emulator's data), as allocated
    /// (API 6).
    public var diskBytes: Int64?

    public init(id: String, platform: Platform, config: String, holder: String, cpus: Int? = nil, memoryLimitBytes: Int64? = nil,
                cpuPercent: Double? = nil, memoryBytes: Int64? = nil, diskBytes: Int64? = nil) {
        self.diskBytes = diskBytes
        self.id = id
        self.platform = platform
        self.config = config
        self.holder = holder
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
    public var description: String { error }
    public init(error: String) { self.error = error }
}

public enum OSS {
    /// This build's version, and the API level it speaks.
    public static let version = "0.9.0"
    /// 6 from 0.9.0: container leases (`platform: container`, a
    /// `ContainerSpec`, `POST /v1/machines/<id>/exec` streamed), a lease's
    /// disk (`MachineUsage.diskBytes`), disk in usage's history. A client says
    /// its level in an `OSS-API` header: one below 6 is shown no containers.
    /// 5 from 0.8.0: usage says what is OS Server's, what is other
    /// processes', the disk, and the biggest other processes; a read-only
    /// token for OS Monitor (`MonitorConnection`).
    /// 4 from 0.5.0: input (`POST /v1/machines/<id>/input`), usage
    /// (`GET /v1/usage`), and a lease's `cpus`, `memoryLimitBytes` and
    /// `guestPassword`.
    /// 3 from 0.4.0: the Bazel cache (`GET /v1/cache`, the `cache` feature).
    /// 2 from 0.3.0: containers (`/v1/containers`) are gone, and Status and
    /// Capabilities no longer carry them.
    public static let apiLevel = 6
    /// What every server does; one that keeps a Bazel cache adds `cache`.
    public static let features = ["machines", "screenshots", "input", "usage"]
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
