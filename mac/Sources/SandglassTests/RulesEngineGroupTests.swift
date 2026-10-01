import SandglassAppCore
import SandglassCore
import Foundation

// What the group editor and the general-settings screen made real, driven through the engine
// rather than through a window: where a day starts, a group that is switched off, a group
// blocked around the clock, and a group that asks its own question.
//
// Every one of these is a rule the UI only *shows*. The fixtures are in `EngineFixtures`.

func runEngineGroupTests() {
    testDayStartMovesTheDayBoundary()
    testDayStartIsWhatTheBlockCopySays()
    testTheWeekStartsWhereTheDayDoes()
    testASwitchedOffGroupIsNotManaged()
    testASwitchedOffGroupLocksNothing()
    testSwitchingOffEndsARunningSession()
    testAllDayWindowRefusesEveryOpen()
    testResetTodayClearsTheDayAndNotTheStreak()
    testResetTodayLeavesADayAlreadyBlownBlown()
    testResetTodayIsRefusedByTheSameLocksAnEditIs()
}

// MARK: - Where a day starts

/// The same moment belongs to two different days depending on one setting, which is the whole
/// point of making it one: 04:00 is last night to somebody whose day starts at 05:00.
private func testDayStartMovesTheDayBoundary() {
    let fourAM = august(10, 4)
    expectEqual(
        EngineState.dayKey(for: fourAM, calendar: testCalendar), "2026-08-10",
        "04:00 is already today when the day starts at 03:00"
    )
    expectEqual(
        EngineState.dayKey(for: fourAM, calendar: testCalendar, dayStartMinutes: 5 * 60),
        "2026-08-09",
        "and still yesterday when it starts at 05:00"
    )

    // The engine rolls on its own boundary, not on the default one.
    let clock = FakeClock(fourAM)
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let config = Config(
        version: 1,
        targets: [target],
        groupSettings: [target.groupID: .standard],
        dayStartMinutes: 5 * 60
    )
    let engine = RulesEngine(
        config: config,
        state: .initial(now: fourAM, calendar: testCalendar, dayStartMinutes: 5 * 60),
        clock: clock,
        calendar: testCalendar
    )
    _ = engine.consumeOpen(targetID: target.id)
    expectEqual(opensUsed(engine), 1, "an open spent at 04:00 counts against the night before")
    clock.advance(seconds: 3600)                       // 05:00, the new day
    expectEqual(engine.tick().contains(.dayRolledOver), true, "the day rolls at 05:00")
    expectEqual(opensUsed(engine), 0, "and today starts empty")
}

/// The two blocks that last "until the counters reset" name the configured hour, not 03:00.
private func testDayStartIsWhatTheBlockCopySays() {
    let clock = FakeClock(noon)
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    var settings = GroupSettings.standard
    settings.opensPerDay = 1
    let config = Config(
        version: 1,
        targets: [target],
        groupSettings: [target.groupID: settings],
        dayStartMinutes: 5 * 60
    )
    let engine = RulesEngine(
        config: config, state: .initial(now: noon, calendar: testCalendar, dayStartMinutes: 5 * 60),
        clock: clock, calendar: testCalendar
    )
    _ = engine.consumeOpen(targetID: target.id)
    engine.endSession(targetID: target.id, early: false)
    clock.advance(seconds: TimeInterval(settings.cooldownMinutes * 60 + 1))
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .budgetExhausted, untilText: "Blocked until 05:00"),
        "an exhausted budget promises the hour the day actually resets at"
    )
}

/// A week that started at a different hour from its days would count a different set of
/// moments — see `Store.weekStart`.
private func testTheWeekStartsWhereTheDayDoes() {
    // 2026-08-12 is a Wednesday; its week begins on Monday the 10th.
    let wednesday = august(12, 12)
    expectEqual(
        Store.weekStart(for: wednesday, calendar: testCalendar), august(10, 3),
        "by default the week begins at 03:00 on Monday"
    )
    expectEqual(
        Store.weekStart(for: wednesday, calendar: testCalendar, dayStartMinutes: 5 * 60),
        august(10, 5),
        "and at 05:00 when that is where a day starts"
    )
    expectEqual(
        Store.weekStart(for: august(10, 4), calendar: testCalendar, dayStartMinutes: 5 * 60),
        august(3, 5),
        "so Monday 04:00 still belongs to the week before"
    )
}

// MARK: - A group that is switched off

