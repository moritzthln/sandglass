import SandglassAppCore
import SandglassCore
import Foundation

/// The whole of a time window's life, step by step, because "time windows don't work" turned out
/// to be true and the pieces that broke were each fine on their own.
///
/// Two things had gone wrong and neither is visible from any one file. Picking a preset replaced
/// the group's `timeWindows`, so a window drawn on a group was discarded by the next preset
/// change — and the sidebar's dropdown makes a group *straight into* a preset. And a group inside
/// its own strict window had every setting frozen, the window list included, so the only moment a
/// window could be edited was a moment it did not apply. Both are fixed next door
/// (`ConfigBuilderTests`, `RulesEngineWindowTests`); this file walks the path they sit on.
///
/// The steps, in the order the user meets them:
///
/// 1. the editor's list arithmetic — adding, changing, removing (`TimeWindowList`);
/// 2. the write reaching the running configuration and the disk (`AppState`);
/// 3. surviving a relaunch, keys and all (`Store`);
/// 4. the engine actually blocking on it (checked here as the end of the round trip; the window
///    arithmetic itself is `RulesEngineWindowTests`);
/// 5. the two pictures drawn from the list — the timeline strip and the sidebar's weekday strip.
///
/// Steps 1 and 5 are what the views call rather than the views themselves: `TimeWindowsCard`,
/// `TimelineStripView` and `GroupCard` are SwiftUI and cannot be built here, so the arithmetic
/// under them was moved into `TimeWindowList` and it is that which is pinned. What is left in
/// those three files is layout.
func runTimeWindowPathTests() {
    testTheEditorsListArithmetic()
    testTheGaplessWarningReadsTheResultingList()
    // Every `AppState` is MainActor-isolated, and this executable's main thread is that actor's
    // executor — the same assertion `runAppStateTests` makes, for the same reason.
    MainActor.assumeIsolated {
        testAWindowWrittenFromTheEditorReachesTheEngineAndTheDisk()
        testTwoWindowsSurviveARelaunchWithEveryFieldIntact()
        testAWindowDrawnOnAGroupSurvivesEveryPresetInTheList()
    }
    testTheChipIsReadOffTheValues()
    testTheStripDrawsWhatWasSaved()
    testEachDayIsDrawnFromTheWindowsThatActuallyRunOnIt()
    testANightIsDrawnOnBothOfTheDaysItTouches()
    testTheSidebarStripNamesTheDaysTheWindowsName()
    testTheDominantKindIsMeasuredInMinutes()
    testTheSidebarLineNamesAKindRatherThanCountingRows()
}

/// What a sidebar card is allowed to call a list of windows, when it has one line to do it in.
private func testTheDominantKindIsMeasuredInMinutes() {
    expectNil(TimeWindowList.dominantKind(in: []), "no windows, nothing to be mostly")
    expectNil(
        TimeWindowList.dominantKind(in: [strictWindow(weekdays: [], from: 540, to: 1020)]),
        "and a window naming no day applies at no moment, so neither is it"
    )
    let allWeek = strictWindow(weekdays: TimeWindow.everyDay, from: 0, to: 24 * 60)
    let lunches = TimeWindow.workWeek.map { window(.break, weekdays: [$0], from: 720, to: 780) }
    expectEqual(
        TimeWindowList.dominantKind(in: [allWeek] + lunches), .strictBlock,
        "five short breaks cut out of a seven-day block is still a blocked group"
    )
    expectEqual(
        TimeWindowList.dominantKind(in: lunches + [allWeek]), .strictBlock,
        "whichever order the list happens to be in"
    )
    expectEqual(
        TimeWindowList.dominantKind(in: [
            window(.break, weekdays: TimeWindow.everyDay, from: 0, to: 24 * 60),
            strictWindow(weekdays: [2], from: 540, to: 1020),
        ]),
        .break,
        "and a week that is mostly free is a free group"
    )
    expectEqual(
        TimeWindowList.dominantKind(in: [
            strictWindow(weekdays: [2], from: 540, to: 1020),
            window(.break, weekdays: [3], from: 540, to: 1020),
        ]),
        .strictBlock,
        "an exact tie goes to the block, which is the one being scanned for"
    )
}

