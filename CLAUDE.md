# SaveState

SaveState lets an iOS app declare its debug state once (controls, actions,
probes, and named scenarios) and reach it from four places: an in-app overlay
for humans, coding agents over MCP, XCUITest launch arguments, and SwiftUI
previews. It is the successor to PremiumToggle, which becomes a shim over it.

## Layout

Two packages in one repo:

- `Package.swift` (root): what apps add. **Zero third-party dependencies.**
  - `SaveState`: the registry. No networking code.
  - `SaveStateUI`: the overlay.
  - `SaveStateAgent`: the Debug-only endpoint the bridge talks to.
  - `SaveStateProtocol`: the versioned wire protocol shared with the bridge.
- `CLI/Package.swift`: Mac-side tools. Third-party dependencies are allowed here.
  - `SaveStateBridgeKit`: bridge logic as a library, so a future Mac app can link it.
  - `SaveStateCLI`: the CLI target. Its product builds the `savestate` command
    (`savestate mcp` runs the MCP server).

## Commands

```bash
swift build && swift test                       # root package on macOS
xcodebuild build -scheme SaveState-Package \
  -destination 'generic/platform=iOS Simulator' # root package on iOS
(cd CLI && swift build && swift test)           # CLI and bridge
swiftlint lint --strict                         # lint; CI pins the version
```

## Rules

- Swift 6 language mode with strict concurrency. Minimum iOS 18 and macOS 15.
  Put iOS 26 APIs such as Liquid Glass behind `if #available(iOS 26, *)`.
- Never add a dependency to the root package. Anything that needs one goes in `CLI/`.
- Every line in `SaveStateAgent` stays inside `#if DEBUG`. Never add networking
  to `SaveState` or `SaveStateUI`. A server in a Release binary ends the project.
- MCP lives only in the bridge. Apps speak `SaveStateProtocol`. Bump
  `WireProtocol.version` on any breaking message change.
- Never give two targets, products, or folders names that differ only in letter
  case (`savestate` vs `SaveState`). macOS filesystems are case-insensitive, so
  their build paths collide at link time.
- Control, action, probe, and scenario keys are stable identifiers. Labels are
  display text and are never matched on.
- SwiftLint runs as a binary, never as a package plugin, so the root package
  stays free of dependencies.
- Tests use Swift Testing. Public API gets doc comments.

## Git

- Commit as `tjb <tjbobella@gmail.com>`.
- Do not add `Co-Authored-By` or `Claude-Session` trailers to commits, and do not
  add a "Generated with Claude Code" footer to pull request descriptions.
- Work on a branch and open a pull request. Do not push to `main`.
- Squash-merge a pull request once CI is green. GitHub deletes the merged branch.

## Decisions

| Area | Decision |
| --- | --- |
| Transport | Simulator: loopback WebSocket plus a per-launch token, discovered through an endpoint file in the app's data container. Device: the app long-polls the Mac, so nothing listens on the phone. |
| Bridge | Swift, on the official MCP Swift SDK. |
| Agent writes | Session-scoped, cleared on relaunch unless `persist: true`. Overlay toggles persist. |
| UI tests | Scenarios export as test-only App Intents from v0.2. |
| License | MIT. |

## Roadmap

v0.1 exit test: an agent applies the `expired-trial` scenario in Campaign Codex
and screenshots the paywall with zero taps.

- **v0.1:** controls (Bool, tri-state, enum, string, number, date), actions,
  scenarios applied live, the overlay ported from PremiumToggle plus the
  `.premiumToggle` shim, the simulator endpoint, and six MCP tools:
  `savestate_list_apps`, `savestate_describe`, `savestate_set`,
  `savestate_run_action`, `savestate_apply_scenario`, `savestate_read`.
- **v0.2:** probes and `savestate_wait`, launch-time scenarios with relaunch,
  the destructive-action tool, scenarios as test-only App Intents.

The Clock plugin only works if the app reads time through SaveState rather than
`Date()`. Prove that adoption path early.
