import SandglassAppCore
import SandglassCore
import Foundation

/// When a block ends — and the one case where it does not, which every screen in the app used to
/// get wrong.
///
/// A group blocked around the clock is one strict window over all seven days, 00:00 to 00:00. It
/// covers all 10,080 minutes of the week and never lifts, but `endMinutes` is still a number, so
/// the sidebar card, the pause screen, the block page, the menu bar's quit refusal, the group
/// editor's pill and three settings rows all read it and said "Blocked until 00:00" — at noon,
/// about a block that has never once cleared at midnight.
///
/// The rule is `TimeWindow.strictBlocksEveryMinute`, which the group editor already used to dim the
/// knobs such a group can never reach; `BlockEnd` is what carries its answer out to the words. What
/// matters most here is the near misses, because a rule that over-claims is worse than the defect:
/// a window that really ends at midnight keeps its 00:00, and a week tiled by a block and a break
/// keeps the hour the block hands over at.
func runBlockEndTests() {
    MainActor.assumeIsolated {
        testAnOrdinaryWindowNamesTheHourItEndsAt()
        testAWindowEndingAtMidnightForRealKeepsIt()
        testARoundTheClockWindowNamesNoHour()
        testTwoBlocksThatTileTheWeekNameNoHourEither()
        testABlockAndABreakThatTileTheWeekKeepTheirHour()
        testAGroupWithNoWindowsHasNoBlockToName()
            testEverySentenceAboutTheEndlessBlockSaysSo()
    }
}

// MARK: - The two ordinary cases, which must not move

private func testAnOrdinaryWindowNamesTheHourItEndsAt() {
    let clock = FakeClock(august(10, 12))
    let (engine, target) = makeEngine(settings: standardSettings(windows: [officeHours]), clock: clock)
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "17:00"),
        "a window with the evening free ends at 17:00 and says so"
    )
    expectEqual(
        engine.strictBlock(forGroup: youtubeGroup)?.end, .at("17:00"),
        "and the settings rows and the quit refusal are handed the same hour"
    )
}

/// The near miss that decides whether the rule is about the *hour* or about the *week*: 23:00 to
/// midnight prints exactly the "00:00" the defect printed, and it is true — the block lifts, the
/// group opens, and an hour later it is blocked again by tomorrow's copy of the same window.
private func testAWindowEndingAtMidnightForRealKeepsIt() {
    let clock = FakeClock(august(10, 23, 30))
    let lateHour = strictWindow(weekdays: TimeWindow.everyDay, from: 23 * 60, to: 24 * 60)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [lateHour]), clock: clock)
    expect(
        !TimeWindow.strictBlocksEveryMinute(of: [lateHour]),
        "one hour a night leaves twenty-three of them"
    )
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "00:00"),
        "so midnight is an hour this block really does end at"
    )
    clock.now = august(11, 0)
    var stillBlocked = false
    if case .blocked = engine.decision(targetID: target.id) { stillBlocked = true }
    expect(!stillBlocked, "and it lifts there, which is the whole difference from the window below")
}

// MARK: - The case that has no hour

/// The configuration this was found in, at the hour it reads worst: midday, under a promise that
/// this clears at midnight.
private func testARoundTheClockWindowNamesNoHour() {
    let clock = FakeClock(august(10, 12))
    let always = TimeWindow.make(.allDay, kind: .strictBlock)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [always]), clock: clock)
    expectEqual(
        engine.decision(targetID: target.id),
        aroundTheClockDecision,
        "a week with no gap in it has no end to name"
    )
    expectEqual(
        engine.strictBlock(forGroup: youtubeGroup)?.end, .never,
        "and the refusals are told so rather than handed the window's edge"
    )
    // Every hour of it, because the defect was an hour-shaped one: midnight is the minute the old
    // sentence pointed at, and it is the minute this window is least over.
    for hour in [0, 6, 18, 23] {
        clock.now = august(11, hour)
        expectEqual(
            engine.strictBlock(forGroup: youtubeGroup)?.end, .never,
            "still no end at \(hour):00"
        )
    }
}

