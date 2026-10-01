import SandglassAppCore
import SandglassCore
import Foundation

/// The settings lock in front of a break — the one thing it guards that is not a settings edit.
///
/// It is off by default, so half of what is checked here is that the default costs nothing: a
/// passcode set against raising a limit at 23:40 must not silently start standing in front of ten
/// minutes of Instagram. The rest is the shape of the gate: the passcode applies, the *settings*
/// timer does not, and ending a break early is never asked about, because that direction only ever
/// puts the blocks back.
///
/// Every case here sits out the Unblock card's own wait first — that is the other friction, it is
/// not the settings lock's, and it stands in front of everything on the card. What these cases are
/// about is what the passcode adds on top of it, and one of them is about the order.
func runQuickDisableLockTests() {
    // Every `AppState` is MainActor-isolated, and this executable's main thread is that actor's
    // executor — the same assertion `runSettingsLockTests` makes, for the same reason.
    MainActor.assumeIsolated {
        testTheBreakIsUngatedUntilTheUserAsksForIt()
        testAGatedBreakRefusesWithoutThePasscodeAndStartsWithIt()
        testTheWaitComesBeforeThePasscode()
        testBothFrictionsStillHoldInsideAStrictWindow()
        testEveryBreakAsksAgain()
        testABreaksPasscodeDoesNotUnlockTheSettings()
        testTheSettingsTimerNeverStandsInFrontOfABreak()
        testEndingABreakEarlyIsNeverGated()
    }
}

/// Off by default, and the default has to cost nothing: a passcode set against raising a limit
/// must not silently start standing in front of ten minutes of Instagram.
@MainActor
private func testTheBreakIsUngatedUntilTheUserAsksForIt() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(passcode: "1234")), "a passcode is set")
        afterTheUnblockWait(state, clock)

        expect(!state.breakNeedsPasscode, "which the break knows nothing about")
        expectNil(state.startBreak(minutes: 10), "so it goes through unasked")
        expect(state.breakEnd != nil, "and everything is unblocked")
    }
}

@MainActor
private func testAGatedBreakRefusesWithoutThePasscodeAndStartsWithIt() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(lockedConfig(passcode: "1234", coversQuickDisable: true)),
            "the break is put behind the passcode"
        )
        afterTheUnblockWait(state, clock)

        expect(state.breakNeedsPasscode, "the menu knows to ask before it calls")
        expectEqual(
            state.startBreak(minutes: 10), "Enter the passcode to change settings",
            "and asking anyway is refused"
        )
        expectNil(state.breakEnd, "with nothing unblocked")
        expectEqual(
            state.pauseStoppedReason, "Enter the passcode to change settings",
            "and the reason on screen, where the card already shows one"
        )

        // A wrong passcode is a refusal in its own words rather than a menu item that does
        // nothing and says nothing.
        expectEqual(
            state.startBreak(minutes: 10, passcode: "0000"),
            "That passcode doesn't match", "the wrong one is refused, and says why"
        )
        expectNil(state.breakEnd, "still nothing unblocked")
        expectEqual(
            state.pauseStoppedReason, "That passcode doesn't match",
            "and that is what the card shows"
        )

        expectNil(state.startBreak(minutes: 10, passcode: "1234"), "the right one goes through")
        expect(state.breakEnd != nil, "and everything is unblocked")
        expectNil(state.pauseStoppedReason, "with last time's refusal cleared")
    }
}

/// Two frictions in series, and in this order. One costs time and the other costs intent, and the
/// timed one is asked first for the reason the settings lock asks its timer first: told to enter
/// the passcode, somebody would enter it and then be refused a second time for a reason nobody had
/// mentioned.
@MainActor
private func testTheWaitComesBeforeThePasscode() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(lockedConfig(passcode: "1234", coversQuickDisable: true)),
            "the break is behind the passcode"
        )
        state.settingsWindowOpened()

        expectEqual(
            state.startBreak(minutes: 10, passcode: "1234"), "You can unblock in 0:30",
            "the right passcode buys nothing while the card's own wait is still running"
        )
        expectNil(state.breakEnd, "and nothing is unblocked")

        clock.advance(seconds: 30)
        expectEqual(
            state.startBreak(minutes: 10), "Enter the passcode to change settings",
            "and the passcode is what is left once the wait has run out"
        )
        expectNil(
            state.startBreak(minutes: 10, passcode: "1234"),
            "answered on the far side of the wait, the break goes through"
        )
        expect(state.breakEnd != nil, "and everything is unblocked")
    }
}

