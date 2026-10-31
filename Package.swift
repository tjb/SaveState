// swift-tools-version: 6.2
import PackageDescription

// The app-facing package. It must stay free of third-party dependencies:
// everything here links into adopters' apps. Tools with dependencies
// (the `savestate` CLI and MCP bridge) live in the separate CLI/ package.
let package = Package(
    name: "SaveState",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        // Registry: controls, actions, probes, scenarios. No networking.
        .library(name: "SaveState", targets: ["SaveState"]),
        // The in-app overlay for humans.
        .library(name: "SaveStateUI", targets: ["SaveStateUI"]),
        // The Debug-only agent endpoint. Compiles to nothing outside DEBUG.
        .library(name: "SaveStateAgent", targets: ["SaveStateAgent"]),
        // The versioned wire protocol shared by the agent endpoint and the bridge.
        .library(name: "SaveStateProtocol", targets: ["SaveStateProtocol"])
    ],
    targets: [
        .target(name: "SaveStateProtocol"),
        .target(
            name: "SaveState",
            dependencies: ["SaveStateProtocol"],
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "SaveStateUI",
            dependencies: ["SaveState"]
        ),
        .target(
            name: "SaveStateAgent",
            dependencies: ["SaveState", "SaveStateProtocol"]
        ),
        .testTarget(
            name: "SaveStateTests",
            dependencies: ["SaveState"]
        ),
        .testTarget(
            name: "SaveStateAgentTests",
            dependencies: ["SaveStateAgent", "SaveState", "SaveStateProtocol"]
        ),
        .testTarget(
            name: "SaveStateUITests",
            dependencies: ["SaveStateUI"]
        ),
        .testTarget(
            name: "SaveStateProtocolTests",
            dependencies: ["SaveStateProtocol"]
        )
    ]
)
