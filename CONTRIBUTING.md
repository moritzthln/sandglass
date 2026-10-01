# Contributing to Sandglass

Thanks for taking the time. Bug reports, fixes and well-argued feature ideas are all welcome.

## Before you start

- **Small fixes** (a bug, a typo, a clearer sentence): open a pull request directly.
- **Bigger changes** (a new mechanic, a new screen, anything that changes how blocking feels):
  please [open an issue](https://github.com/moritzthln/sandglass/issues/new/choose) first and
  describe the problem before the solution. Sandglass is deliberately small, and the most common
  answer to a feature request is a simpler version of it.

## Build and test

You need macOS 14 or later and the Xcode Command Line Tools (or Xcode).

```sh
cd mac
swift build                    # everything
swift run SandglassTests       # the whole suite; exits non-zero on any failure
scripts/build-app.sh           # universal mac/build/Sandglass.app
```

`build-app.sh` pins the toolchain to the Command Line Tools when they are installed, because
SwiftUI layout depends on the SDK a build links against. Set `DEVELOPER_DIR` to use another one.

Running a development build replaces nothing on its own, but a bundled build carries the real
bundle identifier and retires any other running Sandglass when it starts. Two environment
variables keep test runs away from your real setup:

- `SANDGLASS_SUPPORT_DIR=<dir>` keeps config, state and events in `<dir>`.
- `SANDGLASS_LAUNCH_AGENT_DIR=<dir>` writes the keep-alive plist to `<dir>` and never talks to
  launchd.

`scripts/test-keepalive.sh` checks the launchd agent end to end and, in its last part, touches
the real `~/Library/LaunchAgents`; read its header before running it.

## How the code is organised

| Module | What lives there |
|---|---|
| `SandglassCore` | The pure engine: models, rules, time windows, budgets, the store. No UI, no AppKit. |
| `SandglassAppCore` | `AppState` and everything it decides, `@MainActor`, still free of AppKit and SwiftUI. |
| `Sandglass` | The executable: AppKit and SwiftUI, the blocker, browser access, windows. Kept thin. |
| `SandglassTests` | An executable test harness over the two libraries. |

The tests are a plain executable rather than XCTest because XCTest is not available with the
Command Line Tools alone, and the project builds and tests without Xcode. `TestKit.swift` holds
the handful of `expect…` helpers; each area registers in `SandglassTests/main.swift`. Anything
that can be decided without AppKit is moved into the libraries so the suite can reach it.

## House rules

- **At most 800 lines per file and 80 lines per function.** Split along a real seam when you
  get close.
- **Comments explain why**, not what. The codebase is written so that a reader can follow the
  reasoning behind a decision; keep that up, and keep it in plain English.
- **Tests for every engine change.** A behaviour change needs a test that failed before the
  change and passes after it. A refactor changes no behaviour; do not hide one inside it.
- **Conventional commits:** `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, with a
  body that says why.
- **No new dependencies** without discussing it in an issue first.
- **No formatter runs over the whole tree.** Match the style of the file you are in.

## Pull requests

Fill in the template: what changed and why, how you tested it, and screenshots for anything
visible. CI builds the package, runs the suite and builds the universal app on every pull
request; it has to be green before review.

## Licensing of contributions

By submitting a pull request you agree that your contribution is licensed under the project's
[PolyForm Noncommercial License 1.0.0](LICENSE), and that the maintainer may also license it under
other terms in the future.
