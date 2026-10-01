import Foundation
import SandglassCore

// The model: a group owns a list of time windows rather than one schedule and a switch.
// What is checked here is the part the user cannot see and would only discover by being
// blocked at the wrong hour — containment across midnight, which weekday a night belongs to,
// and what happens where two windows overlap.
//
// The older strict-window behaviour (a single Mon–Fri 09:00–17:00 block, what a break does to
// one) is still checked next door in RulesEngineScheduleTests; this file is about what only the
// new shape can express. Fixtures live in EngineFixtures.swift.

func runEngineWindowTests() {
    // Containment
    testAWindowThatCrossesMidnightBelongsToTheDayItStartsOn()
    testTheEngineBlocksAcrossMidnightOnTheStartDayOnly()
    testAWindowWithNoDaysMatchesNothing()
    testAnAllDayWindowCoversTheWholeDay()
    testAStartAtMidnightTomorrowIsNotOnOffer()
    // Precedence
    testBreakBeatsStrictBlock()
    testABreakWindowSpendsNothing()
    testABreakWindowDoesNotEnforceTheTimeLimit()
    testAStoredLimitWindowIsDroppedOnLoad()
    testTheLatestEndingOfTwoOpenBlocksIsTheOneNamed()
    // Everything that keys off "inside a strict window"
    testABreakIsGrantedInsideAMidnightCrossingWindow()
    testAWindowlessGroupLocksNothing()
    testTheWindowListItselfStaysEditableInsideABlock()
    testEverythingAboutAGroupInsideAWindowIsEditable()
    testEmptyingACategoryLiftsWhatAGroupHeldThroughIt()
    testTheGlobalSwitchesAreEditableInsideAWindow()
    testAGaplessWeekIsAnOrdinaryGroup()
    // The guard rail in front of the week with no gap in it
    testAGaplessWeekIsRecognised()
    testOneFreeMinuteIsEnoughToNotBeGapless()
    testABreakIsAGapInAnOtherwiseGaplessWeek()
}

// MARK: - Containment

/// The decision this model turns on, and the one that is invisible until it is wrong: a night
/// belongs to the evening it started in. Ticking Monday for a 22:00–08:00 window means Monday
/// night, not Monday morning.
private func testAWindowThatCrossesMidnightBelongsToTheDayItStartsOn() {
    let monday = strictWindow(weekdays: [2], from: 22 * 60, to: 8 * 60)
    expect(monday.crossesMidnight, "an end at or before the start crosses midnight")

    expect(monday.contains(weekday: 2, minutes: 22 * 60), "Monday 22:00 is the first minute")
    expect(monday.contains(weekday: 2, minutes: 23 * 60 + 59), "Monday 23:59 is inside it")
    expect(monday.contains(weekday: 3, minutes: 30), "and so is Tuesday 00:30 — the same night")
    expect(monday.contains(weekday: 3, minutes: 7 * 60 + 59), "right up to Tuesday 07:59")

    expect(!monday.contains(weekday: 3, minutes: 8 * 60), "Tuesday 08:00 is out")
    expect(!monday.contains(weekday: 3, minutes: 22 * 60), "Tuesday night is a night nobody ticked")
    expect(
        !monday.contains(weekday: 2, minutes: 30),
        "and Monday 00:30 belongs to Sunday night, which is not ticked either"
    )

    // The degenerate case a stepper can walk into: equal ends are a full day, not an empty one.
    let round = strictWindow(weekdays: [2], from: 8 * 60, to: 8 * 60)
    expect(round.contains(weekday: 2, minutes: 9 * 60), "an equal start and end is 24 hours long")
    expect(round.contains(weekday: 3, minutes: 7 * 60), "running to the same time the next day")
    expect(!round.contains(weekday: 3, minutes: 9 * 60), "and no further")
}

