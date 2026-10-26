import OSSClient
import OSSMonitorKit
import SwiftUI

/// OS Monitor: OS Server's client, as Visor is Visor Server's. Each server
/// added (from the connection code in OS Server's Settings) is watched from
/// wherever this is: what the Mac's CPU, memory and disk go to (OS Server
/// and the machines it lends, everyone else, what's free), what's running,
/// its capacity and its files. It reads, and can do nothing else.
@main
struct MonitorApp: App {
    @State private var store = MonitorStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onOpenURL { store.add($0.absoluteString) }
                .modifier(FixtureAppearance())
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 860)
        #endif
    }
}

struct RootView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var adding = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(store.monitors) { monitor in
                    ServerRow(monitor: monitor).tag(monitor.id)
                        .contextMenu {
                            Button("Remove", role: .destructive) { store.remove(monitor) }
                        }
                }
                .onDelete { offsets in offsets.map { store.monitors[$0] }.forEach(store.remove) }
                if store.monitors.isEmpty {
                    Text("Add an OS Server with the code in its Settings (OS Monitor).")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("OS Monitor")
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
            .toolbar {
                ToolbarItem {
                    Button { adding = true } label: { Label("Add Server", systemImage: "plus") }
                }
            }
        } detail: {
            if let monitor = store.monitors.first(where: { $0.id == store.selection }) {
                ServerScreen(monitor: monitor)
            } else {
                ContentUnavailableView("Pick a server", systemImage: "gauge.with.dots.needle.50percent",
                                       description: Text("What its Mac's CPU, memory and disk go to, and what's running on it."))
            }
        }
        .sheet(isPresented: $adding) { AddServerView() }
        #if os(macOS)
        // A Mac's window opens on a server rather than an empty pane.
        .onAppear { if store.selection == nil { store.selection = store.monitors.first?.id } }
        #endif
        // Every server watched while the app is in front (the list's rows
        // show each one's CPU and memory), and again when one is added.
        .task(id: "\(phase) \(store.monitors.map(\.id))") {
            guard phase == .active, !store.isFixture else { return }
            await withTaskGroup(of: Void.self) { group in
                for monitor in store.monitors { group.addTask { await monitor.watch() } }
            }
        }
    }
}

/// A server in the list: its name, where it answers, and its CPU and
/// memory in a line.
struct ServerRow: View {
    let monitor: ServerMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(monitor.connection.name).font(.headline)
            }
            if let host = monitor.usage?.host {
                Text("CPU \(Format.cores(host.cpuPercent)) of \(host.cpus) · memory \(Format.bytes(host.memoryUsedBytes)) of \(Format.bytes(host.memoryBytes))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                let leased = monitor.status?.leases.count ?? 0
                Text(leased == 0 ? "Nothing leased" : leased == 1 ? "1 machine leased" : "\(leased) machines leased")
                    .font(.caption).foregroundStyle(.secondary)
            } else if case .failed = monitor.state {
                Text("Not reachable").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch monitor.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        }
    }
}

struct ServerScreen: View {
    let monitor: ServerMonitor

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let capabilities = monitor.capabilities {
                        // Digits all one width: a new version moves nothing after it.
                        Text(subtitle(capabilities)).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ServerDashboard(monitor: monitor)
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .task {
                // The proof's shot of one card (`-fixture.scroll disk`): the same every run, as a swipe's isn't.
                guard monitor.isFixture, let card = UserDefaults.standard.string(forKey: "fixture.scroll") else { return }
                try? await Task.sleep(for: .milliseconds(500))
                proxy.scrollTo(card, anchor: .top)
            }
        }
        .navigationTitle(monitor.connection.name)
        .refreshable { await monitor.refresh() }
    }

    private func subtitle(_ capabilities: Capabilities) -> String {
        var parts = ["OS Server \(capabilities.version)"]
        if case .connected(let url) = monitor.state, let host = url.host { parts.append("at \(host)") }
        if let updated = monitor.updated, !monitor.isFixture {
            parts.append("updated \(updated.formatted(date: .omitted, time: .standard))")
        }
        return parts.joined(separator: " · ")
    }
}

struct AddServerView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("osmonitor://connect?code=…", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.footnote.monospaced())
                    Button("Paste") { text = Clipboard.string ?? "" }
                } footer: {
                    Text("In OS Server, Settings › OS Monitor › Copy Code; then paste it here (or open its link on this device). The code reads what the server is doing and can do nothing else.")
                }
                if let problem = store.problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { if store.add(text) { dismiss() } }.disabled(text.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 300)
        #endif
    }
}

enum Clipboard {
    static var string: String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

/// The proof's screens in the look they ask for (`-appearance light|dark`).
struct FixtureAppearance: ViewModifier {
    func body(content: Content) -> some View {
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": content.preferredColorScheme(.light)
        case "dark": content.preferredColorScheme(.dark)
        default: content
        }
    }
}
