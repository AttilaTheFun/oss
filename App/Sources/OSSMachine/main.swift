import ContainerRuntime
import Foundation
import OSSServer

// `oss-machine container|macos <helper.json>`: one machine, run for OS
// Server by launchd (ContainerHelper, MacVMHelper). Inside OS Server.app, in
// Contents/Helpers.
// A closed pipe or socket is an error to handle, not the end of the machine.
signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments
switch arguments.count == 3 ? arguments[1] : "" {
case "container":
    if #available(macOS 26, *) {
        await ContainerHelper.main([arguments[0], arguments[2]])
    } else {
        FileHandle.standardError.write(Data("oss-machine: containers need macOS 26\n".utf8))
        exit(1)
    }
case "macos":
    MacVMHelper.main(arguments)
default:
    FileHandle.standardError.write(Data("oss-machine container|macos <helper.json>\n".utf8))
    exit(2)
}
