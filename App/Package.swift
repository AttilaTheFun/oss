// swift-tools-version: 6.0
// OS Server, the app: the server in its own process, watched from a window
// that collapses to the menu bar (App/README.md). A package of its own
// beside oss's, so OSSClient keeps its older floor; build.sh makes the .app.
import PackageDescription

let package = Package(
    name: "OSSApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: ".."),
        // Linux containers, each in a helper process of its own (Virtualization).
        .package(url: "https://github.com/apple/containerization.git", exact: "0.33.3"),
    ],
    targets: [
        // A container's helper and what OS Server shares with it: the spec it
        // runs, the container's VM and its commands (Containerization).
        .target(
            name: "ContainerRuntime",
            dependencies: [.product(name: "OSSClient", package: "oss"),
                           .product(name: "Containerization", package: "containerization"),
                           .product(name: "ContainerizationOCI", package: "containerization"),
                           .product(name: "ContainerizationOS", package: "containerization")]
        ),
        // `oss-machine`: one container or macOS VM, a launchd job of OS Server's (Contents/Helpers).
        .executableTarget(name: "OSSMachine", dependencies: ["ContainerRuntime", .product(name: "OSSServer", package: "oss")]),
        .executableTarget(
            name: "OSSApp",
            dependencies: ["ContainerRuntime",
                           .product(name: "OSSClient", package: "oss"), .product(name: "OSSServer", package: "oss"),
                           .product(name: "OSSMonitorKit", package: "oss"),
                           .product(name: "Containerization", package: "containerization"),
                           .product(name: "ContainerizationOCI", package: "containerization"),
                           .product(name: "ContainerizationEXT4", package: "containerization"),
                           .product(name: "ContainerizationArchive", package: "containerization")]
        ),
    ]
)
