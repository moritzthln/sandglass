import Foundation
import SandglassCore

// Shared fixtures (FakeClock, august/localTime, officeHours, the engine builders and the
// decision builders) live in EngineFixtures.swift. Streak tests live next door in
// RulesEngineStreakTests.swift.

// The order here follows the file.
func runEngineScheduleTests() {
    // Strict windows
    testStrictWindowBlocksDuringOfficeHours()
    testStrictWindowEndsWithTheWorkingDay()
    testStrictWindowSkipsTheWeekend()
    testStrictWindowBoundaries()
    testConsumeInsideStrictWindowCountsNoDeniedAttempt()
    testStrictWindowOutranksARunningSession()
    // Focus sessions
    testFocusSessionBlocksEveryTarget()
    testFocusSessionOutranksAStrictWindow()
    testFocusSessionTerminatesRunningSessions()
    testFocusSessionExtendsButNeverShortens()
    testFocusSessionExpires()
    testFocusSessionOfNoLengthIsIgnored()
    testFocusSessionOutranksASimultaneousPause()
    testConsumeDuringFocusSessionIsDenied()
    // Pausing protection
    testPauseProtectionMakesEverythingUnmanaged()
    testPauseProtectionIsRefusedDuringAFocusSession()
    testPauseProtectionIsGrantedInsideAStrictWindow()
    testPauseOfNoLengthIsRefused()
    testDismissalsAreIgnoredWhileProtectionIsPaused()
    testPauseProtectionExpires()
    testSessionEndsWhileProtectionIsPaused()
    // What a strict window does to a running break, which is nothing
    testPauseRunsItsFullLengthIntoAStrictWindow()
    testAWindowOpeningDoesNotCutAPauseShort()
    testAddingAScheduleDuringAPauseDoesNotEndIt()
    // Reconfiguration
    testUpdateConfigIsAllowedInsideAStrictWindow()
    testUpdateConfigAllowsAnUnaffectedGroupDuringAStrictWindow()
    testUpdateConfigAllowsTargetMembershipInsideAStrictWindow()
    testAFocusSessionBlocksEverythingAndFreezesNothing()
    testUpdateConfigDropsTheStateOfRemovedGroups()
}

// MARK: - Strict windows

private func testStrictWindowBlocksDuringOfficeHours() {
    let clock = FakeClock(noon)   // Monday 12:00
    let (engine, target) = makeStrictEngine(clock: clock)
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .schedule, untilText: "Blocked until 17:00"),
        "inside the window the target is hard-blocked until the window's end"
    )
    expectEqual(engine.decision(domain: "www.youtube.com"), scheduleDecision(until: "17:00"), "the browser gets the same answer")
}

private func testStrictWindowEndsWithTheWorkingDay() {
    let clock = FakeClock(august(10, 18))
    let (engine, target) = makeStrictEngine(clock: clock)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "Monday evening is the normal pause screen again"
    )
}

private func testStrictWindowSkipsTheWeekend() {
    let clock = FakeClock(august(15, 12))   // Saturday, same time of day
    let (engine, target) = makeStrictEngine(clock: clock)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "the window only exists on the weekdays it names"
    )
}

private func testStrictWindowBoundaries() {
    let clock = FakeClock(august(10, 8, 59))
    let (engine, target) = makeStrictEngine(clock: clock)
    let free = pauseDecision(countdown: 10, opensLeft: 5, of: 5)
    expectEqual(engine.decision(targetID: target.id), free, "08:59 is still free")
    clock.now = august(10, 9)
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "09:00 is the first blocked minute")
    clock.now = august(10, 16, 59)
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "16:59 is the last blocked minute")
    clock.now = august(10, 17)
    expectEqual(engine.decision(targetID: target.id), free, "17:00 is free again")
}

private func testConsumeInsideStrictWindowCountsNoDeniedAttempt() {
    let clock = FakeClock(noon)
    let (engine, target) = makeStrictEngine(clock: clock)
    expectEqual(
        engine.consumeOpen(targetID: target.id),
        .denied(scheduleDecision(until: "17:00")),
        "no open can be spent inside the window"
    )
    // Denied attempts are the streak's only input, and the streak is about busting
    // budgets — walking into a wall the user themselves put up is not a slip.
    expect(engine.state.deniedAttempts.isEmpty, "bumping into a schedule is not a busted budget")
    expect(engine.state.opensUsed.isEmpty, "and spends nothing")
}

