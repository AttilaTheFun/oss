import Foundation
import Observation
import OSSClient

/// One OS Server, watched: its status (capacity, bases, leases), its usage
/// (the Mac's CPU, memory and disk, OS Server's share and everyone else's,
/// each lease's), its Bazel cache, asked every few seconds while watched,
/// and the last few minutes of CPU and memory for a chart. The first of the
/// server's addresses that answers is used, and the rest are tried again
/// when it stops answering.
@available(macOS 15, iOS 18, *)
@MainActor @Observable
public final class ServerMonitor: Identifiable {
    public enum State: Equatable {
        case connecting
        /// Answering at this address.
        case connected(URL)
        case failed(String)
    }

    public let connection: MonitorConnection
    public private(set) var state: State = .connecting
    public private(set) var capabilities: Capabilities?
    public private(set) var status: Status?
    public private(set) var usage: Usage?
    public private(set) var cache: CacheInfo?
    public private(set) var history: [Sample] = []
    public private(set) var updated: Date?
    /// Canned (the proof's screens, previews): nothing is asked.
    public private(set) var isFixture = false

    public nonisolated var id: String { connection.name + connection.servers.map(\.absoluteString).joined() }

    public struct Sample: Sendable {
        public var date: Date
        /// Fractions of the whole Mac.
        public var ourCPU: Double
        public var otherCPU: Double
        public var ourMemory: Double
        public var otherMemory: Double
    }

    public init(connection: MonitorConnection) {
        self.connection = connection
    }

    /// The time relative times are shown against: the fixture's, or now.
    public var now: Date { isFixture ? Self.fixtureNow : Date() }

    /// Asks every `interval` seconds until cancelled.
    public func watch(every interval: Double = 3) async {
        guard !isFixture else { return }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    public func refresh() async {
        guard !isFixture else { return }
        if case .connected(let url) = state, await ask(url) { return }
        for url in connection.servers where await ask(url) { return }
        if case .connected = state { state = .connecting }
        if status == nil { state = .failed("No answer at \(connection.servers.map { $0.host ?? $0.absoluteString }.joined(separator: ", ")).") }
    }

    /// Everything, from one address; false when it doesn't answer.
    private func ask(_ url: URL) async -> Bool {
        let client = OSSClient(server: url, token: connection.token, timeout: 6)
        do {
            async let askedCapabilities = client.capabilities()
            async let askedStatus = client.status()
            async let askedUsage = client.usage()
            let capabilities = try await askedCapabilities
            let status = try await askedStatus
            let usage = try await askedUsage
            self.capabilities = capabilities
            self.status = status
            self.usage = usage
            cache = capabilities.features.contains("cache") ? try? await client.cache() : nil
            updated = Date()
            state = .connected(url)
            record(usage)
            return true
        } catch {
            if case .connected(let current) = state, current == url {
                state = .failed("\(url.host ?? url.absoluteString): \(error.localizedDescription)")
            }
            return false
        }
    }

    private func record(_ usage: Usage) {
        let host = usage.host
        let cores = Double(max(1, host.cpus) * 100)
        let memory = Double(max(1, host.memoryBytes))
        let ours = usage.ours, others = usage.others
        history.append(Sample(date: usage.sampledAt,
                              ourCPU: (ours?.cpuPercent ?? 0) / cores,
                              otherCPU: (others?.cpuPercent ?? host.cpuPercent) / cores,
                              ourMemory: Double(ours?.memoryBytes ?? 0) / memory,
                              otherMemory: Double(others?.memoryBytes ?? host.memoryUsedBytes) / memory))
        if history.count > 200 { history.removeFirst(history.count - 200) }
    }

    // MARK: What the screens show

    /// Each lease with what it uses (nil where the server measured nothing).
    public var machines: [MachineRow] {
        let usages = Dictionary((usage?.machines ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (status?.leases ?? []).sorted { $0.created < $1.created }.map { MachineRow(lease: $0, usage: usages[$0.id]) }
    }

    /// Canned, for the proof's screens and previews.
    public func pretend(capabilities: Capabilities, status: Status, usage: Usage, cache: CacheInfo?, history: [Sample]) {
        isFixture = true
        self.capabilities = capabilities
        self.status = status
        self.usage = usage
        self.cache = cache
        self.history = history
        updated = usage.sampledAt
        state = .connected(connection.servers.first ?? URL(string: "http://localhost:7480")!)
    }

    /// The fixture's moment, so every relative time is the same.
    public static let fixtureNow = Date(timeIntervalSince1970: 1_793_534_400)
}

public struct MachineRow: Identifiable, Sendable {
    public var lease: Lease
    public var usage: MachineUsage?
    public var id: String { lease.id }
}
