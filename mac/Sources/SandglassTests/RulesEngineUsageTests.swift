import Foundation
import SandglassCore

// Time spent, and the block that follows when too much of it has been.
//
// Shared fixtures (FakeClock, noon, youtubeGroup, makeEngine, decision builders) live in
// EngineFixtures.swift.

func runEngineUsageTests() {
    testUsageAccumulatesPerGroup()
    testUsageIgnoresNothingAndNonsense()
    testUsageResetsWithTheDay()
    testUsageOfARemovedGroupIsDropped()
    testUsageIsCountedInsideAGroupsOwnBreakWindow()
    testTimeLimitBlocksOnceItIsReached()
    testTimeLimitEndsTheRunningSession()
    testTimeLimitOutranksSessionCooldownAndBudget()
    testHardBlocksOutrankTheTimeLimit()
    testTimeLimitDeniesAnOpenWithoutBustingTheDay()
    testLoweringTheLimitBelowTodayBlocksAtOnce()
    testASessionIsNeverLongerThanTheDayHasLeft()
    testAFullSessionIsGrantedWhileTheDayCanHoldOne()
    testAGroupThatNeverRelocksIsNotGivenASession()
    testThePauseScreenReportsEveryBudgetThatIsOn()
    testATimeBudgetOnItsOwnIsStillReported()
    testAGroupWithNeitherBudgetReportsNothing()
}

/// Standard, plus a limit — no preset carries one, so every fixture here builds its own.
private func limited(to minutes: Int) -> GroupSettings {
    var settings = GroupSettings.standard
    settings.dailyMinutes = minutes
    return settings
}

private let timeLimitDecision = Decision.blocked(reason: .timeLimit, untilText: "Blocked until 03:00")

// MARK: - Counting

private func testUsageAccumulatesPerGroup() {
    let clock = FakeClock(noon)
    let (engine, site, other) = makeTwoGroupEngine(youtube: .standard, clock: clock)
    engine.recordUsage(groupID: site.groupID, seconds: 15)
    engine.recordUsage(groupID: site.groupID, seconds: 1)
    engine.recordUsage(groupID: other.groupID, seconds: 60)
    expectEqual(
        engine.statsSnapshot().usageSecondsToday,
        [youtubeGroup: 16, redditGroup: 60],
        "seconds add up per group, from both the one-a-second and the fifteen-a-heartbeat callers"
    )
}

/// Zero, negative and a group the configuration does not know all change nothing: the state
/// file should carry today's real numbers and no rows for groups that do not exist.
private func testUsageIgnoresNothingAndNonsense() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 0)
    engine.recordUsage(groupID: youtubeGroup, seconds: -600)
    engine.recordUsage(groupID: "grp:nobody", seconds: 60)
    expectEqual(engine.state.usageSecondsToday, [:], "nothing at all was recorded")
}

private func testUsageResetsWithTheDay() {
    let clock = FakeClock(august(10, 22))
    let (engine, _) = makeEngine(settings: limited(to: 30), clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 30 * 60)
    expectEqual(engine.decision(targetID: "domain:youtube.com"), timeLimitDecision, "the day is spent")
    clock.advance(seconds: 6 * 3600)   // 04:00 the next morning, past the 03:00 roll
    expectEqual(engine.statsSnapshot().usageSecondsToday, [:], "the new day starts at zero")
    expectEqual(
        engine.decision(targetID: "domain:youtube.com"),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5, minutesLeft: 30),
        "and the group is open again, with the whole of both budgets"
    )
}

/// The same rule the opens counter follows: a group the new configuration does not have cannot
/// keep yesterday's numbers waiting for the day it is added back.
private func testUsageOfARemovedGroupIsDropped() {
    let clock = FakeClock(noon)
    let (engine, site, other) = makeTwoGroupEngine(youtube: .standard, clock: clock)
    engine.recordUsage(groupID: site.groupID, seconds: 60)
    engine.recordUsage(groupID: other.groupID, seconds: 60)
    expectEdit(engine, "dropping a group is allowed outside a window") {
        Config(
            version: 1,
            targets: [other],
            groupSettings: [other.groupID: .standard]
        )
    }
    expectEqual(engine.state.usageSecondsToday, [redditGroup: 60], "only the surviving group's time is kept")
}

