# Changelog

Notable changes to SaveState. Versions follow
[Semantic Versioning](https://semver.org), and APIs can change before 1.0.

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
