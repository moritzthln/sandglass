import Foundation
import SandglassCore

// A group that opens only with its password: where it sits among the other blocks, what one
// correct password buys, and the wait five wrong ones earn.
//
// Shared fixtures (FakeClock, noon, august, officeHours, makeEngine) live in EngineFixtures.swift.

func runAccessPasswordTests() {
    testAPasswordGroupIsBlockedUntilThePasswordIsTyped()
    testNoBudgetOpensAPasswordGroup()
    testTheRightPasswordOpensTheGroupForItsSessionThenRelocks()
    testAGroupWithNoSessionLengthOpensForHalfAnHour()
    testTheDailyLimitDoesNotCutAPasswordSessionShort()
    testFiveWrongPasswordsEarnAMinutesWait()
    testTheWaitIsMeasuredOnTheUptimeClock()
    testAStrictWindowOutranksThePassword()
    testADatedBlockAndBlockEverythingOutrankThePassword()
    testThePassAndTheBreakLiftAPasswordGroupUnlessItIgnoresThem()
    testSettingAPasswordTightensAndRemovingOrChangingItLoosens()
}

private let password = "drive-2026"

private func passwordSettings(
    _ base: GroupSettings = .standard, sessionMinutes: Int? = 5
) -> GroupSettings {
    var settings = base
    settings.sessionMinutes = sessionMinutes
    settings.accessPassword = PasscodeHash.make(password)
    return settings
}

private let passwordDecision = Decision.blocked(
    reason: .passwordRequired, untilText: "Opens with its password"
)

// MARK: - Blocked, then open

private func testAPasswordGroupIsBlockedUntilThePasswordIsTyped() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: passwordSettings(), clock: clock)
    expectEqual(engine.decision(targetID: target.id), passwordDecision, "blocked, with the password as the way through")
    expectEqual(engine.decision(groupID: youtubeGroup), passwordDecision, "asked about the group, the same")
    expectEqual(
        engine.consumeOpen(targetID: target.id), .denied(passwordDecision),
        "an open cannot be spent past it"
    )
    expectEqual(opensUsed(engine), 0, "and none was spent trying")
    expectEqual(engine.state.deniedAttempts[youtubeGroup] ?? 0, 0, "nor is it a denied attempt on the streak")
}

/// The password is the **only** way through, so a group with every budget switched off — no
/// pause, unlimited opens, no cooldown — is still blocked.
private func testNoBudgetOpensAPasswordGroup() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: passwordSettings(.gentle, sessionMinutes: nil), clock: clock)
    expectEqual(engine.decision(targetID: target.id), passwordDecision, "a gentle group with a password is still shut")
    var noPause = passwordSettings(.gentle, sessionMinutes: nil)
    noPause.pauseSeconds = 0
    let (silent, site) = makeEngine(settings: noPause, clock: clock)
    expectEqual(silent.decision(targetID: site.id), passwordDecision, "and no pause does not mean no password")
}

private func testTheRightPasswordOpensTheGroupForItsSessionThenRelocks() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: passwordSettings(sessionMinutes: 5), clock: clock)
    expectEqual(
        engine.tryAccessPassword(password, targetID: target.id), .unlocked(sessionSeconds: 300),
        "the right password opens the group for its own session length"
    )
    expectEqual(engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 300), "and it is open")
    expectEqual(opensUsed(engine), 0, "nothing was spent from the day to open it")
    expectEqual(
        engine.tryAccessPassword(password, url: "youtube.com/watch"), .unlocked(sessionSeconds: 300),
        "typing it again while open buys nothing and costs nothing"
    )

    clock.advance(seconds: 299)
    expectEqual(engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 1), "open to the last second")
    clock.advance(seconds: 1)
    expectEqual(engine.decision(targetID: target.id), passwordDecision, "then it relocks like any session")
    expectEqual(engine.tick(), [.sessionEnded(groupID: youtubeGroup)], "and says so")
    clock.advance(seconds: 60)
    expectEqual(
        engine.decision(targetID: target.id), passwordDecision,
        "the group's cooldown is a budget, so it does not replace the password afterwards"
    )
}

