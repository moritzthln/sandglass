import Foundation
import SandglassCore

// MARK: - Clock

/// A clock the tests drive by hand. Every engine test must be time-deterministic, so the
/// engine is never allowed to read the wall clock.
///
/// Two clocks, because the engine reads two and the interesting cases are where they disagree:
///
/// - `advance(seconds:)` and setting `now` forward are **time passing**: both move together, the
///   way they do on a Mac that was simply left running (or asleep — see `SystemClock.uptime`).
///   That is what nearly every test means by moving the clock, and it needs no ceremony.
/// - `setWallClock(to:)` moves the wall clock **alone**. Nobody can set the uptime counter, so
///   this is what changing the date in System Settings looks like from in here — the tampering
///   scenario, and the one the guard is about.
final class FakeClock: Clock, @unchecked Sendable {
    private var wall: Date
    private(set) var uptime: TimeInterval

    /// The wall clock. Setting it forward carries the uptime counter with it: "it is now 22:00"
    /// almost always means "ten hours passed", not "somebody edited the date". Setting it
    /// backwards leaves uptime where it is, because a real one cannot go back — which makes a
    /// backwards assignment a clock change on its own.
    var now: Date {
        get { wall }
        set {
            uptime += max(0, newValue.timeIntervalSince(wall))
            wall = newValue
        }
    }

    /// Uptime starts well clear of zero, so a test can drop it to simulate a reboot.
    init(_ start: Date, uptime: TimeInterval = 10_000) {
        wall = start
        self.uptime = uptime
    }

    func advance(seconds: TimeInterval) {
        wall = wall.addingTimeInterval(seconds)
        uptime += seconds
    }

    /// Moves the wall clock and nothing else: somebody in the Date & Time pane.
    func setWallClock(to date: Date) { wall = date }

    /// Moves the wall clock by a length and nothing else.
    func moveWallClock(by seconds: TimeInterval) { wall = wall.addingTimeInterval(seconds) }

    /// A machine that has restarted: uptime begins again, the wall clock carries on.
    func reboot(uptime restarted: TimeInterval = 5) { uptime = restarted }
}

// MARK: - The pinned zone

// Schedules, day keys and week keys are all wall-clock arithmetic, so the machine's own
// time zone would otherwise decide whether a test passes. Everything below — the moments
// the tests build and the calendar the engines run on — goes through one pinned zone, and
// the suite gives the same answer under `TZ=UTC` as it does anywhere else. Berlin is a
// zone that switches DST, which some tests need.

let testZone = TimeZone(identifier: "Europe/Berlin")!

let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = testZone
    return calendar
}()

/// A moment in 2026 — the year every engine test lives in — read in the pinned zone.
func localTime(month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
    testCalendar.date(
        from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)
    )!
}

/// August shorthand — the month most fixtures live in, so day numbers alone identify one:
/// 10th = Monday, 14th = Friday, 15th = Saturday, 16th = Sunday, 17th = Monday of the
/// following ISO week (2026-W34).
func august(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    localTime(month: 8, day: day, hour: hour, minute: minute)
}

/// Monday, so weekday-based schedule tests can reuse the same fixture.
let noon = august(10, 12)

/// Default group of the single-target fixture: one target is its own group.
let youtubeGroup = "domain:youtube.com"

/// Second group of the two-group fixture.
let redditGroup = "domain:reddit.com"

/// The default strict window: office hours on weekdays (Calendar.weekday 2 = Monday).
let officeHours = strictWindow(weekdays: [2, 3, 4, 5, 6], from: 540, to: 1020)

/// Bedtime: 22:00 to 08:00 every night, the shape V1's schedule could not express at all.
let bedtime = strictWindow(weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)

