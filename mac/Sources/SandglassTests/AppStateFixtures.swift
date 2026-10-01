import SandglassAppCore
import SandglassCore
import Foundation

// The doubles and fixtures every `AppState` test is built from, shared by `AppStateTests` and
// `PauseFrictionTests`. Deliberately not file-scoped: `private` does not reach across files,
// and one set of fixtures is what keeps two suites from drifting into two different Notes.
//
// Everything here is time-pinned through `EngineFixtures`: the calendar, the moments, and a
// clock the caller drives by hand.

/// Degraded copy is matched loosely on purpose: these lines are prose for the user and will
/// be reworded, and a test that pins every word turns rewording into a test failure. What
/// matters is that the right *kind* of problem is named. Pause refusals are matched exactly
/// instead — those strings are a contract the button's behaviour is read from.
func expectDegraded(
    _ status: StatusKind, mentioning needle: String, _ name: String,
    file: String = #filePath, line: Int = #line
) {
    guard case .degraded(let text) = status else {
        failTest("\(name) — status is \(status), not degraded", file: file, line: line)
        return
    }
    expect(text.contains(needle), name, file: file, line: line)
}

// MARK: - Doubles

@MainActor
final class RecordingBlocker: BlockerControlling {
    var hidden: [String] = []
    var recheckCount = 0
    /// What the loop is told is in front. `nil` — nobody is looking — is the default, so a
    /// test that is not about usage tracking accrues no seconds behind its own back.
    var frontmost: String?
    /// How often the loop asked about the page in front. The real blocker reads the setting
    /// itself, so the count is of ticks rather than of polls that did anything.
    var pagePollCount = 0
    /// How often the loop asked for the visible blocked applications to be sent away again. The
    /// real blocker walks `NSWorkspace` itself, so the count is of beats rather than of hides.
    var sweepCount = 0
    func hideApp(bundleID: String) { hidden.append(bundleID) }
    func recheckFrontmost() { recheckCount += 1 }
    func pollFrontmostPage() { pagePollCount += 1 }
    func sweepBlockedApps() { sweepCount += 1 }
    func frontmostBundleID() -> String? { frontmost }
}

@MainActor
final class RecordingNotifier: NotificationPresenting {
    var delivered: [String] = []
    func deliverRelockWarning(groupName: String, secondsLeft: Int) {
        delivered.append("\(groupName) relocks in \(secondsLeft) seconds")
    }
}

/// A keep-alive manager that keeps its answer in memory instead of in `~/Library/LaunchAgents`.
///
/// `refusal` is what makes the interesting case reachable: `launchctl` declining to load the
/// agent must leave the toggle showing what is actually installed, which is what `isInstalled`
/// staying `false` after a failed `setInstalled(true)` reproduces.
@MainActor
final class RecordingKeepAlive: KeepAliveManaging {
    private(set) var isInstalled: Bool
    private(set) var asked: [Bool] = []
    var refusal: String?

    init(installed: Bool = false, refusal: String? = nil) {
        isInstalled = installed
        self.refusal = refusal
    }

    func setInstalled(_ installed: Bool) -> String? {
        asked.append(installed)
        guard refusal == nil else { return refusal }
        isInstalled = installed
        return nil
    }
}

// MARK: - Fixtures

