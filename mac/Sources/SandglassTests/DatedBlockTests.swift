import Foundation
import SandglassCore

/// A group blocked until a chosen day: what is stored, when it lifts, and what it outranks.
///
/// The whole feature rests on one decision — the stored thing is a **calendar day**, in the
/// spelling `EngineState.dayKey` already uses — so most of what is checked here is what that
/// buys: an end that honours `dayStartMinutes`, follows it when it moves, and costs a DST switch
/// nothing, because none of it is a duration.
func runDatedBlockTests() {
    testAStoredDayIsADayOrItIsNothing()
    testAPastDayReadsAsAbsent()
    testADayIsWrittenDownTwoWays()
    testTheQuickSpansResolveToADay()
    testASpanSetLateInTheEveningIsShortAndSaysSo()
    testAPickedDateIsTheDayItWasDrawnOn()
    testTheGroupIsBlockedUntilTheDayNamed()
    testTheEndIsTheDayStartRatherThanMidnight()
    testMovingTheStartOfTheDayMovesTheEnd()
    testADSTSwitchInsideTheBlockChangesNothing()
    testTheEmergencyPassLiftsItUnlessTheGroupIgnoresThePass()
    testABreakLiftsItUnlessTheGroupIgnoresTheUnblocks()
    testItOutranksTheGroupsOwnWeek()
    testItOutranksEveryBudget()
    testAPauseOfZeroSecondsSpendsNothingWhileItStands()
    testTheClockGuardHoldsIt()
}

// MARK: - The stored day

/// Every comparison in this feature is a string comparison, which is only a date comparison while
/// the string is a real day. A hand-edited `config.json` is why that is checked rather than
/// assumed — and why anything else is read as no dated block instead of taking the document down.
private func testAStoredDayIsADayOrItIsNothing() {
    expectEqual(DatedBlock.normalized("2026-08-24"), "2026-08-24", "a day comes back as itself")
    expectEqual(
        DatedBlock.normalized("2026-8-5"), "2026-08-05",
        "and a day written short is re-derived rather than left to sort as its own string"
    )
    expectNil(DatedBlock.normalized(nil), "no value is no dated block")
    expectNil(DatedBlock.normalized("soon"), "nor is a word")
    expectNil(DatedBlock.normalized("2026-08"), "nor two thirds of a date")
    expectNil(DatedBlock.normalized("2027-02-29"), "nor three plausible numbers that are not a day")
    expectNil(DatedBlock.normalized("2026-13-01"), "nor a thirteenth month")

    var settings = GroupSettings.standard
    settings.blockedUntilDay = "2026-8-5"
    expectEqual(
        settings.blockedUntilDay, "2026-08-05",
        "a value set in code is normalized too, so nothing downstream meets a day it cannot read"
    )
}

/// The rule that makes a dated block self-cleaning: the moment the named day begins it is over,
/// and from then on it reads exactly like a group that never had one.
private func testAPastDayReadsAsAbsent() {
    expectEqual(
        DatedBlock.standing("2026-08-24", onDay: "2026-08-23"), "2026-08-24",
        "a day still ahead is a block still standing"
    )
    expectNil(
        DatedBlock.standing("2026-08-24", onDay: "2026-08-24"),
        "the named day arriving is the block ending — it lasts *until* that day begins"
    )
    expectNil(DatedBlock.standing("2026-08-24", onDay: "2026-08-25"), "and a day past is absent")
    expectNil(DatedBlock.standing(nil, onDay: "2026-08-23"), "as is no day at all")
}

private func testADayIsWrittenDownTwoWays() {
    expectEqual(DatedBlock.shortText("2026-08-24"), "Mon 24 Aug", "the engine's own sentence")
    expectEqual(
        DatedBlock.longText("2026-08-24"), "Monday, 24 August",
        "and the group editor's row, which has the width for it"
    )
    expectEqual(
        BlockEnd.onDay("Mon 24 Aug").clause, "until Mon 24 Aug",
        "and one place decides the clause either of them ends up inside"
    )
    expectEqual(
        DatedBlock.shortText("2027-01-01"), "Fri 1 Jan",
        "a single-figure day is not padded — it is a sentence, not a key"
    )
    expectEqual(
        DatedBlock.rowText("2026-08-24"), "Blocked until Monday, 24 August",
        "the group editor's row is the engine's sentence at the width it has room for"
    )
}

