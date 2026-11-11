// swift-tools-version: 6.2
import PackageDescription

// The app-facing package. It must stay free of third-party dependencies:
// everything here except the macOS-only SaveStateClientKit links into adopters'
// apps. Tools with dependencies (the `savestate` CLI and MCP bridge) live in the
// separate CLI/ package.
let package = Package(
    name: "SaveState",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        // Registry: controls, actions, scenarios. No networking.
        .library(name: "SaveState", targets: ["SaveState"]),
        // The in-app overlay for humans.
        .library(name: "SaveStateUI", targets: ["SaveStateUI"]),
        // The Debug-only agent endpoint. Compiles to nothing outside DEBUG.
        .library(name: "SaveStateAgent", targets: ["SaveStateAgent"]),
        // The versioned wire protocol shared by the agent endpoint and the bridge.
        .library(name: "SaveStateProtocol", targets: ["SaveStateProtocol"]),
        // macOS only: a client that reads and changes a running app's debug
        // state from a Mac tool. It compiles to nothing on iOS, and no app
        // target should depend on it. The CLI's bridge is built on it, and other
        // tools depend on it by this package's URL, since SwiftPM can't fetch
        // the CLI/ package that way.
        .library(name: "SaveStateClientKit", targets: ["SaveStateClientKit"])
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
        // Every file is inside `#if os(macOS)`. It talks to apps as a client
        // and never listens, but it stays out of apps all the same.
        .target(
            name: "SaveStateClientKit",
            dependencies: ["SaveStateProtocol"]
        ),
        .testTarget(
            name: "SaveStateTests",
            dependencies: ["SaveState"]
        ),
        .testTarget(
            name: "SaveStateAgentTests",
            // The client's end-to-end tests live here, inside the endpoint's
            // serialized suite: every test target shares one process, and it
            // runs one AgentEndpoint at a time.
            dependencies: ["SaveStateAgent", "SaveState", "SaveStateProtocol", "SaveStateClientKit"]
        ),
        .testTarget(
            name: "SaveStateClientKitTests",
            dependencies: ["SaveStateClientKit"]
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
