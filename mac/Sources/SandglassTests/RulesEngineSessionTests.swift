import Foundation
import SandglassCore

// Shared fixtures (FakeClock, noon, youtubeGroup, makeEngine, decision builders) live in
// EngineFixtures.swift.

func runEngineSessionTests() {
    testConsumeGrantsSession()
    testSecondConsumeJoinsSession()
    testGentleConsumeHasNoSession()
    testDeniedAtExhaustedBudgetCountsAttempt()
    testCooldownBlocksUntilItElapses()
    testEndSessionWithoutSessionIsNoOp()
    testEarnBackCreditsHalfOpen()
    testEarnBackHalfCreditDoesNotGrantExtraOpen()
    testEarnBackFullCreditGrantsOpen()
    testEarnBackDisabledKeepsFullOpen()
    testEarnBackLateKeepsFullOpen()
    testTickWarnsOnceBeforeSessionEnds()
    testTickEndsSessionAndStartsCooldown()
    testStatsSnapshotReflectsOpensAndDismissals()
    testFreezeIsSpentForTheWeek()
    testDayRolloverResetsBudget()
    testDayRollsOverOnConsumeWithoutTick()
    testSessionSurvivesDayRollover()
    testExpiredSessionIsReapedWithoutTick()
    testSleepPastCooldownDoesNotResurrectIt()
    testEndSessionOnExpiredSessionKeepsTheReapedCooldown()
    testCooldownSurvivesDayRollover()
    testEffectsSurviveAStatsRead()
    testZeroCooldownStartsNoCooldown()
}

// MARK: - Granting

private func testConsumeGrantsSession() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    expectEqual(engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: 300), "consume grants a 5 min session")
    expectEqual(
        engine.decision(targetID: target.id),
        .allowed(remainingSessionSeconds: 300),
        "the target is allowed while the session runs"
    )
    expectEqual(opensUsed(engine), 1, "one open spent")
}

private func testSecondConsumeJoinsSession() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 100)
    expectEqual(
        engine.consumeOpen(targetID: target.id),
        .granted(sessionSeconds: 200),
        "re-opening during a session returns the remaining time"
    )
    expectEqual(opensUsed(engine), 1, "joining a session spends no second open")
}

private func testGentleConsumeHasNoSession() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: .gentle, clock: clock)
    expectEqual(engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: nil), "gentle grants without a session")
    expect(engine.state.sessions.isEmpty, "gentle tracks no session")
    expect(engine.state.cooldownUntil.isEmpty, "gentle starts no cooldown")
    expectEqual(
        engine.decision(targetID: target.id),
        .pause(countdownSeconds: 10, budgetLine: nil),
        "the next gentle open pauses again straight away"
    )
}

// MARK: - Denials and cooldown

private func testDeniedAtExhaustedBudgetCountsAttempt() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    for _ in 0..<5 { spendOneOpen(engine, target.id, clock) }
    expectEqual(
        engine.consumeOpen(targetID: target.id),
        .denied(budgetExhaustedDecision),
        "the sixth open is denied"
    )
    expectEqual(engine.state.deniedAttempts[youtubeGroup] ?? 0, 1, "the denial is counted")
    _ = engine.consumeOpen(targetID: target.id)
    expectEqual(engine.state.deniedAttempts[youtubeGroup] ?? 0, 2, "each further attempt is counted")
    expectEqual(opensUsed(engine), 5, "a denied attempt spends nothing")
}

private func testCooldownBlocksUntilItElapses() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .cooldown, untilText: "Next open in 10 min"),
        "ending a session starts the cooldown"
    )
    expectEqual(
        engine.consumeOpen(targetID: target.id),
        .denied(cooldownDecision(minutes: 10)),
        "no open can be spent during a cooldown"
    )
    expect(engine.state.deniedAttempts.isEmpty, "a cooldown denial is not a budget denial")
    clock.advance(seconds: 60)
    expectEqual(
        engine.decision(targetID: target.id),
        cooldownDecision(minutes: 9),
        "the cooldown counts down in whole minutes"
    )
    clock.advance(seconds: 541)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 15, opensLeft: 4, of: 5),
        "after the cooldown the pause screen is back"
    )
}

private func testEndSessionWithoutSessionIsNoOp() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    engine.endSession(targetID: target.id, early: true)
    engine.endSession(targetID: "app:com.apple.Xcode", early: true)
    expect(engine.state.cooldownUntil.isEmpty, "ending nothing starts no cooldown")
    expect(engine.state.opensUsed.isEmpty, "ending nothing credits nothing")
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "state is untouched"
    )
}

// MARK: - Earn-back

private func testEarnBackCreditsHalfOpen() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 100)
    engine.endSession(targetID: target.id, early: true)
    expectEqual(opensUsed(engine), 0.5, "leaving in the first half credits half an open")
    expect(engine.state.sessions.isEmpty, "the session is over")
}

