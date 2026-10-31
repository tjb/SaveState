// swift-tools-version: 6.2
import PackageDescription

// The Mac-side tools: the `savestate` CLI and MCP bridge.
//
// This is a separate package so its third-party dependencies never reach
// apps that add SaveState. The bridge logic lives in a library target,
// SaveStateBridgeKit, so a future Mac app can link it.
let package = Package(
    name: "savestate-cli",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "savestate", targets: ["SaveStateCLI"])
    ],
    dependencies: [
        // Named, so the dependency resolves however the repo folder is named
        // (a Homebrew tarball unpacks to SaveState-<version>, for example).
        .package(name: "SaveState", path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "SaveStateBridgeKit",
            dependencies: [
                .product(name: "SaveStateProtocol", package: "SaveState"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .executableTarget(
            name: "SaveStateCLI",
            dependencies: [
                "SaveStateBridgeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "SaveStateBridgeKitTests",
            dependencies: ["SaveStateBridgeKit"]
        )
    ]
)
