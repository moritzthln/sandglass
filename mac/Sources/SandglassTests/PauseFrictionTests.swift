import SandglassAppCore
import SandglassCore
import Foundation

/// The unblock menu, which is the one control in the app that turns protection off — and
/// therefore the one that has to behave when a block opens underneath it.
///
/// Two layers, on purpose. The first cases drive a whole `AppState`, which is what proves the
/// wiring between the engine, the loop and the menu. The last one drives `PauseFriction` itself,
/// where the copy and the note's lifetime live, without a store or a clock in the way.
func runPauseFrictionTests() {
    MainActor.assumeIsolated {
        testABreakIsGrantedByAWindowThatOpenedDuringTheWait()
        testABreakGoesThroughInsideAWindowAndTheWindowComesBack()
        testFrictionForgetsARefusalAndRetiresItsNote()
    }
}

/// The case this suite was written for, now the other way round.
///
/// It used to assert that a window opening during the wait killed the break the wait was spent
/// on: the user sat out the countdown and was told "A scheduled block is active" at the end of
/// it. That is exactly the moment the control has to work — the friction has been paid, and the
/// answer arrives too late to do anything about. A break overrides windows now, so the wait
/// still permits nothing but asking, and asking is now granted.
@MainActor
private func testABreakIsGrantedByAWindowThatOpenedDuringTheWait() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let clock = FakeClock(august(10, 9, 59).addingTimeInterval(45))
        let state = makeState(dir, clock: clock)
        state.prime()

        expectNil(state.pauseBlockedReason, "before the window a break is allowed")
        state.settingsWindowOpened()
        expectEqual(state.breakWaitSecondsLeft, 30, "and the card opens on its thirty-second wait")

        for _ in 0..<15 { clock.advance(seconds: 1); state.tickForTesting() }   // 10:00:00
        expectEqual(state.breakWaitSecondsLeft, 15, "the wait is not disturbed by the block")
        expectNil(state.pauseBlockedReason, "and the block does not kill the menu behind it")

        for _ in 0..<15 { clock.advance(seconds: 1); state.tickForTesting() }   // 10:00:15
        expectNil(state.breakWaitSecondsLeft, "the wait runs out")
        expectNil(state.startBreak(), "and the break the wait was spent on goes through")
        expectNil(state.pauseStoppedReason, "with nothing to explain")
        expect(state.breakEnd != nil, "and everything unblocked")

        var paused = false
        if case .paused = state.statusKind { paused = true }
        expect(paused, "which is what the menu bar says")
        expect(
            state.budgetsByGroup.allSatisfy { $0.reason == nil },
            "and no group is blocked while it runs, window or no window"
        )
    }
}

/// The same promise asked for from a standing start, and the other half of it: what the break
/// lifts, it lifts only for as long as it runs.
@MainActor
private func testABreakGoesThroughInsideAWindowAndTheWindowComesBack() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let clock = FakeClock(august(11, 10, 30))                  // Tuesday, inside the window
        let state = makeState(dir, clock: clock)
        state.prime()
        expect(
            state.budgetsByGroup.contains { $0.reason == .schedule },
            "the window is blocking when the card is reached"
        )
        afterTheUnblockWait(state, clock)

        expectNil(state.pauseBlockedReason, "inside a window the menu is live")
        expectNil(state.startBreak(minutes: 10), "and a break is granted")
        expect(state.breakEnd != nil, "and is running")
        expect(
            state.budgetsByGroup.allSatisfy { $0.reason == nil },
            "with every group standing down for its duration"
        )

        clock.advance(seconds: 601)
        state.tickForTesting()
        expectNil(state.breakEnd, "when it runs out")
        expect(
            state.budgetsByGroup.contains { $0.reason == .schedule },
            "the window that was standing all along blocks again"
        )
    }
}

// MARK: - Pause friction, asked directly

// The two cases above drive the friction through a whole `AppState`, which is what proves the
// wiring. This one drives `PauseFriction` itself, which is where the copy and the note's
// lifetime live: no store, no engine and no clock, so the boundary second can be stated outright.

/// The regression the type exists for, one layer below the `AppState` cases above: a refusal
/// is derived, never remembered, and the note explaining one does not outlive the day.
private func testFrictionForgetsARefusalAndRetiresItsNote() {
    var friction = PauseFriction()
    friction.applyBlock(.focusSession(untilText: "17:00"))
    expectEqual(
        friction.blockedReason, "Everything is blocked until 17:00",
        "the button says why it is dead, naming the time it ends in the app's one wall-clock "
            + "format and the words the Block everything card uses"
    )

    friction.applyBlock(nil)
    expectNil(friction.blockedReason, "and stops saying it the moment the block ends")

    friction.note("Protection couldn't be paused", at: noon)
    friction.expireNote(at: noon.addingTimeInterval(59), lifetime: 60)
    expectEqual(friction.stoppedReason, "Protection couldn't be paused", "a fresh note stays")
    friction.expireNote(at: noon.addingTimeInterval(60), lifetime: 60)
    expectNil(friction.stoppedReason, "an old one is retired")
}