/// The window is the outer wall: a session that started before it does not survive into it.
private func testStrictWindowOutranksARunningSession() {
    let clock = FakeClock(august(10, 8, 55))
    var settings = standardSettings(windows: [officeHours])
    settings.presetID = nil
    settings.sessionMinutes = 30   // long enough to still be running at 09:00
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    expectEqual(engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: 1800), "the session starts before the window")
    clock.now = august(10, 9)
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "the window outranks the running session")
    expect(engine.state.sessions[youtubeGroup] != nil, "which is still running underneath, not expired")
}

// MARK: - Focus sessions

private func testFocusSessionBlocksEveryTarget() {
    let clock = FakeClock(noon)
    let (engine, site, other) = makeTwoGroupEngine(youtube: .standard, clock: clock)
    engine.startFocusSession(minutes: 25)
    expectEqual(
        engine.decision(targetID: site.id),
        .blocked(reason: .focusSession, untilText: "Blocked until 12:25"),
        "the focus session names its own end"
    )
    expectEqual(engine.decision(targetID: other.id), focusDecision(until: "12:25"), "every managed group is blocked, not just one")
    expectEqual(engine.decision(domain: "youtube.com"), focusDecision(until: "12:25"), "the browser gets the same answer")
    expectEqual(engine.focusSessionEndsAt, noon.addingTimeInterval(1500), "and the end is exposed for the menu bar")
}

/// Both walls are up; the nearer one is the one to name. At 12:25 the answer becomes
/// "Blocked until 17:00" — the overlay never lifts, only the line under it changes.
private func testFocusSessionOutranksAStrictWindow() {
    let clock = FakeClock(noon)
    let (engine, site, _) = makeTwoGroupEngine(youtube: standardSettings(windows: [officeHours]), clock: clock)
    engine.startFocusSession(minutes: 25)
    expectEqual(engine.decision(targetID: site.id), focusDecision(until: "12:25"), "the focus session outranks the window")
    clock.advance(seconds: 1501)
    expectEqual(engine.decision(targetID: site.id), scheduleDecision(until: "17:00"), "and hands back to it when it is over")
}

private func testFocusSessionTerminatesRunningSessions() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)   // 12:00 → 12:05
    clock.advance(seconds: 100)                   // still inside the earn-back half
    engine.startFocusSession(minutes: 25)
    expect(engine.state.sessions.isEmpty, "the running session is over immediately")
    expectEqual(opensUsed(engine), 1, "the user did not choose to stop, so nothing is earned back")
    expectEqual(
        engine.state.cooldownUntil[youtubeGroup] ?? .distantPast,
        noon.addingTimeInterval(100 + 600),
        "the cooldown runs from the moment the focus session started"
    )
    expectEqual(engine.tick(), [.sessionEnded(groupID: youtubeGroup)], "and the app is told the session ended")
}

private func testFocusSessionExtendsButNeverShortens() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    engine.startFocusSession(minutes: 25)
    engine.startFocusSession(minutes: 10)
    expectEqual(engine.focusSessionEndsAt, noon.addingTimeInterval(1500), "a shorter focus session cannot cut the running one short")
    engine.startFocusSession(minutes: 50)
    expectEqual(engine.focusSessionEndsAt, noon.addingTimeInterval(3000), "a longer one extends it")
}

private func testFocusSessionExpires() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    engine.startFocusSession(minutes: 25)
    clock.advance(seconds: 1501)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "the pause screen is back once the focus session is over"
    )
    expectNil(engine.focusSessionEndsAt, "nothing is running any more")
    expectNil(engine.state.focusSessionEndsAt, "and the finished block is cleared from the state")
}

private func testFocusSessionOfNoLengthIsIgnored() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.startFocusSession(minutes: 0)
    expectNil(engine.focusSessionEndsAt, "a focus session of no length is not one")
    expectEqual(
        engine.decision(targetID: target.id),
        .allowed(remainingSessionSeconds: 300),
        "and it does not end the running session on its way out"
    )
}