/// The editor's two time steppers ran the same 0…1440, so Start could be nudged to 24:00. That
/// is not a later start than 23:59 — it is midnight the following day, and every screen wraps it
/// back to "12 AM", so the row named an hour and a day the window did not keep.
private func testAStartAtMidnightTomorrowIsNotOnOffer() {
    expectEqual(
        TimeWindow.startRange.upperBound, TimeWindow.minutesInDay - 1,
        "a start is one of the day's minutes, and 24:00 is not one of them"
    )
    expectEqual(
        TimeWindow.endRange.upperBound, TimeWindow.minutesInDay,
        "an end may be the end of the day — that is what All day means by it"
    )

    // What the offered start used to be able to produce, and why it had to stop being offered.
    let ticked = strictWindow(weekdays: [2], from: TimeWindow.minutesInDay, to: 8 * 60)
    expect(ticked.crossesMidnight, "a window starting at 24:00 crosses midnight by definition")
    expect(
        !ticked.contains(weekday: 2, minutes: 23 * 60 + 59),
        "so no minute of the ticked Monday is in it — the head can never match"
    )
    expect(
        ticked.contains(weekday: 3, minutes: 7 * 60),
        "and ticking Monday blocked Tuesday morning instead"
    )
    // The last start still on offer behaves the way the row reads.
    let last = strictWindow(weekdays: [2], from: TimeWindow.startRange.upperBound, to: 8 * 60)
    expect(last.contains(weekday: 2, minutes: 23 * 60 + 59), "23:59 on Monday is Monday")
}

private func testTheEngineBlocksAcrossMidnightOnTheStartDayOnly() {
    let clock = FakeClock(august(10, 21, 59))   // Monday evening
    let mondayNight = strictWindow(weekdays: [2], from: 22 * 60, to: 8 * 60)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [mondayNight]), clock: clock)
    let free = pauseDecision(countdown: 10, opensLeft: 5, of: 5)

    expectEqual(engine.decision(targetID: target.id), free, "21:59 on Monday is still free")
    clock.now = august(10, 22)
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "08:00"),
        "22:00 is the first blocked minute, and it names tomorrow morning"
    )
    clock.now = august(11, 3)
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "08:00"),
        "03:00 on Tuesday is still Monday night"
    )
    clock.now = august(11, 8)
    expectEqual(engine.decision(targetID: target.id), free, "08:00 on Tuesday is free again")
    clock.now = august(11, 23)
    expectEqual(engine.decision(targetID: target.id), free, "and Tuesday night was never ticked")
}

/// A state the editor can be left in mid-edit. It has to mean "off" rather than "every day".
private func testAWindowWithNoDaysMatchesNothing() {
    let clock = FakeClock(noon)
    let noDays = strictWindow(weekdays: [], from: 0, to: 24 * 60)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [noDays]), clock: clock)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "a window naming no day blocks nothing"
    )
    expect(engine.pauseProtection(minutes: 10), "and refuses no break")
}

private func testAnAllDayWindowCoversTheWholeDay() {
    let allDay = TimeWindow.make(.allDay, kind: .strictBlock)
    expect(allDay.contains(weekday: 1, minutes: 0), "midnight is inside an all-day window")
    expect(allDay.contains(weekday: 4, minutes: 24 * 60 - 1), "and so is the last minute of it")
    expectEqual(allDay.minutesUntilEnd(from: 12 * 60), 12 * 60, "at noon it has twelve hours to run")
}

// MARK: - Precedence

/// break > strictBlock, checked on one group carrying both at once — and the third state, which
/// is no window at all rather than a kind of window.
private func testBreakBeatsStrictBlock() {
    let clock = FakeClock(august(10, 12))
    let settings = standardSettings(windows: [
        strictWindow(weekdays: TimeWindow.workWeek, from: 9 * 60, to: 17 * 60),
        window(.break, weekdays: TimeWindow.workWeek, from: 11 * 60, to: 13 * 60),
    ])
    let (engine, target) = makeEngine(settings: settings, clock: clock)

    expectEqual(
        engine.decision(targetID: target.id), .notManaged,
        "inside both, the break wins and the group is wide open"
    )
    clock.now = august(10, 14)
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "17:00"),
        "with the break over, the strict block applies"
    )
    clock.now = august(10, 18)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and outside every window it is the ordinary pause screen"
    )
}

