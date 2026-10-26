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
        .target(name: "OSSClient"),
        .target(name: "OSSServer", dependencies: ["OSSClient"]),
        .executableTarget(name: "OSSCLI", dependencies: ["OSSServer"]),
    ]
)
