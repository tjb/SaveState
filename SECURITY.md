# Security

## Reporting a vulnerability

Report vulnerabilities privately through
[GitHub's private reporting form](https://github.com/tjb/SaveState/security/advisories/new).
Please don't open a public issue. SaveState is maintained by one person, so
replies may take a few days.

## Supported versions

SaveState has no tagged release yet, so only the `main` branch gets fixes.

## What counts

SaveState puts a debug server in Debug builds of apps, so these are the promises
that matter most:

- **Release builds contain no server.** Every line of `SaveStateAgent` is inside
  `#if DEBUG`, and `SaveState` and `SaveStateUI` contain no networking code.
- **The endpoint is reachable only from the same Mac.** It binds to the loopback
  interface and runs in the simulator, or in a Mac app that passes a container
  directory when it starts the endpoint. It doesn't start on a physical device.
- **Each connection needs a token.** The token is new at each launch, and it's
  stored in an endpoint file in the app's data container that only the file's
  owner can read.
- **Agents can't run destructive actions.** The endpoint refuses them, so a person
  has to run them.

A way around any of these is a vulnerability, including a Release build that
contains the endpoint.

## What doesn't count

The registry's `isEnabled:` option lets you turn on the overlay in QA or TestFlight
builds. If you enable it in a build you ship, anyone using that build can change
its debug state. That's the option working as documented.

Other software running as the same Mac user can read the endpoint file, so the
token doesn't protect against it.
