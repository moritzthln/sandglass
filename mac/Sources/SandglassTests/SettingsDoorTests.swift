import SandglassAppCore
import SandglassCore
import Foundation

/// The door in front of the settings window: when it is shut, what opens it, and the one thing it
/// must never do — leave somebody outside their own app with nothing to press.
///
/// Two layers. The value on its own decides what the screen draws; a real `AppState` decides
/// whether a visit is actually held, because a door that closes correctly and is never consulted
/// would pass every check above it.
func runSettingsDoorTests() {
    testNoPasscodeMeansNoDoor()
    testTheDoorOffersTheHourWhileRecoveryIsOn()
    testARunningHourIsWhatTheDoorShows()
    testRecoverySwitchedOffLeavesOnlyTheEmergencyPass()
    // Every `AppState` is MainActor-isolated, and this executable's main thread is that actor's
    // executor — the same assertion `runSettingsLockTests` makes, for the same reason.
    MainActor.assumeIsolated {
        testTheDoorShutsOnEveryVisitAndOpensOnTheRightCode()
        testAnEmergencyPassSkipsTheDoor()
        testTheTimerStillRefusesChangesBehindAnOpenDoor()
        testAForgottenPasscodeCanStartItsHourFromTheDoor()
    }
}

// MARK: - The value on its own

/// No passcode, no door. The one condition, and it is worth pinning on its own: everything else
/// here is about a lock that exists, and the default is a lock that does not.
private func testNoPasscodeMeansNoDoor() {
    let off = SettingsLock()
    expect(
        !SettingsDoor(lock: off, state: SettingsLockState()).isClosed,
        "an app with no passcode set opens straight into the settings"
    )
    // A timer counting down is not a door either: it refuses changes, and reading is not one.
    let timerOnly = SettingsLock(timerMinutes: 10)
    expect(
        !SettingsDoor(
            lock: timerOnly, state: SettingsLockState(unlockSeconds: 600)
        ).isClosed,
        "and neither is a running timer, which refuses changes rather than entry"
    )
}

private func testTheDoorOffersTheHourWhileRecoveryIsOn() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let door = SettingsDoor(
        lock: SettingsLock(passcode: hash), state: SettingsLockState(passcodeRequired: true)
    )
    expect(door.isClosed, "a passcode still owed shuts the window")
    expectEqual(door.recovery, .offer, "with the hour there to be started")
    expectEqual(door.recovery.actionTitle, "Forgot your passcode?", "under those words")
    expectNil(door.recovery.note, "and nothing counting down yet")
}

private func testARunningHourIsWhatTheDoorShows() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let door = SettingsDoor(
        lock: SettingsLock(passcode: hash),
        state: SettingsLockState(passcodeRequired: true, resetSeconds: 128)
    )
    expectEqual(door.recovery, .waiting(secondsLeft: 128), "a wait that is running is the offer")
    expectEqual(door.recovery.note, "Passcode clears in 2:08", "counted down in words")
    expectEqual(door.recovery.actionTitle, "Cancel", "and what it offers is calling it off")
}

/// The case the door had to be checked against before it could ship. With recovery off there is
/// no way back **inside the settings**, and the settings are what this screen is in front of — so
/// the pass has to be on the door itself, or a forgotten passcode is a reinstall.
private func testRecoverySwitchedOffLeavesOnlyTheEmergencyPass() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let lock = SettingsLock(passcode: hash, allowForgot: false)
    let door = SettingsDoor(lock: lock, state: SettingsLockState(passcodeRequired: true))
    expectEqual(door.recovery, .emergencyPassOnly, "the hour is not on offer")
    expectEqual(door.recovery.actionTitle, "Use emergency pass", "the week's pass is")
    expect(door.recovery.note?.contains("emergency pass") == true, "and the door says so")

    // A wait left behind by somebody who has since switched recovery off is not a way back, and
    // must not be drawn as one: `SettingsLock.forgotSecondsLeft` refuses to count it, so the
    // published state carries no seconds and the door falls through to the pass.
    let stale = SettingsLock(
        passcode: hash, allowForgot: false, forgotStartedAt: ClockReading(wall: noon, uptime: 1)
    )
    expectNil(stale.forgotSecondsLeft(at: ClockReading(wall: noon, uptime: 1)), "nothing is counted")
    expectEqual(
        SettingsDoor(lock: stale, state: SettingsLockState(passcodeRequired: true)).recovery,
        .emergencyPassOnly,
        "so a stale timestamp does not become an offer the app cannot keep"
    )
}

