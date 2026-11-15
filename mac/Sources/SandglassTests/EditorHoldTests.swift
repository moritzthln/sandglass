import SandglassAppCore
import SandglassCore
import Foundation

/// The editor's small decisions that used to live inside views: which remove buttons a wait
/// draws dead, how far a dated block's calendar reaches, how an edited item goes back into its
/// list, and how the week strip writes an hour.
func runEditorHoldTests() {
    testAWaitHoldsOnlyTheRemovesThatLoosen()
    testAWaitHoldsTheTimeWindowsThatLoosen()
    testNoWaitHoldsNothing()
    testTheDateSheetOnlyPushesOutUnderAWait()
    testSavingAnItemTwiceKeepsOneCopy()
    testAnItemDeletedWhileOpenIsNotResurrected()
    testTheAxisFollowsTheLocale()
}

private let today = "2026-08-10"

// MARK: - Dead rather than lying

private func testAWaitHoldsOnlyTheRemovesThatLoosen() {
    var current = webConfig()
    let block = Rule(id: "b", pattern: "shorts", matchType: .websiteOrText, action: .block)
    let allow = Rule(id: "a", pattern: "music.youtube.com", matchType: .websiteOrText, action: .allow)
    current.groupSettings[youtubeGroup]?.rules = [block, allow]

    var noTarget = current
    noTarget.targets.removeAll()
    expect(
        HeldControl.isHeld(tighteningOnly: true, from: current, to: noTarget, onDay: today),
        "taking a site out under a wait is held, so its trash is drawn dead"
    )
    var noBlockRule = current
    noBlockRule.groupSettings[youtubeGroup]?.rules = [allow]
    expect(
        HeldControl.isHeld(tighteningOnly: true, from: current, to: noBlockRule, onDay: today),
        "so is taking a block rule out"
    )
    var noAllowRule = current
    noAllowRule.groupSettings[youtubeGroup]?.rules = [block]
    expect(
        !HeldControl.isHeld(tighteningOnly: true, from: current, to: noAllowRule, onDay: today),
        "but taking an allow rule out blocks more, and stays live"
    )
}

private func testAWaitHoldsTheTimeWindowsThatLoosen() {
    let strict = TimeWindow(
        id: "s", kind: .strictBlock, weekdays: [2], startMinutes: 9 * 60, endMinutes: 17 * 60
    )
    let pause = TimeWindow(
        id: "p", kind: .break, weekdays: [2], startMinutes: 12 * 60, endMinutes: 13 * 60
    )
    var before = GroupSettings.standard
    before.timeWindows = [strict, pause]
    var withoutStrict = before
    withoutStrict.timeWindows = [pause]
    var withoutBreak = before
    withoutBreak.timeWindows = [strict]
    expect(
        HeldControl.isHeld(tighteningOnly: true, from: before, to: withoutStrict, onDay: today),
        "deleting a strict window under a wait is held"
    )
    expect(
        !HeldControl.isHeld(tighteningOnly: true, from: before, to: withoutBreak, onDay: today),
        "deleting a break window is a tightening and stays live"
    )
}

private func testNoWaitHoldsNothing() {
    var noTarget = webConfig()
    noTarget.targets.removeAll()
    expect(
        !HeldControl.isHeld(tighteningOnly: false, from: webConfig(), to: noTarget, onDay: today),
        "with no wait running every remove button is live"
    )
}

private func testTheDateSheetOnlyPushesOutUnderAWait() {
    expectEqual(
        DatedBlockPick.earliest(today: today, standing: nil, tighteningOnly: false), "2026-08-11",
        "a new block can end as early as tomorrow"
    )
    expectEqual(
        DatedBlockPick.earliest(today: today, standing: "2026-08-20", tighteningOnly: false),
        "2026-08-11",
        "with no wait a standing block can be pulled in as well as pushed out"
    )
    expectEqual(
        DatedBlockPick.earliest(today: today, standing: "2026-08-20", tighteningOnly: true),
        "2026-08-21",
        "under a wait the calendar starts after the day standing: pushing out always goes through"
    )
}

// MARK: - Writing an item back

/// The rule sheet stayed open after an add, and the second press of Add — the natural one, with
/// no sign the first had worked — appended the same rule a second time.
private func testSavingAnItemTwiceKeepsOneCopy() {
    let first = Rule(id: "r", pattern: "shorts", matchType: .websiteOrText, action: .block)
    let added = ListUpsert.upserting(first, into: [], appendsWhenMissing: true) ?? []
    let again = ListUpsert.upserting(first, into: added, appendsWhenMissing: true) ?? []
    expectEqual(again.count, 1, "the same rule saved twice is one rule")
    let other = Rule(id: "o", pattern: "reels", matchType: .websiteOrText, action: .block)
    let edited = Rule(id: "r", pattern: "short", matchType: .websiteOrText, action: .block)
    let corrected = ListUpsert.upserting(edited, into: [first, other], appendsWhenMissing: true)
    expectEqual(corrected?.map(\.id), ["r", "o"], "a correction keeps its place in the list")
    expectEqual(corrected?.first?.pattern, "short", "and carries the edit")
}

private func testAnItemDeletedWhileOpenIsNotResurrected() {
    let preset = NamedPreset.builtIns[0]
    expectNil(
        ListUpsert.upserting(preset, into: [], appendsWhenMissing: false),
        "an existing preset deleted elsewhere is not written back"
    )
    expectEqual(
        ListUpsert.deletedWhileOpen("Focus"),
        "“Focus” was deleted while it was open. Nothing was written.",
        "and the card says so rather than reading as saved"
    )
}

// MARK: - The week strip

private func testTheAxisFollowsTheLocale() {
    // Newer systems put a narrow no-break space between the hour and its AM, which is a fact
    // about the font rather than the locale.
    let english = TimelineAxis.labels(locale: Locale(identifier: "en_US"))
        .map { $0.replacingOccurrences(of: "\u{202F}", with: " ") }
    expectEqual(english, ["12 AM", "6 AM", "12 PM", "6 PM", "12 AM"], "a twelve-hour locale")
    let german = TimelineAxis.labels(locale: Locale(identifier: "de_DE"))
    expect(
        !german.contains { $0.contains("AM") || $0.contains("PM") },
        "a twenty-four-hour locale gets no AM or PM: \(german)"
    )
    expectEqual(german.first, german.last, "midnight at both ends")
}
