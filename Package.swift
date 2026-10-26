// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "oss",
    // OSSClient's floor (async URLSession, Task.sleep(for:)); the server and
    // its CLI run on macOS 15 and Linux.
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        // The API's types and an async client for it: what an application
        // that uses an oss server depends on.
        .library(name: "OSSClient", targets: ["OSSClient"]),
        // The server, for a Mac app to run in its own process (OS Server,
        // App/): the machines, the API and the Bazel cache.
        .library(name: "OSSServer", targets: ["OSSServer"]),
        // The command line (the server too: `oss serve`), one binary.
        .executable(name: "oss", targets: ["OSSCLI"]),
    ],
    targets: [
        .target(name: "OSSClient", exclude: ["BUILD.bazel"]),
        .target(name: "OSSServer", dependencies: ["OSSClient"]),
        .executableTarget(name: "OSSCLI", dependencies: ["OSSServer"]),
    ]
)

#if os(macOS)
// What OS Monitor shows of a server, its model and its views (SwiftUI, so
// Apple's platforms only): OS Monitor's apps (Monitor/, built with Bazel)
// and OS Server's own window both show it.
package.products.append(.library(name: "OSSMonitorKit", targets: ["OSSMonitorKit"]))
package.targets.append(.target(name: "OSSMonitorKit", dependencies: ["OSSClient"], exclude: ["BUILD.bazel"]))
#endif
