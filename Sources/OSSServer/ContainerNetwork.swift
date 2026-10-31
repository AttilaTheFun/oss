import Foundation
#if canImport(Glibc)
import Glibc
#endif

// The containers' network (0.14): ONE vmnet network, made by a process of
// its own (`oss-machine network <network.json>`, the launchd job
// `oss.network`) and kept for that process's life, which every container's
// helper attaches to. Until 0.14 each helper made a network of its own,
// which died with it; macOS puts each vmnet network on a bridge of its own
// (bridge100, bridge101…), and taking one down could take another live
// network's bridge address and route with it, leaving the container on it
// with a gateway that answered nothing. One network that outlives every
// lease takes that churn away.
//
// This file is what needs no vmnet: the subnet, the addresses handed out
// (kept on disk, so a helper started again gets its container's own), the
// owner's socket and what it answers there, and the helpers' client. The
// vmnet calls are App/Sources/ContainerRuntime/SharedNetwork.swift's; the
// owner here takes the network's serialization as bytes, so its tests run
// against a fake one, on Linux too.

/// Where the network's owner keeps its files, in OS Server's folder:
///
///   Network/network.json    what the owner runs (ContainerNetworkSpec), written by OS Server as it starts it
///   Network/addresses.json  the address each container was given (AddressBook)
///   Network/network.sock    its socket (in the temporary folder's `oss/` when that path is too long for one)
///   Network/launchd.plist   its launchd job (`oss.network`), and network.log, its log
public enum ContainerNetwork {
    /// The owner's launchd job.
    public static let label = "oss.network"
    /// server.json's `containerSubnet` when it names none: 192.168.127.0/24.
    /// Apple's container takes 192.168.64.0/24 by default, and vmnet, asked
    /// for a network with no subnet, takes the next free /24 from
    /// 192.168.64.0 up (64, 65, 66…, as each network is made), so the top
    /// of that run is the last it would reach; it stays inside 192.168/16,
    /// as vmnet's own picks do, and is no router's usual LAN (0, 1, 2, 8,
    /// 10, 50, 86, 100, 178…).
    public static let defaultSubnet = "192.168.127.0/24"

    public static var folder: String { "\(Paths.support)/Network" }
    public static var specFile: String { "\(folder)/network.json" }
    public static var addressesFile: String { "\(folder)/addresses.json" }
    public static var log: String { "\(folder)/network.log" }
    public static var plist: String { "\(folder)/launchd.plist" }

    /// Its socket: in OS Server's folder, unless that path is too long for
    /// a Unix socket's (104 bytes), as an `OSS_HOME` deep in a folder may
    /// make it; then beside the helpers' in the temporary folder.
    public static var socket: String {
        let inFolder = "\(folder)/network.sock"
        guard inFolder.utf8.count >= 100 else { return inFolder }
        return FileManager.default.temporaryDirectory.appendingPathComponent("oss").appendingPathComponent("network.sock").path
    }

    /// The subnet server.json asks for.
    static var configuredSubnet: String { ServerConfig.load().containerSubnet }
}

/// What the network's owner runs (`Network/network.json`).
public struct ContainerNetworkSpec: Codable, Sendable, Equatable {
    public var subnet: String
    public var socket: String
    public var addresses: String

    public init(subnet: String, socket: String, addresses: String) {
        self.subnet = subnet
        self.socket = socket
        self.addresses = addresses
    }
}

public struct ContainerNetworkError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// An IPv4 subnet the containers' network is made on: its first address
/// is the network's, its second the Mac's (the gateway, and the containers'
/// DNS), its last the broadcast; the rest are the containers'.
public struct ContainerSubnet: Sendable, Equatable, CustomStringConvertible {
    /// The network's address, host bits zero.
    public let base: UInt32
    public let prefix: Int

