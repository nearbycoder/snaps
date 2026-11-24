// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Snaps",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Snaps", path: "Sources/Snaps"),
        .testTarget(name: "SnapsTests", dependencies: ["Snaps"], path: "Tests/SnapsTests"),
    ]
)