/// The sidebar's one line under the group name. "10 PM – 8 AM" said nothing about *what* happens
/// then, and "2 time windows" counted rows in a list the reader cannot see.
private func testTheSidebarLineNamesAKindRatherThanCountingRows() {
    expectNil(TimeWindowCopy.summary([]), "a group with no windows has nothing to say here")
    expectEqual(
        TimeWindowCopy.summary([strictWindow(weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)]),
        "Strict block · 10 PM – 8 AM",
        "one window names its kind, so a nightly block and a nightly break are not the same line"
    )
    expectEqual(
        TimeWindowCopy.summary([window(.break, weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)]),
        "Break · 10 PM – 8 AM",
        "which is the whole point of saying it"
    )
    expectEqual(
        TimeWindowCopy.summary([
            strictWindow(weekdays: TimeWindow.workWeek, from: 9 * 60, to: 17 * 60),
            strictWindow(weekdays: [7, 1], from: 10 * 60, to: 18 * 60),
        ]),
        "Strict block · Every day",
        "several of one kind are that kind, over the days they cover between them"
    )
    expectEqual(
        TimeWindowCopy.summary([
            strictWindow(weekdays: TimeWindow.workWeek, from: 9 * 60, to: 17 * 60),
            window(.break, weekdays: TimeWindow.workWeek, from: 12 * 60, to: 13 * 60),
        ]),
        "Strict block · Weekdays · +1 break",
        "and what is left over is counted rather than dropped"
    )
    expectEqual(
        TimeWindowCopy.summary([strictWindow(weekdays: [], from: 540, to: 1020)]),
        "No days chosen",
        "a window that applies at no moment says so instead of printing hours it never keeps"
    )
}

// MARK: - 1. The editor's list

/// What the card does when the sheet says Done, and when the trash button is pressed.
private func testTheEditorsListArithmetic() {
    let bedtime = strictWindow(weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)
    let lunch = window(.break, weekdays: TimeWindow.workWeek, from: 12 * 60, to: 13 * 60)

    let added = TimeWindowList.merging(bedtime, into: [])
    expectEqual(added, [bedtime], "the first window lands in an empty list")
    let both = TimeWindowList.merging(lunch, into: added)
    expectEqual(both.map(\.id), [bedtime.id, lunch.id], "a second is appended after it")

    var changed = bedtime
    changed.startMinutes = 21 * 60
    let edited = TimeWindowList.merging(changed, into: both)
    expectEqual(
        edited.map(\.id), [bedtime.id, lunch.id],
        "changing one replaces it in place rather than moving it to the end"
    )
    expectEqual(edited.first?.startMinutes, 21 * 60, "with the new value in it")

    expectEqual(
        TimeWindowList.removing(bedtime.id, from: edited), [lunch],
        "and the trash button takes out that window and no other"
    )
    expectEqual(
        TimeWindowList.removing("no-such-window", from: edited), edited,
        "while an id nothing answers to changes nothing"
    )
}

/// The confirmation in front of a week with no free minute in it, asked of the list the change
/// would produce — two windows can add up to a trap neither of them is on its own, and taking one
/// out closes a week as surely as putting one in.
private func testTheGaplessWarningReadsTheResultingList() {
    let mornings = strictWindow(weekdays: TimeWindow.everyDay, from: 0, to: 12 * 60)
    let evenings = strictWindow(weekdays: TimeWindow.everyDay, from: 12 * 60, to: 24 * 60)
    expect(
        !closesTheWeek(saving: mornings, in: []),
        "half of every day is not around the clock"
    )
    expect(
        closesTheWeek(saving: evenings, in: [mornings]),
        "but the other half, added to it, is"
    )
    let lunch = window(.break, weekdays: TimeWindow.everyDay, from: 12 * 60, to: 13 * 60)
    expect(
        !closesTheWeek(saving: evenings, in: [mornings, lunch]),
        "and an hour of break a day is a way back in, so nothing is asked"
    )
    expect(
        !closesTheWeek(saving: lunch, in: [mornings, evenings]),
        "a break carved out of a closed week opens it, so nothing is asked there either"
    )

    // The half that was missing: the same trap, reached with the trash button. The gate used to
    // be "a strict block is being saved", which no deletion ever is.
    let full = [mornings, evenings, lunch]
    expect(
        closesTheWeek(deleting: lunch, in: full),
        "deleting the one break in a seven-day block closes the week and is asked about"
    )
    expect(
        !closesTheWeek(deleting: evenings, in: full),
        "while deleting half the block opens the week and is not"
    )
    // A break edited into a block is the third way in, and it is the save path again — what makes
    // it work is that the question is about the list rather than about the window's own kind.
    var closed = lunch
    closed.kind = .strictBlock
    expect(closesTheWeek(saving: closed, in: full), "and so is turning that break into a block")

    // Already shut: redrawing a window inside a week that had no gap to begin with raises
    // nothing, because the warning is about walking into the state and not about being in it.
    expect(
        !closesTheWeek(saving: mornings, in: [mornings, evenings]),
        "a week that was already gapless asks nothing"
    )
}

