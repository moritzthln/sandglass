import Foundation
import SandglassCore

// The two ways back out: the week's emergency pass, and ending a break before it is over.
//
// Shared fixtures (FakeClock, noon, august, officeHours, makeEngine) live in EngineFixtures.swift.

func runEngineReliefTests() {
    testEmergencyPassLiftsAStrictWindow()
    testEmergencyPassIsOnePerIsoWeek()
    testEmergencyPassLiftsARunningFocusSessionForItsHour()
    testAPassSpentDuringAFocusSessionLiftsTheBlockAndNothingElse()
    testAGroupCanOptOutOfTheEmergencyPass()
    testABreakLeavesAloneTheSameGroupThePassDoes()
    testAFocusSessionOverABreakStillBlocksAnImmuneGroupAsASession()
    testEmergencyPassRunsItsFullHourIntoAWindow()
    testEmergencyPassExpiresAndTheBlocksComeBack()
    testFocusSessionEndsTheEmergencyPassButNotTheWeek()
    testNoBlockFreezesTheSettingsBehindIt()
    testAGaplessWindowIsEditableWithoutSpendingAnything()
    testAFocusSessionStartedDuringAPassBlocksWithoutLocking()
    testEndPauseEarlyGivesTheBlocksBack()
    testEndPauseEarlyWithNoPauseIsANoOp()
}

// MARK: - The emergency pass

/// The point of the whole feature: a strict window cannot be paused or waited out from inside, and
/// this is the one thing that lifts it. Editing is no longer on that list — a window blocks and
/// freezes nothing — but the block itself still needs a door.
private func testEmergencyPassLiftsAStrictWindow() {
    let clock = FakeClock(august(10, 10))   // Monday, inside office hours
    let (engine, target) = makeStrictEngine(clock: clock)
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "the window is blocking")
    expect(engine.emergencyPassAvailable, "and this week's pass is unspent")
    expect(engine.useEmergencyPass(), "spending it is allowed")
    expectEqual(engine.decision(targetID: target.id), .notManaged, "everything is lifted")
    expectEqual(engine.emergencyPassEndsAt, august(10, 11), "for exactly one hour")
    expect(!engine.emergencyPassAvailable, "and the week's pass is spent, while it runs")
}

private func testEmergencyPassIsOnePerIsoWeek() {
    let clock = FakeClock(august(10, 10))
    let (engine, target) = makeStrictEngine(clock: clock)
    expect(engine.useEmergencyPass(), "the first one goes through")
    clock.advance(seconds: 2 * 3600)        // the hour is over, still Monday
    expect(!engine.useEmergencyPass(), "the second is refused")
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "and nothing was lifted")

    clock.now = august(14, 10)              // Friday of the same ISO week
    expect(!engine.emergencyPassAvailable, "still spent on the Friday")
    clock.now = august(17, 10)              // Monday of the next ISO week
    expect(engine.emergencyPassAvailable, "a new week brings a new pass")
    expect(engine.useEmergencyPass(), "which can be spent")
}

/// A focus session cannot be cancelled — that is what makes it worth starting. The pass is the
/// exception, and it **lifts** the session rather than ending it: the hour of relief is the hour of
/// relief, and a four-hour block interrupted by it still has three to run.
private func testEmergencyPassLiftsARunningFocusSessionForItsHour() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    engine.startFocusSession(minutes: 4 * 60)
    expectEqual(engine.decision(targetID: target.id), focusDecision(until: "16:00"), "the session is blocking")
    expect(engine.useEmergencyPass(), "the pass is spent")
    expectEqual(engine.decision(targetID: target.id), .notManaged, "and nothing is blocked")
    expectEqual(engine.focusSessionEndsAt, noon.addingTimeInterval(4 * 3600), "the session is still there")

    clock.advance(seconds: 3600 + 1)
    expectEqual(
        engine.decision(targetID: target.id), focusDecision(until: "16:00"),
        "and it blocks again for what is left of it once the hour is over"
    )
    expect(!engine.emergencyPassAvailable, "the week's pass stays spent")
}

