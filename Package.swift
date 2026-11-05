// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Looksee",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Looksee", path: "Sources/Looksee"),
        .testTarget(name: "LookseeTests", dependencies: ["Looksee"], path: "Tests/LookseeTests"),
    ]
)