private func closesTheWeek(saving window: TimeWindow, in windows: [TimeWindow]) -> Bool {
    TimeWindowList.closesTheWeek(
        TimeWindowList.merging(window, into: windows), replacing: windows
    )
}

private func closesTheWeek(deleting window: TimeWindow, in windows: [TimeWindow]) -> Bool {
    TimeWindowList.closesTheWeek(
        TimeWindowList.removing(window.id, from: windows), replacing: windows
    )
}

// MARK: - 2 and 3. The write, the disk, the relaunch

/// The step the editor's binding does: `settings.timeWindows = …` through
/// `AppState.applyConfigEdit`. What has to be true afterwards is that the engine is deciding on
/// it and that it is on disk — the two halves that make a setting real.
@MainActor
private func testAWindowWrittenFromTheEditorReachesTheEngineAndTheDisk() {
    withTempDir { dir in
        let clock = FakeClock(august(10, 12))            // Monday noon
        let state = makeState(dir, clock: clock)
        var config = webConfig()                          // youtube.com, Standard, no windows
        expectNil(state.applyConfigEdit(config), "a configuration with no window saves")

        // What the sheet produces, written the way the card writes it.
        let drawn = strictWindow(weekdays: TimeWindow.workWeek, from: 9 * 60, to: 17 * 60)
        config = state.config
        config.groupSettings["domain:youtube.com"]?.timeWindows =
            TimeWindowList.merging(drawn, into: [])
        expectNil(state.applyConfigEdit(config), "and so does the window drawn on it")

        expectEqual(
            state.config.settings(forGroup: "domain:youtube.com")?.timeWindows, [drawn],
            "the running configuration carries it"
        )
        expectEqual(
            state.blockDecision(forBundleID: "com.apple.Notes"), .notManaged,
            "nothing unrelated is touched"
        )
        expectEqual(
            state.blockDecision(forURL: "youtube.com"), scheduleDecision(until: "17:00"),
            "and the engine is blocking on it, at noon on a Monday"
        )

        // The disk, read the way the next launch reads it.
        guard let saved = Store(directory: dir).loadConfig() else {
            failTest("config.json could not be read back")
            return
        }
        expectEqual(
            saved.groupSettings["domain:youtube.com"]?.timeWindows, [drawn],
            "and config.json holds it, id and all"
        )
    }
}

/// A relaunch, with two windows on one group — the shape the manual check uses. Every field has
/// to come back: a window whose weekdays or kind were lost would block the wrong hours rather
/// than none, which is the failure nobody notices until it happens.
@MainActor
private func testTwoWindowsSurviveARelaunchWithEveryFieldIntact() {
    withTempDir { dir in
        let clock = FakeClock(august(10, 12))
        let bedtime = strictWindow(weekdays: [2, 4, 6], from: 22 * 60, to: 8 * 60)
        let lunch = window(.break, weekdays: TimeWindow.workWeek, from: 12 * 60, to: 13 * 60)

        var config = webConfig()
        config.groupSettings["domain:youtube.com"]?.timeWindows = [bedtime, lunch]
        let first = makeState(dir, clock: clock)
        expectNil(first.applyConfigEdit(config), "two windows on one group save")
        first.stop()

        let second = makeState(dir, clock: clock)
        guard let back = second.config.settings(forGroup: "domain:youtube.com")?.timeWindows else {
            failTest("the group came back without a window list")
            return
        }
        expectEqual(back.count, 2, "both come back")
        expectEqual(back, [bedtime, lunch], "in order, and equal in every field")
        expectEqual(back.first?.weekdays, [2, 4, 6], "the days a Set was written as a sorted array")
        expectEqual(back.first?.kind, .strictBlock, "the kind")
        expectEqual(back.last?.kind, .break, "including the one that is not a block")

        // And the engine on the new instance decides on them, which is the point of the round
        // trip: noon on a Monday is inside the break, so the group is wide open.
        expectEqual(
            second.blockDecision(forURL: "youtube.com"), .notManaged,
            "a break window that survived the disk is a break window that applies"
        )
        second.stop()
    }
}