private func testABreakWindowSpendsNothing() {
    let clock = FakeClock(august(10, 12))
    let free = window(.break, weekdays: TimeWindow.workWeek, from: 11 * 60, to: 13 * 60)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [free]), clock: clock)

    expectEqual(engine.decision(targetID: target.id), .notManaged, "the group is not managed")
    expectEqual(engine.decision(domain: "www.youtube.com"), .notManaged, "in the browser either")
    expectEqual(
        engine.consumeOpen(targetID: target.id), .denied(.notManaged),
        "an open needs no permission, so none is granted"
    )
    expect(engine.state.opensUsed.isEmpty, "nothing is charged for it")
    expect(engine.state.sessions.isEmpty, "and no session is started")
    expect(engine.state.deniedAttempts.isEmpty, "nor is anything held against the streak")

    clock.now = august(10, 13)
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and the day's budget is untouched when the break closes"
    )
}

/// The same treatment the protection pause gets: the seconds are still counted, because the
/// stats are a record of what happened — but nothing is enforced against them while the group
/// is deliberately open.
private func testABreakWindowDoesNotEnforceTheTimeLimit() {
    let clock = FakeClock(august(10, 12))
    var settings = standardSettings(windows: [
        window(.break, weekdays: TimeWindow.workWeek, from: 11 * 60, to: 13 * 60),
    ])
    settings.dailyMinutes = 30
    let (engine, target) = makeEngine(settings: settings, clock: clock)

    engine.recordUsage(groupID: youtubeGroup, seconds: 45 * 60)
    expectEqual(
        engine.statsSnapshot().usageSecondsToday[youtubeGroup], 45 * 60,
        "time spent inside a break is still counted for the stats"
    )
    expectEqual(
        engine.decision(targetID: target.id), .notManaged,
        "but the limit it blew past is not enforced while the break runs"
    )
    clock.now = august(10, 13)
    expectEqual(
        engine.decision(targetID: target.id),
        .blocked(reason: .timeLimit, untilText: "Blocked until 03:00"),
        "and lands the moment it closes"
    )
}

/// The kind that used to be offered first and did nothing, as it arrives from a file that still
/// carries it: the window is dropped and the group keeps everything else.
///
/// Dropping rather than translating is the whole point — `limit` meant "the ordinary budget",
/// which is what a group with no window does, so a group that loses one behaves exactly as it did.
/// The document has to survive it: `Store` treats a decode failure as corruption and renames the
/// file, so one obsolete window must not cost the user every group they have.
private func testAStoredLimitWindowIsDroppedOnLoad() {
    let json = """
    {"pauseSeconds":10,"cooldownMinutes":10,"escalationSeconds":5,"earnBackEnabled":true,\
    "opensPerDay":5,"sessionMinutes":5,"timeWindows":[\
    {"id":"a","kind":"limit","weekdays":[2,3,4,5,6],"startMinutes":540,"endMinutes":1020},\
    {"id":"b","kind":"strictBlock","weekdays":[2],"startMinutes":1320,"endMinutes":480}]}
    """
    guard let settings = try? SandglassJSON.decoder.decode(
        GroupSettings.self, from: Data(json.utf8)
    ) else {
        failTest("a group carrying a limit window no longer decodes at all")
        return
    }
    expectEqual(settings.timeWindows.count, 1, "the limit window is gone")
    expectEqual(settings.timeWindows.first?.id, "b", "and the strict block beside it is not")
    expectEqual(settings.opensPerDay, 5, "the group keeps its budget")
}

/// Two blocks over one group are one block to the person reading the screen, so the end named
/// has to be the one they can actually come back at.
private func testTheLatestEndingOfTwoOpenBlocksIsTheOneNamed() {
    let clock = FakeClock(august(10, 10, 30))
    let settings = standardSettings(windows: [
        strictWindow(weekdays: TimeWindow.workWeek, from: 9 * 60, to: 11 * 60),
        strictWindow(weekdays: TimeWindow.workWeek, from: 10 * 60, to: 17 * 60),
    ])
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "17:00"),
        "the later of the two open blocks is the one named, not the first listed"
    )
    expectEqual(
        engine.strictBlock(forGroup: youtubeGroup)?.end, .at("17:00"),
        "and the same answer is what the menu bar and the quit refusal are given"
    )
    expectEqual(
        engine.strictBlock(forGroup: youtubeGroup)?.minutesLeft, 390,
        "measured forwards from now, which is what makes crossing windows comparable"
    )
}

