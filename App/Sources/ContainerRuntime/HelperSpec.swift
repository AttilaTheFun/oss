import ContainerizationOCI
import Foundation
import OSSClient

/// What a container's helper (`oss-machine container`, a launchd job of OS
/// Server's) runs: written beside the container's root filesystem
/// (`helper.json`) by OS Server, read by the helper when it starts, and
/// again when OS Server starts it after the Mac's restart.
public struct HelperSpec: Codable, Sendable {
    public struct Volume: Codable, Sendable {
        public var path: String
        public var destination: String

        public init(path: String, destination: String) {
            self.path = path
            self.destination = destination
        }
    }

    public var name: String
    public var kernel: String
    public var initfs: String
    public var rootfs: String
    /// Where it takes commands (`ExecFrame`s).
    public var socket: String
    public var cpus: Int
    public var memoryBytes: Int64
    public var rosetta: Bool
    public var mounts: [ContainerMount]
    public var volumes: [Volume]
    /// The image's own settings (its environment, user, working directory, command).
    public var image: ImageConfig?
    public var environment: [String: String]
    public var workingDirectory: String?
    public var command: [String]?
    /// The containers' network's socket (its owner's, ContainerNetwork),
    /// which OS Server writes each time it starts the helper; a spec from
    /// before 0.14 has none, and the helper takes ContainerNetwork.socket.
    public var network: String?

    public init(name: String, kernel: String, initfs: String, rootfs: String, socket: String, cpus: Int, memoryBytes: Int64,
                rosetta: Bool, mounts: [ContainerMount], volumes: [Volume], image: ImageConfig?, environment: [String: String],
                workingDirectory: String?, command: [String]?, network: String? = nil) {
        self.name = name
        self.kernel = kernel
        self.initfs = initfs
        self.rootfs = rootfs
        self.socket = socket
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.rosetta = rosetta
        self.mounts = mounts
        self.volumes = volumes
        self.image = image
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.command = command
        self.network = network
    }

    /// The file beside `helper.json` the helper writes the container's IPv4
    /// address in, once its network is made (where its ports are forwarded).
    public static let addressFile = "address"

    /// What a container runs when its lease names nothing: a process that
    /// waits, so commands are run in it with exec.
    public static let waits = ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 86400 & wait $!; done"]

    /// `NAME=VALUE`s with `extra` set over them.
    public static func merged(_ list: [String], _ extra: [String: String]) -> [String] {
        guard !extra.isEmpty else { return list }
        let kept = list.filter { entry in !extra.keys.contains(String(entry.split(separator: "=", maxSplits: 1).first ?? "")) }
        return kept + extra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}