// MARK: - A real visit

/// Once per window visit, exactly as the sheet was: the right code buys this visit and the next
/// one asks again.
@MainActor
private func testTheDoorShutsOnEveryVisitAndOpensOnTheRightCode() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(state.applyConfigEdit(lockedConfig(passcode: "1234")), "a passcode is set")

        state.settingsWindowOpened()
        expect(door(state).isClosed, "the window opens on the door")
        expect(!state.unlockSettings(passcode: "0000"), "a wrong code is not accepted")
        expect(door(state).isClosed, "and leaves the door shut")
        expect(state.unlockSettings(passcode: "1234"), "the right one is")
        expect(!door(state).isClosed, "and the app is behind it")

        state.settingsWindowClosed()
        state.settingsWindowOpened()
        expect(door(state).isClosed, "closing and reopening asks again")
    }
}

/// A pass lifts the settings lock, so it has to lift the door — the pass is spent from the
/// settings page, and a door that outlived it would shut the user out of the escape they had
/// already paid for.
@MainActor
private func testAnEmergencyPassSkipsTheDoor() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(
            state.applyConfigEdit(lockedConfig(passcode: "1234", allowForgot: false)),
            "a passcode, with no way back inside the app"
        )
        state.settingsWindowOpened()
        expect(door(state).isClosed, "which shuts the window")

        expect(state.useEmergencyPass(), "the week's pass is spent")
        expect(!door(state).isClosed, "and the door is not there")
    }
}

/// The two frictions stay two. Entering the code answers who you are; it does not answer how long
/// you have sat with the change, and "Locked for" goes on refusing until it runs out.
@MainActor
private func testTheTimerStillRefusesChangesBehindAnOpenDoor() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(lockedConfig(timerMinutes: 10, passcode: "1234")),
            "both frictions are switched on"
        )

        state.settingsWindowOpened()
        expect(door(state).isClosed, "the visit starts at the door")
        expect(state.unlockSettings(passcode: "1234"), "the code is entered")
        expect(!door(state).isClosed, "which opens it")
        expectEqual(
            state.applyConfigEdit(
                lockedConfig(timerMinutes: 10, passcode: "1234", dayStartMinutes: 5 * 60)
            ),
            "Held by the settings lock",
            "and the wait still refuses the change"
        )

        clock.advance(seconds: 600)
        state.tickForTesting()
        expectNil(
            state.applyConfigEdit(
                lockedConfig(timerMinutes: 10, passcode: "1234", dayStartMinutes: 5 * 60)
            ),
            "which it stops doing when the countdown ends"
        )
        expectEqual(state.config.dayStartMinutes, 5 * 60, "the change landed")
    }
}

/// The way out has to work from the door, because the row it used to live on is behind it.
/// `setPasscodeReset` deliberately does not go through `applyConfigEdit` — a passcode nobody can
/// remember must not be what guards its own way out — and this is the case that depends on it.
@MainActor
private func testAForgottenPasscodeCanStartItsHourFromTheDoor() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(passcode: "1234")), "a passcode is set")
        state.settingsWindowOpened()
        expectEqual(door(state).recovery, .offer, "the door offers the hour")

        expectNil(state.setPasscodeReset(true), "which starts from behind the shut door")
        expectEqual(
            door(state).recovery, .waiting(secondsLeft: 3600), "and is what the door now shows"
        )
        expect(door(state).isClosed, "the door does not open early for it")

        clock.advance(seconds: 3600)
        state.tickForTesting()
        expect(!door(state).isClosed, "an hour later there is no passcode, and no door")
        expectNil(state.config.settingsLock.passcode, "because the passcode was cleared")
    }
}

// MARK: - Fixtures

/// What the window would draw this second.
@MainActor
private func door(_ state: AppState) -> SettingsDoor {
    SettingsDoor(lock: state.config.settingsLock, state: state.settingsLockState)
}
