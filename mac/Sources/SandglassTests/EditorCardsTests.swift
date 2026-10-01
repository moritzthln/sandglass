import SandglassAppCore
import SandglassCore
import Foundation

/// Which of the group editor's two shared cards are on the page at all.
///
/// One of them can be absent, and its absence is the sentence: a week whose windows leave no
/// minute over runs on nothing the Settings card holds, so the card goes — title, knobs and all.
/// It used to stay and dim itself under a line explaining that none of it was ever reached, which
/// is a card whose whole content is an apology for being there.
///
/// Checked here rather than by opening the window for the reason `EditorFreeze` and `EditorState`
/// are: it is a rule, and a rule written inside a `View` is one no test can read. What makes it
/// worth a type of its own rather than a `TimeWindow.coversEveryMinute` call at the call site is
/// the second caller — the preset editor shows these same cards over a draft, and a preset's week
/// only counts under one of its three answers.
func runEditorCardsTests() {
    testAnOrdinaryWeekKeepsTheSettingsCard()
    testAWeekWithNoGapTakesTheSettingsCardAway()
    testAWeekOfBreaksOnlyTakesItAwayTheSameWay()
    testOneMinuteOfGapIsEnoughToBringItBack()
    testAPresetsWeekOnlyCountsUnderUseTheseWindows()
}

/// The normal case, and the one nearly every group is in: no window at all, or one that leaves
/// the rest of the week to the group's own budget.
private func testAnOrdinaryWeekKeepsTheSettingsCard() {
    expect(
        EditorCards.showsSettings(windows: [], presetRule: nil),
        "a group with no windows runs on its knobs all week, so the card is the whole story"
    )
    expect(
        EditorCards.showsSettings(
            windows: [strictWindow(weekdays: TimeWindow.everyDay, from: 23 * 60, to: 7 * 60)],
            presetRule: nil
        ),
        "and a bedtime block leaves sixteen hours the knobs decide"
    )
}

/// A group blocked around the clock: one strict window over all 24 hours of all seven days. There is
/// no hour in which a pause countdown could run or an open could be spent, and the editor says so
/// by not drawing the card that holds them.
private func testAWeekWithNoGapTakesTheSettingsCardAway() {
    expect(
        !EditorCards.showsSettings(
            windows: [TimeWindow.make(.allDay, kind: .strictBlock)], presetRule: nil
        ),
        "blocked around the clock: there is nothing to set, and no card claiming otherwise"
    )
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 30, to: 8 * 60)
    let day = window(.break, weekdays: TimeWindow.everyDay, from: 8 * 60, to: 30)
    expect(
        !EditorCards.showsSettings(windows: [night, day], presetRule: nil),
        "and so does a pair that between them leaves no third state"
    )
}

/// The other end of the same rule, and the one that reads as a surprise until it is said out
/// loud: a group left fully open all week reaches its budget exactly as often as one blocked all
/// week — never. Fully blocked or fully free, the card has nothing to say either way.
private func testAWeekOfBreaksOnlyTakesItAwayTheSameWay() {
    expect(
        !EditorCards.showsSettings(
            windows: [window(.break, weekdays: TimeWindow.everyDay, from: 0, to: 24 * 60)],
            presetRule: nil
        ),
        "a group that is off all week has no knobs to arrange either"
    )
}

/// What brings the card back, and the reason it has to be read off the list rather than
/// remembered: taking a window out, or shortening one, is the whole of the way back — so the
/// answer has to change in the same breath the list does.
private func testOneMinuteOfGapIsEnoughToBringItBack() {
    let allDay = TimeWindow.make(.allDay, kind: .strictBlock)
    expect(!EditorCards.showsSettings(windows: [allDay], presetRule: nil), "covered, so no card")
    var cut = allDay
    cut.endMinutes = 24 * 60 - 1
    expect(
        EditorCards.showsSettings(windows: [cut], presetRule: nil),
        "one minute of gap is a real minute, and the card is back with it"
    )
    expect(
        EditorCards.showsSettings(windows: [], presetRule: nil),
        "and deleting the window outright is the same answer by the same route"
    )
}

/// The preset editor shows these cards over a draft, and a preset's drawn week is a working list
/// under all three answers — it is only handed to a group under one of them. Dimming, and now
/// hiding, a preset's knobs over a week no group will ever be given would take the seven settings
/// the preset actually carries off the screen.
private func testAPresetsWeekOnlyCountsUnderUseTheseWindows() {
    let covered = [TimeWindow.make(.allDay, kind: .strictBlock)]
    expect(
        EditorCards.showsSettings(windows: covered, presetRule: .leaveAlone),
        "a preset that says nothing about the week hands out seven settings, and shows them"
    )
    expect(
        EditorCards.showsSettings(windows: covered, presetRule: .clear),
        "and one that clears a group's windows hands out a week of gap, so all the more"
    )
    expect(
        !EditorCards.showsSettings(windows: covered, presetRule: .use),
        "under use these windows the drawn week is what a group gets, and covers it"
    )
    expect(
        EditorCards.showsSettings(
            windows: [strictWindow(weekdays: TimeWindow.workWeek, from: 30, to: 8 * 60)],
            presetRule: .use
        ),
        "the same answer over a week with a gap in it keeps the card"
    )
}
