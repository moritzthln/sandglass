import SandglassAppCore
import SandglassCore
import Foundation

// The V1.1 wiring, driven through a whole `AppState`: the loop that counts a second, the two
// ways back out of a block, and the daily limit those seconds add up to.
//
// Shared doubles and fixtures (RecordingBlocker, withTempDir, makeState) live in
// AppStateFixtures.swift; the moments come from EngineFixtures.swift.

func runAppStateUsageTests() {
    MainActor.assumeIsolated {
        testTheLoopChargesTheFrontmostApp()
        testTimeIsCountedThroughABreakAndAPassAlike()
        testUsageOnlySecondsAreCoalescedAndFlushedOnQuit()
        testReachingTheLimitBlocksAndRelocks()
        testWebUsageIsChargedToTheSiteGroup()
        testBreakLengthIsChosenAndCanBeEndedEarly()
        testEmergencyPassLiftsAWindowAndSaysSo()
    }
}

/// Notes and youtube.com sharing one group, so app time and website time land in the same total.
private func limitedConfig(minutes: Int?) -> Config {
    var settings = GroupSettings.standard
    settings.dailyMinutes = minutes
    let app = Target(kind: .app, value: "com.apple.Notes", displayName: "Notes", groupID: "grp:demo")
    let site = Target(kind: .domain, value: "youtube.com", displayName: "YouTube", groupID: "grp:demo")
    return Config(
        version: 1,
        targets: [app, site],
        groupSettings: ["grp:demo": settings]
    )
}

@MainActor
private func run(_ state: AppState, _ clock: FakeClock, ticks: Int) {
    for _ in 0..<ticks {
        clock.advance(seconds: 1)
        state.tickForTesting()
    }
}

// MARK: - Counting

/// One second per tick, charged to the group of whatever the blocker says is in front — which
/// is also the seam where a locked screen and Sandglass's own overlay become "nobody is looking".
@MainActor
private func testTheLoopChargesTheFrontmostApp() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(limitedConfig(minutes: nil))
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()

        run(state, clock, ticks: 3)
        expectEqual(state.stats.usageSecondsToday, [:], "nothing in front, nothing counted")

        blocker.frontmost = "com.apple.Notes"
        run(state, clock, ticks: 5)
        expectEqual(state.stats.usageSecondsToday, ["grp:demo": 5], "five ticks in Notes is five seconds")

        blocker.frontmost = "com.apple.TextEdit"
        run(state, clock, ticks: 5)
        expectEqual(
            state.stats.usageSecondsToday, ["grp:demo": 5],
            "and an app under no rule is not counted against anybody"
        )
    }
}

/// A break lifts the blocking, not the hour. Time spent is time spent, however it was bought —
/// and a "0m used today" after an hour under an emergency pass would be the app lying about the
/// one number it exists to tell the truth about.
@MainActor
private func testTimeIsCountedThroughABreakAndAPassAlike() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(limitedConfig(minutes: nil))
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()

        afterTheUnblockWait(state, clock)
        state.startBreak(minutes: 5)
        blocker.frontmost = "com.apple.Notes"
        run(state, clock, ticks: 10)
        expectEqual(
            state.stats.usageSecondsToday, ["grp:demo": 10],
            "the break lifts the block, and the minutes still land on the day's total"
        )

        state.endPauseEarly()
        run(state, clock, ticks: 4)
        expectEqual(state.stats.usageSecondsToday, ["grp:demo": 14], "counting never stopped")

        expect(state.useEmergencyPass(), "the week's pass is spent")
        run(state, clock, ticks: 6)
        expectEqual(
            state.stats.usageSecondsToday, ["grp:demo": 20],
            "and an hour under the pass is an hour the stats screen has to be able to show"
        )
    }
}

/// The 1 Hz loop bumps `usageSecondsToday` every second somebody is in a managed app. Writing the
/// whole document for that would be an fsync per second, all day — so a run of usage-only changes
/// is coalesced, and going away flushes whatever the window is still holding.
@MainActor
private func testUsageOnlySecondsAreCoalescedAndFlushedOnQuit() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(limitedConfig(minutes: nil))
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        // Nothing was on disk, so priming writes the baseline the window is measured from.
        state.prime()
        blocker.frontmost = "com.apple.Notes"

        run(state, clock, ticks: 14)
        expectEqual(state.stats.usageSecondsToday, ["grp:demo": 14], "fourteen seconds have been counted")
        expectEqual(savedUsage(dir), [:], "and the disk has not been touched for any of them")

        run(state, clock, ticks: 1)
        expectEqual(savedUsage(dir), ["grp:demo": 15], "past fifteen seconds, the whole run is written in one go")

        // A change that is not just usage is never held back: it carries the pending seconds
        // with it, wherever in the window it happens to fall.
        run(state, clock, ticks: 3)
        expectEqual(savedUsage(dir), ["grp:demo": 15], "three more seconds wait their turn")
        _ = state.consumeOpen(targetID: "app:com.apple.Notes")
        expectEqual(savedUsage(dir), ["grp:demo": 18], "and an open spent takes them to disk with it")

        // The case a quit would otherwise lose: seconds counted inside the window, with no
        // further mutation coming to carry them.
        run(state, clock, ticks: 4)
        expectEqual(savedUsage(dir), ["grp:demo": 18], "four seconds are still only in memory")
        state.stop()
        expectEqual(savedUsage(dir), ["grp:demo": 22], "and quitting writes them rather than dropping them")
    }
}

