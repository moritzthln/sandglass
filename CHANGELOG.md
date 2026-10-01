# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-10-01

### Changed

- Licensed under the PolyForm Noncommercial License 1.0.0.

## 1.0.0 - 2026-10-01

First public release.

### Added

- Menu-bar app for macOS 14 and later, universal for Apple Silicon and Intel.
- Groups of apps and websites that share one budget: pause countdown, opens per day, session
  length with automatic relock, cooldown, an escalating countdown and earn-back.
- Time windows per group: strict blocks and breaks, drawn across the week.
- Block a group until a chosen day.
- Built-in categories (social, video, news, shopping, games, messaging, adult) that can be
  ticked per group, and advanced rules to block or allow a path or a piece of text.
- Presets (Gentle, Standard, Strict) and presets of your own.
- Pause screen with countdown for apps; a local block page with the same countdown for
  websites in Safari, Chrome, Arc, Brave and Edge; an overlay for Firefox.
- Blocked apps are hidden, taken out of fullscreen when stuck, and never quit.
- Block everything for a while, an unblock that waits first, and a weekly emergency pass.
- Settings lock by timer or passcode, app-wide and per group. Locks hold loosening only;
  tightening always goes through.
- Hard blocks stay hard when Accessibility is revoked: the affected apps are hidden whole.
- Protection against changing the system clock to escape a block.
- Start at login and restart within seconds through a launchd `KeepAlive` agent.
- Stats page from a local event log.
- All data on-device in `~/Library/Application Support/Sandglass`.

[Unreleased]: https://github.com/moritzthln/sandglass/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/moritzthln/sandglass/releases/tag/v1.0.1
