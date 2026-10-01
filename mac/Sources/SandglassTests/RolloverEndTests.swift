import Foundation
import SandglassCore

/// What a block that lasts "until the counters come back" is allowed to promise.
///
/// A spent budget and a day's time limit both end at the start of the day, and both used to say
/// so and stop there. That is only the truth for a group whose week is empty at that hour. Put a
/// strict window over the boundary — which is exactly what a bedtime window does, since the day
/// starts in the small hours — and the counters come back inside a block that goes on holding.
/// The engine was naming a moment at which nothing whatever could be opened.
///
/// Two layers, checked separately. `TimeWindow.firstUnblockedMinute` is the arithmetic: walk the
/// week forward from a minute and answer with the first one the group is not shut out of. The
/// engine is the sentence built on it.
func runRolloverEndTests() {
    // The arithmetic
    testAnEmptyWeekAnswersTheMinuteItWasAsked()
    testAWindowOverTheMinuteAnswersItsEnd()
    testASecondWindowWaitingAtTheFirstOnesEndIsWalkedThrough()
    testABreakStandingAtTheMinuteIsNotABlock()
    testABreakOpeningInsideTheBlockIsTheAnswer()
    testAWeekWithNoFreeMinuteHasNoAnswer()
    // The sentence
    testAnExhaustedBudgetNamesTheDayStartWhenNothingStandsAtIt()
    testAnExhaustedBudgetNamesTheEndOfTheWindowOverTheDayStart()
    testASpentTimeLimitNamesTheSameMoment()
    testAWindowOpeningAfterTheDayStartIsNotWalkedInto()
    testABreakOverTheDayStartLeavesItNamed()
}

// MARK: - The arithmetic

/// The ordinary case: a group with no schedule at all is free the second its budget is handed
/// back, so the minute asked about is the minute answered.
private func testAnEmptyWeekAnswersTheMinuteItWasAsked() {
    let free = TimeWindow.firstUnblockedMinute(of: [], fromWeekday: 2, minutes: 60)
    expectEqual(free?.weekday, 2, "no windows, so Monday stays Monday")
    expectEqual(free?.minutes, 60, "and 01:00 is already free")
}

/// A video group, at the hour that made this a bug: a 23:30–12:00 window, and a day that
/// starts at 01:00 inside it. The counters really do come back at 01:00; the first open is at noon.
private func testAWindowOverTheMinuteAnswersItsEnd() {
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 23 * 60 + 30, to: 12 * 60)
    let free = TimeWindow.firstUnblockedMinute(of: [night], fromWeekday: 2, minutes: 60)
    expectEqual(free?.minutes, 12 * 60, "the window standing at 01:00 runs to noon")
    expectEqual(free?.weekday, 2, "on the same day, because the tail belongs to Monday morning")
}

/// The case a single lookup gets wrong: one window ends and the next one is already open. The
/// answer is where the chain stops, not where its first link does.
private func testASecondWindowWaitingAtTheFirstOnesEndIsWalkedThrough() {
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 23 * 60, to: 8 * 60)
    let morning = strictWindow(weekdays: TimeWindow.everyDay, from: 8 * 60, to: 10 * 60)
    let free = TimeWindow.firstUnblockedMinute(of: [night, morning], fromWeekday: 4, minutes: 60)
    expectEqual(free?.minutes, 10 * 60, "08:00 is not a way out when another block starts there")
    expectEqual(free?.weekday, 4, "and it is still the same morning")
}

/// A break outranks a block wherever the two overlap — `WindowClock.strictWindow` says so, and
/// this walks the week by the same rule rather than a second one that could disagree.
private func testABreakStandingAtTheMinuteIsNotABlock() {
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 23 * 60, to: 12 * 60)
    let free = window(.break, weekdays: TimeWindow.everyDay, from: 0, to: 2 * 60)
    let answer = TimeWindow.firstUnblockedMinute(of: [night, free], fromWeekday: 2, minutes: 60)
    expectEqual(answer?.minutes, 60, "01:00 is inside the break, so 01:00 is the answer")
}

/// And the reason the week is walked a minute at a time rather than jumped window-end to
/// window-end: a break that opens in the middle of a block is a way out before the block's own end.
private func testABreakOpeningInsideTheBlockIsTheAnswer() {
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 23 * 60, to: 12 * 60)
    let lunch = window(.break, weekdays: TimeWindow.everyDay, from: 9 * 60, to: 10 * 60)
    let answer = TimeWindow.firstUnblockedMinute(of: [night, lunch], fromWeekday: 2, minutes: 60)
    expectEqual(answer?.minutes, 9 * 60, "the hole in the block is reached before the block ends")
}

