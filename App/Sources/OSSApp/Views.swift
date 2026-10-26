import OSSClient
import OSSMonitorKit
import OSSServer
import SwiftUI

// MARK: - The window

struct MainView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(ServerRunner.self) private var server

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ServerHeader()
                if let error = monitor.error, monitor.usage == nil {
                    Text(error).foregroundStyle(.secondary)
                }
                // The Mac's CPU, memory and disk, OS Server's share beside
                // everyone else's: what OS Monitor shows of this server.
                if let watcher = AppModel.shared.watcher, watcher.usage != nil {
                    UsageOverview(monitor: watcher)
                } else {
                    HostSection()
                }
                MachinesSection()
                HStack(alignment: .top, spacing: 18) {
                    CapacitySection()
                    CacheSection()
                }
                LogSection()
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 780, minHeight: 680)
    }
}

struct ServerHeader: View {
    @Environment(Monitor.self) private var monitor
    @Environment(ServerRunner.self) private var server

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StateDot(state: server.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            switch server.state {
            case .running, .starting:
                EmptyView()
            case .elsewhere:
                Button("Run It Here Instead") { Task { await server.takeOver() } }
            case .stopped, .failed:
                Button("Start") { Task { await server.start() } }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var port: Int { ServerSettings.load().port }

    private var title: String {
        switch server.state {
        case .running: "Serving on port \(port)"
        case .starting: "Starting…"
        case .elsewhere: "Another server answers on port \(port)"
        case .stopped: "Stopped"
        case .failed: "The server stopped"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let capabilities = monitor.capabilities { parts.append("OS Server \(capabilities.version), API \(capabilities.api)") }
        switch server.state {
        case .running(let since):
            parts.append("up \(Format.duration(monitor.now.timeIntervalSince(since)))")
        case .elsewhere:
            parts.append(FileManager.default.fileExists(atPath: ServerRunner.launchAgent.path)
                         ? "the launch agent's (oss.server), from before 0.7" : "run outside this app")
        case .failed(let message):
            parts.append(message)
        default:
            break
        }
        if let host = monitor.usage?.host.name { parts.append(host) }
        return parts.joined(separator: " · ")
    }
}

struct StateDot: View {
    var state: ServerRunner.State

    var body: some View {
        Circle().fill(color).frame(width: 12, height: 12)
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .starting, .elsewhere: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }
}

struct HostSection: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        GroupBox {
            if let host = monitor.usage?.host {
                VStack(alignment: .leading, spacing: 12) {
                    MeterRow(title: "CPU", value: "\(Format.cores(host.cpuPercent)) of \(host.cpus) cores",
                             fraction: host.cpuPercent / Double(max(1, host.cpus) * 100), tint: .blue)
                    MeterRow(title: "Memory", value: "\(Format.bytes(host.memoryUsedBytes)) of \(Format.bytes(host.memoryBytes))",
                             fraction: Double(host.memoryUsedBytes) / Double(max(1, host.memoryBytes)), tint: .purple)
                    Sparkline(history: monitor.history).frame(height: 54)
                }
                .padding(6)
            } else {
                Text("No measurements yet.").foregroundStyle(.secondary).padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("This Mac", systemImage: "desktopcomputer")
        }
    }
}

struct MachinesSection: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GroupBox {
            let rows = monitor.machines
            if rows.isEmpty {
                Text("Nothing is leased.").foregroundStyle(.secondary).padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Machine"); Text("Holder"); Text("CPU"); Text("Memory"); Text("Disk"); Text("Time left"); Text("")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GridRow {
                            HStack(spacing: 8) {
                                Image(systemName: Format.symbol(row.lease.platform)).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(Format.platform(row.lease.platform)) · \(row.lease.config)")
                                    Text(row.lease.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            Text(row.lease.holder).lineLimit(1)
                            UsageCell(text: cpuText(row), fraction: cpuFraction(row), tint: .blue)
                            UsageCell(text: memoryText(row), fraction: memoryFraction(row), tint: .purple)
                            Text(row.usage?.diskBytes.map(Format.bytes) ?? "—").monospacedDigit()
                            Text(timeText(row)).monospacedDigit()
                            // A VM of OS Server's own: its screen, live (a macOS
                            // VM's in its helper's window, or this app's for one
                            // run here; a Linux or Windows VM's QEMU in the app's).
                            if MacVMs.names.contains(row.lease.name) {
                                Button("Screen") { openWindow(id: "screen", value: row.lease.name) }
                            } else if MachineScreens.isOwn(row.lease) {
                                Button("Screen") { Task { await MachineScreens.showInHelper(row.lease.name) } }
                            } else if let port = row.lease.qemuVNCPort {
                                Button("Screen") { openWindow(id: "guest-screen", value: GuestScreenTarget(name: row.lease.name, port: port)) }
                            } else {
                                Text("")
                            }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("Leases", systemImage: "square.stack.3d.up")
        }
    }

    private func timeText(_ row: MachineRow) -> String {
        guard row.lease.state == .ready else { return row.lease.state.rawValue }
        // A container held until it is released has no end.
        let left = row.lease.expires.timeIntervalSince(monitor.now)
        return left > 365 * 86400 ? "until released" : Format.minutes(left)
    }

    private func cpuText(_ row: MachineRow) -> String {
        guard let percent = row.usage?.cpuPercent else { return "—" }
        let cpus = row.usage?.cpus ?? row.lease.cpus
        return cpus.map { "\(Format.cores(percent)) of \($0)" } ?? Format.cores(percent)
    }

    private func cpuFraction(_ row: MachineRow) -> Double? {
        guard let percent = row.usage?.cpuPercent, let cpus = row.usage?.cpus ?? row.lease.cpus, cpus > 0 else { return nil }
        return percent / Double(cpus * 100)
    }

    private func memoryText(_ row: MachineRow) -> String {
        guard let bytes = row.usage?.memoryBytes else { return "—" }
        let limit = row.usage?.memoryLimitBytes ?? row.lease.memoryLimitBytes
        guard let limit else { return Format.bytes(bytes) }
        // "9.0 of 16.0 GB": one unit, so the column stays one line beside the disk's.
        let used = Format.bytes(bytes), of = Format.bytes(limit)
        if used.hasSuffix(" GB"), of.hasSuffix(" GB") { return "\(used.dropLast(3)) of \(of)" }
        return "\(used) of \(of)"
    }

    private func memoryFraction(_ row: MachineRow) -> Double? {
        guard let bytes = row.usage?.memoryBytes, let limit = row.usage?.memoryLimitBytes ?? row.lease.memoryLimitBytes, limit > 0
        else { return nil }
        return Double(bytes) / Double(limit)
    }
}

struct CapacitySection: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(monitor.status?.capacity ?? [], id: \.platform) { capacity in
                    HStack(spacing: 8) {
                        Image(systemName: Format.symbol(capacity.platform)).frame(width: 18)
                        Text(Format.platform(capacity.platform))
                        Spacer()
                        Text("\(capacity.leased) of \(capacity.limit)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    let configs = (monitor.status?.bases ?? []).filter { $0.platform == capacity.platform }.map(\.config)
                    if !configs.isEmpty {
                        Text(configs.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Capacity", systemImage: "rectangle.stack")
        }
    }
}

struct CacheSection: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        GroupBox {
            if let cache = monitor.cache {
                VStack(alignment: .leading, spacing: 10) {
                    MeterRow(title: "Size", value: "\(Format.bytes(cache.bytes)) of \(Format.bytes(cache.maxBytes))",
                             fraction: Double(cache.bytes) / Double(max(1, cache.maxBytes)), tint: .orange)
                    let lookups = cache.hits + cache.misses
                    LabeledContent("Hits", value: lookups > 0
                                   ? "\(cache.hits.formatted()) of \(lookups.formatted()) (\(Int((Double(cache.hits) / Double(lookups) * 100).rounded()))%)"
                                   : "none yet")
                    LabeledContent("Written", value: cache.writes.formatted())
                    LabeledContent("Let go", value: cache.evicted.formatted())
                    LabeledContent("Free on the disk", value: Format.bytes(cache.freeBytes))
                }
                .padding(6)
            } else {
                Text("This server keeps no Bazel cache.").foregroundStyle(.secondary).padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("Bazel cache", systemImage: "externaldrive")
        }
    }
}

struct LogSection: View {
    @Environment(ServerRunner.self) private var server

    var body: some View {
        GroupBox {
            ScrollView {
                Text(server.lines.suffix(200).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 140)
            .padding(6)
        } label: {
            Label("Log", systemImage: "text.alignleft")
        }
    }
}

// MARK: - Pieces

struct MeterRow: View {
    var title: String
    var value: String
    var fraction: Double
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            Meter(fraction: fraction, tint: tint)
        }
    }
}

struct UsageCell: View {
    var text: String
    var fraction: Double?
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).monospacedDigit()
            if let fraction { Meter(fraction: fraction, tint: tint).frame(width: 110) }
        }
    }
}

