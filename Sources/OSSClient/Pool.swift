import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One oss server among several a client knows: its name, the addresses it
/// answers at (any order), and its token.
public struct OSSServerEntry: Sendable {
    public var name: String
    public var servers: [URL]
    public var token: @Sendable () async throws -> String

    public init(name: String, servers: [URL], token: @escaping @Sendable () async throws -> String) {
        self.name = name
        self.servers = servers
        self.token = token
    }
}

/// How far a server is: on this computer, on its LAN, over the tailnet
/// (100.64.0.0/10), or further.
public enum OSSDistance: Int, Comparable, Sendable, CustomStringConvertible {
    case thisComputer, lan, tailnet, internet

    public static func < (a: OSSDistance, b: OSSDistance) -> Bool { a.rawValue < b.rawValue }

    public var description: String { ["this computer", "LAN", "tailnet", "internet"][rawValue] }

    /// From the address a server answered at.
    static func of(_ url: URL) -> OSSDistance {
        guard let host = url.host?.lowercased() else { return .internet }
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return .thisComputer }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            if octets[0] == 100 && (64...127).contains(octets[1]) { return .tailnet }
            if octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168) { return .lan }
            return .internet
        }
        if host.hasSuffix(".local") { return .lan }
        if host.hasSuffix(".ts.net") { return .tailnet }
        return .internet
    }
}

/// Several oss servers, leased from as one: a machine comes from the
/// nearest server (this computer, then its LAN, then the tailnet) that has
/// a base for it and room, and a container only from this computer's own
/// server (it shares this computer's folders). Each lease is then used and
/// released through the client of the server that lent it.
public struct OSSPool: Sendable {
    public let entries: [OSSServerEntry]
    let transport: any OSSTransport

    public init(entries: [OSSServerEntry], transport: any OSSTransport = URLSessionTransport()) {
        self.entries = entries
        self.transport = transport
    }

    /// A server as reached now: its nearest answering address's client, how
    /// far that is, and what it has.
    public struct Reached: Sendable {
        public var name: String
        public var client: OSSClient
        public var distance: OSSDistance
        /// The hello's round trip, for servers the same distance away.
        public var latency: TimeInterval
        public var status: Status

        /// Room for one more of `platform` in `config` (nil: its default),
        /// where it has a base for it.
        public func hasRoom(_ platform: Platform, config: String?) -> Bool {
            guard status.bases.contains(where: { $0.platform == platform && (config == nil || $0.config == config) }),
                  let capacity = status.capacity.first(where: { $0.platform == platform }) else { return false }
            return capacity.leased < capacity.limit
        }

        public func lends(_ platform: Platform, config: String?) -> Bool {
            status.bases.contains { $0.platform == platform && (config == nil || $0.config == config) }
        }
    }

    /// Every server that answers, nearest first.
    public func reach() async -> [Reached] {
        let here = Self.thisHost
        let transport = self.transport
        return await withTaskGroup(of: Reached?.self) { group in
            for entry in entries {
                group.addTask {
                    // Its addresses nearest first; the first that answers as oss.
                    for url in entry.servers.sorted(by: { OSSDistance.of($0) < OSSDistance.of($1) }) {
                        let started = Date()
                        let probe = OSSHTTPRequest(method: "GET", url: url.appendingPathComponent("v1/hello"), timeout: 4)
                        guard let answer = try? await transport.send(probe), answer.status == 200,
                              let hello = try? JSONDecoder().decode([String: String].self, from: answer.body), hello["server"] == "oss" else { continue }
                        let latency = Date().timeIntervalSince(started)
                        let client = OSSClient(server: url, token: entry.token, transport: transport)
                        guard let status = try? await client.status() else { continue }
                        // A server whose host is this computer's is this computer's, whatever address reached it.
                        let distance = hello["host"].map { $0.lowercased() == here } == true ? .thisComputer : OSSDistance.of(url)
                        return Reached(name: entry.name, client: client, distance: distance, latency: latency, status: status)
                    }
                    return nil
                }
            }
            var reached: [Reached] = []
            for await result in group { if let result { reached.append(result) } }
            return reached.sorted { ($0.distance, $0.latency) < ($1.distance, $1.latency) }
        }
    }

    /// A lease from the nearest server with room for it (a container: this
    /// computer's server only), waited on until it is ready; with
    /// `waitForCapacity`, until one has room. Returns the lease and the
    /// client to use it with.
    public func lease(_ request: LeaseRequest, waitForCapacity: Bool = false,
                      progress: @Sendable (String) -> Void = { _ in }) async throws -> (client: OSSClient, lease: Lease) {
        while true {
            let reached = await reach()
            let candidates = reached.filter { request.platform != .container || $0.distance == .thisComputer }
            guard candidates.contains(where: { $0.lends(request.platform, config: request.config) }) else {
                let names = reached.map { "\($0.name) (\($0.distance))" }.joined(separator: ", ")
                throw request.platform == .container
                    ? OSSError(status: 0, message: "no server on this computer lends containers (reached: \(names.isEmpty ? "none" : names))",
                               code: reached.contains { $0.lends(.container, config: nil) } ? "notLocal" : "noContainers")
                    : OSSError(status: 0, message: "no server lends \(request.platform.rawValue)\(request.config.map { " \($0)" } ?? "") (reached: \(names.isEmpty ? "none" : names))")
            }
            for server in candidates where server.hasRoom(request.platform, config: request.config) {
                do {
                    progress("\(server.name) (\(server.distance))")
                    return (server.client, try await server.client.lease(request, progress: progress))
                } catch let error as OSSError where error.code == "busy" || error.message.hasPrefix("busy") {
                    continue   // taken meanwhile: the next one
                }
            }
            guard waitForCapacity else {
                throw OSSError(status: 409, message: "busy: no server has room for \(request.platform.rawValue)", code: "busy")
            }
            progress("no server has room for \(request.platform.rawValue); waiting")
            try await Task.sleep(for: .seconds(15))
        }
    }

    /// This computer's name, lowercased, as a server on it says its host
    /// is (`/v1/hello`'s `host`).
    public static let thisHost: String = {
        #if os(Windows)
        return ProcessInfo.processInfo.hostName.lowercased()
        #else
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return ProcessInfo.processInfo.hostName.lowercased() }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
        #endif
    }()
}
