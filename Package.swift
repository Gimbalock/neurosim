// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NeuroSim",
    platforms: [
        // macOS 14 lets us use `.onKeyPress` and the latest Charts/SwiftUI APIs.
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "NeuroSimCore",
            targets: ["NeuroSimCore"]
        ),
        .executable(
            name: "NeuroSimApp",
            targets: ["NeuroSimApp"]
        )
    ],
    targets: [
        // Pure-Swift simulation engine — no UI dependencies, fully testable
        // on Linux too (handy for CI). Numerics only.
        .target(
            name: "NeuroSimCore",
            path: "Sources/NeuroSimCore"
        ),
        // SwiftUI macOS app — depends on the core
        .executableTarget(
            name: "NeuroSimApp",
            dependencies: ["NeuroSimCore"],
            path: "Sources/NeuroSimApp"
        ),
        .testTarget(
            name: "NeuroSimCoreTests",
            dependencies: ["NeuroSimCore"],
            path: "Tests/NeuroSimCoreTests"
        )
    ]
)