/// The bug, end to end and through the disk: draw a window, then set the group to each preset in
/// turn. Before the fix the very first one emptied the list.
@MainActor
private func testAWindowDrawnOnAGroupSurvivesEveryPresetInTheList() {
    withTempDir { dir in
        let clock = FakeClock(august(10, 20))            // Monday evening, outside the window
        let state = makeState(dir, clock: clock)
        let bedtime = strictWindow(weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)
        var config = webConfig()
        config.groupSettings["domain:youtube.com"]?.timeWindows = [bedtime]
        expectNil(state.applyConfigEdit(config), "the window is saved")

        for preset in state.config.presets {
            var picked = state.config
            let current = picked.groupSettings["domain:youtube.com"] ?? .standard
            picked.groupSettings["domain:youtube.com"] =
                ConfigBuilder.settings(forPreset: preset, current: current)
            expectNil(state.applyConfigEdit(picked), "picking \(preset.name) is accepted")
            expectEqual(
                state.config.settings(forGroup: "domain:youtube.com")?.timeWindows, [bedtime],
                "and leaves the window exactly where it was"
            )
        }
        expectEqual(
            ConfigBuilder.presetID(
                matching: state.config.settings(forGroup: "domain:youtube.com") ?? .standard,
                in: state.config.presets
            ),
            state.config.presets.last?.id,
            "the group reads as the preset it was last set to, window and all"
        )
        state.stop()
    }
}

// MARK: - 5. The two pictures

/// Which preset chip is lit, which used to be a field written beside the values and is now read
/// back off them.
///
/// The bug the two halves made together: a new window was built by `make(.custom, …)`, whose
/// fallback is exactly the work-day values — so every window opened on Mon–Fri 9-to-5 with the
/// Custom chip lit and Work day dark, and pressing Work day appeared to do nothing.
private func testTheChipIsReadOffTheValues() {
    for preset in TimeWindow.Preset.allCases {
        expectEqual(
            TimeWindow.make(preset, kind: .strictBlock).livePreset, preset,
            "a window built from \(preset.rawValue) reads as \(preset.rawValue)"
        )
    }
    var workDay = TimeWindow.make(.workDay, kind: .strictBlock)
    workDay.startMinutes = 10 * 60
    expectNil(workDay.livePreset, "one nudged stepper and no chip is lit any more")

    let typedByHand = TimeWindow(
        kind: .break, weekdays: TimeWindow.workWeek, startMinutes: 9 * 60, endMinutes: 17 * 60
    )
    expectEqual(
        typedByHand.livePreset, .workDay,
        "and the work-day hours typed out by hand light Work day, whatever the kind"
    )
}

/// The seven bars under the card, drawn from the same list the engine reads. Fractions of a day,
/// in precedence order, with a window that crosses midnight split over the two days it is on.
private func testTheStripDrawsWhatWasSaved() {
    let bedtime = strictWindow(weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)
    let lunch = window(.break, weekdays: TimeWindow.workWeek, from: 12 * 60, to: 13 * 60)
    let windows = [bedtime, lunch]

    let spans = TimeWindowList.spans(of: bedtime, onWeekday: 3)
    expectEqual(spans.count, 2, "a nightly window puts two pieces on every day it runs")
    expectEqual(spans.first?.start, 22 * 60, "the evening it starts in")
    expectEqual(spans.first?.end, TimeWindow.minutesInDay, "running to midnight")
    expectEqual(spans.last?.start, 0, "and the morning left behind by the night before")
    expectEqual(spans.last?.end, 8 * 60, "running to 08:00")

    let blocks = TimeWindowList.segments(ofKind: .strictBlock, in: windows, onWeekday: 3)
    expectEqual(blocks.count, 2, "both are drawn")
    expectEqual(blocks.first?.width, 2.0 / 24.0, "the evening is two hours of the bar")
    expectEqual(blocks.last?.width, 8.0 / 24.0, "the morning is eight")
    expectEqual(
        TimeWindowList.segments(ofKind: .break, in: windows, onWeekday: 3).count, 1,
        "and the break is drawn on its own pass, so it lands on top where they overlap"
    )
    expect(
        TimeWindowList.segments(ofKind: .break, in: [bedtime], onWeekday: 3).isEmpty,
        "a kind the list does not carry draws nothing"
    )

    // The two shapes the editor can be left in mid-edit, neither of which applies at any moment.
    let noDays = strictWindow(weekdays: [], from: 9 * 60, to: 17 * 60)
    expect(
        (1...7).allSatisfy { TimeWindowList.spans(of: noDays, onWeekday: $0).isEmpty },
        "a window naming no day draws nothing, because it blocks nothing"
    )
    let allDay = TimeWindow.make(.allDay, kind: .strictBlock)
    expectEqual(
        TimeWindowList.segments(ofKind: .strictBlock, in: [allDay], onWeekday: 3).first?.width, 1.0,
        "and an all-day window fills the bar"
    )
}

