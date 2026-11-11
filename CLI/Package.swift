// swift-tools-version: 6.2
import PackageDescription

// The Mac-side tools: the `savestate` CLI and MCP bridge.
//
// This is a separate package so its third-party dependencies never reach
// apps that add SaveState. The bridge logic lives in SaveStateBridgeKit, a
// library product for Mac tools built inside this repo. It re-exports
// SaveStateClientKit, whose SaveStateClient reads, changes, and waits on a
// running app's debug state without going through MCP. The MCP server is
// `package` access, so the MCP SDK's types never become part of its API,
// though the SDK still links.
//
// SwiftPM can't fetch this package by git URL: it isn't at the repo root, and
// it depends on ".." by path. Projects outside this repo depend on the root
// package's SaveStateClientKit product by URL instead.
let package = Package(
    name: "savestate-cli",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "savestate", targets: ["SaveStateCLI"]),
        .library(name: "SaveStateBridgeKit", targets: ["SaveStateBridgeKit"])
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
                .product(name: "SaveStateClientKit", package: "SaveState"),
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
            dependencies: [
                "SaveStateBridgeKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SaveState", package: "SaveState"),
                .product(name: "SaveStateAgent", package: "SaveState")
            ]
        )
    ]
)
