# SaveState

Declare your app's debug state once. Reach it from an in-app overlay, coding
agents, UI tests, and SwiftUI previews.

SaveState is a Swift package for iOS apps. You declare controls (premium status,
backend environment, a clock override), actions (seed data, reset onboarding),
and named **scenarios** that set many of them at once, such as `expired-trial` or
`power-user`. SaveState renders that registry as a debug overlay for people and
serves it over MCP for agents, in Debug builds only.

> **Status:** pre-alpha. The registry and clock are in place; the overlay, the
> agent endpoint, and the MCP tools are under development for v0.1. APIs will
> change.

## Why

Coding agents can now build, launch, and tap through an iOS app, but they still
can't put it into a specific state without walking the UI there, and some states,
like a trial that expired yesterday, can't be reached through the UI at all.
SaveState gives every state a name and a reproducible path.

## Declaring state

Bind controls to the model that holds your debug state, then name the
scenarios you reach for most:

```swift
import SaveState

@MainActor @Observable
final class DebugState {
    var premiumOverride: Bool?
    var environment = ServerEnvironment.production
}

let registry = SaveStateRegistry(model: debugState) { r in
    r.section("Purchases") {
        r.triState("Premium", key: "premium", \.premiumOverride, real: { store.isEntitled })
    }
    r.choice("Environment", key: "env", \.environment, requiresRelaunch: true)
    r.clock()
    r.action("Reset onboarding", key: "reset-onboarding", destructive: true) {
        onboarding.reset()
    }
    r.scenario("expired-trial", "Trial ended yesterday; the paywall shows") { state in
        state.premiumOverride = false
        SaveStateClock.overrideDate = .now.addingTimeInterval(8 * 86_400)
    }
}

try await registry.applyScenario("expired-trial")
```

Keys such as `premium` and `expired-trial` are stable identifiers that agents
and tests use. Labels are display text and can change freely.

The registry is enabled in Debug builds by default and throws
`SaveStateError.disabled` on every change otherwise. Pass `isEnabled:` to turn
it on for QA or TestFlight builds.

### Time travel

Read `SaveStateClock.now` instead of `Date()` wherever "now" decides behavior,
such as trial expiry or streaks. The `clock()` control and scenarios can then
move the app's clock, and time keeps running from the new date. With no
override, `SaveStateClock.now` is `Date()`.

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
