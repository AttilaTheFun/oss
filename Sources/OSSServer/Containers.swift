import Foundation
import OSSClient

/// Linux containers, for a server that can run them: OS Server's app gives
/// one (Apple's Containerization, each container in a helper process of its
/// own, so it outlives the server's restarts), `oss serve` on its own has
/// none and lends no containers. The server keeps the leases; the backend
/// keeps the containers, each named by its lease (`oss-lease-container-<id>`),
/// and their volumes. A container's commands go to it directly, over the
/// Unix socket the backend gives (`Lease.execSocket`).
public protocol ContainerBackend: Sendable {
    /// Started from `spec` (its image pulled if this Mac hasn't it); returns
    /// its exec socket once it runs.
    func start(name: String, spec: ContainerSpec) async throws -> String
    /// After the server's restart: its exec socket, the container still
    /// running or started again from its disk (after the Mac's); nil when
    /// it is gone.
    func reattach(name: String, spec: ContainerSpec) async -> String?
    /// Whether it still runs (its helper answers).
    func isRunning(name: String) async -> Bool
    /// Stopped and deleted, its root filesystem with it, and its volumes but
    /// those it keeps.
    func stop(name: String, spec: ContainerSpec?) async
    /// Every container but `keeping` deleted (at the server's start, after
    /// the leases are taken up again).
    func prune(keeping: Set<String>) async
    /// The folder its root filesystem is in, for the disk it takes.
    func directory(name: String) -> String?
    /// The volumes on this Mac, kept ones too.
    func volumes() async -> [VolumeInfo]
    func deleteVolume(name: String) async throws
}

/// What a container gets where its lease asks for nothing.
public enum ContainerDefaults {
    public static let cpus = 4
    public static let memoryBytes: Int64 = 8 << 30
    public static let diskBytes: Int64 = 64 << 30
}

extension LocalNetworks {
    /// Whether an address is this Mac's own (loopback, or one of its
    /// interfaces'): a container is lent only to a client on its Mac.
    static func isThisMac(_ address: String?) -> Bool {
        // An IPv4 client on the dual-stack listener comes as ::ffff:a.b.c.d.
        guard let address = address.map({ $0.hasPrefix("::ffff:") ? String($0.dropFirst(7)) : $0 }) else { return false }
        if address == "::1" || address.hasPrefix("127.") { return true }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let socketAddress = pointer.pointee.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(socketAddress.pointee.sa_family == sa_family_t(AF_INET6) ? MemoryLayout<sockaddr_in6>.size
                                                                                            : MemoryLayout<sockaddr_in>.size)
            guard getnameinfo(socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if text.components(separatedBy: "%")[0] == address { return true }
        }
        return false
    }
}
