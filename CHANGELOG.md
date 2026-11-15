# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- ⌘W closes the settings window and ⌘Q quits. Group cards in the sidebar can be reached and opened
  with the keyboard.
- On the pause screen, Tab moves between the controls, Escape means "Back to work", and you can
  paste into the password field.

### Changed

- An unlocked settings visit ends after 10 minutes without activity. Time spent waiting out a lock
  does not count.
- Time inside a group's own break window no longer counts toward its daily usage.
- A password that only asks during strict windows now opens the group only until that window
  ends. Outside its strict windows such a group behaves like any other group: the daily time limit
  relocks it, ending early earns half an open back, and the emergency pass and breaks reach it.
- Wrong passwords are counted per password rather than per group, and the one-minute wait survives
  quitting and the keep-alive restart.
- Removing the settings passcode asks first when groups open with it, and names them.
- Under a running lock, remove buttons that would loosen a group are shown disabled instead of
  being refused on click.
- Break windows are drawn hatched, so they can be told from strict blocks without colour; timeline
  hours follow the system's 12/24-hour format.
- Cooldown and earn-back say they need an open length when the group has none.
- The README says that ending Sandglass with SIGTERM skips the quit dialog, the passcode and
  passwords.

### Fixed

- A locked group can no longer lose its sites or apps to another group through an edit elsewhere:
  a new group on the same category, a block rule, or a more specific site in another group. The
  lock holds such an edit unless the receiving group blocks at least as hard.
- Quitting Sandglass, changing the system clock and starting it again no longer resets the clock
  check: on the same boot the app goes on from the last time it trusted. A restart of the Mac is
  now recognised as one even when the app starts late after it.
- Setting the clock back no longer starts a fresh day with a fresh budget; the day only moves
  forward. Moving the clock forward in several small steps is detected once the total passes five
  minutes.
- Setting the clock past a "Block until a day" date no longer deletes that date on the next
  settings save.
- A website's countdown can no longer be skipped by setting the clock forward, and the running
  session row and "End early" no longer disappear when the clock is set forward.
- After changing time zone, time windows and the day boundary follow the new zone without a restart.
- The emergency pass and the streak freeze use the same week boundary, and moving the start of the
  day later no longer counts a streak day twice.
- When a break, an emergency pass or a break window ends by itself, an app left open is blocked
  again at once instead of staying usable until you switch away.
- The pause screen covers every display, and it no longer covers the quit dialog or a passcode
  prompt that is already open.
- Turning off "Start at login and keep running" now sticks even when the app was started at login.
- Starting a new copy of Sandglass waits for the old one to save its last seconds of usage before
  taking over.
- With a group whose opens need no wait, an app is no longer hidden when its session ends, only to
  open again by itself.
- A right password at the keep-alive switch no longer counts as a wrong try for the other password
  groups, and typing a password into a group that is already open no longer says it unlocked
  anything.
- Ending a password session no longer starts a cooldown that blocked the first open after the
  window.
- A running "forgot passcode" hour is called off when the passcode changes or a group starts or
  stops opening with the settings passcode.
- Shortening a group's open length now shortens an open that is already running, and there are no
  more "1 minute left" warnings for very short opens or for opens a strict window is holding.
- A group that opens with the settings passcode while none is set says so, instead of asking for a
  password nothing can match.
- Block rules in different groups respect "high priority" and page-before-text, the same way rules
  within one group do.
- A blocked tab is only sent to the block page while it still shows the page that was blocked;
  switching tabs at the wrong moment no longer moves the new tab.
- "Enter password" works on a block page with no other query, does not stack old presses, ignores
  presses from before a relaunch, and only opens over the browser it was pressed in. The password
  window closes when its block ends, and its close button cancels like the Cancel button.
- After an edit, block pages left open in several browsers are all updated, not only the last one.
- A browser listed as an app in the same group as the site it shows is charged one second per
  second, not two.
- A strict block that runs into a second strict window shows the real end, and one interrupted by a
  break ends at the break.
- Opens avoided are no longer counted while a break or the emergency pass is running.
- An edit that could not be saved no longer announces the same block end twice, and a failing disk
  no longer causes a write every second while the forgotten-passcode hour runs out.
- Clicking the menu bar icon with the settings window open no longer resets the page, open sheets
  and typed values, and an emergency pass ending while a sheet is open no longer destroys the sheet
  and its draft.
- Adding an advanced rule closes the sheet, and pressing Add twice no longer adds the rule twice.
- The "Block until a day" sheet stays open with the reason when the date is refused, and a standing
  block can be pushed further out.
- Editing a preset that was deleted elsewhere says so instead of losing the edit silently.
- A number typed into a field is saved when the window is closed right away.
- "This week" on the Stats page updates when the day changes.
- Return in the passcode sheet's New field moves to the Repeat field.
- The demo seed is never written to the real configuration, and a migration from the old app that
  stops halfway is finished on the next launch.
- `install.sh` puts the previous app back if the swap fails and warns when protection is off.

## [1.2.1] - 2026-11-16

### Fixed

- A running lock now also holds a group's password when it is set together with "Only during
  strict windows" in one edit. Before, that edit counted as adding friction, and it opened the
  group's strict windows to the password while the lock was meant to keep them shut.

## [1.2.0] - 2026-11-15

### Added

- "Only during strict windows" for a group's password: the password then opens the group's strict
  windows for its open length, and outside every window the group spends its budget as usual.
  Narrowing the password this way is a loosening, so a running lock holds it.

## [1.1.1] - 2026-11-05

### Fixed

- A video playing inside a search page is blocked like the video itself. Google's video results
  play YouTube clips in an overlay on `google.com/search`, and DuckDuckGo's do the same, so the
  tab never visited `youtube.com` and a YouTube block let the video play. The overlay's address
  now counts as the YouTube video, and after an unlock the tab comes back to the search.

## [1.1.0] - 2026-10-31

### Added

- Open only with a password: a group can be given a password — the settings passcode, or one of
  its own — and everything in it stays blocked until the password is typed. A correct password
  opens the group for its open length (30 minutes if it has none). The block page offers an
  "Enter password" button that asks in a Sandglass window, never on the page; the pause screen has
  the field for apps. Five wrong tries in a row earn a one-minute wait.
- The same password guards the group's settings like a group passcode, and turning off "Start at
  login and keep running". The emergency pass, "Unblock everything" and the forgotten-passcode
  hour do not open such a group.
- A local install can be signed with a stable identity (`SIGN_IDENTITY`), so the Accessibility
  and Automation grants survive updates.

### Fixed

- Moving from AppBlock no longer leaves Sandglass without its keep-alive agent.

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

[Unreleased]: https://github.com/moritzthln/sandglass/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/moritzthln/sandglass/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/moritzthln/sandglass/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/moritzthln/sandglass/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/moritzthln/sandglass/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/moritzthln/sandglass/releases/tag/v1.0.1