/// Only reachable from a hand-edited state file — the engine sets the two exclusively.
/// If both are there anyway, the block wins over the exemption.
private func testFocusSessionOutranksASimultaneousPause() {
    let clock = FakeClock(noon)
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    var doctored = initialState(clock)
    doctored.focusSessionEndsAt = noon.addingTimeInterval(1500)
    doctored.protectionPausedUntil = noon.addingTimeInterval(600)
    let engine = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: doctored,
        clock: clock
    )
    expectEqual(engine.decision(targetID: target.id), focusDecision(until: "12:25"), "the focus session outranks the pause")
    expectEqual(engine.consumeOpen(targetID: target.id), .denied(focusDecision(until: "12:25")), "and no open slips through underneath it")
}

private func testConsumeDuringFocusSessionIsDenied() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    engine.startFocusSession(minutes: 25)
    expectEqual(
        engine.consumeOpen(targetID: target.id),
        .denied(focusDecision(until: "12:25")),
        "no open can be spent during a focus session"
    )
    expect(engine.state.deniedAttempts.isEmpty, "and it is not held against the streak")
    expect(engine.state.opensUsed.isEmpty, "nor against the budget")
}

// MARK: - Pausing protection

private func testPauseProtectionMakesEverythingUnmanaged() {
    let clock = FakeClock(noon)
    let (engine, site, other) = makeTwoGroupEngine(youtube: .standard, clock: clock)
    expect(engine.pauseProtection(minutes: 10), "pausing outside any hard block is allowed")
    expectEqual(engine.protectionPausedUntil, noon.addingTimeInterval(600), "the end is exposed for the menu bar")
    expectEqual(engine.decision(targetID: site.id), .notManaged, "a paused engine manages nothing")
    expectEqual(engine.decision(targetID: other.id), .notManaged, "for no group")
    expectEqual(engine.decision(domain: "youtube.com"), .notManaged, "and not in the browser either")
    expectEqual(engine.consumeOpen(targetID: site.id), .denied(.notManaged), "an open needs no permission while paused")
    expect(engine.state.opensUsed.isEmpty, "so nothing is charged for it")
    expect(engine.state.sessions.isEmpty, "and no session is started")
}

private func testPauseProtectionIsRefusedDuringAFocusSession() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    engine.startFocusSession(minutes: 25)
    expect(!engine.pauseProtection(minutes: 10), "a focus session cannot be paused away")
    expectNil(engine.protectionPausedUntil, "and the refusal leaves nothing behind")
}

/// The promise "Unblock everything" makes, kept at the moment it is hardest: inside the block
/// the user is actually trying to get out of.
///
/// This is the case that used to be refused — one group inside its window locked the break for
/// every group — and the refusal was the whole reason the control could be reached, waited for,
/// and then do nothing.
private func testPauseProtectionIsGrantedInsideAStrictWindow() {
    let clock = FakeClock(noon)
    let (engine, site, other) = makeTwoGroupEngine(youtube: standardSettings(windows: [officeHours]), clock: clock)
    expectEqual(engine.decision(targetID: site.id), scheduleDecision(until: "17:00"), "the window is blocking")

    expect(engine.pauseProtection(minutes: 10), "and a break is granted inside it anyway")
    expectEqual(engine.protectionPausedUntil, noon.addingTimeInterval(600), "for the length asked for")
    expectEqual(engine.decision(targetID: site.id), .notManaged, "the blocked group stands down")
    expectEqual(engine.decision(targetID: other.id), .notManaged, "and so does every other one")
    expectEqual(engine.consumeOpen(targetID: site.id), .denied(.notManaged), "an open needs no permission")

    clock.advance(seconds: 601)
    expectEqual(
        engine.decision(targetID: site.id), scheduleDecision(until: "17:00"),
        "and the window is back the moment the break runs out"
    )
    expectNil(engine.state.protectionPausedUntil, "with the finished break cleared from the state")
}