/// **Where the 277 minutes on a late-night group's card came from**, pinned because the number is real
/// and somebody will look for its source again.
///
/// `recordUsage` asks whether the group exists and is switched on, and nothing else — it never asks
/// what `decision(for:)` said. So a group sitting inside its own `break` window, which the engine
/// answers `.notManaged` for and the chooser calls "Allow full access", goes on being charged a
/// second per tick for every second one of its apps is in front. A week tiled with strict nights
/// and daytime breaks therefore accrues the whole day's usage while being, by its own schedule, not
/// managed at all.
///
/// **This is worth a decision rather than a test, and the test is here to make sure the decision is
/// taken deliberately.** The reasoning `OpenLedger.recordSecond` gives for counting through a lift
/// — "a daily limit that shrinks after a break spent scrolling is the limit working" — is about the
/// app-wide break and the emergency pass, which are holes somebody punched in a schedule on
/// purpose. A group's own break window is not that: it is the group's schedule saying these hours
/// are none of my business. Counting them is at best arguable, and it is why the sidebar had a
/// number to draw at all. What has been fixed is only the drawing — see `GroupSummary.today`.
private func testUsageIsCountedInsideAGroupsOwnBreakWindow() {
    let clock = FakeClock(august(10, 10))   // Monday, inside the daytime break
    let nights = strictWindow(weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)
    let days = window(.break, weekdays: TimeWindow.everyDay, from: 8 * 60, to: 22 * 60)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [nights, days]), clock: clock)
    expect(
        TimeWindow.coversEveryMinute(of: [nights, days]),
        "the week is the shape the complaint is about: tiled end to end"
    )
    expectEqual(
        engine.decision(targetID: target.id), .notManaged,
        "inside its own break window the engine is standing down over this group"
    )

    engine.recordUsage(groupID: youtubeGroup, seconds: 277 * 60)
    expectEqual(
        engine.state.usageSecondsToday[youtubeGroup], 277 * 60,
        "and the seconds are charged to it anyway — which is where the card's number came from"
    )
    expectEqual(
        engine.decision(targetID: target.id), .notManaged,
        "counted or not, the group is still not managed in this hour"
    )
}

// MARK: - The limit

private func testTimeLimitBlocksOnceItIsReached() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: limited(to: 30), clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 29 * 60 + 59)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5, minutesLeft: 0),
        "one second short of the limit is not the limit"
    )
    engine.recordUsage(groupID: youtubeGroup, seconds: 1)
    expectEqual(engine.decision(targetID: target.id), timeLimitDecision, "reaching it blocks until 03:00")
}

/// A limit that let the session it interrupted run to the end would be a limit only in name.
/// No cooldown follows, unlike every other way a session ends: the group is blocked until 03:00
/// anyway, and "next open in 10 min" would promise an earlier return than the user is getting.
private func testTimeLimitEndsTheRunningSession() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: limited(to: 30), clock: clock)
    expectEqual(engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: 300), "a session is running")
    engine.recordUsage(groupID: youtubeGroup, seconds: 30 * 60)
    expect(engine.state.sessions.isEmpty, "the session ends the moment the limit is reached")
    expect(engine.state.cooldownUntil.isEmpty, "and starts no cooldown behind it")
    expectEqual(engine.tick(), [.sessionEnded(groupID: youtubeGroup)], "the app is told, so the apps are hidden")
    expectEqual(engine.decision(targetID: target.id), timeLimitDecision, "and the group is blocked, not merely relocked")
}

private func testTimeLimitOutranksSessionCooldownAndBudget() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: limited(to: 30), clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)
    expectEqual(engine.decision(targetID: target.id), cooldownDecision(minutes: 10), "a cooldown is running")
    engine.recordUsage(groupID: youtubeGroup, seconds: 30 * 60)
    expectEqual(engine.decision(targetID: target.id), timeLimitDecision, "the limit is the reason shown, not the cooldown")
}

/// Everything that is a harder block than a daily limit still wins: the limit is the user's own
/// budget, and a focus session, a break and a schedule are all statements about the same minutes.
private func testHardBlocksOutrankTheTimeLimit() {
    let clock = FakeClock(august(10, 10))   // Monday, inside office hours
    var settings = standardSettings(windows: [officeHours])
    settings.dailyMinutes = 30
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 30 * 60)
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "the window is the reason")

    engine.startFocusSession(minutes: 25)
    expectEqual(engine.decision(targetID: target.id), focusDecision(until: "10:25"), "and a focus session outranks both")

    clock.advance(seconds: 25 * 60)
    expect(engine.useEmergencyPass(), "the pass is available")
    expectEqual(engine.decision(targetID: target.id), .notManaged, "an emergency pass lifts the limit with everything else")
}

