import SandglassAppCore
import SandglassCore
import Foundation

/// The three app-wide undos — resetting today's counters, the start of the day and the clock
/// guard's off switch — and the one thing that is allowed to hold them.
///
/// **Every block used to hold all three, and none does.** A strict window did, for a week with no
/// gap in it — a group blocked around the clock — which held them for the rest of
/// the app's life; then "Block everything" did, for as long as it ran. Both of those *block apps
/// and websites*, and under the lock rule that is all they do: every setting is always editable
/// unless a lock or a passcode is set. See `EditDirection`.
///
/// So this file is the record of the freedom rather than of the refusal, and the last check is the
/// half that has to survive it: the settings lock still holds all three, focus session or no
/// focus session. The two are independent, and the lock is the one that stays.
@MainActor
func runUndoLockTests() {
    testAnOrdinaryEveningHoldsNothing()
    testARoundTheClockWindowHoldsNothingAtAll()
    testAFocusSessionHoldsNoneOfThemEither()
    testTheAppLetsAllThreeThroughDuringAFocusSession()
    testTheSettingsLockStillHoldsThemDuringAFocusSession()
}

// MARK: - The rule

private func testAnOrdinaryEveningHoldsNothing() {
    let clock = FakeClock(august(10, 18))
    let (engine, _) = makeEngine(settings: standardSettings(windows: [officeHours]), clock: clock)
    expectResetToday(engine, "the office-hours window closed at 17:00, and nothing is standing")
}

/// The configuration this whole file was written for, answering the other way round now: a group
/// blocked every minute of the week holds none of the three, because a window blocks and freezes
/// nothing.
private func testARoundTheClockWindowHoldsNothingAtAll() {
    let clock = FakeClock(august(10, 14))
    let always = TimeWindow.make(.allDay, kind: .strictBlock)
    let (engine, target) = makeEngine(settings: standardSettings(windows: [always]), clock: clock)
    for hour in [0, 6, 12, 18, 23] {
        clock.now = august(11, hour)
        expectResetToday(engine, "today's counters can be handed back at \(hour):00")
    }
    expectEqual(
        engine.decision(targetID: target.id), aroundTheClockDecision,
        "with the group still blocked every minute of the week"
    )

    // And the two app-wide settings the same window used to freeze. Both directions, and the
    // clock guard's off switch, which was the one thing it refused and nothing else.
    var moved = engine.config
    moved.dayStartMinutes = engine.config.dayStartMinutes + 60
    expectEdit(engine, "the start of the day moves later") { moved }
    moved.dayStartMinutes = engine.config.dayStartMinutes - 60
    expectEdit(engine, "and earlier") { moved }
    var unguarded = engine.config
    unguarded.preventTimeChange = false
    expectEdit(engine, "and the clock guard can be switched off") { unguarded }
}

/// The holder that remained, until it did not. "Block everything" goes on blocking everything
/// through all three of these — only the editing was freed.
private func testAFocusSessionHoldsNoneOfThemEither() {
    let clock = FakeClock(august(10, 14))
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    engine.startFocusSession(minutes: 30)
    expectResetToday(engine, "the reset goes through with everything blocked")
    var moved = engine.config
    moved.dayStartMinutes = engine.config.dayStartMinutes + 60
    expectEdit(engine, "the start of the day moves with it") { moved }
    var unguarded = engine.config
    unguarded.preventTimeChange = false
    expectEdit(engine, "and so does the clock guard's off switch") { unguarded }
    expectEqual(
        engine.decision(targetID: target.id), focusDecision(until: "14:30"),
        "and after all three, everything is still blocked"
    )
}

// MARK: - What the screen shows

/// The three controls at the layer the user meets them. They were drawn dead with a caption under
/// them saying what was holding them; nothing holds them, so there is no caption to draw and no
/// refusal to answer with.
@MainActor
private func testTheAppLetsAllThreeThroughDuringAFocusSession() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let clock = FakeClock(august(10, 10, 30))                  // inside the window
        let state = makeState(dir, clock: clock)
        state.prime()
        expectNil(state.resetTodaysCounters(), "the counters go back to zero inside a window")

        state.startFocusSession(minutes: 30)
        expectNil(state.resetTodaysCounters(), "and inside “Block everything” as well")
        var moved = state.config
        moved.dayStartMinutes = state.config.dayStartMinutes + 60
        expectNil(state.applyConfigEdit(moved), "the start of the day moves during one")
        var unguarded = state.config
        unguarded.preventTimeChange = false
        expectNil(state.applyConfigEdit(unguarded), "and the clock guard can be switched off")
        expect(
            state.focusSessionLine != nil, "with the session still running and still blocking"
        )
    }
}

/// **The half that survives.** A focus session and the settings lock are independent, and the lock
/// is the one that holds: it refuses all three exactly as it refuses any other edit, with the
/// session running or not. This is the check that says the freedom above is about blocks rather
/// than about locks.
@MainActor
private func testTheSettingsLockStillHoldsThemDuringAFocusSession() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(timerMinutes: 10)), "the timer is switched on")
        state.settingsWindowOpened()
        state.startFocusSession(minutes: 30)

        expectEqual(
            state.resetTodaysCounters(), "Held by the settings lock",
            "the reset is refused by the lock, not by the block"
        )
        var moved = state.config
        moved.dayStartMinutes = state.config.dayStartMinutes + 60
        expectEqual(
            state.applyConfigEdit(moved), "Held by the settings lock",
            "and so is the start of the day"
        )

        clock.advance(seconds: 600)
        state.tickForTesting()
        expectNil(state.resetTodaysCounters(), "the wait is what ends it, not the session")
        expect(state.focusSessionLine != nil, "which is still running")
    }
}
