import SandglassAppCore
import SandglassCore
import Foundation

/// The third layer of the settings lock: **the whole app refusing a real edit**.
///
/// The one that matters most, and the reason it is worth its own file. A gate that refuses
/// correctly and is never asked would pass every check in `SettingsLockTests` next door, where
/// the stored passcode and the gate's own arithmetic are pinned. Everything here goes through
/// `AppState` — a temporary support directory, a real `Store`, a real edit — so what is checked
/// is that the refusal is actually reached.
///
/// It also carries what the lock covers **besides** `config.json`: the keep-alive agent and the
/// undo of today, both gated by hand and both about `SettingsLockScope`.
///
/// Every `AppState` is MainActor-isolated, and this executable's main thread is that actor's
/// executor — the same assertion `runAppStateTests` makes, for the same reason.
@MainActor
func runSettingsLockEditTests() {
    testTheTimerRefusesARealEdit()
    testTheTimerLetsATighteningEditThrough()
    testSwitchingTheTimerOnLeavesTheVisitThatSwitchedItFree()
    testThePasscodeRefusesARealEdit()
    testAnEmergencyPassUnlocksLockedSettings()
    testAPasscodeResetSurvivesARelaunch()
    testTheTimerHoldsTheKeepAliveToggleButNotTheQuitDialogue()
    testThePasscodeHoldsKeepAliveEverywhere()
    testAnEmergencyPassLetsTheAgentBeSwitchedOff()
    testAnUnlockedSettingsGatesNeitherKeepAliveNorAReset()
    testResettingTodayIsRefusedByEitherFriction()
}

// MARK: - Refusing an edit to `config.json`

/// The app-wide timer holds loosening and only loosening, exactly as a group's own does.
///
/// The lock rule reaches the widest lock in the app too: making things stricter must always work.
/// What is checked here is that the app-wide half asks the same question — a knob
/// turned towards more friction anywhere, one more site, a passcode set, a longer wait on the lock
/// itself — and that each reverse still meets the wait.
@MainActor
private func testTheTimerLetsATighteningEditThrough() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(timerMinutes: 10)), "switching the timer on")
        state.settingsWindowClosed()
        state.settingsWindowOpened()
        expectEqual(state.settingsLockState.unlockSeconds, 600, "the visit starts locked")

        var stricter = state.config
        stricter.groupSettings[youtubeGroup]?.pauseSeconds = 90
        expectNil(state.applyConfigEdit(stricter), "a longer pause goes through")
        var site = state.config
        site.targets.append(
            Target(kind: .domain, value: "x.com", displayName: "X", groupID: youtubeGroup)
        )
        expectNil(state.applyConfigEdit(site), "so does one more site")
        var longer = state.config
        longer.settingsLock.timerMinutes = 60
        expectNil(state.applyConfigEdit(longer), "and so does a longer wait on the lock itself")
        expectEqual(
            state.settingsLockState.unlockSeconds, 3_600,
            "which the countdown picks up from the same window open"
        )
        var coded = state.config
        coded.settingsLock.passcode = PasscodeHash.make("1234")
        expectNil(state.applyConfigEdit(coded), "a passcode may be set while the wait runs")

        var shorter = state.config
        shorter.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectEqual(
            state.applyConfigEdit(shorter), "Held by the settings lock",
            "while a shorter pause is held"
        )
        var fewer = state.config
        fewer.targets.removeAll { $0.groupID == youtubeGroup }
        expectEqual(
            state.applyConfigEdit(fewer), "Held by the settings lock",
            "and so is taking a site out"
        )
        var quicker = state.config
        quicker.breakWaitSeconds = 0
        expectEqual(
            state.applyConfigEdit(quicker), "Held by the settings lock",
            "and so is cutting the wait in front of the Unblock card"
        )
        // The actions with no configuration behind them to compare are judged as loosenings,
        // which is what each of them is: handing a spent budget back is the clearest one there is.
        expectEqual(
            state.resetTodaysCounters(), "Held by the settings lock",
            "and an action with no pair of configurations to weigh is still held"
        )
    }
}