/// The union, not one window: two half-days that meet leave the week exactly as shut as one all-day
/// window does, and either half on its own names an hour that the other half swallows.
private func testTwoBlocksThatTileTheWeekNameNoHourEither() {
    let clock = FakeClock(august(10, 9))
    let mornings = strictWindow(weekdays: TimeWindow.everyDay, from: 0, to: 12 * 60)
    let evenings = strictWindow(weekdays: TimeWindow.everyDay, from: 12 * 60, to: 24 * 60)
    let (engine, target) = makeEngine(
        settings: standardSettings(windows: [mornings, evenings]), clock: clock
    )
    expectEqual(
        engine.decision(targetID: target.id),
        aroundTheClockDecision,
        "12:00 is where one block hands over to the next, not where the blocking stops"
    )
    clock.now = august(10, 12)
    expectEqual(
        engine.decision(targetID: target.id),
        aroundTheClockDecision,
        "and the handover minute reads the same as every other one"
    )
}

/// The other tiling, and the one that must keep its hour: a strict block and a break that meet
/// exactly. This is a night-time group — blocked 00:30 to 08:00, deliberately free the
/// rest of the day — and 08:00 is a real end, because a break is full access with nothing held
/// back. What such a week never reaches is the group's own budget, which `coversEveryMinute` is
/// the question for and which is a different sentence on a different screen.
private func testABlockAndABreakThatTileTheWeekKeepTheirHour() {
    let clock = FakeClock(august(10, 2))
    let night = strictWindow(weekdays: TimeWindow.everyDay, from: 30, to: 8 * 60)
    let rest = window(.break, weekdays: TimeWindow.everyDay, from: 8 * 60, to: 30)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [night, rest]), clock: clock)
    expect(
        TimeWindow.coversEveryMinute(of: [night, rest]),
        "the two of them leave no minute of the week uncovered"
    )
    expect(
        !TimeWindow.strictBlocksEveryMinute(of: [night, rest]),
        "and yet there is a way out of the block every single day"
    )
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "08:00"),
        "so the hour it hands over at is an hour worth naming"
    )
    clock.now = august(10, 9)
    expectEqual(engine.decision(targetID: target.id), .notManaged, "and the break is where it lands")
}

private func testAGroupWithNoWindowsHasNoBlockToName() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    expectNil(engine.strictBlock(forGroup: youtubeGroup), "no windows, no block, nothing to name")
    expect(
        !TimeWindow.strictBlocksEveryMinute(of: []),
        "and an empty list must never read as a week with no gap in it"
    )
}

// MARK: - What the app says with both kinds of block standing
/// The places a block with no end is printed, in the one value they are all drawn from: the
/// group's own line, which the sidebar card, the pause screen, the block page and the editor's
/// pill print verbatim.
///
/// There were six. The menu bar's refusal to quit was one, and it is what this whole group of
/// tests was written against: a block with no end made quitting permanently impossible. The
/// refusal an edit met inside a window was another, and it is gone too — a window blocks and
/// freezes nothing, so no edit meets a sentence about one.
@MainActor
private func testEverySentenceAboutTheEndlessBlockSaysSo() {
    withTempDir { dir in
        let target = Target(kind: .domain, value: "example.com", displayName: "Adult")
        try? Store(directory: dir).saveConfig(Config(
            version: 1,
            targets: [target],
            groupSettings: [target.groupID: standardSettings(
                windows: [TimeWindow.make(.allDay, kind: .strictBlock)]
            )]
        ))
        let state = makeState(dir, clock: FakeClock(august(10, 12)))
        state.prime()

        expectEqual(
            state.budgetsByGroup.first?.line, "Blocked around the clock",
            "the card, the screen, the page and the pill all read this one line"
        )
        var loosened = state.config
        loosened.groupSettings[target.groupID] = .gentle
        expectNil(
            state.applyConfigEdit(loosened),
            "and an edit meets no sentence at all, because the block freezes nothing"
        )
        expectNil(
            state.resetTodaysCounters(), "with the three app-wide undos held by nothing either"
        )
        expectEqual(
            PauseScreenModel.for(
                decision: aroundTheClockDecision,
                info: TargetDisplayInfo(targetID: target.id, name: "Adult")
            )?.mode,
            .blocked(untilText: "Blocked around the clock"),
            "the pause screen and the block page carry the engine's sentence verbatim"
        )
    }
}
