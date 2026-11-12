# Changelog

Notable changes to SaveState. Versions follow
[Semantic Versioning](https://semver.org), and APIs can change before 1.0.

## 0.2.1 - 2026-11-11

- `SaveStateClient`'s timeout is hard. When it passes, or the caller is cancelled,
  the call throws at once and the socket finishes closing in the background.
  Before, the call waited for URLSession to acknowledge the cancelled socket, and
  under the swift.org 6.4.2 toolchain's Swift Testing runner that never happens,
  so the call hung ([#27](https://github.com/tjb/SaveState/issues/27)). The
  bridge, and so `savestate mcp`, gets the same fix.

## 0.2.0 - 2026-11-10

Probes, waits, and a public client for Mac tools:

- Probes: read-only Bool, Int, Double, String, and Date values the app reports,
  declared with `r.probe(_:key:_:)`. Probes share one key space with controls.
- `savestate_read` reads a probe when no control has the key.
- `savestate_wait` waits for a probe to meet a condition: `equals`, `notEquals`,
  `atLeast`, or `atMost`. `timeoutSeconds` is at most 30. The result includes
  `waitedMilliseconds`, and a wait that times out says how long it took.
  Apps can also wait in-process with `wait(forProbe:until:timeout:)`.
- The wire protocol is now version 3, so rebuild apps and the bridge from the
  same SaveState version.
- The overlay shows probes, read-only, in a Probes group.
- `SaveStateClientKit`, a new macOS-only product with a public `SaveStateClient`
  for Mac tools that drive running apps without MCP. Add the package by URL.
  `BridgeError` has a stable `Code` to match on instead of message text.
- `SaveStateBridgeKit` is a library product in `CLI/`, built on
  `SaveStateClientKit`.
- The agent endpoint answers pipelined requests in order, and a disconnect no
  longer cancels an action or scenario halfway.
- The demo app has an `item-count` probe and a `seed-projects` scenario.

## 0.1.0 - 2026-11-02

The first release:

- A registry of controls: Bool, tri-state, enum, string, number, and date.
- Actions, and named scenarios that are applied live.
- `SaveStateClock` and a clock control for moving the app's time.
- A debug overlay, `SaveStateUI`, with a floating button and a panel.
- A `.premiumToggle` shim for apps coming from PremiumToggle.
- A Debug-only simulator endpoint, `SaveStateAgent`, on loopback with a per-launch
  token.
- The `savestate` command with an MCP server and six tools: `savestate_list_apps`,
  `savestate_describe`, `savestate_set`, `savestate_run_action`,
  `savestate_apply_scenario`, and `savestate_read`.
