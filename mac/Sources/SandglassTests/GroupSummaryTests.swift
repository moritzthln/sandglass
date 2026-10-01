import SandglassAppCore
import SandglassCore
import Foundation

/// The short lines the sidebar cards and the popover are made of. They are the numbers the user
/// scans the list for, so they are arithmetic with wording attached rather than layout — and
/// checked here rather than by squinting at a window.
func runGroupSummaryTests() {
    testTargetSummaryCountsWhatIsThere()
    testACardSaysWhereTheDayStandsOrWhatIsInIt()
    testTodayLineIsHonestAboutNothing()
    testBothPlacesThatCountOpensCountThemTheSameWay()
    testTodayLineNamesATimeLimitTheWayItNamesAnOpensBudget()
    testACoveredWeekReportsItsScheduleAndNoNumbers()
    testADatedBlockReportsItsDayAndNoNumbers()
    testDailyTotalMultipliesTheTwoBudgets()
    testDailyTotalIsCappedByTheTimeLimit()
    testWhySomethingIsBlockedIsSaidInWords()
    testTheHeadlineCountsWhatIsBlocked()
    testTheHeadlineRanksTheFactsAgainstEachOther()
    testABreakNamesTheLaterOfTheTwoEnds()
    testABreakOutlastedByAPassSaysWhichIsHolding()
}

private func testTargetSummaryCountsWhatIsThere() {
    expectEqual(GroupSummary.targets(apps: 1, sites: 2), "1 app · 2 sites", "singular and plural")
    expectEqual(GroupSummary.targets(apps: 0, sites: 1), "1 site", "an absent half is left out")
    expectEqual(GroupSummary.targets(apps: 3, sites: 0), "3 apps", "either way round")
    expectEqual(
        GroupSummary.targets(apps: 0, sites: 0), "Nothing in it yet",
        "and an empty group says so rather than showing '0 sites'"
    )
}

private func testACardSaysWhereTheDayStandsOrWhatIsInIt() {
    expectEqual(
        GroupSummary.cardStatus(todayLine: "3 of 5 opens left", apps: 1, sites: 2),
        "3 of 5 opens left",
        "where the day stands wins: it is the half that changes while you watch the list"
    )
    expectEqual(
        GroupSummary.cardStatus(todayLine: "Blocked until 08:00", apps: 0, sites: 1),
        "Blocked until 08:00", "and a block is where the day stands"
    )
    expectEqual(
        GroupSummary.cardStatus(todayLine: "", apps: 0, sites: 0), "Nothing in it yet",
        "a group the engine has nothing to say about falls back to what is in it, which is nothing"
    )
    expectEqual(
        GroupSummary.cardStatus(todayLine: "", apps: 2, sites: 0), "2 apps",
        "or to the count, for a group holding targets it has no settings to block them with"
    )
}

private func testTodayLineIsHonestAboutNothing() {
    expectEqual(
        GroupSummary.today(opensUsed: 3, opensPerDay: 5, usageSeconds: 12 * 60),
        "2 of 5 opens left · 12 min",
        "what is left of the budget, and the unspent time counted as time because nothing caps it"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 2.5, opensPerDay: 5, usageSeconds: 0), "2 of 5 opens left",
        "half an open earned back is not an open to spend, and no minutes yet is not '0 min'"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 1, opensPerDay: nil, usageSeconds: 90), "1 open · 1 min",
        "a group with no budget has nothing to be left of, so it counts what it spent"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 0, opensPerDay: nil, usageSeconds: 30), "Nothing today",
        "and half a minute on an unlimited group is not worth a line"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 0, opensPerDay: 5, usageSeconds: 0), "5 of 5 opens left",
        "while an untouched budget is worth showing, and what it is worth showing is its whole self"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 5, opensPerDay: 5, usageSeconds: 0), "0 of 5 opens left",
        "a spent budget bottoms out at nothing rather than going negative"
    )
}