private func testPauseOfNoLengthIsRefused() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    expect(!engine.pauseProtection(minutes: 0), "a pause of no length is refused rather than granted empty")
    expectNil(engine.protectionPausedUntil, "and nothing is written")
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "protection is untouched"
    )
}

/// No pause screen can be showing while protection is paused, so a dismissal arriving then
/// is a stale signal — and counting it would mark the day as practised for the streak.
private func testDismissalsAreIgnoredWhileProtectionIsPaused() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    expect(engine.pauseProtection(minutes: 10), "protection is paused")
    engine.recordDismissal(targetID: target.id)
    expectEqual(engine.statsSnapshot().opensAvoidedToday, 0, "the stale dismissal is not counted")
    clock.advance(seconds: 601)
    engine.recordDismissal(targetID: target.id)
    expectEqual(engine.statsSnapshot().opensAvoidedToday, 1, "one arriving after the pause is")
}

private func testPauseProtectionExpires() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    expect(engine.pauseProtection(minutes: 10), "the pause starts")
    clock.advance(seconds: 601)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "protection comes back on its own"
    )
    expectNil(engine.protectionPausedUntil, "nothing is paused any more")
    expectNil(engine.state.protectionPausedUntil, "and the finished pause is cleared from the state")
}

// MARK: - What a strict window does to a running break

/// It does nothing to one, and that is the change. A break used to be clamped to the next
/// window's start — an hour asked for at 08:55 ended at 09:00 — which made the same length mean
/// two different things depending on which side of a boundary it was pressed on.
private func testPauseRunsItsFullLengthIntoAStrictWindow() {
    let clock = FakeClock(august(10, 8, 55))
    let (engine, site, other) = makeTwoGroupEngine(youtube: standardSettings(windows: [officeHours]), clock: clock)
    expect(engine.pauseProtection(minutes: 60), "an hour's break before the window is allowed")
    expectEqual(engine.protectionPausedUntil, august(10, 9, 55), "and it is an hour, not five minutes")

    clock.now = august(10, 9, 40)   // not one call in between
    expectEqual(engine.decision(targetID: site.id), .notManaged, "the window does not take it back on waking")
    expectEqual(engine.decision(targetID: other.id), .notManaged, "for any group")

    clock.now = august(10, 9, 56)
    expectEqual(
        engine.decision(targetID: site.id), scheduleDecision(until: "17:00"),
        "and the window holds again the moment the break is over"
    )
    expectNil(engine.protectionPausedUntil, "nothing is paused")
    expectNil(engine.state.protectionPausedUntil, "and the state is clean")
}