    /// `192.168.127.0/24`: a private (RFC 1918) block, /16 to /28, written
    /// as its network's address.
    public init(_ text: String) throws {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (16...28).contains(prefix),
              let base = Self.parse(String(parts[0])) else {
            throw ContainerNetworkError("\(text) isn't a subnet (a.b.c.d/16 to /28)")
        }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        guard base & ~mask == 0 else {
            throw ContainerNetworkError("\(text) isn't its network's address (\(Self.dotted(base & mask))/\(prefix))")
        }
        // 10/8, 172.16/12, 192.168/16: vmnet's NAT is for private addresses.
        let isPrivate = base >> 24 == 10 || base >> 20 == (172 << 4 | 1) || base >> 16 == (192 << 8 | 168)
        guard isPrivate else { throw ContainerNetworkError("\(text) isn't a private (RFC 1918) subnet") }
        self.base = base
        self.prefix = prefix
    }

    public var mask: UInt32 { ~UInt32(0) << (32 - prefix) }
    public var broadcast: UInt32 { base | ~mask }
    /// The Mac's address on it: the containers' gateway and DNS.
    public var gateway: String { Self.dotted(base + 1) }
    /// What containers may be given: all but the network's, the Mac's and the broadcast.
    public var hosts: ClosedRange<UInt32> { (base + 2)...(broadcast - 1) }
    public var description: String { "\(Self.dotted(base))/\(prefix)" }

    public func contains(_ address: UInt32) -> Bool { address & mask == base }

    public static func parse(_ dotted: String) -> UInt32? {
        let octets = dotted.split(separator: ".", omittingEmptySubsequences: false).map { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ ($0 ?? 256) < 256 }) else { return nil }
        return octets.reduce(0) { $0 << 8 | $1! }
    }

    public static func dotted(_ address: UInt32) -> String {
        "\(address >> 24).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }

    /// An interface of this computer's already on the subnet (`bridge100
    /// 192.168.127.1`), which a network made on it would collide with.
    public func interfaceOnIt() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if contains(value) { return "\(String(cString: pointer.pointee.ifa_name)) \(Self.dotted(value))" }
        }
        return nil
    }
}

/// An address the owner gave a container, with the MAC address its network
/// card gets: both its own until its lease ends, so a helper started again
/// (OS Server's restart, the Mac's) brings the container back as it was.
public struct NetworkAllocation: Codable, Sendable, Equatable {
    public var address: String
    public var mac: String
}

/// The addresses handed out, by container name, kept in a file
/// (`addresses.json`) as each changes. They are taken in turn around the
/// subnet rather than the lowest free one first, so an address a container
/// gave back goes to another only once the rest have been used: the Mac's
/// ARP cache may still hold the old card's MAC address for a while.
public final class AddressBook: @unchecked Sendable {
    public let path: String
    public let subnet: ContainerSubnet
    private let lock = NSLock()
    private var allocations: [String: NetworkAllocation] = [:]
    /// The next address to try.
    private var next: UInt32

    private struct Stored: Codable {
        var subnet: String
        var next: String?
        var allocations: [String: NetworkAllocation]
    }

    /// The file's allocations, if it was kept for this subnet (another's are
    /// dropped: server.json's subnet changed since).
    public init(path: String, subnet: ContainerSubnet) throws {
        self.path = path
        self.subnet = subnet
        next = subnet.hosts.lowerBound
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let stored: Stored
        do { stored = try JSONDecoder().decode(Stored.self, from: data) } catch {
            throw ContainerNetworkError("\(path) can't be read (\(error)): move it aside to start the addresses again")
        }
        guard stored.subnet == subnet.description else { return }
        allocations = stored.allocations.filter { ContainerSubnet.parse($0.value.address).map(subnet.hosts.contains) ?? false }
        if let kept = stored.next.flatMap(ContainerSubnet.parse), subnet.hosts.contains(kept) { next = kept }
    }

    /// Every container's, by name.
    public var all: [String: NetworkAllocation] { lock.withLock { allocations } }

