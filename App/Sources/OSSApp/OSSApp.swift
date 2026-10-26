import AppKit
import OSSClient
import OSSMonitorKit
import OSSServer
import ServiceManagement
import SwiftUI

/// The app, or with `--headless` the server alone: no window, no menu bar,
/// its log on standard error (to try a change beside the running app, with
/// an `OSS_HOME` of its own and another port).
@main
enum Entry {
    static func main() {
        guard CommandLine.arguments.contains("--headless") else { return OSSApp.main() }
        var containers: ContainerBackend?
        if #available(macOS 26, *) { containers = ContainerEngine() }
        do {
            _ = try ServerHost.start(containers: containers)
        } catch {
            FileHandle.standardError.write(Data("OS Server: \(error)\n".utf8))
            exit(1)
        }
        dispatchMain()
    }
}

/// OS Server, the app: it is the server (the API, the machines it lends,
/// its Bazel cache, all in this process), shows what the Mac and each
/// lease use, and stays in the menu bar with its window closed (no Dock
/// icon then). Its macOS VMs run headless; any of them can be watched live
/// in a window of its own.
struct OSSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("OS Server", id: "main") {
            MainView()
                .environment(AppModel.shared.monitor)
                .environment(AppModel.shared.server)
                .onAppear { AppActivation.windowShown() }
                .onDisappear { AppActivation.windowClosed() }
        }
        // Taller with the canned server, so its screen holds everything.
        .defaultSize(width: 860, height: Fixture.isOn ? 1110 : 760)
        .defaultLaunchBehavior(Fixture.showsPanel || Fixture.showsSetUp ? .suppressed : .presented)

        // A macOS VM's screen, live (by the machine's name).
        WindowGroup("Screen", id: "screen", for: String.self) { $name in
            if let name {
                MachineScreen(name: name)
                    .onAppear { AppActivation.windowShown() }
            }
        }
        .defaultSize(width: 1280, height: 820)

        // The menu bar's panel in a window of its own, for the proof's
        // screen of it (`-fixture -panel`): the same view, no clicking.
        Window("OS Server menu", id: "panel") {
            MenuBarView()
                .environment(AppModel.shared.monitor)
                .environment(AppModel.shared.server)
                .background(.regularMaterial)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Fixture.showsPanel ? .presented : .suppressed)

        MenuBarExtra {
            MenuBarView()
                .environment(AppModel.shared.monitor)
                .environment(AppModel.shared.server)
        } label: {
            MenuBarLabel().environment(AppModel.shared.monitor)
        }
        .menuBarExtraStyle(.window)

        // The first launch's: what should this Mac lend?
        Window("Set Up OS Server", id: "setup") {
            SetUpView().onAppear { AppActivation.windowShown() }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Fixture.showsSetUp || (!Fixture.isOn && !UserDefaults.standard.bool(forKey: "setUpShown")) ? .presented : .suppressed)

        Settings {
            SettingsView().environment(AppModel.shared.server)
        }
    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    @ObservationIgnored let monitor = Monitor()
    @ObservationIgnored let server = ServerRunner()
    /// This server as OS Monitor sees it (its usage split three ways),
    /// asked through its own monitor token once it serves.
    var watcher: ServerMonitor?
    /// Set while removing everything: the quit that ends it asks nothing.
    var quitting = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        if Fixture.isOn {
            if let appearance = Fixture.appearance { NSApp.appearance = NSAppearance(named: appearance) }
            Fixture.apply(to: model.monitor, server: model.server)
            model.watcher = MonitorFixture.monitor(name: "Mac Studio")
            // Written again as the windows settle (the proof reads the last).
            Task {
                for _ in 0..<4 {
                    try? await Task.sleep(for: .seconds(2))
                    Fixture.writeWindowFrames()
                }
            }
            return
        }
        Task {
            await model.server.start()
            guard case .running = model.server.state else { return }
            var connection = MonitorAccess.connection()
            connection.servers = [URL(string: "http://127.0.0.1:\(ServerSettings.load().port)")!]
            let watcher = ServerMonitor(connection: connection)
            model.watcher = watcher
            await watcher.watch()
        }
        Task { await model.monitor.run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The macOS VMs run in this process: quitting ends their leases, so it
    /// asks first while any runs. (The other machines' leases are kept, and
    /// taken up again at the next launch.)
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MacVMs.names.filter { $0.hasPrefix("oss-lease-") }
        guard !running.isEmpty, !Fixture.isOn, !AppModel.shared.quitting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "A macOS machine is leased" : "\(running.count) macOS machines are leased"
        alert.informativeText = "Its VM runs in OS Server: quitting ends the lease, and whoever holds it loses the machine."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// The Dock icon while a window is open, the menu bar alone without one.
@MainActor
enum AppActivation {
    static func windowShown() {
        NSApp.setActivationPolicy(.regular)
    }

    static func windowClosed() {
        // Another window (a VM's screen) still open: the Dock icon stays.
        let open = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !$0.className.contains("StatusBar") }
        if open.count <= 1 { NSApp.setActivationPolicy(.accessory) }
    }

    static func showWindow(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Opening at login, as macOS keeps it for the app itself (no launch agent).
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func unregister() async throws {
        guard SMAppService.mainApp.status == .enabled else { return }
        try await SMAppService.mainApp.unregister()
    }
}

struct SettingsView: View {
    @Environment(ServerRunner.self) private var server
    @State private var openAtLogin = LoginItem.isOn
    @State private var message: String?
    @State private var confirmingRemoval = false
    @State private var removeUTMMachines = true

    var body: some View {
        Form {
            Toggle("Open at Login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        try LoginItem.set(on)
                    } catch {
                        message = "\(error.localizedDescription)"
                        openAtLogin = LoginItem.isOn
                    }
                }
            LabeledContent("Command line tool") {
                Button("Install in ~/.local/bin") { installCommandLineTool() }
            }
            LabeledContent("Its files", value: "~/Library/Application Support/OS Server")
            LabeledContent("Log", value: "~/Library/Logs/OS Server.log")
            ComponentsSection()
            MonitorSection()
            Section {
                Toggle("UTM's oss machines too (its Linux and Windows bases)", isOn: $removeUTMMachines)
                Button("Remove Everything…", role: .destructive) { confirmingRemoval = true }
            } footer: {
                Text("Ends every lease and deletes what OS Server keeps on this Mac: its machines, settings, log, command line and login item. Then it quits; move the app to the Trash to finish.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .confirmationDialog("Remove everything OS Server keeps on this Mac?", isPresented: $confirmingRemoval) {
            Button("Remove Everything", role: .destructive) {
                AppModel.shared.quitting = true
                Task { await server.removeEverything(includingUTMMachines: removeUTMMachines) }
            }
        } message: {
            Text("Every lease ends now, and the machines' bases are deleted. This can't be undone.")
        }
    }

    /// ~/.local/bin/oss, a link to the app's own: the command line and the
    /// server are the same version.
    private func installCommandLineTool() {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let link = bin.appendingPathComponent("oss")
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            if (try? link.checkResourceIsReachable()) == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: server.commandLine)
            message = "~/.local/bin/oss is the app's."
        } catch {
            message = "\(error.localizedDescription)"
        }
    }
}