/// Each case runs in its own directory: what `AppState` leaves on disk is half of what is
/// being tested, so no case may ever see another one's files.
func withTempDir(_ body: (URL) -> Void) {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("appstate-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: dir) }
    body(dir)
}

func stateFile(_ dir: URL) -> URL { dir.appendingPathComponent("state.json") }
func configFile(_ dir: URL) -> URL { dir.appendingPathComponent("config.json") }

/// Hard-blocked 10:00–11:00 on weekdays; 2026-08-10 is a Monday and 08-11 a Tuesday.
let pauseWindow = strictWindow(weekdays: [2, 3, 4, 5, 6], from: 600, to: 660)


func windowConfig() -> Config {
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    return Config(
        version: 1,
        targets: [target],
        groupSettings: [target.groupID: standardSettings(windows: [pauseWindow])]
    )
}

/// Two groups whose windows overlap, the shorter one first: 10:00-11:00 and 10:00-12:00 on
/// weekdays. Order is load-bearing — it is what tells "the first window found" from "the last
/// one to close".
func overlappingWindowsConfig() -> Config {
    let short = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let long = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
    return Config(
        version: 1,
        targets: [short, long],
        groupSettings: [
            short.groupID: standardSettings(windows: [pauseWindow]),
            long.groupID: standardSettings(windows: [strictWindow(weekdays: [2, 3, 4, 5, 6], from: 600, to: 720)]),
        ]
    )
}

/// Two groups blocked at 22:30 on a Monday, one of them into the next morning: YouTube until
/// 23:00 tonight, Reddit until 08:00 tomorrow. Comparing clock faces picks the wrong one — the
/// whole reason the engine reports how long a block still has to run rather than when it ends.
func crossingWindowsConfig() -> Config {
    let tonight = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let overnight = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
    return Config(
        version: 1,
        targets: [tonight, overnight],
        groupSettings: [
            tonight.groupID: standardSettings(
                windows: [strictWindow(weekdays: TimeWindow.everyDay, from: 20 * 60, to: 23 * 60)]
            ),
            overnight.groupID: standardSettings(
                windows: [strictWindow(weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)]
            ),
        ]
    )
}

/// An app and a site sharing one group, so "hide the apps" can be told from "hide everything".
func groupedConfig() -> Config {
    let app = Target(kind: .app, value: "com.apple.Notes", displayName: "Notes", groupID: "grp:demo")
    let site = Target(kind: .domain, value: "youtube.com", displayName: "YouTube", groupID: "grp:demo")
    return Config(
        version: 1,
        targets: [app, site],
        groupSettings: ["grp:demo": .standard]
    )
}

/// One website in its own group, with no schedule in the way — the shape the browser wire and
/// the domain half of the inbound API are tested against.
func webConfig(settings: GroupSettings = .standard) -> Config {
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    return Config(
        version: 1,
        targets: [target],
        groupSettings: [target.groupID: settings]
    )
}

/// One group that is nothing but a ticked chip: no targets of its own, a live membership of
/// Messaging, and a name the user would have got from setup.
func chipsConfig() -> Config {
    var settings = GroupSettings.standard
    settings.name = "Messaging"
    settings.categories = ["messaging"]
    return Config(
        version: 1,
        targets: [],
        groupSettings: ["grp:chips": settings]
    )
}

/// One app on the gentle preset: a pause screen every visit, no budget, no session.
func gentleConfig() -> Config {
    let notes = Target(kind: .app, value: "com.apple.Notes", displayName: "Notes")
    return Config(
        version: 1,
        targets: [notes],
        groupSettings: [notes.groupID: .gentle]
    )
}

func stateWithSession(endingAt endsAt: Date, startedAt: Date) -> EngineState {
    var state = EngineState.initial(now: startedAt, calendar: testCalendar)
    state.sessions["grp:demo"] = ActiveSession(
        groupID: "grp:demo", startedAt: startedAt, endsAt: endsAt, warned: false
    )
    return state
}

@MainActor
func makeState(
    _ dir: URL,
    clock: FakeClock,
    blocker: BlockerControlling? = nil,
    notifier: NotificationPresenting? = nil,
    keepAlive: KeepAliveManaging? = nil
) -> AppState {
    // `NoopBlocker()` is built here rather than as a default argument: default arguments are
    // evaluated outside the actor context, and its initialiser is MainActor-isolated.
    AppState(
        store: Store(directory: dir), blocker: blocker ?? NoopBlocker(), notifications: notifier,
        keepAlive: keepAlive, clock: clock, calendar: testCalendar
    )
}

/// Opens the settings window and sits out the Unblock card's wait.
///
/// What every break in these suites is asked for on the far side of, because that is the only
/// place one can be asked for: the card lives in this window, and it offers no length until the
/// countdown that started with the window has run out. Advancing the clock is enough — the gate is
/// asked what time it is rather than told, so no tick is needed and none is spent.
@MainActor
func afterTheUnblockWait(_ state: AppState, _ clock: FakeClock) {
    state.settingsWindowOpened()
    clock.advance(seconds: TimeInterval(state.config.breakWaitSeconds))
}

/// The web fixture with a settings lock on it, and optionally a different prompt — the smallest
/// edit there is, so a refusal is about the lock and nothing else.
func lockedConfig(
    timerMinutes: Int? = nil,
    passcode: String? = nil,
    allowForgot: Bool = true,
    dayStartMinutes: Int? = nil,
    coversQuickDisable: Bool = false
) -> Config {
    var config = webConfig()
    config.settingsLock = SettingsLock(
        timerMinutes: timerMinutes,
        passcode: passcode.flatMap(PasscodeHash.make),
        allowForgot: allowForgot,
        coversQuickDisable: coversQuickDisable
    )
    if let dayStartMinutes { config.dayStartMinutes = dayStartMinutes }
    return config
}
