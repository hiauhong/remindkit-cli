// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "remindkit",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "EventKitCore",
            dependencies: []
        ),
        .executableTarget(
            name: "remindkit",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "EventKitCore",
            ]
        ),
        .testTarget(
            name: "RemindKitTests",
            dependencies: ["remindkit", "EventKitCore"]
        ),
    ]
)