/// The same two frictions, at the moment the engine used to refuse a break outright.
///
/// A scheduled block no longer stands in the way of unblocking, and this is what stops that from
/// reading as "the friction was removed": the wait is still asked first and the passcode second,
/// inside the window exactly as outside it. What changed is the answer at the end of them.
@MainActor
private func testBothFrictionsStillHoldInsideAStrictWindow() {
    withTempDir { dir in
        let clock = FakeClock(august(10, 8))               // Monday, before the window
        let state = makeState(dir, clock: clock)
        var config = lockedConfig(passcode: "1234", coversQuickDisable: true)
        for id in config.groupSettings.keys {
            config.groupSettings[id]?.timeWindows = [pauseWindow]   // 10:00–11:00 on weekdays
        }
        expectNil(state.applyConfigEdit(config), "a locked break, and a group with a window")

        clock.now = august(10, 10, 30)                     // inside it
        state.tickForTesting()
        expect(
            state.budgetsByGroup.contains { $0.reason == .schedule },
            "the window is blocking when the card is reached"
        )

        state.settingsWindowOpened()
        expectEqual(
            state.startBreak(minutes: 10, passcode: "1234"), "You can unblock in 0:30",
            "the wait is asked first, window or no window, and the passcode buys nothing yet"
        )
        expectNil(state.breakEnd, "so nothing is unblocked")

        clock.advance(seconds: 30)
        expectEqual(
            state.startBreak(minutes: 10), "Enter the passcode to change settings",
            "then the passcode, which is the only thing left to ask"
        )
        expectNil(state.breakEnd, "and still nothing is unblocked")

        expectNil(
            state.startBreak(minutes: 10, passcode: "1234"),
            "both answered, the break goes through inside the window"
        )
        expect(state.breakEnd != nil, "and is running")
        expect(
            state.budgetsByGroup.allSatisfy { $0.reason == nil },
            "with every group standing down for its duration"
        )
    }
}

/// The bug this file was written against and did not catch: the answer was going through
/// `unlockSettings`, which records it for the rest of a settings *visit*, so one visit's answer
/// bought every break taken during it. The first break asked; every one after it went straight
/// through.
@MainActor
private func testEveryBreakAsksAgain() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(lockedConfig(passcode: "1234", coversQuickDisable: true)),
            "the break is behind the passcode"
        )
        afterTheUnblockWait(state, clock)

        expectNil(state.startBreak(minutes: 1, passcode: "1234"), "the first break asks")
        for _ in 0..<65 {                       // the minute it bought, and a little after
            clock.advance(seconds: 1)
            state.tickForTesting()
        }
        expectNil(state.breakEnd, "and runs out on its own")

        expect(state.breakNeedsPasscode, "the second break owes the same question")
        expectEqual(
            state.startBreak(minutes: 10), "Enter the passcode to change settings",
            "and asking without answering is refused"
        )
        expectNil(state.breakEnd, "so no second break was had for free")
        expectNil(state.startBreak(minutes: 10, passcode: "1234"), "answered, it starts")
    }
}

/// The other half of the same rule: an answer given for a break is not an answer for the settings
/// page. It unlocked one before — `unlockSettings` is what the break was calling — and the window
/// it would unlock is open the whole time now, which is what makes this worth pinning.
@MainActor
private func testABreaksPasscodeDoesNotUnlockTheSettings() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(lockedConfig(passcode: "1234", coversQuickDisable: true)),
            "the break is behind the passcode"
        )
        afterTheUnblockWait(state, clock)

        expectNil(state.startBreak(minutes: 10, passcode: "1234"), "a break is started")

        expect(state.settingsLockState.passcodeRequired, "and the settings are still locked")
        expectEqual(
            state.applyConfigEdit(lockedConfig(passcode: "1234")),
            "Enter the passcode to change settings", "with edits refused"
        )
    }
}

/// The settings lock's timer guards edits to the configuration, and a break is not one. Three
/// hours of it can be running on the very window the card sits in without touching the card's own
/// wait — which is the whole reason a break is a `.deliberateAction` and the two waits are two
/// gates.
@MainActor
private func testTheSettingsTimerNeverStandsInFrontOfABreak() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(lockedConfig(timerMinutes: 180, coversQuickDisable: true)),
            "a three-hour wait on the settings, and the break gated"
        )
        afterTheUnblockWait(state, clock)

        expect(!state.breakNeedsPasscode, "there is no passcode, so nothing is owed")
        expectEqual(
            state.applyConfigEdit(webConfig()), "Held by the settings lock",
            "the settings themselves are locked for what is left of the three hours"
        )
        expectNil(state.startBreak(minutes: 10), "and that wait is not the card's")
        expect(state.breakEnd != nil, "the break the card's own thirty seconds bought goes through")
    }
}

/// The one direction that is never asked about. Ending a break puts every block back, and a
/// passcode in front of that would be a lock on the way *in* to protection.
@MainActor
private func testEndingABreakEarlyIsNeverGated() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(lockedConfig(passcode: "1234", coversQuickDisable: true)),
            "the break is behind the passcode"
        )
        afterTheUnblockWait(state, clock)
        expectNil(state.startBreak(minutes: 10, passcode: "1234"), "answered, and started")
        expect(state.breakEnd != nil, "the break is running")

        expect(state.breakNeedsPasscode, "starting another one would ask")
        state.endPauseEarly()
        expectNil(state.breakEnd, "but ending this one goes straight through")
    }
}