@MainActor
private func testTheTimerRefusesARealEdit() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(timerMinutes: 10)), "switching the timer on")

        state.settingsWindowOpened()
        expectEqual(state.settingsLockState.unlockSeconds, 600, "the visit starts locked")
        expectEqual(
            state.applyConfigEdit(lockedConfig(timerMinutes: 10, dayStartMinutes: 5 * 60)),
            "Held by the settings lock",
            "and an edit is refused, naming the lock rather than a number that would not move"
        )
        expectEqual(state.config.dayStartMinutes, 3 * 60, "nothing was changed")

        clock.advance(seconds: 600)
        state.tickForTesting()
        expectNil(state.settingsLockState.unlockSeconds, "ten minutes later the wait is over")
        expectNil(
            state.applyConfigEdit(lockedConfig(timerMinutes: 10, dayStartMinutes: 5 * 60)),
            "and the same edit goes through"
        )
        expectEqual(state.config.dayStartMinutes, 5 * 60, "the change landed")
    }
}

/// Switching the timer on must not lock the visit that switched it on.
///
/// The trap, as it was walked into: the wait counts from the window opening, which has already
/// happened, so the toggle landed with the whole default already owed — and it held the "Locked
/// for" stepper beside it. The default was never chosen and could not be changed without sitting
/// out the default.
///
/// The other half is untouched and is checked here too: the countdown arms on the next window
/// open, and from then on it holds the duration and the switch that would take it off.
@MainActor
private func testSwitchingTheTimerOnLeavesTheVisitThatSwitchedItFree() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        state.settingsWindowOpened()
        expectNil(
            state.applyConfigEdit(lockedConfig(timerMinutes: 10)),
            "the timer is switched on halfway through a visit"
        )
        expectNil(
            state.settingsLockState.unlockSeconds,
            "and the window's banner has nothing to count: this visit is not held by it"
        )
        expect(
            EditorFreeze.notices(lock: state.settingsLockState, focusSessionLine: nil).isEmpty,
            "nor is a page banded with a notice saying nothing on it can change"
        )

        expectNil(
            state.applyConfigEdit(lockedConfig(timerMinutes: 45)),
            "the duration is free to pick, which is the whole of what was missing"
        )
        expectEqual(state.config.settingsLock.timerMinutes, 45, "and forty-five is what was chosen")
        expectNil(
            state.applyConfigEdit(lockedConfig(timerMinutes: 45, dayStartMinutes: 5 * 60)),
            "the rest of the page is no more frozen than the stepper is"
        )

        state.settingsWindowClosed()
        state.settingsWindowOpened()
        expectEqual(
            state.settingsLockState.unlockSeconds, 2700,
            "the next visit arms it, for the length that was chosen"
        )
        expectEqual(
            state.applyConfigEdit(lockedConfig(timerMinutes: 10, dayStartMinutes: 5 * 60)),
            "Held by the settings lock",
            "which then holds the duration"
        )
        expectEqual(
            state.applyConfigEdit(lockedConfig(dayStartMinutes: 5 * 60)),
            "Held by the settings lock",
            "and the switch that would take it off — the half the lock exists for"
        )
        expectEqual(state.config.settingsLock.timerMinutes, 45, "so it is still forty-five minutes")
    }
}

@MainActor
private func testThePasscodeRefusesARealEdit() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(passcode: "1234")), "setting a passcode")

        state.settingsWindowOpened()
        expect(state.settingsLockState.passcodeRequired, "the settings are locked")
        expectEqual(
            state.applyConfigEdit(lockedConfig(passcode: "1234", dayStartMinutes: 5 * 60)),
            "Enter the passcode to change settings",
            "and an edit is refused"
        )
        expect(!state.unlockSettings(passcode: "0000"), "the wrong passcode does not unlock")
        expect(state.unlockSettings(passcode: "1234"), "the right one does")
        expect(!state.settingsLockState.passcodeRequired, "and the screen stops asking")
        expectNil(
            state.applyConfigEdit(lockedConfig(passcode: "1234", dayStartMinutes: 5 * 60)),
            "the edit goes through"
        )

        state.settingsWindowClosed()
        state.settingsWindowOpened()
        expect(state.settingsLockState.passcodeRequired, "the next visit asks again")
    }
}