/// The fault the seven rows exist to fix: one bar for the whole list said a group was blocked on
/// Saturday and free on Tuesday, because it drew every window on every day.
private func testEachDayIsDrawnFromTheWindowsThatActuallyRunOnIt() {
    let office = strictWindow(weekdays: TimeWindow.workWeek, from: 9 * 60, to: 17 * 60)
    let saturday = window(.break, weekdays: [7], from: 10 * 60, to: 18 * 60)
    let windows = [office, saturday]

    expectEqual(
        TimeWindowList.segments(ofKind: .strictBlock, in: windows, onWeekday: 4).count, 1,
        "Wednesday carries the weekday block"
    )
    expect(
        TimeWindowList.segments(ofKind: .break, in: windows, onWeekday: 4).isEmpty,
        "and not Saturday's break"
    )
    expect(
        TimeWindowList.segments(ofKind: .strictBlock, in: windows, onWeekday: 7).isEmpty,
        "Saturday carries no weekday block"
    )
    expectEqual(
        TimeWindowList.segments(ofKind: .break, in: windows, onWeekday: 7).count, 1,
        "only its own break"
    )
}

/// A night belongs to the day it starts on, which is what the editor's weekday ticks mean — so the
/// morning after a Friday night is drawn on Saturday and nowhere else.
private func testANightIsDrawnOnBothOfTheDaysItTouches() {
    let fridayNight = strictWindow(weekdays: [6], from: 22 * 60, to: 8 * 60)

    let friday = TimeWindowList.spans(of: fridayNight, onWeekday: 6)
    expectEqual(friday.count, 1, "Friday gets the evening only")
    expectEqual(friday.first?.start, 22 * 60, "from 22:00")
    expectEqual(friday.first?.end, TimeWindow.minutesInDay, "to midnight")

    let saturday = TimeWindowList.spans(of: fridayNight, onWeekday: 7)
    expectEqual(saturday.count, 1, "Saturday gets the morning it ran into")
    expectEqual(saturday.first?.start, 0, "from midnight")
    expectEqual(saturday.first?.end, 8 * 60, "to 08:00")

    expect(
        TimeWindowList.spans(of: fridayNight, onWeekday: 5).isEmpty,
        "and Thursday, which the window never touches, gets nothing"
    )
}

/// The strip on the sidebar card: the union of every window's days, so one glance says which days
/// this group has an opinion about.
private func testTheSidebarStripNamesTheDaysTheWindowsName() {
    let weeknights = strictWindow(weekdays: [2, 3, 4, 5, 6], from: 22 * 60, to: 8 * 60)
    let weekend = window(.break, weekdays: [7, 1], from: 10 * 60, to: 18 * 60)
    expectEqual(
        TimeWindowList.weekdays(in: [weeknights, weekend]), TimeWindow.everyDay,
        "two windows between them can name the whole week"
    )
    expectEqual(
        TimeWindowList.weekdays(in: [weeknights]), TimeWindow.workWeek,
        "one names its own days and no others"
    )
    expect(TimeWindowList.weekdays(in: []).isEmpty, "and a group with no windows names none")
    expect(
        TimeWindowList.weekdays(in: [strictWindow(weekdays: [], from: 0, to: 60)]).isEmpty,
        "nor does a window that names no day: the strip must not claim a day nothing applies on"
    )

    // What the card writes under the name, from the same list. The wording is checked in full by
    // `testTheSidebarLineNamesAKindRatherThanCountingRows`; what matters here is that the line and
    // the strip are read off one list and cannot disagree about it.
    expectEqual(
        TimeWindowCopy.summary([weeknights]), "Strict block · 10 PM – 8 AM",
        "one window is described in full"
    )
    expectEqual(
        TimeWindowCopy.summary([weeknights, weekend]), "Strict block · Weekdays · +1 break",
        "and several name what they mostly are"
    )
    expectNil(TimeWindowCopy.summary([]), "a group with none has nothing to say")
    expectEqual(
        TimeWindowCopy.schedule(weeknights), "Weekdays · 10 PM – 8 AM",
        "and a row in the list says both halves"
    )
}
