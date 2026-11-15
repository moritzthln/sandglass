import SandglassAppCore
import SandglassCore
import Foundation

// The edge the loop watches for: the moment the engine stops standing down over a group. A break,
// an emergency pass and a group's break window all end by themselves, and none of them moves the
// group into the blocked set — the countdown screen it lands on is not a block — so a loop that
// compared blocked sets alone left the app in front fully usable until the user switched away.

func runBlockEdgeTests() {
    MainActor.assumeIsolated {
        testABreakRunningOutDecidesTheFrontAppAgain()
        testAPassRunningOutDecidesTheFrontAppAgain()
        testABreakWindowClosingDecidesTheFrontAppAgain()
        testAQuietSecondDecidesNothing()
        testASessionEndingOnAGroupThatOpensByItselfSendsNothingAway()
        testASessionEndingOnAGroupWithAScreenStillSendsItsAppsAway()
    }
}

/// Notes under a countdown and nothing else: no window, no limit, so the only thing between the
/// user and Notes is the pause screen — which is exactly the state no blocked set can see.
private func countdownConfig(windows: [TimeWindow] = []) -> Config {
    let app = Target(kind: .app, value: "com.apple.Notes", displayName: "Notes", groupID: "grp:demo")
    return Config(
        version: 1,
        targets: [app],
        groupSettings: ["grp:demo": standardSettings(windows: windows)]
    )
}

@MainActor
private func tick(_ state: AppState, _ clock: FakeClock, seconds: Int) {
    for _ in 0..<seconds {
        clock.advance(seconds: 1)
        state.tickForTesting()
    }
}

@MainActor
private func testABreakRunningOutDecidesTheFrontAppAgain() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(countdownConfig())
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()
        blocker.frontmost = "com.apple.Notes"

        afterTheUnblockWait(state, clock)
        expectNil(state.startBreak(minutes: 1), "the break is granted")
        tick(state, clock, seconds: 30)
        let rechecks = blocker.recheckCount
        tick(state, clock, seconds: 31)
        expectEqual(state.statusKind, .active(targetCount: 1), "the minute is over")
        expect(
            blocker.recheckCount > rechecks,
            "and the app left in front is decided again the second the break runs out"
        )
    }
}

@MainActor
private func testAPassRunningOutDecidesTheFrontAppAgain() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(countdownConfig())
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()
        blocker.frontmost = "com.apple.Notes"

        expect(state.useEmergencyPass(), "the pass is spent")
        tick(state, clock, seconds: 3599)
        let rechecks = blocker.recheckCount
        tick(state, clock, seconds: 2)
        expectEqual(state.statusKind, .active(targetCount: 1), "the hour is over")
        expect(blocker.recheckCount > rechecks, "and the app in front is decided again")
    }
}

@MainActor
private func testABreakWindowClosingDecidesTheFrontAppAgain() {
    withTempDir { dir in
        let breakHour = window(.break, weekdays: [2, 3, 4, 5, 6], from: 600, to: 660)
        try? Store(directory: dir).saveConfig(countdownConfig(windows: [breakHour]))
        let clock = FakeClock(august(10, 10, 59))          // Monday, a minute before 11:00
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()
        blocker.frontmost = "com.apple.Notes"

        expect(state.budgetsByGroup.first?.isOpen == true, "the break window has the group open")
        let rechecks = blocker.recheckCount
        tick(state, clock, seconds: 61)
        expect(state.budgetsByGroup.first?.isOpen == false, "11:00 closes it")
        expect(blocker.recheckCount > rechecks, "and the app in front is decided again")
    }
}

/// The other half of the contract: a second in which nothing changed tells the blocker nothing,
/// or the 1 Hz loop would be asking `NSWorkspace` about the front app all day.
@MainActor
private func testAQuietSecondDecidesNothing() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(countdownConfig())
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()
        blocker.frontmost = "com.apple.Notes"

        let rechecks = blocker.recheckCount
        tick(state, clock, seconds: 10)
        expectEqual(blocker.recheckCount, rechecks, "ten quiet seconds recheck nothing")
    }
}

// MARK: - The end of a session

/// One-minute sessions with no wait and no cooldown: the end of a session leaves the group at
/// `.opensByItself`, so the next open is spent on arrival rather than met with a screen.
private func silentConfig(pauseSeconds: Int) -> Config {
    var settings = GroupSettings.standard
    settings.pauseSeconds = pauseSeconds
    settings.escalationSeconds = 0
    settings.cooldownMinutes = 0
    settings.sessionMinutes = 1
    let app = Target(kind: .app, value: "com.apple.Notes", displayName: "Notes", groupID: "grp:demo")
    return Config(version: 1, targets: [app], groupSettings: ["grp:demo": settings])
}

@MainActor
private func endOneSession(pauseSeconds: Int) -> (RecordingBlocker, AppState, Int) {
    var result: (RecordingBlocker, AppState, Int)!
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(silentConfig(pauseSeconds: pauseSeconds))
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()
        blocker.frontmost = "com.apple.Notes"
        let target = state.config.targets[0]
        if case .granted = state.consumeOpen(targetID: target.id) {} else {
            expect(false, "the open is granted")
        }
        let rechecks = blocker.recheckCount
        tick(state, clock, seconds: 61)
        result = (blocker, state, rechecks)
    }
    return result
}

@MainActor
private func testASessionEndingOnAGroupThatOpensByItselfSendsNothingAway() {
    let (blocker, state, rechecks) = endOneSession(pauseSeconds: 0)
    expectEqual(
        state.blockDecision(forBundleID: "com.apple.Notes"), .opensByItself,
        "the session is over and the next open is a silent one"
    )
    expectEqual(blocker.hidden, [], "so Notes is not sent away only to open by itself again")
    expect(blocker.recheckCount > rechecks, "it is decided again instead, which spends that open")
}

@MainActor
private func testASessionEndingOnAGroupWithAScreenStillSendsItsAppsAway() {
    let (blocker, _, _) = endOneSession(pauseSeconds: 15)
    expectEqual(blocker.hidden, ["com.apple.Notes"], "a group with a screen still sends its apps away")
}
