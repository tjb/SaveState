# SaveState

Declare your app's debug state once. Reach it from an in-app overlay, coding
agents, UI tests, and SwiftUI previews.

SaveState is a Swift package for iOS apps. You declare controls (premium status,
backend environment, a clock override), actions (seed data, reset onboarding),
and named **scenarios** that set many of them at once, such as `expired-trial` or
`power-user`. SaveState renders that registry as a debug overlay for people and
serves it over MCP for agents, in Debug builds only.

> **Status:** pre-alpha. The registry, clock, and overlay are in place; the agent
> endpoint and the MCP tools are under development for v0.1. APIs will change.

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
    r.scenario(
        "Expired trial",
        key: "expired-trial",
        summary: "The trial ended yesterday, so the paywall shows."
    ) { state in
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

### The overlay

Attach the overlay at your app's root to get a floating ladybug button that
opens a panel of every control, action, and scenario:

```swift
import SaveStateUI

ContentView()
    .saveStateOverlay(registry)
```

It shows nothing when the registry is disabled. Destructive actions ask first.
[`Examples/SaveStateDemo`](Examples/SaveStateDemo) is a small app you can run.

### Coming from PremiumToggle

`SaveStateUI` includes PremiumToggle's API, so an existing
`.premiumToggle(manager)` keeps working after you change the import. Your
provider still owns the override and stores it under the same key, so existing
overrides carry over. The panel is SaveState's, so it offers On, Off, and Real,
and its accessibility identifiers change. `premiumToggle.button` stays the same.

### Time travel

Read `SaveStateClock.now` instead of `Date()` wherever "now" decides behavior,
such as trial expiry or streaks. The `clock()` control and scenarios can then
move the app's clock, and time keeps running from the new date. With no
override, `SaveStateClock.now` is `Date()`. A persisted override restarts from
its date at each launch, so every launch begins in the same state.

### What survives a relaunch

Changes last for the current launch unless you pass `persist: true`. A change
to a control declared `requiresRelaunch` lasts through the next launch, so
relaunching applies it once. The overlay persists its changes; agents choose.

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