/// What the pass buys during a focus session, and what nobody has to buy any more.
///
/// It used to buy three things: the block lifted, an edit the session had refused went through,
/// and today's counters could be handed back. The last two are free — a focus session blocks apps
/// and websites and holds no setting — so the pass has one job here, and the week's pass is still
/// unspent after both of them.
private func testAPassSpentDuringAFocusSessionLiftsTheBlockAndNothingElse() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    engine.startFocusSession(minutes: 4 * 60)
    var loosened = engine.config
    loosened.groupSettings[target.groupID]?.opensPerDay = 50
    expectEdit(engine, "the edit lands with the session running") { loosened }
    expectResetToday(engine, "and so does an undo of today")
    expectEqual(
        engine.decision(targetID: target.id), focusDecision(until: "16:00"),
        "the session goes on blocking regardless — only the editing was freed"
    )
    expect(engine.emergencyPassAvailable, "with the week's pass untouched, because nothing was bought")

    expect(engine.useEmergencyPass(), "spending it is what lifts the block")
    expectEqual(engine.decision(targetID: target.id), .notManaged, "and it lifts")
    clock.advance(seconds: 3600 + 1)
    expectEqual(
        engine.decision(targetID: target.id), focusDecision(until: "16:00"),
        "for its hour, and then the session has what is left of its four to run"
    )
    expect(!engine.useEmergencyPass(), "and there is no second pass this week")
}

/// The pass is not a pause. A pause taken before a window is clamped to the window's start, and
/// suppressed outright once one is open — both of which would make the pass useless exactly when
/// it is needed, so it is a date of its own and neither rule reaches it.
/// A group that has opted out is left exactly where it was, and every other group still opens.
///
/// The pass is spent either way — that is the half a test has to pin, or somebody would read the
/// feature as "the pass costs nothing if one group refuses it" and spend the week's net for one
/// group's sake without meaning to. What changes is only how far the hour reaches.
///
/// Below the pass, not above it: the immune group goes on being judged by everything the branch
/// used to jump over, which is why the window it is inside still names its own end.
private func testAGroupCanOptOutOfTheEmergencyPass() {
    let clock = FakeClock(august(10, 10))   // Monday, inside office hours
    var immune = standardSettings(windows: [officeHours])
    immune.ignoresAppWideUnblocks = true
    let (engine, youtube, reddit) = makeTwoGroupEngine(
        youtube: immune, reddit: standardSettings(windows: [officeHours]), clock: clock
    )
    expectEqual(
        engine.decision(targetID: youtube.id), scheduleDecision(until: "17:00"),
        "both groups are blocked by the same window"
    )
    expect(engine.useEmergencyPass(), "and the pass is spent")
    expectEqual(
        engine.decision(targetID: reddit.id), .notManaged,
        "the group that never asked to be left alone is lifted, exactly as before"
    )
    expectEqual(
        engine.decision(targetID: youtube.id), scheduleDecision(until: "17:00"),
        "and the one that did is still blocked, by the window that was blocking it"
    )
    expect(!engine.emergencyPassAvailable, "the week's pass is spent all the same")
    expectEqual(engine.emergencyPassEndsAt, august(10, 11), "and runs its whole hour")

    clock.advance(seconds: 3600)
    expectEqual(
        engine.decision(targetID: youtube.id), scheduleDecision(until: "17:00"),
        "when the hour is over nothing about the immune group has moved"
    )
    expectEqual(
        engine.decision(targetID: reddit.id), scheduleDecision(until: "17:00"),
        "and the other one is blocked again"
    )
}

/// The weaker door must not open what the stronger one cannot.
///
/// A break is the any-time version of the pass — no rationing, no confirmation, a wait in front of
/// it and that is all — so a group the week's pass is made to leave alone has to be left alone by
/// this as well. Read the other way round, immunity was worth nothing on any afternoon somebody
/// reached for "Unblock everything" instead of the pass, which is the cheaper of the two by every
/// measure.
///
/// Below the branch, not above it, exactly as under a pass: the immune group goes on being judged
/// by everything the branch used to jump over, which is why the window it is inside still names its
/// own end. The break is granted and runs its full length either way — what changes is only how far
/// it reaches, so nobody is refused a break by a group they were not asking about.
private func testABreakLeavesAloneTheSameGroupThePassDoes() {
    let clock = FakeClock(august(10, 10))   // Monday, inside office hours
    var immune = standardSettings(windows: [officeHours])
    immune.ignoresAppWideUnblocks = true
    let (engine, youtube, reddit) = makeTwoGroupEngine(
        youtube: immune, reddit: standardSettings(windows: [officeHours]), clock: clock
    )
    expectEqual(
        engine.decision(targetID: youtube.id), scheduleDecision(until: "17:00"),
        "both groups are blocked by the same window"
    )
    expect(engine.pauseProtection(minutes: 15), "and the break is granted")
    expectEqual(
        engine.decision(targetID: reddit.id), .notManaged,
        "the group that never asked to be left alone is unblocked, exactly as before"
    )
    expectEqual(
        engine.decision(targetID: youtube.id), scheduleDecision(until: "17:00"),
        "and the one that did is still blocked, by the window that was blocking it"
    )
    expectEqual(
        engine.protectionPausedUntil, august(10, 10, 15),
        "the break runs the length it was asked for all the same"
    )

    clock.advance(seconds: 15 * 60)
    expectEqual(
        engine.decision(targetID: reddit.id), scheduleDecision(until: "17:00"),
        "and when it is over the other group is blocked again"
    )
}

