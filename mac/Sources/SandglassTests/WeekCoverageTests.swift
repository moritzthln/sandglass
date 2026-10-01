import SandglassCore
import Foundation

/// Whether a group's week leaves any minute to the group's own friction — the pause countdown,
/// the opens budget, the cooldown, the session length.
///
/// `RulesEngine.decision(for:)` answers `.notManaged` inside a break window and `.blocked` inside
/// a strict one, and only reaches the seven knobs when **neither** is open. So a week its windows
/// cover end to end runs on nothing else, whatever those knobs say, and the editor that goes on
/// drawing them as settings in force is lying about the group.
///
/// This is the union of both kinds, which is what makes it a different question from
/// `strictBlocksEveryMinute` next door: that one subtracts breaks, because a break is a way back
/// into a locked settings screen. Here a break covers the minute exactly as a block does — the
/// group is fully open rather than fully shut, and reaches its budget neither way.
func runWeekCoverageTests() {
    testAWeekWithNoWindowsIsAllGap()
    testOneAllDayBlockLeavesNoGap()
    testABlockAndABreakThatMeetExactlyLeaveNoGap()
    testTheSamePairOnWeekdaysOnlyLeavesTheWeekend()
    testOverlappingWindowsStillCoverTheWeek()
    testOneMinuteIsAGap()
    testAWindowNamingNoDayCoversNothing()
    testABreakCoversAMinuteItDoesNotBlock()
}

/// Today's normal case, and the one the app is built around: no window at all, so every minute of
/// the week is the group's ordinary budget.
private func testAWeekWithNoWindowsIsAllGap() {
    expect(
        !TimeWindow.coversEveryMinute(of: []),
        "a group with no windows is its knobs, all week"
    )
}

/// A group blocked around the clock: one strict window over all 24 hours of all seven days, and a
/// 300-second pause countdown underneath it that nothing will ever show.
private func testOneAllDayBlockLeavesNoGap() {
    expect(
        TimeWindow.coversEveryMinute(of: [TimeWindow.make(.allDay, kind: .strictBlock)]),
        "blocked around the clock never reaches a pause screen"
    )
}

/// A night-time group: hard from 00:30 to 08:00, and deliberately free for the rest of the day. Two
/// windows, no third state, and so no minute in which a budget could be spent.
private func testABlockAndABreakThatMeetExactlyLeaveNoGap() {
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 30, to: 8 * 60)
    let day = window(.break, weekdays: TimeWindow.everyDay, from: 8 * 60, to: 30)
    expect(
        TimeWindow.coversEveryMinute(of: [night, day]),
        "hard until 08:00 and open after it leaves nothing in between"
    )
    // The two edges are the same number and the week is still whole, because a window holds its
    // start and not its end: 08:00 belongs to the break alone and 00:30 to the block alone. Were
    // the end inclusive they would overlap by a minute, which changes no answer here; were the
    // start exclusive both edges would fall through and the week would read as two holes.
    for (minute, name) in [(8 * 60, "08:00"), (30, "00:30")] {
        let holding = [night, day].filter { $0.contains(weekday: 2, minutes: minute) }
        expectEqual(holding.count, 1, "\(name) is inside exactly one of the two, not both")
    }
}

/// The same pair ticked Monday to Friday. The weekend is outside both, so the knobs are what the
/// group runs on for two days a week and the editor must go on saying so.
private func testTheSamePairOnWeekdaysOnlyLeavesTheWeekend() {
    let night = strictWindow(weekdays: TimeWindow.workWeek, from: 30, to: 8 * 60)
    let day = window(.break, weekdays: TimeWindow.workWeek, from: 8 * 60, to: 30)
    expect(
        !TimeWindow.coversEveryMinute(of: [night, day]),
        "a week that is only drawn on five days has two days of gap in it"
    )
    expect(
        ![night, day].contains { $0.contains(weekday: 7, minutes: 12 * 60) },
        "Saturday noon being inside neither is what the gap is made of"
    )
}

/// Overlap is not a hole. Windows may be listed in any order and may sit on top of one another,
/// and the union is still the union.
private func testOverlappingWindowsStillCoverTheWeek() {
    let morning = strictWindow(weekdays: TimeWindow.everyDay, from: 0, to: 14 * 60)
    let evening = window(.break, weekdays: TimeWindow.everyDay, from: 10 * 60, to: 24 * 60)
    expect(
        TimeWindow.coversEveryMinute(of: [morning, evening]),
        "four hours of overlap is not four hours of hole"
    )
    expect(
        TimeWindow.coversEveryMinute(of: [evening, morning]),
        "and the list is a set: the order it is written in decides nothing"
    )
}

/// One minute is a real minute: the engine reaches the pause screen in it, spends an open in it
/// and starts a session from it. So the smallest hole counts, and the editor keeps its knobs.
private func testOneMinuteIsAGap() {
    let almost = strictWindow(weekdays: TimeWindow.everyDay, from: 0, to: 24 * 60 - 1)
    expect(!TimeWindow.coversEveryMinute(of: [almost]), "23:59 to midnight is a gap")
    let head = strictWindow(weekdays: TimeWindow.everyDay, from: 0, to: 12 * 60)
    let tail = window(.break, weekdays: TimeWindow.everyDay, from: 12 * 60 + 1, to: 24 * 60)
    expect(
        !TimeWindow.coversEveryMinute(of: [head, tail]),
        "and so is the single minute between two windows that nearly meet"
    )
}

/// A state the editor can be left in mid-edit — every day unticked — and it has to mean the same
/// here as it does in `contains(weekday:minutes:)`: this window is not on.
private func testAWindowNamingNoDayCoversNothing() {
    let noDays = window(.break, weekdays: [], from: 0, to: 24 * 60)
    expect(!TimeWindow.coversEveryMinute(of: [noDays]), "a window on no day covers no minute")
    expect(
        TimeWindow.coversEveryMinute(of: [TimeWindow.make(.allDay, kind: .strictBlock), noDays]),
        "and takes nothing away from a week that was already whole"
    )
}

/// The line between this rule and the one beside it. An hour of break inside an otherwise
/// gapless block is an hour of unlocked settings — but not an hour in which any of them applies.
private func testABreakCoversAMinuteItDoesNotBlock() {
    let allWeek = TimeWindow.make(.allDay, kind: .strictBlock)
    let lunch = window(.break, weekdays: TimeWindow.everyDay, from: 12 * 60, to: 13 * 60)
    expect(
        TimeWindow.coversEveryMinute(of: [allWeek, lunch]),
        "an hour fully open is still an hour that spends no budget"
    )
    expect(
        !TimeWindow.strictBlocksEveryMinute(of: [allWeek, lunch]),
        "though it is a way back into the settings, which is the other rule's question"
    )
    expect(
        TimeWindow.coversEveryMinute(of: [
            window(.break, weekdays: TimeWindow.everyDay, from: 0, to: 24 * 60),
        ]),
        "and a group left open all week reaches its knobs exactly as often: never"
    )
}