/// A bar: the share used; orange past what was given (a VM's process
/// counts its own overhead beside the guest's memory), red well past it.
struct Meter: View {
    var fraction: Double
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(fraction > 1.25 ? .red : fraction > 1 ? .orange : tint)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
    }
}

struct Sparkline: View {
    var history: [Monitor.Sample]

    var body: some View {
        Canvas { context, size in
            guard history.count > 1 else { return }
            for (key, color) in [(\Monitor.Sample.cpuFraction, Color.blue), (\Monitor.Sample.memoryFraction, Color.purple)] {
                var path = Path()
                for (i, sample) in history.enumerated() {
                    let point = CGPoint(x: size.width * Double(i) / Double(history.count - 1),
                                        y: size.height * (1 - min(1, max(0, sample[keyPath: key]))))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.quinary))
    }
}

enum Format {
    static func bytes(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return gigabytes >= 1000 ? String(format: "%.1f TB", gigabytes / 1024) : String(format: "%.1f GB", gigabytes)
    }

    static func cores(_ percent: Double) -> String {
        String(format: "%.1f", percent / 100)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        "\(max(0, Int((seconds / 60).rounded()))) min"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func platform(_ platform: Platform) -> String {
        switch platform {
        case .macos: "macOS"
        case .ios: "iOS"
        case .android: "Android"
        case .linux: "Linux"
        case .windows: "Windows"
        case .container: "Container"
        }
    }

    static func symbol(_ platform: Platform) -> String {
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

// MARK: - The menu bar

struct MenuBarLabel: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let count = monitor.status?.leases.count ?? 0
        // The leases' count beside the icon (a Label shows the icon alone there).
        if count > 0 {
            Label("\(count)", systemImage: "square.stack.3d.up.fill").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "square.stack.3d.up")
        }
    }
}

struct MenuBarView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(ServerRunner.self) private var server
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StateDot(state: server.state)
                Text(stateText).font(.headline)
                Spacer()
            }
            if let host = monitor.usage?.host {
                MeterRow(title: "CPU", value: "\(Format.cores(host.cpuPercent)) of \(host.cpus) cores",
                         fraction: host.cpuPercent / Double(max(1, host.cpus) * 100), tint: .blue)
                MeterRow(title: "Memory", value: "\(Format.bytes(host.memoryUsedBytes)) of \(Format.bytes(host.memoryBytes))",
                         fraction: Double(host.memoryUsedBytes) / Double(max(1, host.memoryBytes)), tint: .purple)
            }
            Divider()
            let rows = monitor.machines
            if rows.isEmpty {
                Text("Nothing is leased.").foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: Format.symbol(row.lease.platform)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Format.platform(row.lease.platform)) · \(row.lease.config)").lineLimit(1)
                            Text(row.lease.holder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(row.usage?.cpuPercent.map { "\(Format.cores($0)) cores" } ?? "—")
                            Text(row.usage?.memoryBytes.map(Format.bytes) ?? "—").foregroundStyle(.secondary)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
            }
            Divider()
            HStack {
                Button("Open OS Server") { AppActivation.showWindow(openWindow) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var stateText: String {
        switch server.state {
        case .running: "Serving on port \(ServerSettings.load().port)"
        case .starting: "Starting…"
        case .elsewhere: "Another server is running"
        case .stopped: "Stopped"
        case .failed: "The server stopped"
        }
    }
}
