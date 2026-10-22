// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "oss",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        // The API's types and an async client for it: what an application
        // that uses an oss server depends on.
        .library(name: "OSSClient", targets: ["OSSClient"]),
        // The server and its command line, one binary.
        .executable(name: "oss", targets: ["OSSCLI"]),
    ],
    targets: [
        .target(name: "OSSClient"),
        .executableTarget(name: "OSSCLI", dependencies: ["OSSClient"]),
    ]
)