// MARK: - The spans

private func testTheQuickSpansResolveToADay() {
    let monday = "2026-08-24"
    expectEqual(DatedBlock.day(.day, from: monday), "2026-08-25", "1 day")
    expectEqual(DatedBlock.day(.threeDays, from: monday), "2026-08-27", "3 days")
    expectEqual(DatedBlock.day(.week, from: monday), "2026-08-31", "1 week")
    expectEqual(DatedBlock.day(.twoWeeks, from: monday), "2026-09-07", "2 weeks")
    expectEqual(
        DatedBlock.day(.month, from: monday), "2026-09-24",
        "and a month is a month rather than thirty days, which is what choosing it means"
    )
    expectEqual(
        DatedBlock.day(.month, from: "2026-01-31"), "2026-02-28",
        "a month from a day the next one does not have lands on its last"
    )
    expectEqual(
        DatedBlock.Span.allCases.map(\.title),
        ["1 day", "3 days", "1 week", "2 weeks", "1 month"],
        "and the control offers them in that order"
    )
    expectEqual(
        DatedBlock.Span.allCases.map { DatedBlock.spanTitle($0, from: monday) },
        [
            "1 day · Tue 25 Aug", "3 days · Thu 27 Aug", "1 week · Mon 31 Aug",
            "2 weeks · Mon 7 Sep", "1 month · Thu 24 Sep",
        ],
        "each row carrying the day it reaches, so the date is read before the press and not after"
    )
}

/// The case that would otherwise want a special rule: "for 1 day" pressed at 23:00 buys about two
/// hours. It needs none, because the day it resolves to is on screen before anything is saved —
/// which is the whole reason the spans resolve at all rather than being stored as spans.
private func testASpanSetLateInTheEveningIsShortAndSaysSo() {
    let lateEvening = august(23, 23)
    let today = DatedBlock.today(at: lateEvening, calendar: testCalendar, dayStartMinutes: 60)
    expectEqual(today, "2026-08-23", "23:00 is still inside the day that began at 01:00")
    expectEqual(
        DatedBlock.day(.day, from: today), "2026-08-24",
        "so a one-day block reaches tomorrow's day start"
    )
    expectEqual(
        DatedBlock.longText(DatedBlock.day(.day, from: today) ?? ""), "Monday, 24 August",
        "and the row names the day before anything is committed"
    )
}

private func testAPickedDateIsTheDayItWasDrawnOn() {
    let midnight = august(25, 0)
    expectEqual(
        DatedBlock.day(picked: midnight, calendar: testCalendar), "2026-08-25",
        "a date picker draws calendar days, so no day start shifts a click on the 25th to the 24th"
    )
    expectEqual(
        DatedBlock.date("2026-08-25", calendar: testCalendar), august(25, 12),
        "and the seed reads back as midday, where no zone or DST switch can move the date"
    )
}

// MARK: - The engine

private func testTheGroupIsBlockedUntilTheDayNamed() {
    let clock = FakeClock(august(20, 12))
    let (engine, target) = makeEngine(settings: datedSettings(until: "2026-08-24"), clock: clock)
    expectEqual(
        engine.decision(targetID: target.id), datedDecision(until: "Mon 24 Aug"),
        "the sentence carries the date, because no clock face could say when this ends"
    )
    clock.now = august(24, 3)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and the ordinary week takes over the moment the named day begins"
    )
}

/// The follow-up choice: the block ends when the day begins **by the app's own day
/// start**, which is when a budget comes back — not at midnight.
private func testTheEndIsTheDayStartRatherThanMidnight() {
    let clock = FakeClock(august(24, 23))
    let (engine, target) = makeEngine(
        settings: datedSettings(until: "2026-08-25"), clock: clock, dayStartMinutes: 60
    )
    expectEqual(
        engine.decision(targetID: target.id), datedDecision(until: "Tue 25 Aug"),
        "blocked the evening before"
    )
    clock.now = august(25, 0, 30)
    expectEqual(
        engine.decision(targetID: target.id), datedDecision(until: "Tue 25 Aug"),
        "and still blocked at half past midnight, which is the night before as this app counts"
    )
    clock.now = august(25, 1)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "it lifts at 01:00, where the day starts"
    )
}