/// Standard's knobs with a week drawn on them — the shape most of these tests need.
///
/// It used to be `GroupSettings.strict(windows:)`, which said Standard's values plus a window
/// *were* the Strict preset. They are not: a preset owns the friction knobs and a window belongs
/// to the group, so these settings read as Standard and `GroupSettings.strict` is its own set of
/// harder knobs. Here rather than on the type because nothing outside this suite needs it.
func standardSettings(windows: [TimeWindow]) -> GroupSettings {
    var settings = GroupSettings.standard
    settings.timeWindows = windows
    return settings
}

/// A window with a fixed id, so a fixture used in two places stays comparable.
func strictWindow(weekdays: Set<Int>, from start: Int, to end: Int) -> TimeWindow {
    window(.strictBlock, weekdays: weekdays, from: start, to: end)
}

func window(
    _ kind: TimeWindow.Kind, weekdays: Set<Int>, from start: Int, to end: Int
) -> TimeWindow {
    TimeWindow(
        id: "\(kind.rawValue)-\(weekdays.sorted().map(String.init).joined())-\(start)-\(end)",
        kind: kind,
        weekdays: weekdays,
        startMinutes: start,
        endMinutes: end
    )
}

// MARK: - Engines

/// The one place an engine is built. Every other builder goes through here, so the pinned
/// calendar is written down once and cannot drift between fixtures.
func makeEngine(
    targets: [Target],
    groupSettings: [String: GroupSettings],
    state: EngineState? = nil,
    clock: FakeClock,
    preventTimeChange: Bool = true,
    dayStartMinutes: Int = EngineState.defaultDayStartMinutes
) -> RulesEngine {
    let config = Config(
        version: 1,
        targets: targets,
        groupSettings: groupSettings,
        dayStartMinutes: dayStartMinutes,
        preventTimeChange: preventTimeChange
    )
    return RulesEngine(
        config: config,
        state: state ?? initialState(clock),
        clock: clock,
        calendar: testCalendar
    )
}

/// A clean state on the pinned calendar, for tests that then doctor one field.
func initialState(_ clock: FakeClock) -> EngineState {
    .initial(now: clock.now, calendar: testCalendar)
}

/// One domain target in its own group — the default shape for most tests.
///
/// `preventTimeChange` is on by default, exactly as a real configuration has it. A test that wants
/// to watch what a wrong clock does to the arithmetic *underneath* the block turns it off.
func makeEngine(
    settings: GroupSettings = .standard,
    clock: FakeClock,
    preventTimeChange: Bool = true,
    dayStartMinutes: Int = EngineState.defaultDayStartMinutes
) -> (RulesEngine, Target) {
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let engine = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: settings],
        clock: clock,
        preventTimeChange: preventTimeChange,
        dayStartMinutes: dayStartMinutes
    )
    return (engine, target)
}

/// The same single target, hard-blocked during office hours.
func makeStrictEngine(clock: FakeClock) -> (RulesEngine, Target) {
    makeEngine(settings: standardSettings(windows: [officeHours]), clock: clock)
}

/// An app and a domain sharing one group, so budget/session sharing can be observed.
func makeGroupedEngine(clock: FakeClock) -> (RulesEngine, Target, Target) {
    let app = Target(kind: .app, value: "com.google.Chrome", displayName: "Chrome", groupID: "grp:yt")
    let site = Target(kind: .domain, value: "youtube.com", displayName: "YouTube", groupID: "grp:yt")
    let engine = makeEngine(targets: [app, site], groupSettings: ["grp:yt": .standard], clock: clock)
    return (engine, app, site)
}

/// Two independent groups, so "every group" and "only this group" can be told apart.
func makeTwoGroupEngine(
    youtube: GroupSettings,
    reddit: GroupSettings = .standard,
    clock: FakeClock
) -> (RulesEngine, Target, Target) {
    let site = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let other = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
    let engine = makeEngine(
        targets: [site, other],
        groupSettings: [site.groupID: youtube, other.groupID: reddit],
        clock: clock
    )
    return (engine, site, other)
}

// MARK: - Driving