// MARK: - What keys off a strict window

/// A break asked for inside a window that is on the far side of midnight, which is where the
/// old clamp had its one interesting case and where the new promise has to hold just as plainly.
private func testABreakIsGrantedInsideAMidnightCrossingWindow() {
    let clock = FakeClock(august(10, 20))   // Monday evening, before bedtime
    let (engine, target) = makeEngine(settings: standardSettings(windows: [bedtime]), clock: clock)

    expect(engine.pauseProtection(minutes: 4 * 60), "a break before the window is allowed")
    expectEqual(
        engine.protectionPausedUntil, august(11, 0),
        "and runs its four hours straight through the night's start"
    )

    clock.now = august(10, 23)
    expectEqual(engine.decision(targetID: target.id), .notManaged, "inside the window nothing is managed")
    clock.now = august(11, 0, 1)
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "08:00"),
        "and the night takes over when the break is spent"
    )

    expect(engine.pauseProtection(minutes: 30), "a second break is granted inside the window too")
    expectEqual(engine.protectionPausedUntil, august(11, 0, 31), "at the length asked for")
    clock.now = august(11, 7)
    expect(engine.pauseProtection(minutes: 30), "and after midnight, where the same window still runs")
    expectEqual(engine.protectionPausedUntil, august(11, 7, 30), "at that length as well")
}

private func testAWindowlessGroupLocksNothing() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    expect(engine.config.settings(forGroup: youtubeGroup)?.timeWindows.isEmpty == true, "no windows")

    var loosened = engine.config
    loosened.groupSettings[target.groupID]?.opensPerDay = 50
    expectEdit(engine, "a group with no windows is editable at any hour") { loosened }
    expect(engine.pauseProtection(minutes: 10), "and refuses no break")
    expectNil(engine.strictBlock(forGroup: youtubeGroup), "there being no block to name")
}

/// **A time window blocks apps and websites, and freezes nothing.**
///
/// This used to be the one exception to a freeze — the window list stayed editable while
/// everything else about the group was held — and it is now the whole rule: the commitment moved
/// to the settings lock, app-wide or per group. See `EditDirection` for the lock rule.
///
/// **Deleting the block you are standing in lifts it in the same instant**, which is the promise
/// that has to be checked through the engine rather than reasoned about.
private func testTheWindowListItselfStaysEditableInsideABlock() {
    let clock = FakeClock(august(10, 12))   // Monday noon, inside office hours
    let (engine, target) = makeEngine(settings: standardSettings(windows: [officeHours]), clock: clock)
    expectEqual(
        engine.decision(targetID: target.id), scheduleDecision(until: "17:00"),
        "the group is inside its own strict window"
    )

    var addingOne = engine.config
    addingOne.groupSettings[target.groupID]?.timeWindows.append(
        window(.break, weekdays: TimeWindow.everyDay, from: 20 * 60, to: 22 * 60)
    )
    expectEdit(engine, "a second window can be added from inside the first") { addingOne }

    var removingIt = engine.config
    removingIt.groupSettings[target.groupID]?.timeWindows.removeAll { $0.kind == .strictBlock }
    expectEdit(engine, "and the block you are standing in can be taken out") { removingIt }
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "which lifts it in the same instant"
    )
}

