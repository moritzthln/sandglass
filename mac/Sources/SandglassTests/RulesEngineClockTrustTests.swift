import Foundation
import SandglassCore

/// What the engine may believe about the clock across a launch, over many small steps, over a
/// change of day start and over a flight.
///
/// `RulesEngineClockJumpTests` and `RulesEngineClockTamperTests` are about one clock change under
/// a running engine. These are the ways round them: quitting and starting again on a moved clock,
/// walking the clock forward four minutes at a time, and every place the day key could be talked
/// into going backwards.
func runEngineClockTrustTests() {
    testARelaunchOnTheSameBootDoesNotBelieveAMovedClock()
    testARelaunchOnTheSameBootRemembersTheHighWater()
    testARelaunchOnTheSameBootHoldsAStrictWindow()
    testARebootIsWhereTheClockIsBelievedAgain()
    testARebootTheUptimeCannotSeeStillDropsTheTwins()
    testTheAnchorIsNotWrittenEverySecond()
    testSmallStepsAddUpToAClockChange()
    testHonestDriftIsFollowedSlowly()
    testTheDayRollsForwardOnly()
    testADayFarAheadIsLetGoWithoutAFreshBudget()
    testMovingTheDayStartLaterScoresNoDayTwice()
    testThePassAndTheFreezeShareOneWeek()
    testATimeZoneChangeIsFollowed()
    testTheEnginesDayIsTheGuardedOne()
}

// MARK: - Across a launch

/// Spend the budget, quit, set the clock back a day, start again: the relaunch used to anchor on
/// whatever the clock said and roll the day over into a fresh budget. Two minutes of real time
/// have passed and the uptime counter says so.
private func testARelaunchOnTheSameBootDoesNotBelieveAMovedClock() {
    let clock = FakeClock(august(11, 12))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    _ = engine.tick()
    let saved = engine.state
    expect(saved.clockAnchor != nil, "the state carries the reading the engine last believed")

    let relaunched = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: saved,
        clock: FakeClock(august(10, 12), uptime: 10_000 + 120)
    )
    _ = relaunched.tick()
    expect(relaunched.clockWasChanged, "a day back on the same boot is a clock change")
    expectEqual(relaunched.state.dayKey, "2026-08-11", "the day is held where it was")
    expectEqual(opensUsed(relaunched), 1, "and so is the open that was spent")
}

/// The backwards warning across a launch: the mark is persisted with the anchor, so the relaunch
/// knows it is behind what the last run had already seen.
private func testARelaunchOnTheSameBootRemembersTheHighWater() {
    let clock = FakeClock(august(11, 12))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.tick()

    let relaunched = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: engine.state,
        clock: FakeClock(august(11, 9), uptime: 10_000 + 60)
    )
    expectEqualText(
        relaunched.clockWarningLine, "System clock moved backwards — counters held",
        "the relaunch says the clock is behind"
    )
}

/// The evening block, skipped by quitting and starting again with the clock set past its end.
private func testARelaunchOnTheSameBootHoldsAStrictWindow() {
    let clock = FakeClock(august(10, 16, 30))
    let (engine, target) = makeEngine(
        settings: standardSettings(windows: [officeHours]), clock: clock, preventTimeChange: false
    )
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "blocked")

    let relaunched = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: standardSettings(windows: [officeHours])],
        state: engine.state,
        clock: FakeClock(august(10, 18), uptime: 10_000 + 60),
        preventTimeChange: false
    )
    expectEqual(
        relaunched.decision(targetID: target.id), scheduleDecision(until: "17:00"),
        "a minute of real time later the window is still standing"
    )
}