/// The same fact from the other side, and the one that used to be enforced twice — once by the
/// clamp written into the state, once by a guard that suppressed the pause while any window
/// stood. Both are gone, so a Mac that sleeps through the window's start wakes up still on its
/// break rather than blocked by something it had already bought its way out of.
private func testAWindowOpeningDoesNotCutAPauseShort() {
    let clock = FakeClock(august(10, 8, 55))
    let (engine, site, other) = makeTwoGroupEngine(youtube: standardSettings(windows: [officeHours]), clock: clock)
    expect(engine.pauseProtection(minutes: 10), "before the window a break is allowed")
    expectEqual(engine.decision(targetID: site.id), .notManaged, "and it hides everything while it runs")

    clock.now = august(10, 9)
    expectEqual(engine.decision(targetID: site.id), .notManaged, "the opening window does not end it")
    expectEqual(engine.decision(targetID: other.id), .notManaged, "for either group")
    expectEqual(engine.protectionPausedUntil, august(10, 9, 5), "and its end is where it always was")

    clock.now = august(10, 9, 6)
    expectEqual(engine.decision(targetID: site.id), scheduleDecision(until: "17:00"), "then the window takes over")
    expectEqual(
        engine.decision(targetID: other.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and the group without a window is protected again too"
    )
}

/// A schedule added while a break runs used to end it, because the clamp could only account for
/// the windows that existed when the break started. There is no clamp to defend, so the break
/// the user asked for survives the edit — and the new window starts working when it is over.
private func testAddingAScheduleDuringAPauseDoesNotEndIt() {
    let clock = FakeClock(august(10, 8))
    let (engine, site, other) = makeTwoGroupEngine(youtube: .standard, clock: clock)
    expect(engine.pauseProtection(minutes: 4 * 60), "a four-hour break is granted")
    expectEqual(engine.protectionPausedUntil, august(10, 12), "and runs its full length")

    var withSchedule = engine.config
    withSchedule.groupSettings[site.groupID] = standardSettings(windows: [officeHours])
    expectEdit(engine, "a schedule can be added while protection is paused") { withSchedule }
    clock.now = august(10, 10)   // inside the window that was just drawn
    // Read before anything else: the answer has to be right on its own, not because some
    // earlier call happened to clean the state up first.
    expectEqual(engine.protectionPausedUntil, august(10, 12), "the break is untouched by the new window")
    expectEqual(engine.decision(targetID: site.id), .notManaged, "which does not block while it runs")
    expectEqual(engine.decision(targetID: other.id), .notManaged, "any more than the group without one")

    clock.now = august(10, 12, 1)
    expectEqual(engine.decision(targetID: site.id), scheduleDecision(until: "17:00"), "and blocks once it is over")
}


/// Pausing protection is not a time machine: session clocks keep running underneath, and
/// the relock the app has to perform still arrives.
private func testSessionEndsWhileProtectionIsPaused() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)   // 12:00 → 12:05
    expect(engine.pauseProtection(minutes: 10), "pausing mid-session is allowed")   // → 12:10
    clock.advance(seconds: 310)
    expectEqual(engine.tick(), [.sessionEnded(groupID: youtubeGroup)], "the session still ends on time")
    expectEqual(engine.decision(targetID: target.id), .notManaged, "while the pause keeps hiding everything")
    clock.advance(seconds: 300)
    expectEqual(
        engine.decision(targetID: target.id),
        cooldownDecision(minutes: 5),
        "and the cooldown it started was running all along"
    )
}

// MARK: - Reconfiguration

/// **A window blocks and freezes nothing**, which is the whole of the reconfiguration rule now.
/// A knob either way, a target out, a target moved to a group with no window at all: all of it
/// goes through while the block stands. What may be changed is the settings lock's question —
/// app-wide, or per group. See `EditDirection` for the lock rule.
private func testUpdateConfigIsAllowedInsideAStrictWindow() {
    let clock = FakeClock(noon)
    let (engine, site, _) = makeTwoGroupEngine(youtube: standardSettings(windows: [officeHours]), clock: clock)
    var loosened = engine.config
    loosened.groupSettings[site.groupID]?.opensPerDay = 50
    expectEdit(engine, "a group inside its window can be edited") { loosened }
    expectEqual(engine.config.settings(forGroup: site.groupID)?.opensPerDay, 50, "and it landed")
}

private func testUpdateConfigAllowsAnUnaffectedGroupDuringAStrictWindow() {
    let clock = FakeClock(noon)
    let (engine, _, other) = makeTwoGroupEngine(youtube: standardSettings(windows: [officeHours]), clock: clock)
    var changed = engine.config
    changed.groupSettings[other.groupID]?.opensPerDay = 3
    changed.targets.append(Target(kind: .app, value: "com.reddit.app", displayName: "Reddit", groupID: other.groupID))
    expectEdit(engine, "someone else's window is nobody's business either") { changed }
    expectEqual(
        engine.decision(targetID: other.id),
        pauseDecision(countdown: 10, opensLeft: 3, of: 3),
        "and the engine decides on the new settings straight away"
    )
    expectEqual(
        engine.decision(targetID: "app:com.reddit.app"),
        pauseDecision(countdown: 10, opensLeft: 3, of: 3),
        "including for the target just added to it"
    )
}