private func switchedOffEngine(_ clock: FakeClock, windows: [TimeWindow] = [])
    -> (RulesEngine, Target) {
    var settings = GroupSettings.standard
    settings.enabled = false
    settings.timeWindows = windows
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let engine = makeEngine(
        targets: [target], groupSettings: [target.groupID: settings], clock: clock
    )
    return (engine, target)
}

/// Off means the engine cannot see it: no pause screen, no budget, no counted seconds. The
/// settings are still there, which is what tells it apart from a deleted group.
private func testASwitchedOffGroupIsNotManaged() {
    let clock = FakeClock(noon)
    let (engine, target) = switchedOffEngine(clock)

    expectEqual(engine.decision(targetID: target.id), .notManaged, "a group that is off blocks nothing")
    expectEqual(engine.decision(domain: "www.youtube.com"), .notManaged, "on the web side too")
    expectEqual(
        engine.consumeOpen(targetID: target.id), .denied(.notManaged),
        "and there is no budget to spend from"
    )
    expectNil(engine.budgetLine(forGroup: target.groupID), "so there is no budget line to show")

    engine.recordUsage(groupID: target.groupID, seconds: 60)
    expectEqual(
        engine.state.usageSecondsToday[target.groupID] ?? 0, 0,
        "and a minute spent in it is not charged to a group that is doing nothing"
    )

    // Back on, and it is the same group it was — settings and all.
    var back = engine.config
    back.groupSettings[target.groupID]?.enabled = true
    expectEdit(engine, "switching a group back on is an ordinary edit") { back }
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and it protects again from the moment it is on"
    )
}

/// The trap this avoids: a group nobody uses, switched off, with a weekday schedule on it would
/// otherwise freeze the settings screen every morning and refuse every break.
private func testASwitchedOffGroupLocksNothing() {
    let clock = FakeClock(noon)                             // inside office hours on a Monday
    let (engine, target) = switchedOffEngine(clock, windows: [officeHours])

    expectEqual(engine.decision(targetID: target.id), .notManaged, "its window does not block")
    expect(engine.pauseProtection(minutes: 10), "and does not refuse a break")

    var edited = engine.config
    edited.groupSettings[target.groupID]?.pauseSeconds = 45
    expectEdit(engine, "nor does it freeze the settings behind it") { edited }
}

/// Switching a group off while it is open ends the session: the group is off as of now, and a
/// countdown for something that is no longer blocking anything is a lie.
private func testSwitchingOffEndsARunningSession() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    expect(engine.state.sessions[target.groupID] != nil, "a session is running")
    var off = engine.config
    off.groupSettings[target.groupID]?.enabled = false
    engine.updateConfig(off)
    expectNil(engine.state.sessions[target.groupID], "switching the group off ends it")
    expectEqual(opensUsed(engine, target.groupID), 1, "while today's spent open stays spent")
}

// MARK: - An all-day window

/// The retired always-block flag, said honestly: a `.strictBlock` window over all seven days. It is one
/// window rather than a mode, which is why `BlockReason.alwaysBlock` is gone — but it is also the
/// one block with no end, and it says so rather than naming the midnight it crosses every night
/// without lifting. See `BlockEnd`.
private func testAllDayWindowRefusesEveryOpen() {
    let clock = FakeClock(noon)
    let allDay = window(.strictBlock, weekdays: TimeWindow.everyDay, from: 0, to: 24 * 60)
    let settings = standardSettings(windows: [allDay])
    let (engine, target) = makeEngine(settings: settings, clock: clock)

    expectEqual(
        engine.decision(targetID: target.id),
        aroundTheClockDecision,
        "an all-day window blocks, and names no midnight it does not stop at"
    )
    expectEqual(
        engine.consumeOpen(targetID: target.id),
        .denied(aroundTheClockDecision),
        "and pushing through it is refused"
    )
    expectEqual(opensUsed(engine), 0, "with nothing spent")

    // It blocks and it freezes nothing: a break can be taken inside it, and every setting the
    // group has stays editable. That is the whole model now — a window decides what may be
    // opened, and the settings lock decides what may be changed. See
    // `RulesEngineWindowTests.testEverythingAboutAGroupInsideAWindowIsEditable`.
    expect(engine.pauseProtection(minutes: 5), "a break can be taken inside it")
    engine.endPauseEarly()
    var loosened = engine.config
    loosened.groupSettings[target.groupID]?.opensPerDay = 50
    expectEdit(engine, "and its knobs are editable behind it") { loosened }
    expect(engine.useEmergencyPass(), "the emergency pass lifts the block itself")
    expectEqual(engine.decision(targetID: target.id), .notManaged, "for its hour")
}

