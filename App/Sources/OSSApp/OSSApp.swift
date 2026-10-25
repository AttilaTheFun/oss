import AppKit
import ServiceManagement
import SwiftUI

/// oss, the app: runs the server (its helper, the `oss` binary), shows what
/// the Mac and each lease use, and stays in the menu bar with its window
/// closed (no Dock icon then).
@main
struct OSSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("oss", id: "main") {
            MainView()
                .environment(AppModel.shared.monitor)
                .environment(AppModel.shared.server)
                .onAppear { AppActivation.windowShown() }
                .onDisappear { AppActivation.windowClosed() }
        }
        // Taller with the canned server, so its screen holds everything.
        .defaultSize(width: 860, height: Fixture.isOn ? 1110 : 760)
        .defaultLaunchBehavior(Fixture.showsPanel ? .suppressed : .presented)

        // The menu bar's panel in a window of its own, for the proof's
        // screen of it (`-fixture -panel`): the same view, no clicking.
        Window("oss menu", id: "panel") {
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

        Settings {
            SettingsView().environment(AppModel.shared.server)
        }
    }
}

@MainActor
final class AppModel {
    static let shared = AppModel()

    let monitor = Monitor()
    let server: ServerSupervisor

    private init() {
        // The server's binary inside the app (build.sh puts it there); the
        // `swift run` of a development build finds it beside its own.
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/oss")
        let beside = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("oss")
        server = ServerSupervisor(helper: FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : (beside ?? bundled))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        if Fixture.isOn {
            if let appearance = Fixture.appearance { NSApp.appearance = NSAppearance(named: appearance) }
            Fixture.apply(to: model.monitor, supervisor: model.server)
            // Written again as the windows settle (the proof reads the last).
            Task {
                for _ in 0..<4 {
                    try? await Task.sleep(for: .seconds(2))
                    Fixture.writeWindowFrames()
                }
            }
            return
        }
        Task { await model.server.start() }
        Task { await model.monitor.run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting stops the server it runs (its leases are kept, and taken up
    /// again when oss starts).
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let server = AppModel.shared.server
        guard case .running = server.state, !Fixture.isOn else { return .terminateNow }
        server.stop()
        Task {
            for _ in 0..<50 {
                if case .running = server.state { try? await Task.sleep(for: .milliseconds(100)) } else { break }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The Dock icon while the window is open, the menu bar alone without it.
@MainActor
enum AppActivation {
    static func windowShown() {
        NSApp.setActivationPolicy(.regular)
    }

    static func windowClosed() {
        NSApp.setActivationPolicy(.accessory)
    }

    static func showWindow(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }
}

struct SettingsView: View {
    @Environment(ServerSupervisor.self) private var server
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var message: String?

    var body: some View {
        Form {
            Toggle("Open at Login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        message = "\(error.localizedDescription)"
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            LabeledContent("Command line tool") {
                Button("Install in ~/.local/bin") { installCommandLineTool() }
            }
            LabeledContent("Server log", value: "~/Library/Logs/oss.log")
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
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
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: server.helper)
            message = "~/.local/bin/oss is the app's."
        } catch {
            message = "\(error.localizedDescription)"
        }
    }
}