/// The honest consequence of storing a day rather than an instant, and the reason it is stored
/// that way: the promise was "until Tuesday", so the boundary the app draws is the one that moves.
private func testMovingTheStartOfTheDayMovesTheEnd() {
    let clock = FakeClock(august(25, 2))
    let (engine, target) = makeEngine(
        settings: datedSettings(until: "2026-08-25"), clock: clock, dayStartMinutes: 180
    )
    expectEqual(
        engine.decision(targetID: target.id), datedDecision(until: "Tue 25 Aug"),
        "02:00 belongs to Monday while the day starts at 03:00, so the block still stands"
    )
    var moved = engine.config
    moved.dayStartMinutes = 60
    engine.updateConfig(moved)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "moving the start of the day to 01:00 puts this moment in Tuesday, and the block is over"
    )
}

/// The end is a local-calendar moment worked out by the arithmetic that decides when a budget
/// comes back, so the 25-hour day the clocks go back on is not an hour of block gained or lost.
private func testADSTSwitchInsideTheBlockChangesNothing() {
    // Europe/Berlin puts its clocks back in the small hours of Sunday 25 October 2026.
    let clock = FakeClock(localTime(month: 10, day: 24, hour: 12))
    let (engine, target) = makeEngine(settings: datedSettings(until: "2026-10-26"), clock: clock)
    expectEqual(
        engine.decision(targetID: target.id), datedDecision(until: "Mon 26 Oct"),
        "blocked the day before the switch"
    )
    clock.now = localTime(month: 10, day: 25, hour: 12)
    expectEqual(
        engine.decision(targetID: target.id), datedDecision(until: "Mon 26 Oct"),
        "and through the long day itself"
    )
    clock.now = localTime(month: 10, day: 26, hour: 3)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "lifting at the day start on the day named, with the extra hour changing nothing"
    )
}

/// It sits under the pass for the reason a strict window does: the pass is the one way out of a
/// block made to have none. A group that has opted out of the pass follows from the ordering for
/// free, which is exactly why it is worth a check of its own.
private func testTheEmergencyPassLiftsItUnlessTheGroupIgnoresThePass() {
    let clock = FakeClock(august(20, 12))
    var immune = datedSettings(until: "2026-08-24")
    immune.ignoresAppWideUnblocks = true
    let (engine, reachable, opted) = makeTwoGroupEngine(
        youtube: datedSettings(until: "2026-08-24"), reddit: immune, clock: clock
    )
    engine.useEmergencyPass()
    expectEqual(
        engine.decision(targetID: reachable.id), .notManaged,
        "the pass lifts a dated block like any other"
    )
    expectEqual(
        engine.decision(targetID: opted.id), datedDecision(until: "Mon 24 Aug"),
        "and a group that ignores the pass goes on being blocked until its day"
    )
}

/// The other way out, and the one a fortnight-long block has to survive: "Unblock everything" sits
/// above the date exactly as the pass does, and the same group is exempt from both.
///
/// Worth its own check rather than left to follow from the ordering: a dated block is the longest
/// commitment the app can make, and a break is the cheapest thing that used to end one — a wait and
/// a menu, no rationing, as often as you like. A group immune to the once-a-week pass being opened
/// by the any-time break is the hole this closes, and the date is where it cost the most.
private func testABreakLiftsItUnlessTheGroupIgnoresTheUnblocks() {
    let clock = FakeClock(august(20, 12))
    var immune = datedSettings(until: "2026-08-24")
    immune.ignoresAppWideUnblocks = true
    let (engine, reachable, opted) = makeTwoGroupEngine(
        youtube: datedSettings(until: "2026-08-24"), reddit: immune, clock: clock
    )
    expect(engine.pauseProtection(minutes: 15), "the break is granted with both groups blocked")
    expectEqual(
        engine.decision(targetID: reachable.id), .notManaged,
        "and it lifts a dated block like any other"
    )
    expectEqual(
        engine.decision(targetID: opted.id), datedDecision(until: "Mon 24 Aug"),
        "while a group that ignores the app's ways out is blocked until its day regardless"
    )

    clock.advance(seconds: 15 * 60)
    expectEqual(
        engine.decision(targetID: reachable.id), datedDecision(until: "Mon 24 Aug"),
        "and the other one is blocked again when the break is over"
    )
}