/// A group blocked around the clock: one strict window over all 24 hours of all seven days. There
/// is no first free minute, and saying so is the only honest answer — see
/// `RulesEngine.decision(for:)` for why no sentence is ever built on it.
private func testAWeekWithNoFreeMinuteHasNoAnswer() {
    let always = TimeWindow.make(.allDay, kind: .strictBlock)
    expectNil(
        TimeWindow.firstUnblockedMinute(of: [always], fromWeekday: 2, minutes: 60),
        "a week with no gap in it never opens"
    )
}

// MARK: - The sentence

/// The unchanged case, and the one every other engine test relies on: a group with no windows is
/// blocked until the day rolls over, and says the hour it rolls over at.
private func testAnExhaustedBudgetNamesTheDayStartWhenNothingStandsAtIt() {
    let clock = FakeClock(august(10, 19, 30))
    let (engine, target) = makeRolloverEngine(windows: [], clock: clock)
    spendTheBudget(engine, target, clock)
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .budgetExhausted, untilText: "Blocked until 01:00"),
        "an empty week hands the budget back at the day's start and nothing holds it"
    )
}

/// The bug, in the shape it was found in: six opens spent at 19:30 on a group blocked 23:30–12:00,
/// with the day starting at 01:00. It said 01:00 — sixteen and a half hours before an open could
/// actually be taken.
private func testAnExhaustedBudgetNamesTheEndOfTheWindowOverTheDayStart() {
    let clock = FakeClock(august(10, 19, 30))
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 23 * 60 + 30, to: 12 * 60)
    let (engine, target) = makeRolloverEngine(windows: [night], clock: clock)
    spendTheBudget(engine, target, clock)
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .budgetExhausted, untilText: "Blocked until 12:00"),
        "the counters reset at 01:00 inside a block that runs to noon, so noon is the answer"
    )
}

/// The other block that ends when the day does. Both read the same moment, so a group with a time
/// limit cannot end up promising one hour and a group with a budget another.
private func testASpentTimeLimitNamesTheSameMoment() {
    let clock = FakeClock(august(10, 19, 30))
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 23 * 60 + 30, to: 12 * 60)
    var settings = standardSettings(windows: [night])
    settings.dailyMinutes = 30
    let (engine, target) = makeRolloverEngine(settings: settings, clock: clock)
    engine.recordUsage(groupID: target.groupID, seconds: 31 * 60)
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .timeLimit, untilText: "Blocked until 12:00"),
        "a day's time is handed back with the day, and held by the same window"
    )
}

/// The walk starts at the boundary rather than now, so a window between the two is not walked
/// into: the same video group also blocks 14:00–19:00, which is over long before 01:00 comes round.
private func testAWindowOpeningAfterTheDayStartIsNotWalkedInto() {
    let clock = FakeClock(august(10, 19, 30))
    let afternoon = strictWindow(weekdays: TimeWindow.everyDay, from: 14 * 60, to: 19 * 60)
    let (engine, target) = makeRolloverEngine(windows: [afternoon], clock: clock)
    spendTheBudget(engine, target, clock)
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .budgetExhausted, untilText: "Blocked until 01:00"),
        "a window that is closed at the boundary holds nothing back"
    )
}

/// A break standing at the boundary is the group fully open, which is as free as a minute gets.
private func testABreakOverTheDayStartLeavesItNamed() {
    let clock = FakeClock(august(10, 19, 30))
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 23 * 60, to: 12 * 60)
    let early = window(.break, weekdays: TimeWindow.everyDay, from: 0, to: 2 * 60)
    let (engine, target) = makeRolloverEngine(windows: [night, early], clock: clock)
    spendTheBudget(engine, target, clock)
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .budgetExhausted, untilText: "Blocked until 01:00"),
        "a deliberate hole over the boundary is where the budget is spendable again"
    )
}

// MARK: - Helpers

/// A day that starts late, which is the whole reason this is worth checking: it starts at 01:00, so
/// a bedtime window is standing over the boundary rather than closed well before it.
private func makeRolloverEngine(
    windows: [TimeWindow], clock: FakeClock
) -> (RulesEngine, Target) {
    makeRolloverEngine(settings: standardSettings(windows: windows), clock: clock)
}

private func makeRolloverEngine(
    settings: GroupSettings, clock: FakeClock
) -> (RulesEngine, Target) {
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let config = Config(
        version: 1,
        targets: [target],
        groupSettings: [target.groupID: settings],
        dayStartMinutes: 60
    )
    let engine = RulesEngine(
        config: config,
        state: .initial(now: clock.now, calendar: testCalendar, dayStartMinutes: 60),
        clock: clock,
        calendar: testCalendar
    )
    return (engine, target)
}

/// Spends every open the group has, so the next question is answered by the empty budget.
private func spendTheBudget(_ engine: RulesEngine, _ target: Target, _ clock: FakeClock) {
    for _ in 0..<(GroupSettings.standard.opensPerDay ?? 0) {
        spendOneOpen(engine, target.id, clock)
    }
}