/// The one number this app exists to report, read off the two places that report it.
///
/// `GroupSummary.today` writes the sidebar card and the Stats page; `GroupBudget.line` — reached
/// here through the engine — writes the pause screen, the block page, the popover and the group
/// editor's own pill. They used to disagree about which way `"N of M opens"` counted, so the
/// editor showed "0 of 5 opens" on the left and "5 of 5 opens left today" at the top right about
/// one group at one moment. Whichever way the wording goes next, these two go together.
private func testBothPlacesThatCountOpensCountThemTheSameWay() {
    let (engine, target) = makeEngine(clock: FakeClock(noon))

    func card(_ opensUsed: Double) -> String {
        GroupSummary.today(opensUsed: opensUsed, opensPerDay: 5, usageSeconds: 0)
    }

    expectEqual(
        card(0), "5 of 5 opens left",
        "an untouched budget is five left in the card"
    )
    expect(
        engine.budgetLine(forGroup: target.groupID)?.hasPrefix("5 of 5 opens") == true,
        "and five left in the engine's own line, which is the same five"
    )
    // The floor is the half-open trap: 1.5 gone leaves three whole opens, not four. Flooring the
    // spend instead of the remainder is how the two sites drift by a whole open.
    expectEqual(
        card(1.5), "3 of 5 opens left",
        "the remainder is floored, so half an open earned back buys nothing until it is whole"
    )
}

/// The time limit is a budget too, so the line names it from the moment it exists — the same rule
/// the opens half follows, and the reason the stats page can now show this very sentence.
private func testTodayLineNamesATimeLimitTheWayItNamesAnOpensBudget() {
    expectEqual(
        GroupSummary.today(
            opensUsed: 2, opensPerDay: 5, usageSeconds: 12 * 60, dailyMinutes: 60
        ),
        "3 of 5 opens · 48 of 60 min left",
        "both budgets, both counting down, and 'left' said once for the pair"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 0, opensPerDay: nil, usageSeconds: 0, dailyMinutes: 60),
        "60 of 60 min left",
        "a limit is worth showing before a minute of it is spent"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 0, opensPerDay: nil, usageSeconds: 90, dailyMinutes: 60),
        "58 of 60 min left",
        "and the seconds the card never shows still count: ninety of them are two minutes gone"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 0, opensPerDay: nil, usageSeconds: 0),
        "Nothing today",
        "while a group with neither budget still says so"
    )
}

/// **A week with no gap in it has no day to report**, so the card says what the schedule is doing
/// and nothing else.
///
/// The complaint this comes from: a late-night group's card read "277 min" — the day's *usage* of those
/// seven apps, drawn in the place a budget goes, on a group that is blocked or off at every moment
/// of the week and can never spend an open. The number was true and answered nothing.
///
/// The same rule `EditorCards.showsSettings` takes the knobs off the editor with, so a group whose
/// settings card is gone cannot still be reporting one on its card.
private func testACoveredWeekReportsItsScheduleAndNoNumbers() {
    // Strict every night, break every day: 168 hours between them, and no budget ever reached.
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)
    let day = window(.break, weekdays: TimeWindow.everyDay, from: 8 * 60, to: 22 * 60)
    let covered = [night, day]
    expect(TimeWindow.coversEveryMinute(of: covered), "the fixture is the week the complaint is about")

    expectEqual(
        GroupSummary.today(
            opensUsed: 0, opensPerDay: nil, usageSeconds: 277 * 60, windows: covered
        ),
        "Nothing held back right now",
        "277 minutes of usage on a group that is never on a budget is not a line about the day"
    )
    expectEqual(
        GroupSummary.today(
            opensUsed: 0, opensPerDay: nil, usageSeconds: 277 * 60, windows: covered,
            blockLine: "Blocked until 08:00"
        ),
        "Blocked until 08:00",
        "and while the strict half of that week is standing, the schedule state is the block"
    )
    expectEqual(
        GroupSummary.today(
            opensUsed: 2, opensPerDay: 5, usageSeconds: 12 * 60, dailyMinutes: 60, windows: covered
        ),
        "Nothing held back right now",
        "budgets it happens to carry say nothing either: no minute of the week reaches them"
    )
    expectEqual(
        GroupSummary.cardStatus(
            todayLine: GroupSummary.today(
                opensUsed: 0, opensPerDay: nil, usageSeconds: 277 * 60, windows: covered
            ),
            apps: 7, sites: 0
        ),
        "Nothing held back right now",
        "which is what the card ends up showing, in place of the number that started this"
    )

    // One minute back and the whole card returns, because the group can reach a budget again in
    // it. The near miss is the test: `EditorCards` puts the knobs back at exactly this point.
    let gapped = [night, window(.break, weekdays: TimeWindow.everyDay, from: 8 * 60, to: 22 * 60 - 1)]
    expect(!TimeWindow.coversEveryMinute(of: gapped), "a week with one free minute is not covered")
    expectEqual(
        GroupSummary.today(
            opensUsed: 0, opensPerDay: nil, usageSeconds: 277 * 60, windows: gapped
        ),
        "277 min",
        "and then the day is worth reporting again, exactly as it always was"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 3, opensPerDay: 5, usageSeconds: 12 * 60),
        "2 of 5 opens left · 12 min",
        "a group with no windows at all is untouched by any of this"
    )
}