/// The lock must never trap. With recovery switched off there is no way back inside the app,
/// so the week's pass has to be one — otherwise a forgotten passcode is a reinstall.
@MainActor
private func testAnEmergencyPassUnlocksLockedSettings() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(lockedConfig(timerMinutes: 180, passcode: "1234", allowForgot: false)),
            "a locked-down settings, with no recovery"
        )
        state.settingsWindowOpened()
        expect(state.applyConfigEdit(webConfig()) != nil, "which refuses every edit")

        expect(state.useEmergencyPass(), "the week's pass is spent")
        expectNil(state.settingsLockState.unlockSeconds, "the countdown stops")
        expect(!state.settingsLockState.passcodeRequired, "and so does the asking")
        expectNil(state.applyConfigEdit(webConfig()), "the settings can be edited again")
        expectEqual(state.config.settingsLock, SettingsLock(), "including switching the lock off")
    }
}

/// The hour survives being quit, which is the whole point of storing where it started rather
/// than counting it down in memory.
@MainActor
private func testAPasscodeResetSurvivesARelaunch() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let first = makeState(dir, clock: clock)
        expectNil(first.applyConfigEdit(lockedConfig(passcode: "1234")), "a passcode is set")
        expectNil(first.setPasscodeReset(true), "and forgotten")
        expectEqual(first.settingsLockState.resetSeconds, 3600, "an hour to wait")
        first.stop()

        // A new app on the same files: the app was quit and started again.
        clock.advance(seconds: 59 * 60)
        let second = makeState(dir, clock: clock)
        second.tickForTesting()
        expect(second.config.settingsLock.passcode != nil, "fifty-nine minutes later, still locked")
        expectEqual(second.settingsLockState.resetSeconds, 60, "with a minute left")

        clock.advance(seconds: 120)
        second.tickForTesting()
        expectNil(second.config.settingsLock.passcode, "the hour clears the passcode")
        expectNil(second.config.settingsLock.forgotStartedAt, "and the wait with it")
        expectNil(second.settingsLockState.resetSeconds, "the screen stops counting")
        second.settingsWindowOpened()
        expect(!second.settingsLockState.passcodeRequired, "and the settings are open again")
    }
}

// MARK: - What the lock covers besides `config.json`

// Two things loosen the rules without being edits to the settings file: the keep-alive agent,
// which is a LaunchAgent, and resetting today's counters, which is the engine's state. Both are
// gated by hand — see `AppState.setKeepAlive(_:requiring:)`. The cases below are about which
// friction reaches which of them, which is the whole of `SettingsLockScope`.

/// The split, in one case. The wait is a condition of the visit, so it holds the toggle on the
/// settings page and does not touch the quit dialogue — where it could never be waited out.
@MainActor
private func testTheTimerHoldsTheKeepAliveToggleButNotTheQuitDialogue() {
    withTempDir { dir in
        let agent = RecordingKeepAlive(installed: true)
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)
        expectNil(state.applyConfigEdit(lockedConfig(timerMinutes: 10)), "the timer is switched on")
        state.settingsWindowOpened()

        expectEqual(
            state.setKeepAlive(false, requiring: .settingsWindow),
            "Held by the settings lock",
            "the toggle on the settings page is refused by it"
        )
        expect(agent.asked.isEmpty, "and the agent was never asked")
        expect(state.keepAliveEnabled, "so the toggle stays on, which is what is installed")

        expectNil(
            state.setKeepAlive(false, requiring: .deliberateAction),
            "the quit dialogue's own button is not made to wait for a window it has not got"
        )
        expectEqual(agent.asked, [false], "and the agent was asked exactly once")
    }
}