    /// The container's own address if it has one, else the next free one.
    public func allocate(_ name: String) throws -> NetworkAllocation {
        try lock.withLock {
            if let kept = allocations[name] { return kept }
            let taken = Set(allocations.values.compactMap { ContainerSubnet.parse($0.address) })
            let hosts = subnet.hosts
            let count = Int(hosts.upperBound - hosts.lowerBound) + 1
            guard taken.count < count else {
                throw ContainerNetworkError("no address left on \(subnet) (\(count) containers hold them all)")
            }
            var candidate = hosts.contains(next) ? next : hosts.lowerBound
            while taken.contains(candidate) { candidate = candidate == hosts.upperBound ? hosts.lowerBound : candidate + 1 }
            let macs = Set(allocations.values.map(\.mac))
            var mac = Self.randomMAC()
            while macs.contains(mac) { mac = Self.randomMAC() }
            let allocation = NetworkAllocation(address: ContainerSubnet.dotted(candidate), mac: mac)
            allocations[name] = allocation
            next = candidate == hosts.upperBound ? hosts.lowerBound : candidate + 1
            try save()
            return allocation
        }
    }

    /// Given back (its lease ended); false when it had none.
    @discardableResult
    public func release(_ name: String) throws -> Bool {
        try lock.withLock {
            guard allocations.removeValue(forKey: name) != nil else { return false }
            try save()
            return true
        }
    }

    /// Every container's but those named given back (OS Server's start,
    /// after it has deleted the containers no lease holds); the names given back.
    public func keep(_ names: Set<String>) throws -> [String] {
        try lock.withLock {
            let gone = allocations.keys.filter { !names.contains($0) }.sorted()
            guard !gone.isEmpty else { return [] }
            for name in gone { allocations.removeValue(forKey: name) }
            try save()
            return gone
        }
    }