/// A limit reached is not a budget busted: `deniedAttempts` is what ends a streak, and it is
/// about knocking after the opens are gone, not about walking into a wall the user built.
private func testTimeLimitDeniesAnOpenWithoutBustingTheDay() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: limited(to: 30), clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 30 * 60)
    expectEqual(engine.consumeOpen(targetID: target.id), .denied(timeLimitDecision), "the open is refused, with the reason")
    expectEqual(opensUsed(engine), 0, "and nothing is spent")
    expectEqual(engine.state.deniedAttempts, [:], "a time limit does not bust the day")
    expect(engine.state.sessions.isEmpty, "and grants no session")
}

/// The other way to reach a limit: the day's time is already spent when the limit is set.
private func testLoweringTheLimitBelowTodayBlocksAtOnce() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 40 * 60)
    _ = engine.consumeOpen(targetID: target.id)
    expectEdit(engine, "setting a limit is an ordinary edit") {
        Config(
            version: 1,
            targets: [target],
            groupSettings: [target.groupID: limited(to: 30)]
        )
    }
    expectEqual(engine.decision(targetID: target.id), timeLimitDecision, "the day is already over for this group")
    expect(engine.state.sessions.isEmpty, "and the session it was in the middle of is over too")
}

// MARK: - What one open is worth when both budgets are on

/// Standard's five-minute open is too short to show the defect; ten minutes against a limit with
/// two left is the case the old code sold and then took back two minutes later.
private func limited(to minutes: Int, openLength: Int?) -> GroupSettings {
    var settings = limited(to: minutes)
    settings.sessionMinutes = openLength
    return settings
}

/// The open still costs a whole open — fractional opens are a concept for a problem nobody has —
/// so what has to be true is that the session is honest about how long it can last.
private func testASessionIsNeverLongerThanTheDayHasLeft() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: limited(to: 30, openLength: 10), clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 28 * 60)
    expectEqual(
        engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: 2 * 60),
        "two minutes left in the day buys a two-minute open, not a ten-minute one"
    )
    expectEqual(opensUsed(engine), 1, "and it costs a whole open all the same")
    expectEqual(
        engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 2 * 60),
        "the session the app counts down is the one that was actually granted"
    )
}

private func testAFullSessionIsGrantedWhileTheDayCanHoldOne() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: limited(to: 30, openLength: 10), clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 5 * 60)
    expectEqual(
        engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: 10 * 60),
        "twenty-five minutes left is room for the whole open"
    )
}

/// "No relock" is what the user set. There is no session to shorten, and inventing one that ends
/// at the limit would bring a cooldown and a menu-bar countdown with it.
private func testAGroupThatNeverRelocksIsNotGivenASession() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: limited(to: 30, openLength: nil), clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 28 * 60)
    expectEqual(
        engine.consumeOpen(targetID: target.id), .granted(sessionSeconds: nil),
        "a gentle group is still gentle under a time limit"
    )
    expect(engine.state.sessions.isEmpty, "and nothing was written that would relock it")
}

// MARK: - What the pause screen says about them

private func testThePauseScreenReportsEveryBudgetThatIsOn() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: limited(to: 30), clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 18 * 60)
    expectEqual(
        engine.decision(targetID: target.id),
        .pause(countdownSeconds: 10, budgetLine: "5 of 5 opens and 12 min left today"),
        "both budgets are on, so both are on the screen"
    )
    expectEqual(
        engine.budgetLine(forGroup: youtubeGroup), "5 of 5 opens and 12 min left today",
        "and the menu bar reads that sentence from the same place"
    )
}

/// The minutes are floored the way the opens are: forty seconds left is not a minute to stay.
private func testATimeBudgetOnItsOwnIsStillReported() {
    let clock = FakeClock(noon)
    var settings = limited(to: 30)
    settings.opensPerDay = nil
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 12 * 60 + 20)
    expectEqual(
        engine.decision(targetID: target.id),
        .pause(countdownSeconds: 10, budgetLine: "17 min left today"),
        "no opens budget is no reason to say nothing about the day"
    )
}

private func testAGroupWithNeitherBudgetReportsNothing() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(settings: .gentle, clock: clock)
    expectEqual(
        engine.decision(targetID: target.id),
        .pause(countdownSeconds: 10, budgetLine: nil),
        "there is no budget to report, so no line is invented"
    )
}
