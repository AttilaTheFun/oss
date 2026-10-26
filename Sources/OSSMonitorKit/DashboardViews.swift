import OSSClient
import SwiftUI

/// What a server is doing, whole: the Mac's CPU, memory and disk (OS
/// Server's share, every other process's, what's free), what's running on
/// it, its capacity, its files, the other apps using the most, its Bazel
/// cache. OS Monitor shows it for each server; OS Server's window for its
/// own.
@available(macOS 15, iOS 18, *)
public struct ServerDashboard: View {
    let monitor: ServerMonitor

    public init(monitor: ServerMonitor) {
        self.monitor = monitor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .failed(let message) = monitor.state, monitor.usage == nil {
                Card("Not reachable", systemImage: "exclamationmark.triangle") {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            if let usage = monitor.usage {
                ResourcesCard(usage: usage, history: monitor.history)
                MachinesCard(monitor: monitor)
                if let disk = usage.disk { DiskCard(disk: disk, day: monitor.day, volumes: monitor.volumes).id("disk") }
                if let top = usage.topProcesses, !top.isEmpty { OthersCard(processes: top) }
                if let status = monitor.status { CapacityCard(status: status) }
                if let cache = monitor.cache { CacheCard(cache: cache) }
            } else if monitor.state == .connecting {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - CPU, memory and disk, and their history

/// The Mac's CPU, memory and disk side by side, each split three ways (OS
/// Server's, everyone else's, free), and the last minutes of CPU and memory.
@available(macOS 15, iOS 18, *)
struct ResourcesCard: View {
    let usage: Usage
    let history: [ServerMonitor.Sample]

    var body: some View {
        let host = usage.host
        let cores = Double(host.cpus * 100)
        let ourCPU = usage.ours?.cpuPercent ?? 0
        let otherCPU = usage.others?.cpuPercent ?? host.cpuPercent
        let ourMemory = Double(usage.ours?.memoryBytes ?? 0)
        let otherMemory = Double(usage.others?.memoryBytes ?? host.memoryUsedBytes)
        Card(usage.disk == nil ? "CPU and memory" : "CPU, memory and disk", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 14) {
                ShareRow(title: "CPU", total: "\(host.cpus) cores",
                         ours: ourCPU / cores, others: otherCPU / cores,
                         labels: (Format.cores(ourCPU), Format.cores(otherCPU), Format.cores(max(0, cores - ourCPU - otherCPU))))
                ShareRow(title: "Memory", total: Format.bytes(host.memoryBytes),
                         ours: ourMemory / Double(max(1, host.memoryBytes)), others: otherMemory / Double(max(1, host.memoryBytes)),
                         labels: (Format.bytes(Int64(ourMemory)), Format.bytes(Int64(otherMemory)),
                                  Format.bytes(max(0, host.memoryBytes - Int64(ourMemory) - Int64(otherMemory)))))
                if let disk = usage.disk {
                    let ours = disk.parts.reduce(0) { $0 + $1.bytes }
                    let used = disk.totalBytes - disk.freeBytes
                    let total = Double(max(1, disk.totalBytes))
                    ShareRow(title: "Disk", total: Format.bytes(disk.totalBytes),
                             ours: Double(min(ours, used)) / total, others: Double(max(0, used - ours)) / total,
                             labels: (Format.bytes(ours), Format.bytes(max(0, used - ours)), Format.bytes(disk.freeBytes)))
                }
                if history.count > 1 {
                    HistoryChart(history: history).frame(height: 70)
                    HStack(spacing: 14) {
                        Legend(color: .blue, text: "CPU")
                        Legend(color: .purple, text: "Memory")
                        Text("solid: OS Server · faint: everyone").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One resource as a bar of three parts: OS Server's (and its machines'),
/// every other process's, and what's free.
@available(macOS 15, iOS 18, *)
struct ShareRow: View {
    let title: String
    let total: String
    let ours: Double
    let others: Double
    let labels: (ours: String, others: String, free: String)
    /// What the first part is called; no second part when `others` is nil.
    var oursName = "OS Server"
    var othersName: String? = "Others"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(total).foregroundStyle(.secondary).monospacedDigit()
            }
            ShareBar(parts: [(ours, Color.accentColor), (others, Color.gray)])
            HStack(spacing: 12) {
                Legend(color: .accentColor, text: "\(oursName) \(labels.ours)")
                if let othersName { Legend(color: .gray, text: "\(othersName) \(labels.others)") }
                Legend(color: Color.gray.opacity(0.25), text: "Free \(labels.free)")
            }
            .font(.caption)
        }
    }
}

struct ShareBar: View {
    let parts: [(Double, Color)]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: proxy.size.width * min(1, max(0, part.0)))
                }
                Spacer(minLength: 0)
            }
            .background(Color.gray.opacity(0.18))
            .clipShape(Capsule())
        }
        .frame(height: 10)
    }
}

struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).monospacedDigit().lineLimit(1)
        }
    }
}