/// The binding rule: an open has to fit whole, so a lone half credit buys nothing.
private func testEarnBackHalfCreditDoesNotGrantExtraOpen() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    for _ in 0..<4 { spendOneOpen(engine, target.id, clock) }
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 100)
    engine.endSession(targetID: target.id, early: true)
    clock.advance(seconds: 601)
    expectEqual(opensUsed(engine), 4.5, "4.5 of 5 opens used")
    expectEqual(
        engine.decision(targetID: target.id),
        budgetExhaustedDecision,
        "4.5 + 1 > 5, so the half credit grants nothing"
    )
}

/// Two half credits do add up to an open — that is the point of earn-back.
private func testEarnBackFullCreditGrantsOpen() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    for _ in 0..<3 { spendOneOpen(engine, target.id, clock) }
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 100)
    engine.endSession(targetID: target.id, early: true)
    clock.advance(seconds: 601)
    expectEqual(opensUsed(engine), 3.5, "3.5 of 5 opens used")
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 25, opensLeft: 1, of: 5),
        "3.5 + 1 fits, so the pause screen is shown"
    )
    expectEqual(engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: 300), "and the open is granted")
}

private func testEarnBackDisabledKeepsFullOpen() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.presetID = nil
    settings.earnBackEnabled = false
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 100)
    engine.endSession(targetID: target.id, early: true)
    expectEqual(opensUsed(engine), 1, "without earn-back the open stays spent")
}

private func testEarnBackLateKeepsFullOpen() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 200)
    engine.endSession(targetID: target.id, early: true)
    expectEqual(opensUsed(engine), 1, "leaving after halftime credits nothing")

    // Halftime exactly is still too late — the first half has to be strictly undercut.
    let other = FakeClock(noon)
    let (halfway, halfwayTarget) = makeEngine(clock: other)
    _ = halfway.consumeOpen(targetID: halfwayTarget.id)
    other.advance(seconds: 150)
    halfway.endSession(targetID: halfwayTarget.id, early: true)
    expectEqual(opensUsed(halfway), 1, "leaving exactly at halftime credits nothing")
}

// MARK: - Tick

private func testTickWarnsOnceBeforeSessionEnds() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    expect(engine.tick().isEmpty, "a fresh session has nothing to report")
    clock.advance(seconds: 240)
    expectEqual(
        engine.tick(),
        [.sessionWarning(groupID: youtubeGroup, secondsLeft: 60)],
        "the last minute is announced"
    )
    expect(engine.tick().isEmpty, "the warning is not repeated")
    clock.advance(seconds: 30)
    expect(engine.tick().isEmpty, "still not repeated a second later")
}

private func testTickEndsSessionAndStartsCooldown() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 310)
    expectEqual(engine.tick(), [.sessionEnded(groupID: youtubeGroup)], "the expired session ends")
    expect(engine.state.sessions.isEmpty, "the session is gone")
    expectEqual(
        engine.decision(targetID: target.id),
        cooldownDecision(minutes: 10),
        "the cooldown started with the session's end"
    )
    expect(engine.tick().isEmpty, "the session ends only once")
}

// MARK: - Stats

private func testStatsSnapshotReflectsOpensAndDismissals() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 100)
    engine.endSession(targetID: target.id, early: true)
    engine.recordDismissal(targetID: target.id)
    engine.recordDismissal(targetID: target.id)
    let stats = engine.statsSnapshot()
    expectEqual(stats.opensUsedToday[youtubeGroup] ?? 0, 0.5, "opens are reported in half steps")
    expectEqual(stats.opensAvoidedToday, 2, "dismissed pause screens are counted")
    expectEqual(stats.streakDays, 0, "a fresh state has no streak")
    expectEqual(stats.freezesLeft, 1, "and its weekly freeze")
}

private func testFreezeIsSpentForTheWeek() {
    let clock = FakeClock(noon)
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    var seeded = initialState(clock)
    seeded.freezeUsedInWeek = "2026-W33"   // the ISO week Monday 2026-08-10 belongs to
    let engine = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: seeded,
        clock: clock
    )
    expectEqual(engine.statsSnapshot().freezesLeft, 0, "a freeze used this week is gone")
}

// MARK: - The day

private func testDayRolloverResetsBudget() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    for _ in 0..<5 { spendOneOpen(engine, target.id, clock) }
    _ = engine.consumeOpen(targetID: target.id)
    engine.recordDismissal(targetID: target.id)
    clock.now = august(11, 2, 59)
    expect(engine.tick().isEmpty, "02:59 is still yesterday")
    expectEqual(
        engine.decision(targetID: target.id),
        budgetExhaustedDecision,
        "and yesterday's budget is still empty"
    )
    clock.now = august(11, 3, 1)
    expectEqual(engine.tick(), [.dayRolledOver], "03:00 starts the new day")
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "the budget is full again"
    )
    expect(engine.state.deniedAttempts.isEmpty, "denied attempts are cleared")
    expectEqual(engine.statsSnapshot().opensAvoidedToday, 0, "avoided opens are cleared")
}