/// The same reading, from the other end: a group shut until Monday has no day to report either.
///
/// The stats page reports a *day* rather than a moment, which is why a strict window standing this
/// second leaves the budget alone there — it will be spendable again this evening. A dated block is
/// not about this second: no open can be spent for as long as it stands, so a budget beside it is
/// the "277 min" fault in a different shape.
///
/// A dated block is **not** a window, and this is where that shows: it takes the line without
/// touching `coversEveryMinute`, so the editor's Settings card stays exactly where it was.
private func testADatedBlockReportsItsDayAndNoNumbers() {
    expect(
        !TimeWindow.coversEveryMinute(of: []),
        "a dated block puts no window on the group, so the week is as uncovered as it ever was"
    )
    expectEqual(
        GroupSummary.today(
            opensUsed: 2, opensPerDay: 5, usageSeconds: 12 * 60, datedBlock: true,
            blockLine: "Blocked until Mon 24 Aug"
        ),
        "Blocked until Mon 24 Aug",
        "the day it ends is the whole story while it stands"
    )
    expectEqual(
        GroupSummary.today(
            opensUsed: 2, opensPerDay: 5, usageSeconds: 12 * 60, datedBlock: true
        ),
        "Nothing held back right now",
        "and with the pass lifting it there is no block line to show, which is the honest answer"
    )
    expectEqual(
        GroupSummary.today(opensUsed: 2, opensPerDay: 5, usageSeconds: 12 * 60),
        "3 of 5 opens left · 12 min",
        "the day the block ends, the same group reports its day again"
    )
}

/// The number the two controls above it multiply to, which the user was left to work out.
private func testDailyTotalMultipliesTheTwoBudgets() {
    expectEqual(
        GroupSummary.dailyTotal(opensPerDay: 5, sessionMinutes: 7), "5 opens × 7 min = 35 min a day",
        "opens times session is the day's total"
    )
    expectEqual(
        GroupSummary.dailyTotal(opensPerDay: nil, sessionMinutes: 7), "Unlimited opens · no daily total",
        "an unlimited group has no total to state"
    )
    expectEqual(
        GroupSummary.dailyTotal(opensPerDay: 5, sessionMinutes: nil),
        "5 opens · no relock, so no daily total",
        "and neither has one whose opens never end"
    )
}

/// The daily time limit is the third knob in the same sum, and leaving it out was the one number
/// on the card that could be wrong: five opens of twenty minutes under an hour's limit is an hour.
private func testDailyTotalIsCappedByTheTimeLimit() {
    expectEqual(
        GroupSummary.dailyTotal(opensPerDay: 5, sessionMinutes: 20, dailyMinutes: 60),
        "5 opens × 20 min = 100 min, capped at 60 min a day",
        "the limit is the ceiling the product never reaches"
    )
    // A limit above the product used to be dropped, on the argument that it changed nothing. It
    // counts time in the group whether or not an open is running — a break or an emergency pass
    // spends it without spending an open — so it can be the thing that blocks even here, and the
    // line that adds the day up was leaving it out.
    expectEqual(
        GroupSummary.dailyTotal(opensPerDay: 5, sessionMinutes: 5, dailyMinutes: 60),
        "5 opens × 5 min = 25 min a day, under a 60 min limit",
        "a limit the opens never reach is still a ceiling, on minutes the opens do not count"
    )
    expectEqual(
        GroupSummary.dailyTotal(opensPerDay: 5, sessionMinutes: 12, dailyMinutes: 60),
        "5 opens × 12 min = 60 min, capped at 60 min a day",
        "and a limit exactly at the total is the ceiling, which is what 'capped' says"
    )
    expectEqual(
        GroupSummary.dailyTotal(opensPerDay: nil, sessionMinutes: 7, dailyMinutes: 60),
        "Unlimited opens · 60 min a day",
        "with no opens budget the limit is the only ceiling there is"
    )
    expectEqual(
        GroupSummary.dailyTotal(opensPerDay: 5, sessionMinutes: nil, dailyMinutes: 60),
        "5 opens · no relock · 60 min a day",
        "and it is still the ceiling when the opens never end on their own"
    )
}

