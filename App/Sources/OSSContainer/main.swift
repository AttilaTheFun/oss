import ContainerRuntime
import Foundation

// `oss-container <helper.json>`: one container, run for OS Server by launchd
// (ContainerHelper). Inside OS Server.app, in Contents/Helpers.
if #available(macOS 26, *) {
    await ContainerHelper.main(CommandLine.arguments)
} else {
    FileHandle.standardError.write(Data("oss-container: containers need macOS 26\n".utf8))
    exit(1)
}