// MARK: - Starting the day over

/// What the Advanced card's reset button does, and — just as much the point — what it does not.
private func testResetTodayClearsTheDayAndNotTheStreak() {
    let clock = FakeClock(noon)
    var seeded = initialState(clock)
    seeded.streakDays = 6
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let engine = makeEngine(
        targets: [target], groupSettings: [target.groupID: .standard], state: seeded, clock: clock
    )
    _ = engine.consumeOpen(targetID: target.id)
    engine.recordUsage(groupID: target.groupID, seconds: 300)
    engine.endSession(targetID: target.id, early: false)
    engine.recordDismissal(targetID: target.id)
    expect(engine.state.cooldownUntil[target.groupID] != nil, "a cooldown is running")

    expectResetToday(engine, "nothing is blocking, so the reset goes through")

    expectEqual(opensUsed(engine), 0, "today's opens are back to zero")
    expectEqual(engine.state.usageSecondsToday[target.groupID] ?? 0, 0, "and today's minutes")
    expectEqual(engine.state.opensAvoided, 0, "and the pause screens turned away from")
    expectNil(
        engine.state.cooldownUntil[target.groupID],
        "the cooldown goes with them: a wait bought by an open that no longer counts is a wait for nothing"
    )
    expectEqual(engine.state.streakDays, 6, "the streak is a record of days that happened, and stays")
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and the group is back to a full day"
    )
}

/// The reset hands back a budget; it does not rewrite the day that spent it.
///
/// It used to clear `deniedAttempts` along with everything else, which is the one counter the
/// streak is scored on — so a day already over budget was scored at 03:00 as a neutral one and
/// cost the week's freeze nothing. Somebody could blow a day, press Reset, and keep a streak they
/// had not kept.
private func testResetTodayLeavesADayAlreadyBlownBlown() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    for _ in 0..<5 { spendOneOpen(engine, target.id, clock) }
    _ = engine.consumeOpen(targetID: target.id)          // one knock too many: the day is blown
    expectEqual(engine.state.deniedAttempts[target.groupID], 1, "the day is on the record as blown")

    expectResetToday(engine, "the reset goes through")
    expectEqual(opensUsed(engine), 0, "the budget is handed back")
    expectEqual(
        engine.state.deniedAttempts[target.groupID], 1,
        "but the knocking is not un-knocked — the streak's one input is left alone"
    )

    clock.now = august(11, 3, 1)
    _ = engine.tick()
    expectEqual(engine.state.streakDays, 0, "so the day scores as blown")
    expectEqual(
        engine.statsSnapshot().freezesLeft, 0,
        "and costs the week's freeze, exactly as it would have without the reset"
    )
}

/// The undo the one remaining lock exists to refuse, reachable from the screen next door: handing
/// back a spent budget while everything is blocked defeats that block as thoroughly as raising the
/// budget would, and this call used to go straight through while `updateConfig` was refusing.
///
/// A strict window used to refuse it as well and no longer does — a window blocks, and what may be
/// changed is the settings lock's question.
private func testResetTodayIsRefusedByTheSameLocksAnEditIs() {
    let clock = FakeClock(august(10, 8))                 // Monday, before office hours open
    let (engine, target) = makeEngine(
        settings: standardSettings(windows: [officeHours]), clock: clock
    )
    _ = engine.consumeOpen(targetID: target.id)
    expectEqual(opensUsed(engine), 1, "an open is spent before the window opens")

    clock.now = august(10, 12)                           // and now we are inside it
    expectResetToday(engine, "the reset goes through inside the window")
    expectEqual(opensUsed(engine), 0, "and today is back to a full budget")

    // The last lock that used to remain, on a group with no window at all. It is gone too: a
    // focus session blocks everything and holds no setting, this one included.
    let evening = FakeClock(august(10, 20))
    let (windowless, site) = makeEngine(clock: evening)
    _ = windowless.consumeOpen(targetID: site.id)
    windowless.startFocusSession(minutes: 30)
    expectResetToday(windowless, "a focus session does not refuse it either")
    expectEqual(opensUsed(windowless), 0, "so the open is handed back there too")
    expectEqual(
        windowless.decision(targetID: site.id), focusDecision(until: "20:30"),
        "and the session goes on blocking the group it was just handed back to"
    )
}
