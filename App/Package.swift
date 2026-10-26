// swift-tools-version: 6.0
// OS Server, the app: the server in its own process, watched from a window
// that collapses to the menu bar (App/README.md). A package of its own
// beside oss's, so OSSClient keeps its older floor; build.sh makes the .app.
import PackageDescription

let package = Package(
    name: "OSSApp",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "OSSApp",
            dependencies: [.product(name: "OSSClient", package: "oss"), .product(name: "OSSServer", package: "oss"),
                           .product(name: "OSSMonitorKit", package: "oss")]
        ),
    ]
)
