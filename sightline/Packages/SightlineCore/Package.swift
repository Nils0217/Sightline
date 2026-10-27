// swift-tools-version: 6.0
// labels: production, config
import PackageDescription

// Pure, device-independent logic for the Sightline app (geometry, sampling, stats).
// Runs on macOS so `swift test` works without the iPhone.
let package = Package(
    name: "SightlineCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SightlineCore", targets: ["SightlineCore"]),
    ],
    targets: [
        .target(name: "SightlineCore"),
        .testTarget(name: "SightlineCoreTests", dependencies: ["SightlineCore"]),
    ]
)