/// The honest limit, stated: uptime starts again at a reboot, so nothing can vouch for the stored
/// anchor and the clock is believed. The day key still only moves forward — see below.
private func testARebootIsWhereTheClockIsBelievedAgain() {
    let clock = FakeClock(august(11, 12))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.tick()

    let restarted = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: engine.state,
        clock: FakeClock(august(11, 18), uptime: 30)
    )
    _ = restarted.tick()
    expect(!restarted.clockWasChanged, "after a reboot there is nothing to disagree with")
    expectNil(restarted.clockWarningLine, "and nothing is announced")
}

/// A state that moves every second is an fsync every second. The anchor is written when it is
/// taken and then at most once an hour.
private func testTheAnchorIsNotWrittenEverySecond() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    _ = engine.tick()
    let first = engine.state.clockAnchor
    for _ in 0..<120 {
        clock.advance(seconds: 1)
        _ = engine.tick()
    }
    expectEqual(engine.state.clockAnchor, first, "two minutes of ticks leave the anchor alone")

    clock.advance(seconds: 3600)
    _ = engine.tick()
    expect(engine.state.clockAnchor != first, "an hour later it is taken again")
}

/// A reboot the uptime comparison cannot see: the new boot has already run longer than the old
/// one had when it last wrote a twin. The boot names differ, so the twins are measured from a
/// counter that no longer exists and have to go — the session is then judged by its wall end,
/// which is two hours behind us, instead of running on for the twin's remaining minutes.
private func testARebootTheUptimeCannotSeeStillDropsTheTwins() {
    let clock = FakeClock(august(11, 12), uptime: 1_000, bootSession: "boot-1")
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    _ = engine.tick()
    expect(engine.state.sessions[target.groupID] != nil, "a session is running before the reboot")

    let restarted = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: engine.state,
        clock: FakeClock(august(11, 14), uptime: 1_100, bootSession: "boot-2")
    )
    _ = restarted.tick()
    expectNil(restarted.state.sessions[target.groupID], "the session ended at its wall time")
}

// MARK: - Many small steps

/// Four minutes at a time, each under the five-minute tolerance: the anchor used to follow every
/// step, so the wall clock could be walked out of a strict window without the detector noticing.
private func testSmallStepsAddUpToAClockChange() {
    let clock = FakeClock(august(10, 16, 40))
    let (engine, target) = makeEngine(
        settings: standardSettings(windows: [officeHours]), clock: clock, preventTimeChange: false
    )
    for _ in 0..<6 {
        clock.moveWallClock(by: 4 * 60)
        clock.advance(seconds: 5)
        _ = engine.tick()
    }
    expect(engine.clockWasChanged, "twenty-four minutes of steps are a clock change")
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "17:00"),
        "and the window is read against the time it really is"
    )
}

/// The other side of that: a clock a few seconds out that NTP keeps correcting is followed, at a
/// rate no person stepping the clock could use.
private func testHonestDriftIsFollowedSlowly() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    _ = engine.tick()
    // Two seconds a day for ten weeks: 140 seconds, under the tolerance anyway — and then a
    // further four minutes of real correction, which is only fine because the anchor followed.
    for _ in 0..<70 {
        clock.advance(seconds: 86_400)
        clock.moveWallClock(by: 2)
        _ = engine.tick()
    }
    clock.moveWallClock(by: 4 * 60)
    _ = engine.tick()
    expect(!engine.clockWasChanged, "drift the anchor followed is not a clock change")
}

// MARK: - The day key

/// The day is a counter of days lived, so it only moves forward. A reboot is where the clock is
/// believed again, and even there a day back is not a fresh budget.
private func testTheDayRollsForwardOnly() {
    let clock = FakeClock(august(11, 3, 30))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)

    let restarted = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: engine.state,
        clock: FakeClock(august(10, 20), uptime: 30)
    )
    _ = restarted.tick()
    expectEqual(restarted.state.dayKey, "2026-08-11", "a day back after a reboot is not a new day")
    expectEqual(opensUsed(restarted), 1, "and the open spent is still spent")
}

