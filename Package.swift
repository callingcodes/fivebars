// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fivebars",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned exactly: updating Sparkle is a deliberate act (test an update from the previous build).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "FivebarsCore"),
        .executableTarget(
            name: "Fivebars",
            dependencies: ["FivebarsCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "FivebarsCoreTests",
            dependencies: ["FivebarsCore"]
        ),
    ]
)