/// "Blocked until 11:00" is a fact with no cause attached, and the causes are different things to
/// do about it. Every one of them has to have words.
///
/// **`allCases`, not a list written out here**, which is the whole point of the enum being
/// `CaseIterable`: a reason added later would otherwise slip past this and reach a screen with no
/// clause after the engine's sentence. The dated block was exactly that case.
private func testWhySomethingIsBlockedIsSaidInWords() {
    let reasons = BlockReason.allCases
    for reason in reasons {
        let why = BlockCopy.why(reason)
        expect(!why.isEmpty, "\(reason.rawValue) has words of its own")
        expect(why.first?.isUppercase != true, "\(reason.rawValue) reads on after the engine's sentence")
    }
    expectEqual(Set(reasons.map(BlockCopy.why)).count, reasons.count, "and no two say the same thing")
    expectEqual(BlockCopy.why(.schedule), "time window", "a window is what the user drew")
    expectEqual(
        BlockCopy.why(.datedBlock), "a date you set",
        "and a date is the other thing they set, which is removed rather than redrawn"
    )
    expectEqual(BlockCopy.why(.budgetExhausted), "today's opens are spent", "a budget is what they used up")
}

/// The headline the popover leads with when several groups are blocked at once.
private func testTheHeadlineCountsWhatIsBlocked() {
    expectNil(BlockCopy.blockedNow(0, of: 4), "nothing blocked is not a headline")
    expectEqual(BlockCopy.blockedNow(2, of: 4), "2 of 4 groups blocked right now", "some of them are counted")
    expectEqual(BlockCopy.blockedNow(4, of: 4), "All 4 groups are blocked right now", "all of them says so")
    expectEqual(BlockCopy.blockedNow(1, of: 1), "Blocked right now", "and one group does not need a count at all")
}

/// The one sentence the popover and the settings page's Protection card both lead with.
///
/// It is a precedence, and the order is the whole of it: an app that cannot do its job outranks
/// everything, a lift outranks a block, and a block outranks a count. Two screens wording this
/// for themselves is how one of them ends up claiming protection that is not there.
private func testTheHeadlineRanksTheFactsAgainstEachOther() {
    let noon = Date(timeIntervalSince1970: 1_760_000_000)
    func headline(
        _ status: StatusKind, focus: String? = nil, blocked: Int = 0, groups: Int = 4
    ) -> String {
        BlockCopy.headline(
            status: status, focusSessionLine: focus, blockedGroups: blocked, groups: groups,
            clockText: { _ in "12:25" }
        )
    }

    expectEqual(
        headline(.degraded("Accessibility access is missing"), focus: "Everything is blocked until 12:25", blocked: 4),
        "Accessibility access is missing",
        "an app that cannot see what it is blocking says that before anything else"
    )
    expectEqual(
        headline(.emergencyPass(until: noon)),
        "Emergency pass — nothing is blocked until 12:25",
        "a pass outranks the blocks it is lifting"
    )
    expectEqual(
        headline(.paused(until: noon)), "Nothing is blocked until 12:25",
        "and so does a break"
    )
    // What it does not outrank, and the reason the count is a parameter at all: a group may
    // ignore both doors (`GroupSettings.ignoresAppWideUnblocks`), and a headline saying nothing is
    // blocked while one of them sits blocked underneath is the same lie as a shield over an open
    // group. Said as a count, because the rows below name them one by one.
    expectEqual(
        headline(.emergencyPass(until: noon), blocked: 4),
        "Emergency pass — unblocked until 12:25 · 4 groups still blocked",
        "a group that ignores the pass is not lifted, so the line stops claiming it was"
    )
    expectEqual(
        headline(.paused(until: noon), blocked: 1),
        "Unblocked until 12:25 · 1 group still blocked",
        "and a break says the same about the same groups, in the singular where it is one"
    )
    expectEqual(
        headline(.active(targetCount: 9), focus: "Everything is blocked until 12:25", blocked: 2),
        "Everything is blocked until 12:25",
        "a focus session is the answer, not the two groups it happens to be blocking"
    )
    expectEqual(
        headline(.active(targetCount: 9), blocked: 2), "2 of 4 groups blocked right now",
        "otherwise what is blocked right now"
    )
    expectEqual(
        headline(.active(targetCount: 9), blocked: 0), "Protecting 9 targets",
        "and with nothing blocked, what is being watched"
    )
    expectEqual(
        headline(.active(targetCount: 0), groups: 0), "Nothing is being blocked yet",
        "an empty setup says so rather than claiming to protect nothing"
    )
    // A group whose scope is advanced rules or the adult list has no target to
    // count — `managedTargetCount` counts targets and the domains a category carries, and none of
    // those exist here. Reading that zero as "nothing" told somebody blocking the entire web that
    // nothing was being blocked.
    expectEqual(
        headline(.active(targetCount: 0), groups: 1), "Protecting 1 group",
        "a group with nothing countable in it is still a group that is blocking"
    )
    expectEqual(
        headline(.active(targetCount: 0), groups: 3), "Protecting 3 groups",
        "however many of them there are"
    )
}