/// The rest of the same rule, and the list is the one the freeze used to hold: a knob either way,
/// the off switch, a target out, the group deleted. Every one of them goes through now.
///
/// **Switching the group off mid-window works**, and that is checked by what the engine answers
/// afterwards rather than by the edit being accepted: a group that is off is `.notManaged`, which
/// is the block gone.
private func testEverythingAboutAGroupInsideAWindowIsEditable() {
    let clock = FakeClock(august(10, 12))
    let (engine, target) = makeEngine(settings: standardSettings(windows: [officeHours]), clock: clock)

    var loosened = engine.config
    loosened.groupSettings[target.groupID]?.opensPerDay = 50
    expectEdit(engine, "a knob can be moved the loose way") { loosened }

    var emptied = engine.config
    emptied.targets.removeAll { $0.groupID == target.groupID }
    expectEdit(engine, "and a target can be taken out") { emptied }

    var switchedOff = engine.config
    switchedOff.groupSettings[target.groupID]?.enabled = false
    expectEdit(engine, "the group can be switched off inside its own block") { switchedOff }
    expectEqual(
        engine.decision(groupID: target.groupID), .notManaged,
        "which lifts the block on the spot, because a group that is off blocks nothing"
    )

    var deleted = engine.config
    deleted.groupSettings[target.groupID] = nil
    deleted.targets.removeAll { $0.groupID == target.groupID }
    expectEdit(engine, "and it can be deleted outright") { deleted }
    expect(engine.config.groupSettings.isEmpty, "which it was")
}

/// The list a group holds through a live category, which the freeze compared contents of. Emptying
/// one lifts every block the group held through it, in the same second — and nothing refuses that
/// any more. What does refuse it is the group's own passcode; see `GroupLockTests`.
private func testEmptyingACategoryLiftsWhatAGroupHeldThroughIt() {
    let clock = FakeClock(august(10, 12))               // Monday noon, inside office hours
    var settings = standardSettings(windows: [officeHours])
    settings.categories = ["video"]
    let engine = makeEngine(targets: [], groupSettings: ["grp:video": settings], clock: clock)
    expectEqual(
        engine.decision(url: "youtube.com"), scheduleDecision(until: "17:00"),
        "the group is inside its window and blocking through the category"
    )

    var emptied = engine.config
    if let index = emptied.categories.firstIndex(where: { $0.id == "video" }) {
        emptied.categories[index].domains = []
        emptied.categories[index].bundleIDs = []
    }
    expectEdit(engine, "the list behind the membership can be emptied") { emptied }
    expectEqual(
        engine.decision(url: "youtube.com"), .notManaged,
        "and what the group held through it is open in the same second"
    )
}

/// The two app-wide switches the freeze held, and the ones it never did. All of them are ordinary
/// settings now: a window blocks, and what may be changed is the settings lock's question.
private func testTheGlobalSwitchesAreEditableInsideAWindow() {
    let clock = FakeClock(august(10, 12))
    let (engine, _) = makeEngine(settings: standardSettings(windows: [officeHours]), clock: clock)

    var loosened = engine.config
    loosened.preventTimeChange = false
    loosened.dayStartMinutes = 5 * 60
    expectEdit(engine, "the clock guard and the day boundary both move") { loosened }
    expect(!engine.config.preventTimeChange, "and they landed")
    expectEqual(engine.config.dayStartMinutes, 5 * 60, "including the day boundary")

    var rest = engine.config
    rest.showsMenuBarCountdown = false
    rest.expiryWarningSeconds = nil
    rest.presets = []
    rest.settingsLock = SettingsLock(timerMinutes: 30)
    expectEdit(engine, "and so does everything that never froze in the first place") { rest }
}

/// What this un-traps, and it is the case the whole decision was taken for. A `.strictBlock` over
/// all seven days never closes, so its group used to be frozen for the life of the app — its own
/// switch and its delete button included — and only the week's emergency pass could reach it.
private func testAGaplessWeekIsAnOrdinaryGroup() {
    let clock = FakeClock(august(10, 12))
    let allWeek = TimeWindow.make(.allDay, kind: .strictBlock)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [allWeek]), clock: clock)
    expectEqual(
        engine.decision(targetID: target.id), aroundTheClockDecision,
        "blocked around the clock, with no minute of the week to wait for"
    )

    var switchedOff = engine.config
    switchedOff.groupSettings[target.groupID]?.enabled = false
    expectEdit(engine, "and one click switches it off") { switchedOff }
    expectEqual(engine.decision(groupID: target.groupID), .notManaged, "which ends the block")

    var deleted = engine.config
    deleted.groupSettings[target.groupID] = nil
    deleted.targets.removeAll { $0.groupID == target.groupID }
    expectEdit(engine, "and it can be deleted like any other group") { deleted }
    expect(engine.config.groupSettings.isEmpty, "which it was")
}

