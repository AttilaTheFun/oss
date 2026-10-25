import OSSServer
import SwiftUI
import Virtualization

/// A macOS VM's screen, live: Virtualization's own view of the machine
/// this process runs (a lease's, or a base being built). Clicks and keys go
/// to the guest while the window has focus. The display keeps the size the
/// machine was made with (the screenshots a lease's holder takes stay that
/// size), scaled to the window.
struct MachineScreen: View {
    let name: String

    var body: some View {
        Group {
            if let machine = MacVMs.virtualMachine(named: name) {
                VirtualMachineView(machine: machine)
            } else {
                ContentUnavailableView("\(name) isn't running", systemImage: "display.trianglebadge.exclamationmark",
                                       description: Text("Its lease ended, or the machine stopped."))
            }
        }
        .navigationTitle(name)
        .frame(minWidth: 640, minHeight: 400)
    }
}

struct VirtualMachineView: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = false
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
    }
}