// MARK: - When a break actually ends

/// The card read `breakEndsAt` and nothing else, so a fifteen-minute break taken under an
/// emergency pass said "Nothing is blocked until 12:30" while the pass ran to 13:00 — and its
/// "Block again now" then blocked nothing, because ending a break leaves the pass standing.
private func testABreakNamesTheLaterOfTheTwoEnds() {
    let clockText: (Date) -> String = { $0 == noon ? "12:00" : "13:00" }

    let alone = BreakEnd(breakEndsAt: noon, emergencyPassEndsAt: nil)
    expectEqual(alone.endsAt, noon, "with no pass the break's own end is the end")
    expect(!alone.heldByPass, "and nothing else is holding it")
    expectEqual(
        alone.line(clockText: clockText), "Nothing is blocked until 12:00",
        "which is the sentence the headline uses for the same fact"
    )
    expectEqual(alone.buttonTitle, "Block again now", "and the button does what it says")

    // A pass that ends first changes nothing: the break outlives it, and the break's end is
    // still when blocking comes back.
    let outlived = BreakEnd(breakEndsAt: august(10, 13), emergencyPassEndsAt: noon)
    expectEqual(outlived.endsAt, august(10, 13), "the later end wins in both directions")
    expect(!outlived.heldByPass, "a pass that runs out first is not what is holding")
    expectEqual(outlived.buttonTitle, "Block again now", "so the button is honest as it stands")

    // And the card stops saying "nothing" over the groups a break does not reach — the headline's
    // rule, on the card the break was actually started from. See `BlockCopy.stillBlocked`.
    let partial = BreakEnd(breakEndsAt: noon, emergencyPassEndsAt: nil, stillBlocked: 2)
    expectEqual(
        partial.line(clockText: clockText), "Unblocked until 12:00 · 2 groups still blocked",
        "a group that ignores the unblocks is counted rather than quietly claimed as open"
    )
    expectEqual(
        partial.buttonTitle, "Block again now",
        "with the button unchanged: it ends the break, whatever the break failed to reach"
    )
}

/// The pass is the thing being spent. Somebody who believes a quarter of an hour is what is
/// running has no idea they have most of their week's escape still on the table.
private func testABreakOutlastedByAPassSaysWhichIsHolding() {
    let held = BreakEnd(breakEndsAt: noon, emergencyPassEndsAt: august(10, 13))
    expectEqual(held.endsAt, august(10, 13), "the pass's end is the one that counts")
    expect(held.heldByPass, "and it is named as the one holding")
    expectEqual(
        held.line(clockText: { _ in "13:00" }),
        "Nothing is blocked until 13:00 — this week's emergency pass, which outlasts your break.",
        "the later end, and what is buying it"
    )
    expectEqual(
        held.buttonTitle, "End the break",
        "and the button claims only what it can do: the pass stands either way"
    )
}