/// The other half: the passcode asks who you are, and that question is as fair at the quit
/// dialogue as on the settings page. Both call sites owe it.
@MainActor
private func testThePasscodeHoldsKeepAliveEverywhere() {
    withTempDir { dir in
        let agent = RecordingKeepAlive(installed: true)
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)
        expectNil(state.applyConfigEdit(lockedConfig(passcode: "1234")), "a passcode is set")
        state.settingsWindowOpened()

        expectEqual(
            state.setKeepAlive(false, requiring: .deliberateAction),
            "Enter the passcode to change settings",
            "the quit dialogue is refused with nothing typed"
        )
        expectEqual(
            state.setKeepAlive(false, requiring: .deliberateAction, passcode: "0000"),
            "That passcode doesn't match",
            "and refused in its own words on a wrong one"
        )
        expectEqual(
            state.setKeepAlive(false, requiring: .settingsWindow),
            "Enter the passcode to change settings",
            "and so is the settings toggle"
        )
        expect(agent.asked.isEmpty, "nothing was written any of those times")

        expectNil(
            state.setKeepAlive(false, requiring: .deliberateAction, passcode: "1234"),
            "the right one turns the agent off"
        )
        expect(!state.keepAliveEnabled, "and it is off")

        // Switching the agent back on is a tightening and passes with nothing typed — a lock
        // holds loosening only. Which also makes it the wrong probe for whether the passcode
        // answer was remembered; the honest probe is the next switch-off.
        expectNil(
            state.setKeepAlive(true, requiring: .settingsWindow),
            "switching protection on is never refused"
        )
        expect(state.keepAliveEnabled, "and it is back on")
        expectEqual(
            state.setKeepAlive(false, requiring: .deliberateAction),
            "Enter the passcode to change settings",
            "the answer bought one action; the next switch-off owes its own"
        )
    }
}

/// The lock must never trap, and that has to hold for the agent too: a forgotten passcode with
/// recovery off would otherwise leave the app unable to stop restarting itself.
@MainActor
private func testAnEmergencyPassLetsTheAgentBeSwitchedOff() {
    withTempDir { dir in
        let agent = RecordingKeepAlive(installed: true)
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)
        expectNil(
            state.applyConfigEdit(
                lockedConfig(timerMinutes: 180, passcode: "1234", allowForgot: false)
            ),
            "locked down, with no way back inside the app"
        )
        state.settingsWindowOpened()
        expect(state.setKeepAlive(false, requiring: .settingsWindow) != nil, "which refuses both")
        expect(state.setKeepAlive(false, requiring: .deliberateAction) != nil, "scopes")
        expect(state.resetTodaysCounters() != nil, "and the reset with them")

        expect(state.useEmergencyPass(), "the week's pass is spent")
        expectNil(state.setKeepAlive(false, requiring: .settingsWindow), "the agent can go")
        expectNil(state.resetTodaysCounters(), "and today can be reset")
    }
}

/// Both frictions off is the default, and the default must cost nothing.
@MainActor
private func testAnUnlockedSettingsGatesNeitherKeepAliveNorAReset() {
    withTempDir { dir in
        let agent = RecordingKeepAlive()
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)
        state.settingsWindowOpened()

        expectNil(state.setKeepAlive(true, requiring: .settingsWindow), "the toggle goes through")
        expectNil(state.setKeepAlive(false, requiring: .deliberateAction), "and so does the quit")
        expectEqual(agent.asked, [true, false], "the agent was asked both times")
        expectNil(state.resetTodaysCounters(), "and today can be reset")
    }
}

/// Handing back a budget already spent is loosening today's rules, so it waits like an edit does.
@MainActor
private func testResettingTodayIsRefusedByEitherFriction() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(timerMinutes: 10)), "the timer is switched on")
        state.settingsWindowOpened()
        expectEqual(
            state.resetTodaysCounters(), "Held by the settings lock",
            "the reset waits out the timer like every other control on the page"
        )

        clock.advance(seconds: 600)
        state.tickForTesting()
        expectNil(
            state.applyConfigEdit(lockedConfig(timerMinutes: 10, passcode: "1234")),
            "the wait is over, and a passcode goes on instead"
        )
        expectEqual(
            state.resetTodaysCounters(), "Enter the passcode to change settings",
            "which the reset owes as well"
        )
        expect(state.unlockSettings(passcode: "1234"), "the passcode is entered")
        expectNil(state.resetTodaysCounters(), "and the counters go back to zero")
    }
}