/// The branch that gained the condition sits under the focus session, and it still does.
///
/// Only reachable from a hand-edited state file, like `testFocusSessionOutranksASimultaneousPause`
/// beside it — the engine sets the two exclusively. What it pins is that immunity cannot make a
/// group's answer *weaker* than the group beside it: both read as the session, and neither falls
/// through to the window underneath.
private func testAFocusSessionOverABreakStillBlocksAnImmuneGroupAsASession() {
    let clock = FakeClock(august(10, 10))
    var immune = standardSettings(windows: [officeHours])
    immune.ignoresAppWideUnblocks = true
    let youtube = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let reddit = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
    var doctored = initialState(clock)
    doctored.focusSessionEndsAt = august(10, 10, 25)
    doctored.protectionPausedUntil = august(10, 10, 15)
    let engine = makeEngine(
        targets: [youtube, reddit],
        groupSettings: [
            youtube.groupID: immune, reddit.groupID: standardSettings(windows: [officeHours]),
        ],
        state: doctored,
        clock: clock
    )
    expectEqual(
        engine.decision(targetID: reddit.id), focusDecision(until: "10:25"),
        "the session outranks the break for an ordinary group"
    )
    expectEqual(
        engine.decision(targetID: youtube.id), focusDecision(until: "10:25"),
        "and for an immune one, which is judged by the session rather than by its own window"
    )
}

private func testEmergencyPassRunsItsFullHourIntoAWindow() {
    let clock = FakeClock(august(10, 8, 55))   // five minutes before office hours open
    let (engine, target) = makeStrictEngine(clock: clock)
    expect(engine.useEmergencyPass(), "the pass is spent before the window opens")
    expectEqual(engine.emergencyPassEndsAt, august(10, 9, 55), "and is not clamped to 09:00")
    clock.advance(seconds: 30 * 60)            // 09:25, well inside the window
    expectEqual(engine.decision(targetID: target.id), .notManaged, "the open window does not suppress it")
    expectEqual(engine.emergencyPassEndsAt, august(10, 9, 55), "nor cut it short")
}

private func testEmergencyPassExpiresAndTheBlocksComeBack() {
    let clock = FakeClock(august(10, 10))
    let (engine, target) = makeStrictEngine(clock: clock)
    expect(engine.useEmergencyPass(), "the pass is spent")
    clock.advance(seconds: 3600)
    expectEqual(engine.decision(targetID: target.id), scheduleDecision(until: "17:00"), "the hour is over to the second")
    expectNil(engine.emergencyPassEndsAt, "and nothing is left running")
    expectNil(engine.state.emergencyPassEndsAt, "the finished pass is not carried around in the state")
    expectEqual(engine.state.emergencyPassUsedInWeek, "2026-W33", "but the week it was spent in is remembered")
}

/// The same rule a pause follows: starting a focus session is the newer and stronger wish, so it
/// ends the exemption. The week stays spent — the hour was taken, however little of it was used.
private func testFocusSessionEndsTheEmergencyPassButNotTheWeek() {
    let clock = FakeClock(august(10, 10))
    let (engine, target) = makeStrictEngine(clock: clock)
    expect(engine.useEmergencyPass(), "the pass is spent")
    engine.startFocusSession(minutes: 25)
    expectNil(engine.emergencyPassEndsAt, "the pass is over")
    expectEqual(engine.decision(targetID: target.id), focusDecision(until: "10:25"), "and the focus session blocks")
    expect(!engine.emergencyPassAvailable, "the week's pass is still spent")
}

