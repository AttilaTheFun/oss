import Foundation
import Observation
import OSSClient

/// What the server says, asked every two seconds through its own API: its
/// leases and capacity, what it and each lease use, and its Bazel cache.
@MainActor @Observable
final class Monitor {
    private(set) var capabilities: Capabilities?
    private(set) var status: Status?
    private(set) var usage: Usage?
    private(set) var cache: CacheInfo?
    private(set) var error: String?
    /// The Mac's CPU and memory over the last few minutes, oldest first.
    private(set) var history: [Sample] = []

    struct Sample {
        var date: Date
        var cpuFraction: Double
        var memoryFraction: Double
    }

    private var fixture = false

    /// The time relative times are shown against: the fixture's, or now.
    var now: Date { fixture ? Fixture.now : Date() }

    /// Canned, for the proof's screens (Fixture.swift).
    func pretend(capabilities: Capabilities, status: Status, usage: Usage, cache: CacheInfo?, history: [Sample]) {
        fixture = true
        self.capabilities = capabilities
        self.status = status
        self.usage = usage
        self.cache = cache
        self.history = history
    }

    func run() async {
        while !Task.isCancelled && !fixture {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        guard !fixture else { return }
        let port = ServerSettings.load().port
        guard let url = URL(string: "http://127.0.0.1:\(port)"), let token = ServerSettings.token() else {
            error = "No server yet (no token in ~/.config/oss)."
            return
        }
        let client = OSSClient(server: url, token: token, timeout: 10)
        do {
            async let askedCapabilities = client.capabilities()
            async let askedStatus = client.status()
            async let askedUsage = client.usage()
            capabilities = try await askedCapabilities
            status = try await askedStatus
            let usage = try await askedUsage
            self.usage = usage
            cache = (self.capabilities?.features.contains("cache") ?? false) ? try? await client.cache() : nil
            error = nil
            let host = usage.host
            history.append(Sample(date: usage.sampledAt,
                                  cpuFraction: host.cpus > 0 ? host.cpuPercent / Double(host.cpus * 100) : 0,
                                  memoryFraction: host.memoryBytes > 0 ? Double(host.memoryUsedBytes) / Double(host.memoryBytes) : 0))
            if history.count > 150 { history.removeFirst(history.count - 150) }
        } catch {
            self.error = "\(error)"
        }
    }

    /// Each lease with what it uses (nil where the server measured nothing).
    var machines: [MachineRow] {
        let usages = Dictionary((usage?.machines ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (status?.leases ?? []).sorted { $0.created < $1.created }.map { MachineRow(lease: $0, usage: usages[$0.id]) }
    }
}

struct MachineRow: Identifiable {
    var lease: Lease
    var usage: MachineUsage?
    var id: String { lease.id }
}
