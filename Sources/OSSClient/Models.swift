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

// MARK: Containers

public enum ContainerState: String, Codable, Sendable {
    case starting, running, stopped, archived, failed
}

/// A Linux container of its own (Apple's container on a Mac, Podman or
/// Docker on Linux): any image, kept running by oss until it is stopped,
/// archived or removed, with commands run in it as processes. Its home
/// (`/root`) is a directory on the server, so it outlives the container:
/// archived as a tarball, restored into a new one.
public struct Container: Codable, Sendable {
    public var id: String
    public var holder: String
    public var state: ContainerState
    public var created: Date
    /// The container tool's name for it: `oss-container-<id>`.
    public var name: String
    /// Its image, when not the server's default.
    public var image: String?
    /// Its home on the server, while it has a container.
    public var home: String?
    /// The archive, once archived: restarting restores it into a new container.
    public var archive: String?
    public var error: String?
    /// The server's computer as the container reaches it: the container can
    /// reach that computer's ports on this address.
    public var hostAddress: String?
    /// Files in the home (relative to it) holding secrets, left out of archives.
    public var secretFiles: [String]?
    /// A client's own names for it: `GET /v1/containers?label=key=value` finds it.
    public var labels: [String: String]?
    /// Its CPUs and memory, when not the server's defaults.
    public var cpus: Int?
    public var memory: String?
    /// Its own token, also in its home (`~/.config/oss/token`, beside the
    /// server's address in `client.json`): it leases, uses and releases
    /// machines as the holder `container-<id>`, nothing else.
    public var token: String?

    public init(id: String, holder: String, state: ContainerState, created: Date, name: String) {
        self.id = id
        self.holder = holder
        self.state = state
        self.created = created
        self.name = name
    }
}

public struct ContainerRequest: Codable, Sendable {
    public var holder: String?
    /// Its image (any the container tool can pull or has built), when not the server's default.
    public var image: String?
    /// An archive (a path on the server) to restore its home from: one made
    /// by `oss container archive`, here or on another computer.
    public var archive: String?
    /// Variables for the container (every process in it sees them).
    public var environment: [String: String]?
    /// Files in the home (relative to it) holding secrets, left out of archives.
    public var secretFiles: [String]?
    /// A client's own names for it, to find it by.
    public var labels: [String: String]?
    /// Its CPUs and memory ("4g"), when not the server's defaults.
    public var cpus: Int?
    public var memory: String?

    public init(holder: String? = nil, image: String? = nil, archive: String? = nil, environment: [String: String]? = nil,
                secretFiles: [String]? = nil, labels: [String: String]? = nil, cpus: Int? = nil, memory: String? = nil) {
        self.holder = holder
        self.image = image
        self.archive = archive
        self.environment = environment
        self.secretFiles = secretFiles
        self.labels = labels
        self.cpus = cpus
        self.memory = memory
    }
}

/// Restarting a container: an archived one is restored into a new container,
/// which takes its variables again.
public struct RestartRequest: Codable, Sendable {
    public var environment: [String: String]?
    public init(environment: [String: String]? = nil) { self.environment = environment }
}

/// A command run in a container, apart from any terminal: its input a pipe
/// the client writes to, its output and errors files in the home that the
/// client reads from any offset, so it can go away and come back (the
/// process runs on without it, and without oss).
public struct ProcessRequest: Codable, Sendable {
    public var command: [String]
    /// Its variables: for this process alone (over the server's
    /// container.env), never kept.
    public var environment: [String: String]?
    /// Its working directory in the container (default the home, /root).
    public var directory: String?

    public init(command: [String], environment: [String: String]? = nil, directory: String? = nil) {
        self.command = command
        self.environment = environment
        self.directory = directory
    }
}

public enum ProcessState: String, Codable, Sendable {
    /// `lost`: its container stopped under it, so it has no exit status.
    case running, exited, lost
}

public struct ContainerProcess: Codable, Sendable {
    public var id: String
    public var container: String
    public var command: [String]
    public var directory: String?
    public var started: Date
    public var state: ProcessState
    public var status: Int32?
    /// Its pid in the container.
    public var pid: Int32?
    /// Bytes written so far to its output and its errors.
    public var outputSize: Int
    public var errorSize: Int

    public init(id: String, container: String, command: [String], directory: String?, started: Date, state: ProcessState,
                status: Int32?, pid: Int32?, outputSize: Int, errorSize: Int) {
        self.id = id
        self.container = container
        self.command = command
        self.directory = directory
        self.started = started
        self.state = state
        self.status = status
        self.pid = pid
        self.outputSize = outputSize
        self.errorSize = errorSize
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
    public var containers: [Container]
    public var containerLimit: Int

    public init(server: String, bases: [Base], capacity: [Capacity], leases: [Lease], containers: [Container], containerLimit: Int) {
        self.server = server
        self.bases = bases
        self.capacity = capacity
        self.leases = leases
        self.containers = containers
        self.containerLimit = containerLimit
    }
}

/// What a server is and offers (`GET /v1/capabilities`), for a client to
/// check before it relies on something.
public struct Capabilities: Codable, Sendable {
    /// oss's version (MAJOR.MINOR.PATCH).
    public var version: String
    /// The API's level: raised when something changes that a client can see.
    public var api: Int
    /// What this server does: `machines`, `containers`, `containers.processes`,
    /// `containers.files`, `containers.files.follow`, `containers.labels`,
    /// `containers.tokens`, `screenshots`.
    public var features: [String]
    /// The platforms it can lend machines of (those it has bases for).
    public var platforms: [Platform]
    /// Whether it can run containers (a container tool is installed).
    public var containers: Bool

    public init(version: String, api: Int, features: [String], platforms: [Platform], containers: Bool) {
        self.version = version
        self.api = api
        self.features = features
        self.platforms = platforms
        self.containers = containers
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
    public static let version = "0.1.0"
    public static let apiLevel = 1
    public static let features = ["machines", "screenshots", "containers", "containers.processes", "containers.files",
                                  "containers.files.follow", "containers.labels", "containers.tokens"]
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
