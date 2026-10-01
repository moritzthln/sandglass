import Foundation
import SandglassCore

/// What happens when the system clock moves under a running engine.
///
/// macOS will not let an app without admin rights stop the clock being changed, so the promise is
/// the honest subset. Backwards: the engine refuses to believe it, and nothing is handed back.
/// Forwards: every wait in this app is measured against the uptime counter instead, so an hour of
/// clock buys nothing at all. The reboot at the end is where that runs out, and says what it costs.
func runEngineClockJumpTests() {
    testABackwardsJumpHoldsTheDayAndItsCounters()
    testABackwardsJumpLiftsNothingEarly()
    testDriftUnderFiveMinutesIsNotWorthMentioning()
    testTheWarningEndsWhenTheClockCatchesUp()
    testAForwardJumpDoesNotEndASessionEarly()
    testAForwardJumpDoesNotEndACooldownEarly()
    testAForwardJumpDoesNotEndABreakEarly()
    testAForwardJumpDoesNotEndTheEmergencyPassEarly()
    testARelaunchOnTheSameBootKeepsTheTwins()
    testARebootFallsBackToTheWallClock()
}

/// 03:30 on Tuesday, half an hour into a fresh day: winding back to 02:00 would otherwise put
/// the engine back in Monday's day key and hand over a whole new budget.
private func testABackwardsJumpHoldsTheDayAndItsCounters() {
    let clock = FakeClock(august(11, 3, 30))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    expectEqual(engine.state.dayKey, "2026-08-11", "the day the open was spent in")

    clock.setWallClock(to: august(11, 2, 0))
    _ = engine.tick()

    expectEqual(engine.state.dayKey, "2026-08-11", "the day key is held where it was")
    expectEqual(opensUsed(engine), 1, "and so is the open that was spent")
    expectEqualText(
        engine.clockWarningLine, "System clock moved backwards — counters held", "the warning"
    )
}

/// `preventTimeChange` off, because this is about the arithmetic underneath the block: with it on
/// the answer to every question below would be `.clockTampered` and say nothing about the wait.
private func testABackwardsJumpLiftsNothingEarly() {
    let clock = FakeClock(august(10, 12))
    let (engine, target) = makeEngine(clock: clock, preventTimeChange: false)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)      // ten minutes of cooldown
    expectEqual(engine.decision(targetID: target.id), cooldownDecision(minutes: 10), "the cooldown")

    // Wound back an hour: the wait is neither shortened nor lengthened by it.
    clock.setWallClock(to: august(10, 11))
    expectEqual(
        engine.decision(targetID: target.id), cooldownDecision(minutes: 10),
        "the cooldown is not shortened by winding the clock back"
    )
    // Eleven minutes of real time, still an hour behind. The wait is measured against a counter
    // nobody can set, so those eleven minutes count for exactly what they are — the cooldown is
    // over, even though the wall clock says 11:11 and the wait was written for 12:10.
    clock.advance(seconds: 11 * 60)
    expectEqual(
        engine.decision(targetID: target.id), pauseDecision(countdown: 15, opensLeft: 4, of: 5),
        "real minutes still count while the clock is wrong"
    )
    expect(engine.clockMovedBackwards, "the engine is still holding the wall clock where it was")
}

private func testDriftUnderFiveMinutesIsNotWorthMentioning() {
    let clock = FakeClock(august(10, 12))
    let (engine, _) = makeEngine(clock: clock)
    _ = engine.tick()
    clock.advance(seconds: -120)
    _ = engine.tick()
    expectNil(engine.clockWarningLine, "two minutes back is an NTP correction, not a clock change")
    expect(!engine.clockMovedBackwards, "and nothing is announced about it")
}

private func testTheWarningEndsWhenTheClockCatchesUp() {
    let clock = FakeClock(august(11, 3, 30))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)

    clock.setWallClock(to: august(11, 2, 0))
    _ = engine.tick()
    expect(engine.clockMovedBackwards, "held while the clock is behind")

    // A day and a half-hour of real time later, with the clock put back where it belongs — which
    // is where the engine had been counting all along. The day it was holding is over.
    clock.advance(seconds: 24 * 3600 + 30 * 60)
    clock.setWallClock(to: august(12, 4, 0))
    _ = engine.tick()
    expectNil(engine.clockWarningLine, "the warning says itself out of existence")
    expectEqual(engine.state.dayKey, "2026-08-12", "and the day it was holding rolls over")
    expectEqual(opensUsed(engine), 0, "with a fresh budget, at the right time")
}