private func testAGroupWithNoSessionLengthOpensForHalfAnHour() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: passwordSettings(sessionMinutes: nil), clock: clock)
    expectEqual(GroupSettings.defaultAccessMinutes, 30, "the default is half an hour")
    expectEqual(
        engine.tryAccessPassword(password, groupID: youtubeGroup), .unlocked(sessionSeconds: 1800),
        "a group set to never relock still relocks after a password"
    )
    clock.advance(seconds: 1800)
    expectEqual(engine.decision(targetID: target.id), passwordDecision, "after thirty minutes")
}

/// Budgets do not judge a password group in either direction: they do not open it, and they do
/// not end the session the password bought.
private func testTheDailyLimitDoesNotCutAPasswordSessionShort() {
    let clock = FakeClock(noon)
    var settings = passwordSettings(sessionMinutes: 10)
    settings.dailyMinutes = 1
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 120)
    expectEqual(engine.decision(targetID: target.id), passwordDecision, "a spent day still asks for the password")
    _ = engine.tryAccessPassword(password, targetID: target.id)
    engine.recordUsage(groupID: youtubeGroup, seconds: 120)
    expectEqual(
        engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 600),
        "and the session it bought runs its full length"
    )
}

// MARK: - Brute force

private func testFiveWrongPasswordsEarnAMinutesWait() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: passwordSettings(), clock: clock)
    for left in stride(from: 4, through: 1, by: -1) {
        expectEqual(engine.tryAccessPassword("nope", targetID: target.id), .wrong(attemptsLeft: left), "wrong, \(left) left")
    }
    expectEqual(engine.tryAccessPassword("nope", targetID: target.id), .wrong(attemptsLeft: 0), "the fifth starts the wait")
    expectEqual(
        engine.tryAccessPassword(password, targetID: target.id), .lockedOut(secondsLeft: 60),
        "and during it not even the right password is checked"
    )
    expectEqual(engine.accessWaitSeconds(groupID: youtubeGroup), 60, "the prompt can say how long")
    expectEqual(engine.decision(targetID: target.id), passwordDecision, "the group stays shut")

    clock.advance(seconds: 59)
    expectEqual(engine.tryAccessPassword(password, targetID: target.id), .lockedOut(secondsLeft: 1), "a second left")
    clock.advance(seconds: 1)
    expectNil(engine.accessWaitSeconds(groupID: youtubeGroup), "the wait is over")
    expectEqual(
        engine.tryAccessPassword("nope", targetID: target.id), .wrong(attemptsLeft: 4),
        "and the count starts again from five rather than a wait after every miss"
    )
    expectEqual(
        engine.tryAccessPassword(password, targetID: target.id), .unlocked(sessionSeconds: 300),
        "the right one opens it"
    )
}

/// Winding the system clock forward is no way to skip the wait. The clock guard is off here so
/// the wrong clock does not block everything on its own and hide what this is about.
private func testTheWaitIsMeasuredOnTheUptimeClock() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: passwordSettings(), clock: clock, preventTimeChange: false)
    for _ in 1...5 { _ = engine.tryAccessPassword("nope", targetID: target.id) }
    clock.moveWallClock(by: 3600)
    expectEqual(
        engine.tryAccessPassword(password, targetID: target.id), .lockedOut(secondsLeft: 60),
        "an hour on the wall clock is no time at all on the uptime clock"
    )
}

// MARK: - Precedence