/// Settings are only half of a group. Dropping the target, or moving it into a group without a
/// window, unblocks it just as thoroughly as raising its budget would — and all three are edits
/// like any other, which is the decision.
private func testUpdateConfigAllowsTargetMembershipInsideAStrictWindow() {
    let clock = FakeClock(noon)
    let (engine, site, _) = makeTwoGroupEngine(youtube: standardSettings(windows: [officeHours]), clock: clock)

    var withExtraTarget = engine.config
    withExtraTarget.targets.append(Target(kind: .app, value: "com.google.Chrome", displayName: "Chrome", groupID: site.groupID))
    expectEdit(engine, "one pushed in arrives already blocked") { withExtraTarget }
    expectEqual(
        engine.decision(targetID: "app:com.google.Chrome"), scheduleDecision(until: "17:00"),
        "which the window blocks from the second it lands"
    )

    var moved = engine.config
    if let index = moved.targets.firstIndex(where: { $0.id == site.id }) {
        moved.targets[index].groupID = redditGroup
    }
    expectEdit(engine, "and one can be moved into a group that has no window") { moved }
    expectEqual(
        engine.decision(targetID: site.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "which unblocks it in the same instant, because it is somewhere else now"
    )

    var withoutTarget = engine.config
    withoutTarget.targets.removeAll { $0.id == site.id }
    expectEdit(engine, "and one can be taken out altogether") { withoutTarget }
    expectEqual(engine.decision(targetID: site.id), .notManaged, "leaving it unmanaged")
}

/// A focus session used to freeze the whole configuration, on the argument that while the user is
/// inside a block they chose, nothing about the setup should move. It does not: under the lock
/// rule a block is not a lock, and the settings lock is the only thing that holds an edit. The
/// blocking is untouched — that is the half of "Block everything" that is the feature.
private func testAFocusSessionBlocksEverythingAndFreezesNothing() {
    let clock = FakeClock(august(10, 18))   // no strict window in the way
    let (engine, site, other) = makeTwoGroupEngine(youtube: standardSettings(windows: [officeHours]), clock: clock)
    engine.startFocusSession(minutes: 25)
    var changed = engine.config
    changed.groupSettings[other.groupID]?.opensPerDay = 3
    expectEdit(engine, "an unrelated group can be edited during a focus session") { changed }
    expectEqual(
        engine.config.settings(forGroup: other.groupID)?.opensPerDay, 3, "and the change landed"
    )
    expectEqual(
        engine.decision(targetID: other.id), focusDecision(until: "18:25"),
        "with the session still blocking the group that was just edited"
    )
    expectEqual(
        engine.decision(targetID: site.id), focusDecision(until: "18:25"), "and every other group"
    )
}

private func testUpdateConfigDropsTheStateOfRemovedGroups() {
    let clock = FakeClock(noon)
    let (engine, site, other) = makeTwoGroupEngine(youtube: .standard, clock: clock)
    _ = engine.consumeOpen(targetID: site.id)               // a session and a spent open
    _ = engine.consumeOpen(targetID: other.id)
    engine.endSession(targetID: other.id, early: false)     // and a cooldown for the survivor

    var withoutYouTube = engine.config
    withoutYouTube.targets.removeAll { $0.groupID == site.groupID }
    withoutYouTube.groupSettings.removeValue(forKey: site.groupID)
    expectEdit(engine, "a group without a schedule can be removed at any time") { withoutYouTube }
    expectNil(engine.state.sessions[site.groupID], "the removed group's session is gone")
    expectNil(engine.state.opensUsed[site.groupID], "its spent opens too")
    expectEqual(engine.decision(targetID: site.id), .notManaged, "and its target is no longer managed")
    expectEqual(engine.state.opensUsed[redditGroup] ?? 0, 1, "the group that stayed keeps its budget")
    expect(engine.state.cooldownUntil[redditGroup] != nil, "and its cooldown")

    // Drive the survivor into a denied attempt, then drop it as well.
    clock.advance(seconds: 601)
    for _ in 0..<4 { spendOneOpen(engine, other.id, clock) }
    _ = engine.consumeOpen(targetID: other.id)
    expectEqual(engine.state.deniedAttempts[redditGroup] ?? 0, 1, "the survivor busted its budget")
    var empty = engine.config
    empty.targets.removeAll()
    empty.groupSettings.removeAll()
    expectEdit(engine, "the last group can go too") { empty }
    expect(engine.state.cooldownUntil.isEmpty, "no cooldown is left behind")
    expect(engine.state.deniedAttempts.isEmpty, "no denied attempts either")
    expect(engine.state.opensUsed.isEmpty, "and no budgets")
}
