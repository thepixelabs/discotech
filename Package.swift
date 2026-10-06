// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Discotech",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Discotech",
            path: "Sources/Discotech"
        ),
        // Tests import the executable target with `@testable import Discotech`.
        .testTarget(
            name: "DiscotechTests",
            dependencies: ["Discotech"],
            path: "Tests/DiscotechTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
