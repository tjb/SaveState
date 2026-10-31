# SaveState

Declare your app's debug state once. Reach it from an in-app overlay, coding
agents, UI tests, and SwiftUI previews.

SaveState is a Swift package for iOS apps. You declare controls (premium status,
backend environment, a clock override), actions (seed data, reset onboarding),
and named **scenarios** that set many of them at once, such as `expired-trial` or
`power-user`. SaveState renders that registry as a debug overlay for people and
serves it over MCP for agents, in Debug builds only.

> **Status:** pre-alpha. The package skeleton is in place; v0.1 is under
> development. APIs will change.

## Why

Coding agents can now build, launch, and tap through an iOS app, but they still
can't put it into a specific state without walking the UI there, and some states,
like a trial that expired yesterday, can't be reached through the UI at all.
SaveState gives every state a name and a reproducible path.

## Packages

- `SaveState`, `SaveStateUI`, `SaveStateAgent`, `SaveStateProtocol`: the
  app-facing Swift package, with no third-party dependencies.
- `savestate`: a Mac CLI and MCP server for coding agents, in `CLI/`. It will
  install with `brew install tjb/tap/savestate` once v0.1 ships.

## Requirements

- iOS 18+ / macOS 15+
- Swift 6.2+ (Xcode 26+)

## License

SaveState is available under the MIT license. See [LICENSE](LICENSE).