/// A week set aside is a week set aside, and this is the placement the whole feature turns on: the
/// check sits **above** the break-window branch, not beside the strict one.
///
/// Read the other way round — under the break — a dated block would be void for every hour a break
/// covers, and a night-time group is often tiled with a daytime break: "blocked for a week"
/// would hold at night and nowhere else. The rule is deliberate: the whole group is
/// shut until the day begins, *then* the ordinary week takes over.
private func testItOutranksTheGroupsOwnWeek() {
    let clock = FakeClock(august(20, 12))
    let allDayOff = window(
        .break, weekdays: TimeWindow.everyDay, from: 0, to: TimeWindow.minutesInDay
    )
    let (engine, target) = makeEngine(
        settings: datedSettings(until: "2026-08-24", windows: [allDayOff]), clock: clock
    )
    expectEqual(
        engine.decision(targetID: target.id), datedDecision(until: "Mon 24 Aug"),
        "a break window open right now does not punch a hole in a dated block"
    )
    // And the one thing that still reaches such a group, so the ordering is pinned from both ends:
    // the pass is above the date exactly as the date is above the week.
    engine.useEmergencyPass()
    expectEqual(
        engine.decision(targetID: target.id), .notManaged,
        "while the week's pass, which sits above it, opens that same group for the hour"
    )

    let (blocked, blockedTarget) = makeEngine(
        settings: datedSettings(until: "2026-08-24", windows: [officeHours]), clock: clock
    )
    expectEqual(
        blocked.decision(targetID: blockedTarget.id), datedDecision(until: "Mon 24 Aug"),
        "and a strict window standing at the same moment does not get to name the earlier end"
    )
    clock.now = august(24, 3)
    expectEqual(
        engine.decision(targetID: target.id), .notManaged,
        "when the day arrives the ordinary week takes over, break window and all"
    )
}

private func testItOutranksEveryBudget() {
    let clock = FakeClock(august(20, 12))
    let (engine, target) = makeEngine(settings: datedSettings(until: "2026-08-24"), clock: clock)
    expectEqual(
        engine.consumeOpen(targetID: target.id),
        .denied(datedDecision(until: "Mon 24 Aug")),
        "there is no way through while it stands, whatever today's budget has left"
    )
    expectEqual(opensUsed(engine), 0, "and nothing was spent finding that out")
    expectEqual(
        engine.state.deniedAttempts[youtubeGroup] ?? 0, 0,
        "nor does walking into a wall the user themselves put up bust the day"
    )
}

/// The group with no pause screen at all is the one case where "blocked" and "opens by itself"
/// could be confused: arriving at such a group spends an open on its own. A dated block outranks
/// it, so nothing is spent and nothing opens.
private func testAPauseOfZeroSecondsSpendsNothingWhileItStands() {
    let clock = FakeClock(august(20, 12))
    var silent = datedSettings(until: "2026-08-24")
    silent.pauseSeconds = 0
    let (engine, target) = makeEngine(settings: silent, clock: clock)
    expectEqual(
        engine.decision(targetID: target.id), datedDecision(until: "Mon 24 Aug"),
        "no pause screen does not mean no block"
    )
    expectEqual(
        engine.consumeOpen(targetID: target.id),
        .denied(datedDecision(until: "Mon 24 Aug")),
        "and the arrival that would normally spend an open by itself spends nothing"
    )
    expectEqual(opensUsed(engine), 0, "the budget is untouched")
}

/// What the clock guard is worth here, stated rather than assumed: winding the clock forward past
/// the day does not open the group, because the guard sits above every block including this one.
/// What it cannot cover is a forward jump plus a restart, which is the honest limit of it.
private func testTheClockGuardHoldsIt() {
    let clock = FakeClock(august(20, 12))
    let (engine, target) = makeEngine(settings: datedSettings(until: "2026-08-24"), clock: clock)
    clock.setWallClock(to: august(26, 12))
    expectEqual(
        engine.decision(targetID: target.id), clockTamperedDecision,
        "a clock set past the day is a clock the engine refuses to believe"
    )
    clock.setWallClock(to: august(20, 12, 1))
    expectEqual(
        engine.decision(targetID: target.id), datedDecision(until: "Mon 24 Aug"),
        "and putting it back leaves the block exactly where it was"
    )
}