// MARK: - Forwards
//
// Each of the four waits, put through the same hour: the clock is wound forward under a running
// engine, the engine is asked (a real one is asked once a second), and the clock is put back.
// Nothing may have been spent by the round trip — and the last line of each says what does spend
// it, so the pin cannot pass by making the wait immortal.

private func testAForwardJumpDoesNotEndASessionEarly() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)             // five minutes
    expectEqual(
        engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 300), "the session"
    )

    clock.moveWallClock(by: 3600)
    _ = engine.tick()
    clock.moveWallClock(by: -3600)
    expectEqual(
        engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 300),
        "an hour of clock does not spend a second of a five-minute session"
    )

    clock.advance(seconds: 5 * 60 + 1)
    expectEqual(
        engine.decision(targetID: target.id), cooldownDecision(minutes: 10),
        "five real minutes do end it, and start the wait that follows"
    )
}

private func testAForwardJumpDoesNotEndACooldownEarly() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)    // ten minutes of cooldown

    clock.moveWallClock(by: 3600)
    _ = engine.tick()
    clock.moveWallClock(by: -3600)
    expectEqual(
        engine.decision(targetID: target.id), cooldownDecision(minutes: 10),
        "an hour of clock does not wait a ten-minute cooldown out"
    )

    clock.advance(seconds: 10 * 60 + 1)
    expectEqual(
        engine.decision(targetID: target.id), pauseDecision(countdown: 15, opensLeft: 4, of: 5),
        "ten real minutes do"
    )
}

private func testAForwardJumpDoesNotEndABreakEarly() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    expect(engine.pauseProtection(minutes: 30), "a half-hour break starts")

    clock.moveWallClock(by: 3600)
    _ = engine.tick()
    clock.moveWallClock(by: -3600)
    expectEqual(
        engine.decision(targetID: target.id), .notManaged, "an hour of clock does not end the break"
    )

    clock.advance(seconds: 30 * 60 + 1)
    expectNil(engine.protectionPausedUntil, "half an hour of real time does")
}

/// The pass lifts a strict window for an hour, so this is also the one wait where ending it early
/// would hand back something the user deliberately locked away.
private func testAForwardJumpDoesNotEndTheEmergencyPassEarly() {
    let clock = FakeClock(august(10, 10))          // Monday, inside office hours
    let (engine, target) = makeStrictEngine(clock: clock)
    expect(engine.useEmergencyPass(), "the week's pass is spent")
    expectEqual(engine.decision(targetID: target.id), .notManaged, "and the window is lifted")

    clock.moveWallClock(by: 2 * 3600)
    _ = engine.tick()
    clock.moveWallClock(by: -2 * 3600)
    expectEqual(
        engine.decision(targetID: target.id), .notManaged, "two hours of clock do not spend the hour"
    )

    clock.advance(seconds: 61 * 60)
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "17:00"),
        "sixty-one real minutes do, and the window is back"
    )
}

// MARK: - Across a launch

/// Quitting the app, changing the clock and starting it again is the obvious way round a wait.
/// The uptime counter does not restart when the app does, so the twins close it.
private func testARelaunchOnTheSameBootKeepsTheTwins() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)    // ten minutes, until 12:10
    let saved = engine.state

    // Quit, an hour put on the clock, started again — two minutes of real time later.
    let relaunched = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: saved,
        clock: FakeClock(august(10, 13, 2), uptime: 10_000 + 120)
    )
    expectEqual(
        relaunched.decision(targetID: target.id), cooldownDecision(minutes: 8),
        "the wait comes back with the two minutes it actually served taken off"
    )
}

/// A restart is where the promise runs out, and this says what that costs: uptime begins again, so
/// every twin is measured from a counter that no longer exists and the wall clock decides alone.
private func testARebootFallsBackToTheWallClock() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)    // ten minutes, until 12:10
    let saved = engine.state
    expect(saved.uptimeAnchor != nil, "the state carries the reading its twins were written at")

    let restarted = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: saved,
        clock: FakeClock(august(10, 13), uptime: 5)
    )
    expectNil(restarted.state.uptimeAnchor, "a machine reporting five seconds of uptime restarted")
    expect(restarted.state.cooldownUntilUptime.isEmpty, "so the twins are dropped rather than believed")
    expectEqual(
        restarted.decision(targetID: target.id), pauseDecision(countdown: 15, opensLeft: 4, of: 5),
        "and the wall clock, which says the wait is long over, decides on its own"
    )
}