/// CPU and memory over the last minutes: OS Server's share solid, the
/// whole Mac's (its share and everyone else's) faint above it.
@available(macOS 15, iOS 18, *)
struct HistoryChart: View {
    let history: [ServerMonitor.Sample]

    var body: some View {
        Canvas { context, size in
            func line(_ value: (ServerMonitor.Sample) -> Double) -> Path {
                var path = Path()
                for (i, sample) in history.enumerated() {
                    let point = CGPoint(x: size.width * Double(i) / Double(max(1, history.count - 1)),
                                        y: size.height * (1 - min(1, max(0, value(sample)))))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }
            context.stroke(line { $0.ourCPU + $0.otherCPU }, with: .color(.blue.opacity(0.35)), lineWidth: 1.2)
            context.stroke(line { $0.ourMemory + $0.otherMemory }, with: .color(.purple.opacity(0.35)), lineWidth: 1.2)
            context.stroke(line(\.ourCPU), with: .color(.blue), lineWidth: 1.8)
            context.stroke(line(\.ourMemory), with: .color(.purple), lineWidth: 1.8)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }
}

// MARK: - What's running

@available(macOS 15, iOS 18, *)
struct MachinesCard: View {
    let monitor: ServerMonitor

    var body: some View {
        let rows = monitor.machines
        Card(rows.isEmpty ? "Nothing is leased" : "Running (\(rows.count))", systemImage: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: Format.symbol(row.lease.platform)).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Format.platform(row.lease.platform)) · \(row.lease.config)").font(.body.weight(.medium))
                            Text(row.lease.holder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(cpu(row)).monospacedDigit()
                            Text(memory(row)).monospacedDigit().foregroundStyle(.secondary)
                            if let disk = row.usage?.diskBytes {
                                Text("\(Format.bytes(disk)) disk").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Text(time(row)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func time(_ row: MachineRow) -> String {
        guard row.lease.state == .ready else { return row.lease.state.rawValue }
        // A container held until it is released has no end.
        let left = row.lease.expires.timeIntervalSince(monitor.now)
        return left > 365 * 86400 ? "until released" : Format.minutes(left) + " left"
    }

    private func cpu(_ row: MachineRow) -> String {
        guard let percent = row.usage?.cpuPercent else { return "—" }
        let cpus = row.usage?.cpus ?? row.lease.cpus
        return cpus.map { "\(Format.cores(percent)) of \($0) cores" } ?? "\(Format.cores(percent)) cores"
    }

    private func memory(_ row: MachineRow) -> String {
        guard let bytes = row.usage?.memoryBytes else { return "—" }
        let limit = row.usage?.memoryLimitBytes ?? row.lease.memoryLimitBytes
        return limit.map { "\(Format.bytes(bytes)) of \(Format.bytes($0))" } ?? Format.bytes(bytes)
    }
}

// MARK: - The disk

@available(macOS 15, iOS 18, *)
struct DiskCard: View {
    let disk: DiskUsage
    var day: [UsageSample] = []
    var volumes: [VolumeInfo] = []

    var body: some View {
        Card("Disk", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                let samples = day.filter { $0.diskBytes != nil }
                if samples.count > 1 {
                    DiskHistoryChart(samples: samples).frame(height: 60)
                    HStack(spacing: 14) {
                        Legend(color: .orange, text: "Used")
                        Legend(color: .accentColor, text: "OS Server's")
                        Text("the last \(Format.span(samples))").font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                ForEach(disk.parts) { part in
                    Row(part.name, Format.bytes(part.bytes))
                }
                if !volumes.isEmpty {
                    Text("Volumes").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                    ForEach(volumes) { volume in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(volume.name).lineLimit(1).truncationMode(.middle)
                                Text(volume.lease.map { "lease \($0)" } ?? "kept, no lease using it")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Format.bytes(volume.allocatedBytes)) of \(Format.bytes(volume.sizeBytes))")
                                .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if !disk.parts.isEmpty {
                    Text("OS Server's files as allocated: a clone counts whole, though it shares its blocks.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The disk over the server's last day: all of it used, and OS Server's
/// files. Drawn between the day's least and most, so a day's change shows
/// on a disk of terabytes; the scale's ends are written beside it.
@available(macOS 15, iOS 18, *)
struct DiskHistoryChart: View {
    let samples: [UsageSample]

    private static func used(_ sample: UsageSample) -> Int64? {
        guard let total = sample.diskBytes, let free = sample.diskFreeBytes else { return nil }
        return total - free
    }

    var body: some View {
        let values = samples.flatMap { [Self.used($0), $0.ourDiskBytes].compactMap { $0 } }
        let low = values.min() ?? 0, high = values.max() ?? 1
        // A little room above and below, and never a zero range.
        let margin = max((high - low) / 10, 1 << 30)
        let bottom = max(0, low - margin), top = high + margin
        HStack(alignment: .top, spacing: 6) {
            Canvas { context, size in
                guard let first = samples.first?.date, let last = samples.last?.date else { return }
                let span = max(1, last.timeIntervalSince(first))
                func line(_ value: (UsageSample) -> Int64?) -> Path {
                    var path = Path()
                    var started = false
                    for sample in samples {
                        guard let value = value(sample) else { continue }
                        let fraction = Double(value - bottom) / Double(max(1, top - bottom))
                        let point = CGPoint(x: size.width * sample.date.timeIntervalSince(first) / span,
                                            y: size.height * (1 - min(1, max(0, fraction))))
                        if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                    }
                    return path
                }
                context.stroke(line(Self.used), with: .color(.orange), lineWidth: 1.8)
                context.stroke(line(\.ourDiskBytes), with: .color(.accentColor), lineWidth: 1.8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
            VStack(alignment: .trailing) {
                Text(Format.bytes(top))
                Spacer()
                Text(Format.bytes(bottom))
            }
            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Everyone else

@available(macOS 15, iOS 18, *)
struct OthersCard: View {
    let processes: [ProcessUsage]

    var body: some View {
        Card("Other apps", systemImage: "app.badge") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Text("Memory")
                    Text("Cores").frame(width: 44, alignment: .trailing)
                }
                .font(.caption2).foregroundStyle(.secondary)
                ForEach(processes) { process in
                    HStack {
                        Text(process.name).lineLimit(1)
                        if process.processes > 1 {
                            Text("\(process.processes)").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).background(Capsule().fill(Color.gray.opacity(0.15)))
                        }
                        Spacer()
                        Text(Format.bytes(process.memoryBytes)).monospacedDigit()
                        Text(Format.cores(process.cpuPercent)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Capacity and the cache

@available(macOS 15, iOS 18, *)
struct CapacityCard: View {
    let status: Status

    var body: some View {
        Card("Capacity", systemImage: "rectangle.stack") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(status.capacity, id: \.platform) { capacity in
                    HStack(spacing: 8) {
                        Image(systemName: Format.symbol(capacity.platform)).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Format.platform(capacity.platform))
                            let configs = status.bases.filter { $0.platform == capacity.platform }.map(\.config)
                            if !configs.isEmpty {
                                Text(configs.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(capacity.leased) of \(capacity.limit)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

@available(macOS 15, iOS 18, *)
struct CacheCard: View {
    let cache: CacheInfo

    var body: some View {
        Card("Bazel cache", systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 8) {
                ShareRow(title: "Size", total: Format.bytes(cache.maxBytes),
                         ours: Double(cache.bytes) / Double(max(1, cache.maxBytes)), others: 0,
                         labels: (Format.bytes(cache.bytes), "", Format.bytes(max(0, cache.maxBytes - cache.bytes))),
                         oursName: "Used", othersName: nil)
                let lookups = cache.hits + cache.misses
                Row("Hits", lookups > 0
                    ? "\(cache.hits.formatted()) of \(lookups.formatted()) (\(Int((Double(cache.hits) / Double(lookups) * 100).rounded()))%)"
                    : "none yet")
                Row("Written", cache.writes.formatted())
            }
        }
    }
}

// MARK: - Pieces

/// A label and its value at the row's end, the same on every platform
/// (outside a Form, a Mac sets LabeledContent's value beside its label).
struct Row: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// A titled panel.
struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.1)))
    }
}

public enum Format {
    public static func bytes(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1000 { return String(format: "%.1f TB", gigabytes / 1024) }
        if gigabytes >= 10 { return String(format: "%.0f GB", gigabytes) }
        return String(format: "%.1f GB", gigabytes)
    }

    public static func cores(_ percent: Double) -> String {
        String(format: "%.1f", percent / 100)
    }

    /// How long the samples cover: "24 h", "35 min".
    public static func span(_ samples: [UsageSample]) -> String {
        guard let first = samples.first?.date, let last = samples.last?.date else { return "" }
        let minutes = Int((last.timeIntervalSince(first) / 60).rounded())
        return minutes >= 120 ? "\(Int((Double(minutes) / 60).rounded())) h" : "\(minutes) min"
    }

    public static func minutes(_ seconds: TimeInterval) -> String {
        "\(max(0, Int((seconds / 60).rounded()))) min"
    }

    public static func platform(_ platform: Platform) -> String {
        switch platform {
        case .macos: "macOS"
        case .ios: "iOS"
        case .android: "Android"
        case .linux: "Linux"
        case .windows: "Windows"
        case .container: "Container"
        }
    }

    public static func symbol(_ platform: Platform) -> String {
        switch platform {
        case .macos: "laptopcomputer"
        case .ios: "iphone"
        case .android: "candybarphone"
        case .linux: "server.rack"
        case .windows: "pc"
        case .container: "shippingbox"
        }
    }
}

/// The Mac's CPU, memory and disk split three ways, and the other apps
/// using the most: what OS Server's own window shows above its leases.
@available(macOS 15, iOS 18, *)
public struct UsageOverview: View {
    let monitor: ServerMonitor

    public init(monitor: ServerMonitor) {
        self.monitor = monitor
    }

    public var body: some View {
        if let usage = monitor.usage {
            VStack(alignment: .leading, spacing: 16) {
                ResourcesCard(usage: usage, history: monitor.history)
                HStack(alignment: .top, spacing: 16) {
                    if let disk = usage.disk { DiskCard(disk: disk, day: monitor.day, volumes: monitor.volumes) }
                    if let top = usage.topProcesses, !top.isEmpty { OthersCard(processes: top) }
                }
            }
        }
    }
}