/// A Mac that slept through the night asks before it ticks — the answer must already
/// be about the new day.
private func testDayRollsOverOnConsumeWithoutTick() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    for _ in 0..<5 { spendOneOpen(engine, target.id, clock) }
    clock.now = august(11, 3, 1)
    expectEqual(engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: 300), "consume rolls the day itself")
    expectEqual(opensUsed(engine), 1, "and spends from the new day's budget")
    // Whoever notices the new day first performs the reset, but the news still reaches
    // the app: the effect waits in the queue until the next tick drains it.
    expectEqual(engine.tick(), [.dayRolledOver], "a roll another call performed is still reported")
    expect(engine.tick().isEmpty, "and reported only once")
}

private func testSessionSurvivesDayRollover() {
    let clock = FakeClock(august(10, 2, 58))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)   // 02:58 → 03:03
    clock.advance(seconds: 180)                   // 03:01
    expectEqual(engine.tick(), [.dayRolledOver], "the day rolled over mid-session")
    expectEqual(
        engine.decision(targetID: target.id),
        .allowed(remainingSessionSeconds: 120),
        "the session keeps running past 03:00"
    )
    expect(engine.state.opensUsed.isEmpty, "while the budget still reset")
}

// MARK: - Catching up with the clock

/// Nothing may depend on a tick having run: the relock has to be true the moment the
/// session's time is up, not the moment the app next asks.
private func testExpiredSessionIsReapedWithoutTick() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 301)   // one second past the session's end, no tick in between
    expectEqual(
        engine.decision(targetID: target.id),
        cooldownDecision(minutes: 10),
        "asking alone ends the session and starts the cooldown"
    )
    expectEqual(
        engine.consumeOpen(targetID: target.id),
        .denied(cooldownDecision(minutes: 10)),
        "and no second open slips through the gap"
    )
    expectEqual(opensUsed(engine), 1, "the budget was charged once")
    expect(engine.state.sessions.isEmpty, "the expired session is gone")
    expectEqual(
        engine.state.cooldownUntil[youtubeGroup] ?? .distantPast,
        noon.addingTimeInterval(900),
        "the cooldown runs from the session's end, not from when the engine noticed"
    )
    expectEqual(engine.tick(), [.sessionEnded(groupID: youtubeGroup)], "the end reaches the app late but intact")
}

/// A Mac that slept for three hours wakes up with the session and its cooldown both
/// long over — neither may be resurrected.
private func testSleepPastCooldownDoesNotResurrectIt() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 3 * 3600)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 15, opensLeft: 4, of: 5),
        "a cooldown that elapsed while asleep does not start now"
    )
    expect(engine.state.cooldownUntil.isEmpty, "and leaves nothing stale behind")
    expectEqual(engine.tick(), [.sessionEnded(groupID: youtubeGroup)], "the session end is reported once")
    expect(engine.tick().isEmpty, "and not again")
}

/// "I'm done" arriving after the session already ran out must not restart the cooldown.
private func testEndSessionOnExpiredSessionKeepsTheReapedCooldown() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 301)
    engine.endSession(targetID: target.id, early: true)
    expectEqual(
        engine.state.cooldownUntil[youtubeGroup] ?? .distantPast,
        noon.addingTimeInterval(900),
        "the cooldown stays anchored at the session's end"
    )
    expectEqual(opensUsed(engine), 1, "and a late exit earns nothing back")
}

/// Cooldowns are running clocks like sessions, not daily counters — 03:00 does not
/// wipe them.
private func testCooldownSurvivesDayRollover() {
    let clock = FakeClock(august(10, 2, 55))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)   // cooldown 02:55 → 03:05
    clock.advance(seconds: 360)                            // 03:01
    expectEqual(engine.decision(targetID: target.id), cooldownDecision(minutes: 4), "the cooldown outlives the rollover")
    expect(engine.state.opensUsed.isEmpty, "while the budget did reset at 03:00")
    clock.advance(seconds: 300)                            // 03:06
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and once it is over the new day's full budget is there"
    )
}

/// Any call may be the one that notices time passed; the effect belongs to the app
/// either way.
private func testEffectsSurviveAStatsRead() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 301)
    _ = engine.statsSnapshot()   // reads, and reaps on the way
    expectEqual(engine.tick(), [.sessionEnded(groupID: youtubeGroup)], "the reap another call performed is still reported")
    expect(engine.tick().isEmpty, "and not reported twice")
}

/// A group without a cooldown must not leave a zero-length one behind in the state.
private func testZeroCooldownStartsNoCooldown() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.presetID = nil
    settings.cooldownMinutes = 0
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)
    expect(engine.state.cooldownUntil.isEmpty, "no cooldown is recorded")
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 15, opensLeft: 4, of: 5),
        "the next open only waits out the pause screen"
    )
}
