import Foundation
import SandglassCore

// Shared fixtures (FakeClock, noon, makeEngine, decision builders) live in EngineFixtures.swift.

// MARK: - Decision tests

func runEngineDecisionTests() {
    testFreshTargetShowsPause()
    testUnknownTargetIsNotManaged()
    testGroupWithoutSettingsIsNotManaged()
    testDomainLookupMatchesSubdomains()
    testDomainLookupRejectsLookalikes()
    testDomainLookupNormalizesHost()
    testGentleShowsPauseWithoutBudgetLine()
    testEscalationGrowsCountdown()
    testEscalationGrowsByTheChosenAmount()
    testBudgetExhaustionBlocks()
    testGroupSharesBudgetAcrossTargets()
    testNoPauseOpensByItself()
    testNoPauseOnAGentleGroupChargesEveryArrival()
    testNoPauseWithEscalationMeetsAScreenOnTheSecondOpen()
    testNoPauseStillWallsACooldownAndAnEmptyBudget()
}

private func testFreshTargetShowsPause() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    expectEqual(
        engine.decision(targetID: target.id),
        .pause(countdownSeconds: 10, budgetLine: "5 of 5 opens left today"),
        "fresh target shows the pause screen with a full budget"
    )
}

private func testUnknownTargetIsNotManaged() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    expectEqual(engine.decision(targetID: "app:com.apple.Xcode"), .notManaged, "unknown target id")
}

/// A target whose group has no settings is as good as unknown: nothing is blocked or counted.
private func testGroupWithoutSettingsIsNotManaged() {
    let clock = FakeClock(noon)
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube", groupID: "grp:orphan")
    let engine = makeEngine(targets: [target], groupSettings: [:], clock: clock)
    expectEqual(engine.decision(targetID: target.id), .notManaged, "group without settings")
    expectEqual(engine.consumeOpen(targetID: target.id), .denied(.notManaged), "consume on unsettled group")
}

private func testDomainLookupMatchesSubdomains() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    let expected = pauseDecision(countdown: 10, opensLeft: 5, of: 5)
    expectEqual(engine.decision(domain: "youtube.com"), expected, "exact domain match")
    expectEqual(engine.decision(domain: "www.youtube.com"), expected, "www subdomain match")
    expectEqual(engine.decision(domain: "m.youtube.com"), expected, "m subdomain match")
}

private func testDomainLookupRejectsLookalikes() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    expectEqual(engine.decision(domain: "notyoutube.com"), .notManaged, "suffix without a dot is no match")
    expectEqual(engine.decision(domain: "youtube.com.evil.io"), .notManaged, "domain as a prefix is no match")
}

private func testDomainLookupNormalizesHost() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    let expected = pauseDecision(countdown: 10, opensLeft: 5, of: 5)
    expectEqual(engine.decision(domain: "WWW.YouTube.com"), expected, "host match is case-insensitive")
    expectEqual(engine.decision(domain: "youtube.com:8443"), expected, "port is stripped before matching")
}

private func testGentleShowsPauseWithoutBudgetLine() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: .gentle, clock: clock)
    expectEqual(
        engine.decision(targetID: target.id),
        .pause(countdownSeconds: 10, budgetLine: nil),
        "gentle has no budget to report"
    )
}

private func testEscalationGrowsCountdown() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    spendOneOpen(engine, target.id, clock)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 15, opensLeft: 4, of: 5),
        "second open waits 5 s longer"
    )
}

/// Escalation is a number the user picks, not a switch that means five. The presets still mean
/// five — that is what `testEscalationGrowsCountdown` above pins — and everything else is
/// whatever the group says, applied once per whole open already spent today.
private func testEscalationGrowsByTheChosenAmount() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.escalationSeconds = 30
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    spendOneOpen(engine, target.id, clock)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 40, opensLeft: 4, of: 5),
        "a group set to 30 s waits half a minute longer on its second open"
    )
    spendOneOpen(engine, target.id, clock)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 70, opensLeft: 3, of: 5),
        "and another half minute on its third"
    )
}

