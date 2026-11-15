import SandglassAppCore
import SandglassCore
import Foundation

/// The settings window as one visit: what asking for it again does, when a door that closes
/// mid-edit comes down, and when a visit left open with nobody at it ends.
///
/// The first two are values the window's wiring asks, pinned here because the wiring itself is
/// AppKit and SwiftUI and out of this harness's reach. The third goes through a real `AppState`,
/// because a visit that ends correctly in `SettingsVisit` and is never told the time would pass
/// every check that stopped short of the app.
func runSettingsWindowTests() {
    testAnOpenWindowIsOnlyBroughtForward()
    testADoorClosingUnderASheetWaitsForTheSheet()
    testASheetRaisedAtTheDoorIsNotAPage()
    MainActor.assumeIsolated {
        testAnIdleUnlockedVisitEnds()
        testActivityKeepsTheVisitOpen()
        testAWaitStillCountingIsNotIdleness()
        testAJumpPastTheWaitStillLeavesTheTenMinutes()
        testAClosedWindowHasNoVisitToEnd()
        testTheEmergencyPassKeepsTheVisitOpen()
    }
}

// MARK: - Asking for the window again

/// The status item used to rebuild the window's content on every click.
private func testAnOpenWindowIsOnlyBroughtForward() {
    expectEqual(
        SettingsWindowOpen.action(exists: false, onScreen: false), .build,
        "the first open builds the window"
    )
    expectEqual(
        SettingsWindowOpen.action(exists: true, onScreen: true), .bringForward,
        "a click with the window open only brings it forward"
    )
    expectEqual(
        SettingsWindowOpen.action(exists: true, onScreen: false), .build,
        "a window that was closed starts a new visit with fresh content"
    )
}

// MARK: - A door closing mid-edit

private func testADoorClosingUnderASheetWaitsForTheSheet() {
    var deferral = DoorDeferral()
    expect(
        !deferral.showsDoor(doorClosed: false, sheetOpen: false), "an unlocked window shows the page"
    )
    deferral.drew(door: false)
    expect(
        !deferral.showsDoor(doorClosed: true, sheetOpen: true),
        "the pass running out under an open sheet leaves the sheet and its draft standing"
    )
    deferral.drew(door: false)
    expect(
        deferral.showsDoor(doorClosed: true, sheetOpen: false),
        "and the door comes down the moment the sheet goes"
    )
    deferral.drew(door: true)
    expect(
        !deferral.showsDoor(doorClosed: false, sheetOpen: false),
        "a door that opens is never held"
    )
}

/// The door raises sheets of its own — the emergency pass asks before it is spent — and one of
/// those must not be read as a page with something open on it.
private func testASheetRaisedAtTheDoorIsNotAPage() {
    var deferral = DoorDeferral()
    expect(deferral.showsDoor(doorClosed: true, sheetOpen: false), "a locked window shows the door")
    deferral.drew(door: true)
    expect(
        deferral.showsDoor(doorClosed: true, sheetOpen: true),
        "and keeps showing it while the door's own alert is up"
    )
    expect(
        DoorDeferral().showsDoor(doorClosed: true, sheetOpen: true),
        "nothing drawn yet means no page to protect"
    )
}

// MARK: - An idle visit

/// Advances a minute at a time with a tick after each, which is what the app's loop does sixty
/// times as often.
@MainActor
private func idle(_ state: AppState, _ clock: FakeClock, minutes: Int) {
    for _ in 0..<minutes {
        clock.advance(seconds: 60)
        state.tickForTesting()
    }
}

/// The loophole: a window left open for hours kept a visit unlocked for hours.
@MainActor
private func testAnIdleUnlockedVisitEnds() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        // No Unblock-card wait, so the visit is idle from its first second: that wait counts as
        // somebody sitting with the window too, and is pinned by the timer test below.
        var config = lockedConfig(passcode: "1234")
        config.breakWaitSeconds = 0
        expectNil(state.applyConfigEdit(config), "a passcode is set")
        state.settingsWindowOpened()
        expect(state.unlockSettings(passcode: "1234"), "the visit is unlocked")
        idle(state, clock, minutes: 9)
        expect(!state.settingsLockState.passcodeRequired, "nine idle minutes leave it unlocked")
        idle(state, clock, minutes: 1)
        expect(
            state.settingsLockState.passcodeRequired,
            "the tenth ends the visit, and the door asks again"
        )
        expect(state.unlockSettings(passcode: "1234"), "which the passcode opens as before")
    }
}

@MainActor
private func testActivityKeepsTheVisitOpen() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(passcode: "1234")), "a passcode is set")
        state.settingsWindowOpened()
        expect(state.unlockSettings(passcode: "1234"), "the visit is unlocked")
        idle(state, clock, minutes: 8)
        state.settingsActivity()
        idle(state, clock, minutes: 8)
        state.settingsActivity()
        idle(state, clock, minutes: 8)
        expect(
            !state.settingsLockState.passcodeRequired,
            "twenty-four minutes with a press every eight is a visit somebody is at"
        )
    }
}

/// Sitting out the settings timer **is** the visit, and must not end it: idleness is counted
/// from the moment nothing is counting down any more.
@MainActor
private func testAWaitStillCountingIsNotIdleness() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(timerMinutes: 15)), "a fifteen-minute timer")
        state.settingsWindowClosed()
        state.settingsWindowOpened()
        idle(state, clock, minutes: 15)
        expectNil(state.settingsLockState.unlockSeconds, "the wait was sat out, with no press")
        idle(state, clock, minutes: 9)
        expectNil(state.settingsLockState.unlockSeconds, "nine idle minutes after it, still open")
        idle(state, clock, minutes: 1)
        expectEqual(
            state.settingsLockState.unlockSeconds, 900,
            "ten minutes after the wait ran out, the visit ends and the wait starts again"
        )
    }
}

/// A clock that moves in one jump — a Mac waking from sleep — still owes the ten minutes after
/// the wait, not after the last press.
@MainActor
private func testAJumpPastTheWaitStillLeavesTheTenMinutes() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(timerMinutes: 15)), "a fifteen-minute timer")
        state.settingsWindowClosed()
        state.settingsWindowOpened()
        clock.advance(seconds: 20 * 60)
        state.tickForTesting()
        expectNil(
            state.settingsLockState.unlockSeconds,
            "twenty minutes in one step: the wait is over and the visit five minutes idle"
        )
        clock.advance(seconds: 5 * 60)
        state.tickForTesting()
        expectEqual(state.settingsLockState.unlockSeconds, 900, "and five more end it")
    }
}

@MainActor
private func testAClosedWindowHasNoVisitToEnd() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(timerMinutes: 15)), "a fifteen-minute timer")
        state.settingsWindowClosed()
        idle(state, clock, minutes: 30)
        state.settingsWindowOpened()
        expectEqual(
            state.settingsLockState.unlockSeconds, 900,
            "a closed window is not a visit, so nothing ran out behind it"
        )
    }
}

@MainActor
private func testTheEmergencyPassKeepsTheVisitOpen() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(passcode: "1234")), "a passcode is set")
        state.settingsWindowOpened()
        expect(state.useEmergencyPass(), "the week's pass is spent")
        idle(state, clock, minutes: 20)
        expect(
            !state.settingsLockState.passcodeRequired,
            "the pass, while it runs, lifts the lock however long nobody presses anything"
        )
    }
}