/// A day key weeks ahead of the clock cannot be a day this Mac lived: a clock set into the future
/// across a reboot and then put right. It is let go rather than held for weeks — and let go
/// without a fresh budget or a scored day, so walking it there and back buys nothing.
private func testADayFarAheadIsLetGoWithoutAFreshBudget() {
    let clock = FakeClock(august(10, 12))
    var state = initialState(clock)
    state.dayKey = "2026-09-30"
    state.opensUsed = [youtubeGroup: 2]
    state.streakDays = 4
    let (_, target) = makeEngine(clock: clock)
    let engine = makeEngine(
        targets: [target], groupSettings: [target.groupID: .standard], state: state, clock: clock
    )
    _ = engine.tick()
    expectEqual(engine.state.dayKey, "2026-08-10", "the day comes back to the one it is")
    expectEqual(opensUsed(engine), 2, "with the counters it had")
    expectEqual(engine.state.streakDays, 4, "and the streak untouched")
}

/// 02:00 with the day starting at 01:00 is the new day already. Moving the start to 03:00 used to
/// rebase the key back a day, and at 03:00 that day rolled over a second time and scored again.
private func testMovingTheDayStartLaterScoresNoDayTwice() {
    let clock = FakeClock(august(10, 12))
    let (engine, target) = makeEngine(clock: clock, dayStartMinutes: 60)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)
    clock.now = august(11, 2)
    _ = engine.tick()
    expectEqual(engine.state.dayKey, "2026-08-11", "the day rolled at 01:00")
    expectEqual(engine.state.streakDays, 1, "and the tenth was scored")
    _ = engine.consumeOpen(targetID: target.id)

    var later = engine.config
    later.dayStartMinutes = 180
    engine.updateConfig(later)
    expectEqual(engine.state.dayKey, "2026-08-11", "the key does not go back a day")

    clock.now = august(11, 3, 30)
    _ = engine.tick()
    expectEqual(engine.state.streakDays, 1, "and no day is scored twice")
    expectEqual(opensUsed(engine), 1, "nor are today's counters cleared at 03:00")
}

/// Monday 01:00 is still Sunday's logical day, and the freeze is charged to that day's week. The
/// pass used to be charged to the raw ISO week, so the two disagreed until the day started.
private func testThePassAndTheFreezeShareOneWeek() {
    let clock = FakeClock(august(16, 20))
    let (engine, _) = makeEngine(clock: clock)
    expect(engine.useEmergencyPass(), "the pass is spent on Sunday evening")

    clock.now = august(17, 1)
    expect(!engine.emergencyPassAvailable, "Monday 01:00 is still Sunday's week")

    clock.now = august(17, 4)
    expect(engine.emergencyPassAvailable, "and the new week starts with the day")
}

/// After a flight the windows are read in the zone the Mac is in now, not the one it launched in.
private func testATimeZoneChangeIsFollowed() {
    let clock = FakeClock(august(10, 12))
    let (engine, target) = makeEngine(
        settings: standardSettings(windows: [officeHours]), clock: clock, preventTimeChange: false
    )
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "blocked")

    // Noon in Berlin is 03:00 in Los Angeles: office hours are not open there.
    engine.adoptTimeZone(TimeZone(identifier: "America/Los_Angeles")!)
    expectEqual(
        engine.decision(targetID: target.id), pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "the window follows the zone the Mac is in"
    )
    expectEqual(engine.timeZone.identifier, "America/Los_Angeles", "and the engine says which")
}

/// What the app asks when it needs to know which day it is — a dated block's end — has to be the
/// engine's guarded day, not the raw clock's.
private func testTheEnginesDayIsTheGuardedOne() {
    let clock = FakeClock(august(11, 12))
    let (engine, _) = makeEngine(clock: clock)
    _ = engine.tick()
    expectEqual(engine.today, "2026-08-11", "today, in the engine's words")

    clock.setWallClock(to: august(25, 12))
    expectEqual(engine.today, "2026-08-11", "a clock set two weeks ahead does not move it")
}