// MARK: - The week with no gap in it

/// What the editor warns about before it saves: a set of blocks that leaves no minute of the
/// week free. Nothing is frozen by it any more — see `testAGaplessWeekIsAnOrdinaryGroup` — but the
/// user is still told, because a week with no gap is a thing to walk into deliberately.
private func testAGaplessWeekIsRecognised() {
    expect(
        TimeWindow.strictBlocksEveryMinute(of: [TimeWindow.make(.allDay, kind: .strictBlock)]),
        "all day, every day, is the shape V1's alwaysBlock migrated into"
    )
    // The union, not one window: neither half covers the week, and together they do.
    let mornings = strictWindow(weekdays: TimeWindow.everyDay, from: 0, to: 12 * 60)
    let evenings = strictWindow(weekdays: TimeWindow.everyDay, from: 12 * 60, to: 24 * 60)
    expect(!TimeWindow.strictBlocksEveryMinute(of: [mornings]), "half a day leaves the other half")
    expect(
        TimeWindow.strictBlocksEveryMinute(of: [mornings, evenings]),
        "two halves add up to the same trap one all-day window is"
    )
    // Crossing midnight is no way around it: nights plus days is still every minute.
    let nights = strictWindow(weekdays: TimeWindow.everyDay, from: 18 * 60, to: 6 * 60)
    let days = strictWindow(weekdays: TimeWindow.everyDay, from: 6 * 60, to: 18 * 60)
    expect(
        TimeWindow.strictBlocksEveryMinute(of: [nights, days]),
        "and so do a window that crosses midnight and the one that fills the daylight"
    )
    expect(
        !TimeWindow.strictBlocksEveryMinute(of: [
            window(.break, weekdays: TimeWindow.everyDay, from: 0, to: 24 * 60),
        ]),
        "a break covers the week without locking anything"
    )
    expect(!TimeWindow.strictBlocksEveryMinute(of: []), "and no windows is not coverage")
}

/// One minute is a real way out — the lock lifts for it, and the settings screen opens. So the
/// warning must not fire, however close the week comes.
private func testOneFreeMinuteIsEnoughToNotBeGapless() {
    let almost = strictWindow(weekdays: TimeWindow.everyDay, from: 0, to: 24 * 60 - 1)
    expect(!TimeWindow.strictBlocksEveryMinute(of: [almost]), "23:59 to 00:00 is a gap")
    let sixDays = strictWindow(weekdays: [2, 3, 4, 5, 6, 7], from: 0, to: 24 * 60)
    expect(!TimeWindow.strictBlocksEveryMinute(of: [sixDays]), "and so is the day nobody ticked")
    let noDays = strictWindow(weekdays: [], from: 0, to: 24 * 60)
    expect(!TimeWindow.strictBlocksEveryMinute(of: [noDays]), "a window naming no day covers nothing")
}

/// Breaks outrank blocks in the engine, so a deliberate hole in the week is a real way back
/// into the settings. The guard rail has to read the list the same way the engine does.
private func testABreakIsAGapInAnOtherwiseGaplessWeek() {
    let allWeek = TimeWindow.make(.allDay, kind: .strictBlock)
    let lunch = window(.break, weekdays: TimeWindow.everyDay, from: 12 * 60, to: 13 * 60)
    expect(
        !TimeWindow.strictBlocksEveryMinute(of: [allWeek, lunch]),
        "an hour of break every day is an hour of unlocked settings every day"
    )
    let mondayLunch = window(.break, weekdays: [2], from: 12 * 60, to: 13 * 60)
    expect(
        !TimeWindow.strictBlocksEveryMinute(of: [allWeek, mondayLunch]),
        "and one hour a week is still a way out"
    )
}