    private func save() throws {
        let stored = Stored(subnet: subnet.description, next: ContainerSubnet.dotted(next), allocations: allocations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(stored).write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// A locally administered unicast address (02:…, 06:…, 0a:…).
    static func randomMAC() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = bytes[0] & 0xFC | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// What the network's owner answers on its socket: a JSON object of
/// strings in, one out (a line each), a connection each.
///
///   {"op": "network"}                    {"subnet", "gateway", "serialization"}
///   {"op": "allocate", "name": N}        {"address", "prefix", "gateway", "mac", "subnet", "serialization"}
///   {"op": "release", "name": N}         {"released": "true" | "false"}
///   {"op": "keep", "names": "a\nb"}      {"released": the names given back, a line each}
///   {"op": "status"}                     {"pid", "subnet", "gateway", "containers"}
///
/// `serialization` is the network's, base64: what a helper makes its own
/// reference to the network from (vmnet_network_create_with_serialization).
/// A failure answers `{"error": why}`.
public final class NetworkOwnerService: Sendable {
    public let subnet: ContainerSubnet
    public let book: AddressBook
    private let serialization: String

    public init(subnet: ContainerSubnet, serialization: Data, book: AddressBook) {
        self.subnet = subnet
        self.book = book
        self.serialization = serialization.base64EncodedString()
    }

    public func handle(_ request: [String: String]) -> [String: String] {
        switch request["op"] {
        case "network":
            return ["subnet": subnet.description, "gateway": subnet.gateway, "serialization": serialization]
        case "allocate":
            guard let name = Self.name(request["name"]) else { return ["error": "allocate needs a container's name"] }
            do {
                let allocation = try book.allocate(name)
                return ["address": allocation.address, "prefix": String(subnet.prefix), "gateway": subnet.gateway, "mac": allocation.mac,
                        "subnet": subnet.description, "serialization": serialization]
            } catch {
                return ["error": "\(error)"]
            }
        case "release":
            guard let name = Self.name(request["name"]) else { return ["error": "release needs a container's name"] }
            do { return ["released": String(try book.release(name))] } catch { return ["error": "\(error)"] }
        case "keep":
            let names = Set((request["names"] ?? "").split(separator: "\n").map(String.init))
            do { return ["released": try book.keep(names).joined(separator: "\n")] } catch { return ["error": "\(error)"] }
        case "status":
            return ["pid": String(getpid()), "subnet": subnet.description, "gateway": subnet.gateway, "containers": String(book.all.count)]
        default:
            return ["error": "no such op \(request["op"] ?? "(none)")"]
        }
    }

    private static func name(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name.utf8.count <= 200, !name.contains("\n") else { return nil }
        return name
    }
}

/// A Unix socket that answers a JSON line with one (the owner's), and the
/// asking side: plain POSIX sockets, on macOS and Linux alike.
public enum LineSocket {
    /// Listening at `path` (made afresh, mode 600), each connection's line
    /// answered by `handle` on a thread of its own; until `stop()`.
    public final class Listener: @unchecked Sendable {
        public let path: String
        private let descriptor: Int32
        private let lock = NSLock()
        private var stopped = false

        init(path: String, descriptor: Int32) {
            self.path = path
            self.descriptor = descriptor
        }

        /// No more connections; the socket's file removed.
        public func stop() {
            let first = lock.withLock {
                defer { stopped = true }
                return !stopped
            }
            guard first else { return }
            // Its accept woken by a connection of its own (a closed socket's
            // accept isn't woken everywhere), which it sees is the end.
            _ = LineSocket.isAnswering(path)
            shutdown(descriptor, Int32(SHUT_RDWR))
            close(descriptor)
            unlink(path)
        }

        var isStopped: Bool { lock.withLock { stopped } }
    }

    public static func listen(at path: String, handle: @escaping @Sendable ([String: String]) -> [String: String]) throws -> Listener {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let descriptor = makeSocket()
        guard descriptor >= 0 else { throw ContainerNetworkError("no socket for \(path)") }
        guard var address = socketAddress(path) else {
            close(descriptor)
            throw ContainerNetworkError("\(path) is too long for a Unix socket")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard bound, posixListen(descriptor, 16) == 0 else {
            let why = String(cString: strerror(errno))
            close(descriptor)
            throw ContainerNetworkError("can't listen at \(path): \(why)")
        }
        chmod(path, 0o600)
        let listener = Listener(path: path, descriptor: descriptor)
        Thread.detachNewThread {
            while !listener.isStopped {
                let connection = accept(descriptor, nil, nil)
                if listener.isStopped {
                    if connection >= 0 { close(connection) }
                    return
                }
                guard connection >= 0 else { continue }
                Thread.detachNewThread { serve(connection, handle) }
            }
        }
        return listener
    }

    private static func serve(_ connection: Int32, _ handle: @Sendable ([String: String]) -> [String: String]) {
        defer { close(connection) }
        noSignalOnWrite(connection)
        // One that connects and says nothing is let go.
        var seconds = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
        guard let line = readLine(connection, limit: 1 << 20) else { return }
        // A connection that only checks the socket says nothing, and is answered nothing.
        guard !line.isEmpty else { return }
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: String]
        let answer = request.map(handle) ?? ["error": "not a JSON object of strings"]
        guard var out = try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]) else { return }
        out.append(0x0A)
        writeAll(connection, out)
    }

    /// One request and its answer; nil when nothing answers at `path`.
    public static func request(_ path: String, _ message: [String: String], timeout: TimeInterval = 10) async -> [String: String]? {
        await Task.detached { requestNow(path, message, timeout: timeout) }.value
    }

    static func requestNow(_ path: String, _ message: [String: String], timeout: TimeInterval) -> [String: String]? {
        guard let descriptor = connect(path) else { return nil }
        defer { close(descriptor) }
        noSignalOnWrite(descriptor)
        var seconds = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
        guard var line = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        line.append(0x0A)
        guard writeAll(descriptor, line), let answer = readLine(descriptor, limit: 16 << 20), !answer.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: answer)) as? [String: String]
    }

    /// Whether something takes connections at `path`.
    public static func isAnswering(_ path: String) -> Bool {
        guard let descriptor = connect(path) else { return false }
        close(descriptor)
        return true
    }

    // MARK: POSIX

    private static func makeSocket() -> Int32 {
        #if canImport(Glibc)
        socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
    }

    private static func socketAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    private static func connect(_ path: String) -> Int32? {
        guard var address = socketAddress(path) else { return nil }
        let descriptor = makeSocket()
        guard descriptor >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                posixConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { close(descriptor); return nil }
        return descriptor
    }

    /// A write to a peer that has gone fails rather than ends the process.
    private static func noSignalOnWrite(_ descriptor: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    @discardableResult
    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                #if canImport(Glibc)
                let sent = send(descriptor, buffer.baseAddress! + offset, buffer.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let sent = send(descriptor, buffer.baseAddress! + offset, buffer.count - offset, 0)
                #endif
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }
    }

    /// Up to the first newline (without it); empty when the peer closed
    /// having sent nothing; nil on an error, a timeout or a line too long.
    private static func readLine(_ descriptor: Int32, limit: Int) -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return line.isEmpty ? Data() : nil }
            if let end = buffer[0..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[0..<end])
                return line
            }
            line.append(contentsOf: buffer[0..<count])
            guard line.count <= limit else { return nil }
        }
    }
}

