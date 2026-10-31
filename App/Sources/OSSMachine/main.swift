import ContainerRuntime
import Foundation
import OSSServer

// `oss-machine container|macos|network <spec.json>`: one machine, or the
// containers' network, run for OS Server by launchd (ContainerHelper,
// MacVMHelper, NetworkOwnerProcess). Inside OS Server.app, in
// Contents/Helpers. `oss-machine network-check` tries the containers'
// network for real, on a folder of its own (CI's macOS VM).
// A closed pipe or socket is an error to handle, not the end of the machine.
signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments
let usage = "oss-machine container|macos|network <spec.json>, or oss-machine network-check\n"
switch arguments.count >= 2 ? arguments[1] : "" {
case "container" where arguments.count == 3:
    if #available(macOS 26, *) {
        await ContainerHelper.main([arguments[0], arguments[2]])
    } else {
        FileHandle.standardError.write(Data("oss-machine: containers need macOS 26\n".utf8))
        exit(1)
    }
case "network" where arguments.count == 3:
    if #available(macOS 26, *) {
        await NetworkOwnerProcess.main(arguments[2])
    } else {
        FileHandle.standardError.write(Data("oss-machine: the containers' network needs macOS 26\n".utf8))
        exit(1)
    }
case "network-check" where arguments.count == 2:
    if #available(macOS 26, *) {
        await NetworkCheck.main()
    } else {
        FileHandle.standardError.write(Data("oss-machine: the containers' network needs macOS 26\n".utf8))
        exit(1)
    }
case "macos" where arguments.count == 3:
    MacVMHelper.main(arguments)
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
