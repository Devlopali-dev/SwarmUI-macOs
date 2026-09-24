// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwarmUILauncher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SwarmUILauncher", path: "Sources/SwarmUILauncher")
    ]
)
