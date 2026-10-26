import AppKit
import Observation
import OSSServer
import SwiftUI
import UniformTypeIdentifiers

/// What OS Server lends, a component at a time (`Components`): its state,
/// asked every couple of seconds while shown.
@MainActor @Observable
final class ComponentsModel {
    static let shared = ComponentsModel()

    private(set) var list: [ComponentInfo] = []
    var message: String?

    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        list = Fixture.isOn ? Fixture.components : await Components.shared.list()
    }

    func install(_ id: String, file: String? = nil) async {
        guard !Fixture.isOn else { return }
        await Components.shared.install(id, file: file)
        await refresh()
    }

    func remove(_ id: String) async {
        guard !Fixture.isOn else { return }
        do { try await Components.shared.remove(id) } catch { message = "\(error)" }
        await refresh()
    }

    /// Whether this Mac lends anything yet (onboarding shows until it does).
    var nothingInstalled: Bool { !list.isEmpty && !list.contains { $0.state == .installed } }
}

/// The components, each with its state and what can be done with it.
struct ComponentsList: View {
    @State private var model = ComponentsModel.shared
    /// Onboarding's: checkboxes for what isn't installed, installed together.
    var choosing: Binding<Set<String>>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.list) { component in
                ComponentRow(component: component, model: model, choosing: choosing)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await model.watch() }
    }
}

struct ComponentRow: View {
    let component: ComponentInfo
    let model: ComponentsModel
    var choosing: Binding<Set<String>>?
    @State private var confirmingRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let choosing, component.state == .absent {
                Toggle("", isOn: Binding(get: { choosing.wrappedValue.contains(component.id) },
                                         set: { on in if on { choosing.wrappedValue.insert(component.id) } else { choosing.wrappedValue.remove(component.id) } }))
                    .labelsHidden().toggleStyle(.checkbox)
            }
            Image(systemName: component.symbol).font(.title3).frame(width: 26).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(component.name).font(.body.weight(.medium))
                Text(component.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                status
            }
            Spacer(minLength: 8)
            if choosing == nil { actions }
        }
        .confirmationDialog("Remove \(component.name)?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { Task { await model.remove(component.id) } }
        } message: {
            Text("What it installed is deleted. Install it again whenever you like.")
        }
    }

    @ViewBuilder private var status: some View {
        switch component.state {
        case .installed: Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .installing(let line):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .unavailable(let why): Text(why.prefix(1).capitalized + why.dropFirst()).font(.caption).foregroundStyle(.orange)
        case .failed(let why): Text("Failed: \(why)").font(.caption).foregroundStyle(.red).lineLimit(3)
        case .absent: EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        switch component.state {
        case .installed:
            Button("Remove…") { confirmingRemoval = true }
        case .absent, .failed:
            HStack {
                if !component.accepts.isEmpty {
                    Button("From a File…") { pickFile() }
                }
                Button("Install") { Task { await model.install(component.id) } }
            }
        case .installing, .unavailable:
            EmptyView()
        }
    }

    /// An image of your own to install from (an .ipsw, a cloud image).
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = component.accepts.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.install(component.id, file: url.path) }
    }
}

/// Settings › Components.
struct ComponentsSection: View {
    var body: some View {
        Section {
            ComponentsList()
        } header: {
            Text("Components")
        } footer: {
            Text("Each is installed from a download, or an image you give it, into OS Server's folder, and removed on its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The first launch: what should this Mac lend? Checked components are
/// installed together; the window goes once one is in, or when told.
struct SetUpView: View {
    @State private var model = ComponentsModel.shared
    @State private var chosen: Set<String> = ["containers", "linux", "android", "ios"]
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set Up OS Server").font(.title2.weight(.semibold))
                    Text("Choose what this Mac lends. Each is downloaded and set up with no one at its screen; add or remove any later in Settings.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ComponentsList(choosing: $chosen)
            HStack {
                Spacer()
                Button("Later") {
                    UserDefaults.standard.set(true, forKey: "setUpShown")
                    dismissWindow(id: "setup")
                }
                Button("Install") {
                    UserDefaults.standard.set(true, forKey: "setUpShown")
                    let ids = model.list.filter { chosen.contains($0.id) && $0.state == .absent }.map(\.id)
                    Task { for id in ids { await model.install(id) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.list.contains { chosen.contains($0.id) && $0.state == .absent })
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}