/// **The pass has no settings left to unlock**, and this is the pair of cases that used to want it.
/// A strict window froze the group it was blocking; "Block everything" froze the configuration
/// whole. Neither does, so both edits land with the week's pass unspent — which is what makes the
/// pass an escape from *blocks* rather than the only way to change a number.
private func testNoBlockFreezesTheSettingsBehindIt() {
    let clock = FakeClock(august(10, 10))   // Monday, inside office hours
    let (engine, target) = makeStrictEngine(clock: clock)
    var loosened = engine.config
    loosened.groupSettings[target.groupID]?.opensPerDay = 50
    expectEdit(engine, "an open window freezes nothing behind it") { loosened }

    engine.startFocusSession(minutes: 240)
    var again = engine.config
    again.groupSettings[target.groupID]?.opensPerDay = 100
    expectEdit(engine, "and neither does “Block everything”") { again }
    expectEqual(
        engine.config.settings(forGroup: youtubeGroup)?.opensPerDay, 100, "the change landed"
    )
    expectEqual(
        engine.decision(targetID: target.id), focusDecision(until: "14:00"),
        "with the session still blocking"
    )
    expect(engine.emergencyPassAvailable, "and the week's pass unspent")
}

/// The reason the rule changed, and what it looks like now. A `.strictBlock` over all seven days
/// never closes, so before this the group's own off switch — and its delete button, and the window
/// itself — could only be reached with the week's pass or by hand-editing config.json. Every
/// migrated V1 config with `alwaysBlock` was here.
private func testAGaplessWindowIsEditableWithoutSpendingAnything() {
    let clock = FakeClock(august(10, 10))
    let allWeek = TimeWindow.make(.allDay, kind: .strictBlock)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [allWeek]), clock: clock)
    expectEqual(engine.decision(targetID: target.id), aroundTheClockDecision, "blocked, all week")

    var switchedOff = engine.config
    switchedOff.groupSettings[target.groupID]?.enabled = false
    expectEdit(engine, "one click switches it off") { switchedOff }
    expectEqual(
        engine.decision(targetID: target.id), .notManaged, "and the block is gone on the spot"
    )
    expect(engine.emergencyPassAvailable, "with the week's pass still unspent")
}

/// The corner that used to be a trap. A focus session and a pass cannot run at once — starting one
/// ends the other — so starting a session during the pass is how to end up blocked with the week's
/// pass already gone. That refroze the configuration whole, and there was nothing left to buy the
/// way out with. It blocks, and it holds nothing.
private func testAFocusSessionStartedDuringAPassBlocksWithoutLocking() {
    let clock = FakeClock(august(10, 10))
    let (engine, target) = makeStrictEngine(clock: clock)
    expect(engine.useEmergencyPass(), "the pass is spent")
    engine.startFocusSession(minutes: 25)
    expectEqual(engine.decision(targetID: target.id), focusDecision(until: "10:25"), "everything is blocked")

    var loosened = engine.config
    loosened.groupSettings[target.groupID]?.opensPerDay = 50
    expectEdit(engine, "and the edit goes through with the pass already spent") { loosened }
    expectEqual(engine.config.settings(forGroup: youtubeGroup)?.opensPerDay, 50, "so it moved")
    expectEqual(
        engine.decision(targetID: target.id), focusDecision(until: "10:25"),
        "with the block untouched by it"
    )
    expect(!engine.emergencyPassAvailable, "and no second pass this week")
}

// MARK: - Ending a break

private func testEndPauseEarlyGivesTheBlocksBack() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    expect(engine.pauseProtection(minutes: 15), "a break is granted")
    expectEqual(engine.decision(targetID: target.id), .notManaged, "and the engine is off")
    engine.endPauseEarly()
    expectNil(engine.protectionPausedUntil, "the break is over")
    expectNil(engine.state.protectionPausedUntil, "and nothing is left in the state")
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "the blocks are back, with the day's budget untouched"
    )
}

private func testEndPauseEarlyWithNoPauseIsANoOp() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    engine.endPauseEarly()
    expectEqual(
        engine.decision(targetID: target.id),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "ending a break nobody took changes nothing"
    )
}