private func testBudgetExhaustionBlocks() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    for _ in 0..<4 { spendOneOpen(engine, target.id, clock) }
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)
    // Budget and cooldown are both spent now; the nearer wall is the one to name.
    expectEqual(
        engine.decision(targetID: target.id),
        cooldownDecision(minutes: 10),
        "a cooldown outranks an empty budget"
    )
    clock.advance(seconds: 601)
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .budgetExhausted, untilText: "Blocked until 03:00"),
        "sixth open is blocked until the day rolls over"
    )
}

private func testGroupSharesBudgetAcrossTargets() {
    let clock = FakeClock(noon)
    let (engine, app, site) = makeGroupedEngine(clock: clock)
    _ = engine.consumeOpen(targetID: app.id)
    expectEqual(
        engine.decision(domain: "youtube.com"),
        .allowed(remainingSessionSeconds: 300),
        "the domain joins the session the app started"
    )
    engine.endSession(targetID: site.id, early: false)
    clock.advance(seconds: 601)
    expectEqual(
        engine.decision(domain: "youtube.com"),
        pauseDecision(countdown: 15, opensLeft: 4, of: 5),
        "the open the app spent is missing from the domain's budget"
    )
}

// MARK: - A pause of no seconds

/// Zero is not a countdown that is already over — it is the pause case with no screen in it.
/// Everything downstream is the ordinary path: the open costs one, the session starts, the
/// relock and the wall behind it are untouched. See `GroupBudget.countdownSeconds`.
private func testNoPauseOpensByItself() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.pauseSeconds = 0
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    expectEqual(engine.decision(targetID: target.id), .opensByItself, "no wait, so no screen")
    expectEqual(
        engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: 300),
        "and the visit still costs an open and still starts the session"
    )
    expectEqual(opensUsed(engine), 1, "exactly one open, spent by arriving")
    expectEqual(
        engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 300),
        "the session is what the next arrival meets, so nothing is spent twice"
    )
}

/// A group with no session length has nothing to hold the next arrival, which is the whole of
/// what "gentle" means. It stays silent and it charges for every arrival — the cost a user
/// accepts by choosing it.
private func testNoPauseOnAGentleGroupChargesEveryArrival() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.gentle
    settings.pauseSeconds = 0
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    expectEqual(engine.decision(targetID: target.id), .opensByItself, "silent")
    expectEqual(
        engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: nil),
        "a gentle open, with no session behind it"
    )
    expectEqual(engine.decision(targetID: target.id), .opensByItself, "and still silent after it")
    expectEqual(
        engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: nil),
        "so a second arrival spends a second open"
    )
    expectEqual(opensUsed(engine), 2, "two arrivals, two opens")
}

/// The rule is about the *computed* wait, which is what makes a base of nought compose with
/// escalation instead of fighting it: the first open of the day is silent and the second meets a
/// screen with the escalated wait on it.
private func testNoPauseWithEscalationMeetsAScreenOnTheSecondOpen() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.pauseSeconds = 0
    settings.escalationSeconds = 30
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    expectEqual(engine.decision(targetID: target.id), .opensByItself, "the first open is silent")
    spendOneOpen(engine, target.id, clock)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 30, opensLeft: 4, of: 5),
        "and the second meets half a minute of screen"
    )
}

/// An emptied budget is still a wall, because there is nothing to auto-grant: the group is
/// blocked, and the block keeps its screen and its hide. A cooldown is the same.
private func testNoPauseStillWallsACooldownAndAnEmptyBudget() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.pauseSeconds = 0
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)
    expectEqual(
        engine.decision(targetID: target.id), cooldownDecision(minutes: 10),
        "the cooldown between opens still stands in the way"
    )
    clock.advance(seconds: 601)
    for _ in 0..<4 { spendOneOpen(engine, target.id, clock) }
    expectEqual(
        engine.decision(targetID: target.id), budgetExhaustedDecision,
        "and the day's last open leaves a wall rather than a silent way in"
    )
    expectEqual(
        engine.consumeOpen(targetID: target.id), .denied(budgetExhaustedDecision),
        "which refuses the spend rather than granting it"
    )
}
