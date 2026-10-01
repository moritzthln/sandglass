import Foundation
import SandglassCore

/// Telling a clock that was *set* from one that was merely left to run — and what the engine does
/// with the difference.
///
/// The durations are safe without any of this (see `RulesEngineClockJumpTests`): they are measured
/// against uptime and cannot be shortened. What is left are the two things that genuinely mean
/// local time — the 03:00 day boundary and the weekday windows — and they are read against the
/// time it *would* be rather than the time the Mac claims. On top of that sits one switch:
/// `preventTimeChange`, which blocks every managed group for as long as the two clocks disagree.
func runEngineClockTamperTests() {
    testSleepIsNotAClockChange()
    testACorrectionUnderFiveMinutesIsNotAClockChange()
    testTheDayKeyRunsOnTheExtrapolationWhileTheClockIsWrong()
    testAWindowOpensOnTheExtrapolationRatherThanTheReportedClock()
    testTheFlagBlocksEveryGroupWhileTheClockIsWrong()
    testWithoutTheFlagOnlyTheExtrapolationApplies()
    testTheBlockLiftsWhenTheClockAgreesAgain()
}

// MARK: - What is not a clock change

/// The false positive that would matter most: a Mac is asleep far more often than its clock is
/// edited, and a night with the lid shut moves the wall clock by eight hours. It moves the uptime
/// counter by the same eight — see `SystemClock.uptime` — so the two still agree.
private func testSleepIsNotAClockChange() {
    let clock = FakeClock(august(10, 22))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    _ = engine.tick()

    clock.advance(seconds: 8 * 3600)
    _ = engine.tick()

    expect(!engine.clockWasChanged, "eight hours of sleep is not a clock change")
    expectNil(engine.clockWarningLine, "so nothing is announced about it")
    expectEqual(engine.state.dayKey, "2026-08-11", "the day rolled over while the Mac slept")
    expectEqual(
        engine.decision(targetID: target.id), pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and the morning starts with a whole budget, not a block"
    )
}

/// The other one: a clock that is a few minutes out and gets corrected. Under the tolerance, and
/// deliberately the same five minutes the backwards guard uses.
private func testACorrectionUnderFiveMinutesIsNotAClockChange() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)

    clock.moveWallClock(by: 4 * 60)
    _ = engine.tick()

    expect(!engine.clockWasChanged, "four minutes is a correction, not a change")
    expectEqual(
        engine.decision(targetID: target.id), pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and nothing is blocked over it"
    )
}

// MARK: - The extrapolated clock

/// Winding past 03:00 is the interesting wall-clock attack: the durations cannot be shortened, but
/// a day that rolled over would hand out a whole new budget.
private func testTheDayKeyRunsOnTheExtrapolationWhileTheClockIsWrong() {
    let clock = FakeClock(august(11, 2, 0))          // an hour before the day rolls
    let (engine, target) = makeEngine(clock: clock, preventTimeChange: false)
    _ = engine.consumeOpen(targetID: target.id)
    expectEqual(engine.state.dayKey, "2026-08-10", "02:00 belongs to the night before it")

    clock.setWallClock(to: august(11, 4, 0))
    _ = engine.tick()
    expectEqual(engine.state.dayKey, "2026-08-10", "a clock set past 03:00 does not roll the day")
    expectEqual(opensUsed(engine), 1, "nor hand back the open that was spent")

    clock.advance(seconds: 2 * 3600)                 // 04:00, this time for real
    _ = engine.tick()
    expectEqual(engine.state.dayKey, "2026-08-11", "two real hours do roll it")
    expectEqual(opensUsed(engine), 0, "with the fresh budget that comes with it")
}

/// The same for a window, in the direction that costs the user rather than the app: a clock set
/// *into* office hours must not start the block, or the app would be blocking on a lie.
private func testAWindowOpensOnTheExtrapolationRatherThanTheReportedClock() {
    let clock = FakeClock(august(10, 8, 55))         // Monday, five minutes before office hours
    let (engine, target) = makeEngine(
        settings: standardSettings(windows: [officeHours]), clock: clock, preventTimeChange: false
    )
    let openGroup = pauseDecision(countdown: 10, opensLeft: 5, of: 5)
    expectEqual(engine.decision(targetID: target.id), openGroup, "not blocked yet")

    clock.setWallClock(to: august(10, 10))
    expectEqual(
        engine.decision(targetID: target.id), openGroup, "a clock set into the window does not open it"
    )

    clock.advance(seconds: 6 * 60)                   // 09:01, for real
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "17:00"),
        "six real minutes do"
    )
}

// MARK: - The switch

private func testTheFlagBlocksEveryGroupWhileTheClockIsWrong() {
    let clock = FakeClock(noon)
    let (engine, youtube, reddit) = makeTwoGroupEngine(youtube: .standard, clock: clock)

    clock.setWallClock(to: august(10, 14))
    _ = engine.tick()

    expectEqual(engine.decision(targetID: youtube.id), clockTamperedDecision, "the group is held")
    expectEqual(
        engine.decision(targetID: reddit.id), clockTamperedDecision,
        "and so is every other managed group, not only the one that was asked about"
    )
    expectEqualText(
        engine.clockWarningLine, "System clock was changed — blocks held", "the menu bar says so"
    )

    expect(engine.useEmergencyPass(), "the week's pass can still be spent")
    expectEqual(
        engine.decision(targetID: youtube.id), clockTamperedDecision,
        "but it is a way out of a block, not a way out of not knowing the time"
    )
}

private func testWithoutTheFlagOnlyTheExtrapolationApplies() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock, preventTimeChange: false)

    clock.setWallClock(to: august(10, 14))
    _ = engine.tick()

    expect(engine.clockWasChanged, "the change is noticed either way")
    expectEqual(
        engine.decision(targetID: target.id), pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and the group is judged on the extrapolated clock rather than blocked"
    )
}

/// The block has to be able to end, and putting the clock back is the way: hold it any longer and
/// it would be a punishment rather than a refusal to guess.
private func testTheBlockLiftsWhenTheClockAgreesAgain() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)

    clock.setWallClock(to: august(10, 14))
    _ = engine.tick()
    expectEqual(engine.decision(targetID: target.id), clockTamperedDecision, "blocked while wrong")

    clock.setWallClock(to: august(10, 12))
    _ = engine.tick()
    expect(!engine.clockWasChanged, "the clock agrees again")
    expectNil(engine.clockWarningLine, "so the warning goes")
    expectEqual(
        engine.decision(targetID: target.id), pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and the block goes with it"
    )
}
