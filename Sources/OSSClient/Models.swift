import Foundation

/// What a machine lease can be: a whole machine (a VM: macOS, Linux,
/// Windows), an iOS simulator or an Android emulator on the server's Mac.
public enum Platform: String, Codable, CaseIterable, Sendable {
    case macos, ios, android, linux, windows

    public var isVM: Bool { self == .macos || self == .linux || self == .windows }
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

    public init(platform: Platform, config: String? = nil, minutes: Int? = nil, holder: String? = nil, sshPublicKey: String? = nil) {
        self.platform = platform
        self.config = config
        self.minutes = minutes
        self.holder = holder
        self.sshPublicKey = sshPublicKey
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

    public init(sampledAt: Date, host: HostUsage, machines: [MachineUsage]) {
        self.sampledAt = sampledAt
        self.host = host
        self.machines = machines
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

    public init(id: String, platform: Platform, config: String, holder: String, cpus: Int? = nil, memoryLimitBytes: Int64? = nil,
                cpuPercent: Double? = nil, memoryBytes: Int64? = nil) {
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
    public static let version = "0.7.0"
    /// 4 from 0.5.0: input (`POST /v1/machines/<id>/input`), usage
    /// (`GET /v1/usage`), and a lease's `cpus`, `memoryLimitBytes` and
    /// `guestPassword`.
    /// 3 from 0.4.0: the Bazel cache (`GET /v1/cache`, the `cache` feature).
    /// 2 from 0.3.0: containers (`/v1/containers`) are gone, and Status and
    /// Capabilities no longer carry them.
    public static let apiLevel = 4
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