/// What a helper is given for its container: an address on the network,
/// and the network's serialization to attach with.
public struct NetworkAttachment: Sendable, Equatable {
    public var address: String
    public var prefix: Int
    public var gateway: String
    public var mac: String
    public var subnet: String
    public var serialization: Data

    /// `192.168.127.2/24`.
    public var cidr: String { "\(address)/\(prefix)" }
}

/// The helpers' (and OS Server's) side of the owner's socket.
public enum NetworkOwnerClient {
    /// The container's address on the network, and the network's
    /// serialization, waiting up to `wait` seconds for the owner to answer
    /// (launchd starting it again). Never a network of the helper's own:
    /// one made and taken down with each container is what broke its
    /// neighbours' networks, so with no owner the container doesn't start.
    public static func attach(name: String, socket: String = ContainerNetwork.socket, wait: TimeInterval = 30) async throws -> NetworkAttachment {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if let answer = await LineSocket.request(socket, ["op": "allocate", "name": name]) {
                if let error = answer["error"] { throw ContainerNetworkError("the containers' network: \(error)") }
                guard let address = answer["address"], let prefix = answer["prefix"].flatMap(Int.init), let gateway = answer["gateway"],
                      let mac = answer["mac"], let subnet = answer["subnet"],
                      let serialization = answer["serialization"].flatMap({ Data(base64Encoded: $0) }) else {
                    throw ContainerNetworkError("the containers' network answered without an address: \(answer.keys.sorted())")
                }
                return NetworkAttachment(address: address, prefix: prefix, gateway: gateway, mac: mac, subnet: subnet,
                                         serialization: serialization)
            }
            guard Date() < deadline else {
                throw ContainerNetworkError("OS Server's containers' network (launchd job \(ContainerNetwork.label)) didn't answer at "
                                            + "\(socket) in \(Int(wait)) seconds; its log is \(ContainerNetwork.log)")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// The container's address given back (its lease ended); false when
    /// the owner had none for it or didn't answer.
    @discardableResult
    public static func release(name: String, socket: String = ContainerNetwork.socket) async -> Bool {
        await LineSocket.request(socket, ["op": "release", "name": name])?["released"] == "true"
    }

    /// Every address but those of the containers named given back; the
    /// names given back, or nil when the owner didn't answer.
    public static func keep(_ names: Set<String>, socket: String = ContainerNetwork.socket) async -> [String]? {
        guard let answer = await LineSocket.request(socket, ["op": "keep", "names": names.sorted().joined(separator: "\n")]),
              answer["error"] == nil else { return nil }
        return (answer["released"] ?? "").split(separator: "\n").map(String.init)
    }

    /// The owner's pid, subnet, gateway and how many containers hold an
    /// address; nil when nothing answers.
    public static func status(socket: String = ContainerNetwork.socket, timeout: TimeInterval = 5) async -> [String: String]? {
        guard let answer = await LineSocket.request(socket, ["op": "status"], timeout: timeout), answer["error"] == nil else { return nil }
        return answer
    }
}

#if os(macOS)
/// OS Server's side of the owner: its launchd job started when a container
/// is about to be, unless it already runs, and never stopped while OS
/// Server lends containers (only with the containers' component removed).
/// The job is KeepAlive: launchd starts it again if it ends, with the same
/// subnet and its addresses from its file.
public actor ContainerNetworkOwner {
    public static let shared = ContainerNetworkOwner()
    private var ensuring: Task<Void, Error>?

    /// Running and answering (started if it wasn't), before a helper is.
    /// Two leases starting at once wait on the same start: a second start
    /// would boot the first's owner out, and its network with it.
    public func ensure(helper: String) async throws {
        if let ensuring { return try await ensuring.value }
        let task = Task { try await Self.ensureNow(helper: helper) }
        ensuring = task
        defer { ensuring = nil }
        try await task.value
    }

    private static func ensureNow(helper: String) async throws {
        let socket = ContainerNetwork.socket
        let subnet = ContainerNetwork.configuredSubnet
        if let status = await NetworkOwnerClient.status(socket: socket) {
            note(status, subnet: subnet)
            return
        }
        // Loaded but not answering yet: launchd is starting it (again).
        if await LaunchdJobs.isRunning(label: ContainerNetwork.label) {
            for _ in 0..<60 {
                if let status = await NetworkOwnerClient.status(socket: socket) {
                    note(status, subnet: subnet)
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        _ = try ContainerSubnet(subnet)
        Paths.ensure(ContainerNetwork.folder)
        let spec = ContainerNetworkSpec(subnet: subnet, socket: socket, addresses: ContainerNetwork.addressesFile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(spec).write(to: URL(fileURLWithPath: ContainerNetwork.specFile))
        log("containers' network: starting its owner (\(ContainerNetwork.label), \(subnet))")
        try await LaunchdJobs.start(label: ContainerNetwork.label, plist: ContainerNetwork.plist,
                                    program: [helper, "network", ContainerNetwork.specFile], log: ContainerNetwork.log, keepAlive: true)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let status = await NetworkOwnerClient.status(socket: socket) {
                log("containers' network: \(status["subnet"] ?? subnet), owner pid \(status["pid"] ?? "?")")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let tail = ((try? String(contentsOfFile: ContainerNetwork.log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(3)
        throw ContainerNetworkError("the containers' network didn't start: \(tail.joined(separator: " / "))")
    }

    /// A running owner keeps the subnet it was made with: a changed
    /// server.json takes effect when it is next made (the Mac's restart).
    private static func note(_ status: [String: String], subnet: String) {
        if let running = status["subnet"], running != subnet {
            log("containers' network: on \(running), not server.json's \(subnet), until its owner is next started (the Mac's restart)")
        }
    }

    /// Its job ended and its files removed (the containers' component
    /// removed, after every container).
    public func remove() async {
        await LaunchdJobs.stop(label: ContainerNetwork.label)
        try? FileManager.default.removeItem(atPath: ContainerNetwork.folder)
        unlink(ContainerNetwork.socket)
    }
}
#endif

// The C library's listen and connect, by names LineSocket's own don't shadow.
#if canImport(Glibc)
private func posixListen(_ descriptor: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(descriptor, backlog) }
private func posixConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Glibc.connect(descriptor, address, length)
}
#else
private func posixListen(_ descriptor: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(descriptor, backlog) }
private func posixConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Darwin.connect(descriptor, address, length)
}
#endif
