// swift-tools-version: 6.0
// The oss app: the server, run and watched from a Mac app that collapses to
// the menu bar (App/README.md). A package of its own beside oss's, so
// OSSClient keeps its older floor; build.sh makes the .app.
import PackageDescription

let package = Package(
    name: "OSSApp",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "OSSApp",
            dependencies: [.product(name: "OSSClient", package: "oss")]
        ),
    ]
)