private func testAStrictWindowOutranksThePassword() {
    let clock = FakeClock(august(10, 10))   // Monday, inside office hours
    let (engine, target) = makeEngine(settings: passwordSettings(standardSettings(windows: [officeHours])), clock: clock)
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "the window is what blocks")
    expectEqual(
        engine.tryAccessPassword(password, targetID: target.id), .refused(scheduleDecision(until: "17:00")),
        "and a right password does not open a group inside its strict window"
    )
    for _ in 1...5 { _ = engine.tryAccessPassword("nope", targetID: target.id) }
    clock.now = august(10, 17)
    expectEqual(engine.decision(targetID: target.id), passwordDecision, "once the window ends the password is asked for")
    expectEqual(
        engine.tryAccessPassword("nope", targetID: target.id), .wrong(attemptsLeft: 4),
        "and the guesses made inside the window were never counted"
    )
}

private func testADatedBlockAndBlockEverythingOutrankThePassword() {
    let clock = FakeClock(noon)
    var dated = passwordSettings()
    dated.blockedUntilDay = "2026-08-14"
    let (engine, target) = makeEngine(settings: dated, clock: clock)
    let shut = engine.decision(targetID: target.id)
    expectEqual(shut, datedDecision(until: "Fri 14 Aug"), "a dated block outranks the password")
    expectEqual(engine.tryAccessPassword(password, targetID: target.id), .refused(shut), "and is not opened by it")

    let (focused, site) = makeEngine(settings: passwordSettings(), clock: clock)
    _ = focused.tryAccessPassword(password, targetID: site.id)
    focused.startFocusSession(minutes: 60)
    expectEqual(focused.decision(targetID: site.id), focusDecision(until: "13:00"), "Block everything outranks an open password session")
    expectEqual(
        focused.tryAccessPassword(password, targetID: site.id), .refused(focusDecision(until: "13:00")),
        "and the password cannot reopen it"
    )
}

/// The app's two ways out reach a password group like any other block, and the group's own
/// opt-out keeps them away, also like any other block.
private func testThePassAndTheBreakLiftAPasswordGroupUnlessItIgnoresThem() {
    let clock = FakeClock(noon)
    var immune = passwordSettings()
    immune.ignoresAppWideUnblocks = true
    let (engine, site, other) = makeTwoGroupEngine(youtube: immune, reddit: passwordSettings(), clock: clock)
    expect(engine.useEmergencyPass(), "the pass is spent")
    expectEqual(engine.decision(targetID: other.id), .notManaged, "the pass lifts a password group")
    expectEqual(engine.decision(targetID: site.id), passwordDecision, "but not one that ignores it")
    expectEqual(
        engine.tryAccessPassword(password, targetID: other.id), .refused(.notManaged),
        "and a lifted group has no password to check"
    )

    let (paused, pausedSite, pausedOther) = makeTwoGroupEngine(
        youtube: immune, reddit: passwordSettings(), clock: clock
    )
    expect(paused.pauseProtection(minutes: 30), "a break is taken")
    expectEqual(paused.decision(targetID: pausedOther.id), .notManaged, "the break lifts it too")
    expectEqual(paused.decision(targetID: pausedSite.id), passwordDecision, "and leaves the immune one alone")
}

// MARK: - Settings

private func testSettingAPasswordTightensAndRemovingOrChangingItLoosens() {
    let plain = webConfig()
    var locked = plain
    locked.groupSettings[youtubeGroup]?.accessPassword = PasscodeHash.make(password)
    var changed = locked
    changed.groupSettings[youtubeGroup]?.accessPassword = PasscodeHash.make("another-one")
    let day = "2026-08-10"
    expect(
        !EditDirection.loosens(group: youtubeGroup, from: plain, to: locked, onDay: day),
        "setting a password shuts the group further, so it is a tightening"
    )
    expect(
        EditDirection.loosens(group: youtubeGroup, from: locked, to: plain, onDay: day),
        "removing it is the way back out"
    )
    expect(
        EditDirection.loosens(group: youtubeGroup, from: locked, to: changed, onDay: day),
        "and changing it is a removal and a setting in one edit"
    )
    expect(
        !EditDirection.loosens(group: youtubeGroup, from: locked, to: locked, onDay: day),
        "leaving it alone moves nothing"
    )
}
