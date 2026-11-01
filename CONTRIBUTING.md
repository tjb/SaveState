# Contributing

SaveState is pre-alpha and its APIs will change, so please open an issue to discuss
anything large before you build it. To report a vulnerability, follow
[SECURITY.md](SECURITY.md) instead of opening an issue.

## Setup

You need Xcode 26 or later. The repository holds two packages:

- `Package.swift` at the root is what apps add. Never add a dependency to it.
- `CLI/Package.swift` holds the `savestate` command and MCP bridge. Third-party
  dependencies are allowed here.

## Checks

CI runs all of these on every pull request:

```bash
swift build && swift test                       # root package on macOS
xcodebuild build -scheme SaveState-Package \
  -destination 'generic/platform=iOS Simulator' # root package on iOS
(cd CLI && swift build && swift test)           # CLI and bridge
swiftlint lint --strict                         # lint; CI pins the version
swift test -c release -Xswiftc -enable-testing  # what only Release builds do
python3 .github/scripts/coverage.py .           # coverage; pass CLI for the bridge
```

CI also runs the UI tests of the demo app in `Examples/SaveStateDemo`. They can
fail from timing on CI runners, so check the failing test's log before assuming
your change caused it.

## Rules

- Keep every line in `SaveStateAgent` inside `#if DEBUG`, and don't add networking
  to `SaveState` or `SaveStateUI`.
- MCP lives only in the bridge. Apps speak `SaveStateProtocol`, and any breaking
  message change bumps `WireProtocol.version`.
- Swift 6 language mode with strict concurrency, on iOS 18 and macOS 15 or later.
  Put newer APIs behind `#available`.
- Control, action, and scenario keys are stable identifiers. Labels are display
  text and are never matched on.
- Don't give two targets, products, or folders names that differ only in letter
  case, because the build paths collide on macOS.
- Write tests with Swift Testing and add doc comments to public API.
- Keep decisions out of SwiftUI view bodies so tests can reach them. A test has to
  fail when the behavior breaks, so check important ones by breaking the code.
- CI fails if a file drops below its floor in `.github/coverage-floor-*.json`. If
  you have to lower a floor, say why in the pull request.

## Pull requests

Work on a branch and open a pull request against `main`. Pull requests are
squash-merged once CI is green.

By contributing, you agree that your work is licensed under the
[MIT license](LICENSE).
