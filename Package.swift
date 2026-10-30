// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "UsageIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageIsland", targets: ["UsageIsland"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .target(name: "IslandUI", dependencies: ["UsageCore"]),
        .executableTarget(name: "UsageIsland", dependencies: ["IslandUI", "UsageCore"]),
        .executableTarget(name: "IslandSnapshots", dependencies: ["IslandUI", "UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
