import SandglassAppCore
import SandglassCore
import Foundation

/// The app's half of the clock: every place above the engine that used to read the system clock
/// for itself — "today", the session row, the waits a block page serves, the two-second guards —
/// and the time zone the app runs in.
///
/// `RulesEngineClockTrustTests` is the engine's half. What is pinned here is that the app asks
/// the engine, or measures on uptime, rather than keeping a second opinion about the time.
func runAppStateClockTests() {
    MainActor.assumeIsolated {
        testAClockSetPastADatedBlockDoesNotDeleteIt()
        testTheSessionRowSurvivesAClockSetForward()
        testATimeZoneChangeReachesTheApp()
    }
    testAWaitIsServedInRealSeconds()
    testTheActivationGuardsIgnoreTheWallClock()
}

/// Set the clock past the block's day, make any edit: the save used to judge the day "past"
/// against the raw clock and drop it, and with it the block, for good.
@MainActor
private func testAClockSetPastADatedBlockDoesNotDeleteIt() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        var config = twoGroupConfig()
        config.groupSettings[youtubeGroup]?.blockedUntilDay = "2026-08-20"
        expectNil(state.applyConfigEdit(config), "the dated block is set")

        clock.setWallClock(to: august(25, 12))
        state.tickForTesting()
        expectEqual(state.today, "2026-08-10", "today is the engine's day, not the clock's")

        var tighter = state.config
        tighter.groupSettings[redditGroup]?.blockedUntilDay = "2026-08-30"
        expectNil(state.applyConfigEdit(tighter), "an unrelated edit goes through")
        expectEqual(
            state.config.groupSettings[youtubeGroup]?.blockedUntilDay, "2026-08-20",
            "and the block it did not touch is still written down"
        )
    }
}

/// The engine relocks a session on uptime; the row used to count down to its wall end against
/// the raw clock, so an hour on the clock hid it and took "End early" with it.
@MainActor
private func testTheSessionRowSurvivesAClockSetForward() {
    withTempDir { dir in
        let store = Store(directory: dir)
        try? store.saveConfig(groupedConfig())
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        _ = state.consumeOpen(forURL: "youtube.com")
        state.tickForTesting()
        expect(state.activeSession != nil, "the open started a session")

        clock.moveWallClock(by: 3600)
        clock.advance(seconds: 10)
        state.tickForTesting()
        expectEqual(
            state.activeSession?.secondsLeft, 290,
            "an hour of clock leaves the row counting the seconds the engine is counting"
        )
        state.endActiveSessionEarly()
        expectNil(state.activeSession, "and the session can still be ended early")
    }
}

/// The app runs in the zone the Mac is in. Noon in Berlin is 03:00 in Los Angeles, where office
/// hours are not open.
@MainActor
private func testATimeZoneChangeReachesTheApp() {
    withTempDir { dir in
        let store = Store(directory: dir)
        var config = twoGroupConfig()
        config.groupSettings[youtubeGroup]?.timeWindows = [officeHours]
        try? store.saveConfig(config)
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()
        expect(isStrict(state.blockDecision(forURL: "youtube.com")), "office hours stand in Berlin")

        state.systemTimeZoneChanged(to: TimeZone(identifier: "America/Los_Angeles")!)
        expect(
            !isStrict(state.blockDecision(forURL: "youtube.com")),
            "and not in Los Angeles"
        )
    }
}

private func isStrict(_ decision: Decision) -> Bool {
    if case .blocked(.schedule, _) = decision { return true }
    return false
}

/// A block page's wait, kept on `steadyNow`: a clock set forward an hour serves none of it.
private func testAWaitIsServedInRealSeconds() {
    let clock = FakeClock(noon)
    let tab = BrowserTab(browserID: "com.google.Chrome", tabID: nil)
    var opens = EarnedOpens()
    opens.promise(target: "instagram.com", tab: tab, countdownSeconds: 60, now: clock.steadyNow)
    opens.sighted(target: "instagram.com", tab: tab, now: clock.steadyNow)

    clock.moveWallClock(by: 3600)
    expect(
        !opens.claim(target: "instagram.com", tab: tab, now: clock.steadyNow),
        "an hour of clock is not a minute of waiting"
    )
    clock.advance(seconds: 60)
    expect(
        opens.claim(target: "instagram.com", tab: tab, now: clock.steadyNow),
        "a minute of real time is"
    )
}

/// The grace and the stale-frontmost guard, kept on `steadyNow`: a clock set back an hour does
/// not stretch two seconds into an hour, and one set forward does not skip them.
private func testTheActivationGuardsIgnoreTheWallClock() {
    let clock = FakeClock(noon)
    var grace = ActivationGrace()
    grace.grant(bundleID: "com.apple.Notes", until: clock.steadyNow.addingTimeInterval(2))
    var hidden = RecentlyHidden(window: 2)
    hidden.record("com.apple.Notes", at: clock.steadyNow)

    clock.moveWallClock(by: 3600)
    expect(grace.isPending(bundleID: "com.apple.Notes", now: clock.steadyNow), "still forgiven")
    expect(hidden.isRecent("com.apple.Notes", now: clock.steadyNow), "and still recent")

    clock.setWallClock(to: noon.addingTimeInterval(-3600))
    clock.advance(seconds: 3)
    expect(!grace.isPending(bundleID: "com.apple.Notes", now: clock.steadyNow), "three seconds on")
    expect(!hidden.isRecent("com.apple.Notes", now: clock.steadyNow), "both are over")
}