/// What `state.json` actually says about today's usage, read back through the same `Store` the
/// app writes it with. `[:]` for a file that is not there or cannot be read — neither of which
/// any case here should be able to produce.
@MainActor
private func savedUsage(_ dir: URL) -> [String: Int] {
    guard case .loaded(let saved) = Store(directory: dir).loadStateOutcome() else { return [:] }
    return saved.usageSecondsToday
}

/// End to end: seconds accrue, the limit is reached, the session it was in the middle of ends,
/// the apps are sent away and the popover says why.
@MainActor
private func testReachingTheLimitBlocksAndRelocks() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(limitedConfig(minutes: 1))
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()
        blocker.frontmost = "com.apple.Notes"

        // Standard's open is five minutes and the day's limit is one, so one minute is what is
        // sold: a session is never granted for longer than the day has left. It used to hand out
        // the full five and take four of them back a minute later.
        expectEqual(
            state.consumeOpen(targetID: "app:com.apple.Notes"), .granted(sessionSeconds: 60),
            "the open is cut to the minute the day still has in it"
        )
        run(state, clock, ticks: 30)
        expect(state.activeSession != nil, "half a minute in, the session is still running")

        run(state, clock, ticks: 31)                      // past the minute, plus a tick to deliver
        expectNil(state.activeSession, "the limit ends the session rather than letting it run out")
        expect(blocker.hidden.contains("com.apple.Notes"), "and the app is sent away")
        expectEqual(
            state.budgetsByGroup.first?.line, "Blocked until 03:00",
            "the popover names the block the day's time limit put up"
        )
        expectEqual(
            state.blockDecision(forBundleID: "com.apple.Notes"),
            .blocked(reason: .timeLimit, untilText: "Blocked until 03:00"),
            "and so does the decision the overlay is built from"
        )
    }
}

/// The second the page in front is charged, which the browser watcher reports from inside the
/// same tick that charges the frontmost app — one counting path, so nothing is charged twice.
@MainActor
private func testWebUsageIsChargedToTheSiteGroup() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(limitedConfig(minutes: nil))
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()

        state.recordPageSecond(forURL: "www.youtube.com")
        state.recordPageSecond(forURL: "m.youtube.com")
        state.recordPageSecond(forURL: "news.ycombinator.com")
        // The loop is what publishes them, exactly as it does for the app path: the blocker
        // charges these from inside a tick, and the tick's own `finishMutation` follows.
        state.tickForTesting()
        expectEqual(
            state.stats.usageSecondsToday, ["grp:demo": 2],
            "every subdomain of the rule counts, and a site under no rule counts for nothing"
        )
    }
}

// MARK: - The two ways out

@MainActor
private func testBreakLengthIsChosenAndCanBeEndedEarly() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(limitedConfig(minutes: nil))
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()

        // The wait is the window's and is spent before a length is offered at all, so the break
        // starts the second one is picked: thirty seconds of waiting, then the minute it bought.
        afterTheUnblockWait(state, clock)
        expectNil(state.startBreak(minutes: 1), "a length is picked on the far side of the wait")
        expectEqual(
            state.statusKind, .paused(until: noon.addingTimeInterval(30 + 60)),
            "the break lasts the minute that was asked for, not the default ten"
        )

        let rechecks = blocker.recheckCount
        state.endPauseEarly()
        expectEqual(state.statusKind, .active(targetCount: 2), "ending it puts the blocks straight back")
        expect(blocker.recheckCount > rechecks, "and whatever is on screen is decided again")
    }
}

@MainActor
private func testEmergencyPassLiftsAWindowAndSaysSo() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let clock = FakeClock(august(10, 10, 30))          // Monday, inside the 10:00–11:00 window
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()

        expectEqual(state.budgetsByGroup.first?.line, "Blocked until 11:00", "the window is blocking")
        expect(state.emergencyPassAvailable, "and this week's pass is unspent")
        expectEqual(state.emergencyPassLine, "One pass left this week", "which the settings section says")

        let rechecks = blocker.recheckCount
        expect(state.useEmergencyPass(), "spending it goes through")
        expectEqual(
            state.statusKind, .emergencyPass(until: august(10, 11, 30)),
            "the menu bar shows the hour it bought"
        )
        expect(blocker.recheckCount > rechecks, "and whatever is on screen is decided again")
        expect(!state.emergencyPassAvailable, "the week's pass is spent")
        expectEqual(
            state.emergencyPassLine, "Everything is unblocked until 11:30",
            "and the section says what is happening rather than what is left"
        )

        expect(!state.useEmergencyPass(), "a second one this week is refused")

        clock.advance(seconds: 3600)
        state.tickForTesting()
        expectEqual(state.statusKind, .active(targetCount: 1), "the hour ends and the window is back")
        expectEqual(
            state.emergencyPassLine, "Used this week · available again on Monday",
            "with the next one named"
        )
    }
}