/// Spend one open and get back to a clean slate: session ended, cooldown elapsed.
func spendOneOpen(_ engine: RulesEngine, _ targetID: String, _ clock: FakeClock) {
    _ = engine.consumeOpen(targetID: targetID)
    engine.endSession(targetID: targetID, early: false)
    clock.advance(seconds: TimeInterval(GroupSettings.standard.cooldownMinutes * 60 + 1))
}

func opensUsed(_ engine: RulesEngine, _ groupID: String = youtubeGroup) -> Double {
    engine.state.opensUsed[groupID] ?? 0
}

/// An edit that must land.
///
/// `RulesEngine.updateConfig` refuses nothing and cannot throw, so `expectNoThrow` around it would
/// be a check that passes whatever the engine does with the configuration. What is worth stating
/// instead is the thing the old refusals used to prevent: the engine is running on the edit
/// afterwards. See `RulesEngine.updateConfig`, and `EditDirection` for the lock rule.
func expectEdit(_ engine: RulesEngine, _ name: String, _ build: () -> Config) {
    let newConfig = build()
    engine.updateConfig(newConfig)
    expectEqual(engine.config, newConfig, name)
}

/// An undo of today that must land, checked the same way and for the same reason: what it did,
/// rather than that it did not throw. `deniedAttempts` is deliberately not in the list — a day
/// already blown stays blown. See `DayReset.handBackToday`.
func expectResetToday(_ engine: RulesEngine, _ name: String) {
    engine.resetToday()
    let handedBack = engine.state.opensUsed.isEmpty
        && engine.state.usageSecondsToday.isEmpty
        && engine.state.cooldownUntil.isEmpty
        && engine.state.opensAvoided == 0
    expect(handedBack, name)
}

// MARK: - Expected decisions

// The user-visible strings are spelled out in full by one test each (fresh pause,
// cooldown, exhausted budget); everywhere else these builders keep the copy in one place.

/// `minutesLeft` is what a group with a daily time limit adds to the sentence — the pause screen
/// reports every budget that is on, so a fixture that only ever named the opens would be a
/// fixture that could not describe a group with both. See `GroupBudget.line`.
func pauseDecision(
    countdown: Int, opensLeft: Int, of total: Int, minutesLeft: Int? = nil
) -> Decision {
    var parts = ["\(opensLeft) of \(total) opens"]
    if let minutesLeft { parts.append("\(minutesLeft) min") }
    return .pause(
        countdownSeconds: countdown,
        budgetLine: "\(parts.joined(separator: " and ")) left today"
    )
}

func cooldownDecision(minutes: Int) -> Decision {
    .blocked(reason: .cooldown, untilText: "Next open in \(minutes) min")
}

let budgetExhaustedDecision = Decision.blocked(reason: .budgetExhausted, untilText: "Blocked until 03:00")

let clockTamperedDecision = Decision.blocked(
    reason: .clockTampered, untilText: "System clock was changed"
)

func scheduleDecision(until clockTime: String) -> Decision {
    .blocked(reason: .schedule, untilText: "Blocked until \(clockTime)")
}

/// What a week with no gap in it says instead. There is no hour to name — see `BlockEnd`, and
/// `BlockEndTests` for the near misses that keep theirs.
let aroundTheClockDecision = Decision.blocked(
    reason: .schedule, untilText: "Blocked around the clock"
)

func focusDecision(until clockTime: String) -> Decision {
    .blocked(reason: .focusSession, untilText: "Blocked until \(clockTime)")
}

/// A one-shot block, which names a day rather than an hour. See `DatedBlock`.
func datedDecision(until dayText: String) -> Decision {
    .blocked(reason: .datedBlock, untilText: "Blocked until \(dayText)")
}

/// Standard's knobs with a day to be blocked until — the shape the dated-block tests need.
func datedSettings(until day: String, windows: [TimeWindow] = []) -> GroupSettings {
    var settings = standardSettings(windows: windows)
    settings.blockedUntilDay = day
    return settings
}
