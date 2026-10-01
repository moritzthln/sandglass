import SandglassAppCore
import SandglassCore
import Foundation

/// The wait in front of the Unblock card: when it starts, when it lets go, and what makes it
/// start over.
///
/// Two layers, the way the pause friction is tested. The first cases drive `BreakWaitGate`, which
/// is pure arithmetic on two readings, so the boundary seconds can be stated outright. The last
/// four drive a whole `AppState`, which is what proves the wiring — that the window's own seam
/// starts and resets it, and that both of the things it stands in front of are held by exactly
/// one condition.
func runBreakWaitTests() {
    testAnUnannouncedWindowOwesTheWholeWait()
    testTheWaitRunsFromTheWindowOpening()
    testAWaitOfNoughtIsLiveAtOnce()
    testClosingTheWindowStartsTheWaitOver()
    testReopeningAnOpenWindowDoesNotDisturbTheWait()
    testTheConfiguredWaitIsReadEveryTime()
    MainActor.assumeIsolated {
        testTheCardIsInertUntilTheWindowsWaitRunsOut()
        testTheWaitsOwnSettingIsHeldByTheWaitItSets()
        testAConfiguredNoughtLetsTheCardStraightThrough()
        testClosingTheWindowPutsTheWaitBackOnTheCard()
    }
}

/// Fail-closed, the same rule the settings lock's timer follows: the card lives in a window that
/// announces itself, so nothing open means a path that forgot rather than a card to wave through.
private func testAnUnannouncedWindowOwesTheWholeWait() {
    let gate = BreakWaitGate()
    expectEqual(
        gate.secondsLeft(waitSeconds: 30, at: reading(at: noon)), 30,
        "with no window open the whole wait is owed"
    )
}

private func testTheWaitRunsFromTheWindowOpening() {
    var gate = BreakWaitGate()
    gate.windowOpened(at: reading(at: noon))

    expectEqual(
        gate.secondsLeft(waitSeconds: 30, at: reading(at: noon)), 30,
        "the card opens inert, with the whole wait in front of it"
    )
    expectEqual(
        gate.secondsLeft(waitSeconds: 30, at: reading(at: noon.addingTimeInterval(12))), 18,
        "and counts down while the window is open"
    )
    expectEqualText(
        BreakWaitGate.waitText(18), "You can unblock in 0:18",
        "in the app's one countdown shape"
    )
    expectNil(
        gate.secondsLeft(waitSeconds: 30, at: reading(at: noon.addingTimeInterval(30))),
        "the thirtieth second is where it lets go"
    )
    expectNil(
        gate.secondsLeft(waitSeconds: 30, at: reading(at: noon.addingTimeInterval(6_000))),
        "and it stays let go for the rest of the visit"
    )
}

/// Zero is the setting's soft door: somebody who asked for no wait has decided, and the gate does
/// not argue — not even with the fail-closed rule above, which exists to stop a wait being skipped
/// rather than to stop one being declined.
private func testAWaitOfNoughtIsLiveAtOnce() {
    var gate = BreakWaitGate()
    expectNil(
        gate.secondsLeft(waitSeconds: 0, at: reading(at: noon)),
        "a wait of nought is over before any window opens"
    )
    gate.windowOpened(at: reading(at: noon))
    expectNil(
        gate.secondsLeft(waitSeconds: 0, at: reading(at: noon)),
        "and the window opening does not invent one"
    )
}

/// Otherwise the wait could be started, abandoned and collected later: open the window, walk away,
/// come back to a card that is already live.
private func testClosingTheWindowStartsTheWaitOver() {
    var gate = BreakWaitGate()
    gate.windowOpened(at: reading(at: noon))
    expectNil(
        gate.secondsLeft(waitSeconds: 30, at: reading(at: noon.addingTimeInterval(30))),
        "the wait is waited out"
    )

    gate.windowClosed()
    let hourLater = noon.addingTimeInterval(3_600)
    expectEqual(
        gate.secondsLeft(waitSeconds: 30, at: reading(at: hourLater)), 30,
        "and closing the window puts the whole thing back"
    )
    gate.windowOpened(at: reading(at: hourLater))
    expectEqual(
        gate.secondsLeft(waitSeconds: 30, at: reading(at: hourLater.addingTimeInterval(29))), 1,
        "the next visit counts from its own open"
    )
}

/// Asking for a window that is already up brings it forward rather than opening a second, and the
/// same call arrives every time. Restarting the wait on one would let the menu lengthen it.
private func testReopeningAnOpenWindowDoesNotDisturbTheWait() {
    var gate = BreakWaitGate()
    gate.windowOpened(at: reading(at: noon))
    gate.windowOpened(at: reading(at: noon.addingTimeInterval(20)))
    expectEqual(
        gate.secondsLeft(waitSeconds: 30, at: reading(at: noon.addingTimeInterval(20))), 10,
        "the wait already running is left alone"
    )
}

/// The configured number is read on every question rather than copied when the window opened,
/// which is what makes a raised wait real at once — and a lowered one already spent.
private func testTheConfiguredWaitIsReadEveryTime() {
    var gate = BreakWaitGate()
    gate.windowOpened(at: reading(at: noon))
    let after = reading(at: noon.addingTimeInterval(30))

    expectNil(gate.secondsLeft(waitSeconds: 30, at: after), "thirty seconds buys a thirty-second wait")
    expectEqual(
        gate.secondsLeft(waitSeconds: 600, at: after), 570,
        "raised to ten minutes, the rest of it is owed from this second"
    )
    expectNil(
        gate.secondsLeft(waitSeconds: 10, at: after),
        "and lowering it re-locks nothing: those seconds were spent either way"
    )
}

// MARK: - The card, through a whole AppState

// The six cases above drive the gate, where the arithmetic is. These drive the wiring: the window
// seam that starts the wait, the loop that publishes it, and the two actions it holds.

/// Inert before, live after. The countdown is the only thing the card has to show while it runs,
/// and a break asked for anyway is refused in the same words rather than quietly granted — a wait
/// a screen enforces by greying something out is a suggestion.
@MainActor
private func testTheCardIsInertUntilTheWindowsWaitRunsOut() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()

        state.settingsWindowOpened()
        expectEqual(state.breakWaitSecondsLeft, 30, "the card opens on the whole wait")
        expectEqual(
            state.startBreak(minutes: 10), "You can unblock in 0:30",
            "and a break asked for during it is refused"
        )
        expectNil(state.breakEnd, "with nothing unblocked")

        for _ in 0..<29 { clock.advance(seconds: 1); state.tickForTesting() }
        expectEqual(state.breakWaitSecondsLeft, 1, "the countdown runs while the window is open")
        clock.advance(seconds: 1)
        state.tickForTesting()
        expectNil(state.breakWaitSecondsLeft, "and lets go on the thirtieth second")

        expectNil(state.startBreak(minutes: 10), "then a length can be picked")
        expect(state.breakEnd != nil, "and everything is unblocked")
    }
}

/// The row that sets the wait is held by exactly the condition the length picker is held by, which
/// is what makes the number a commitment rather than a preference: shortening the friction costs
/// the friction one last time.
@MainActor
private func testTheWaitsOwnSettingIsHeldByTheWaitItSets() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()

        state.settingsWindowOpened()
        expectEqual(
            state.setBreakWaitSeconds(0), "You can unblock in 0:30",
            "the wait cannot be shortened from inside itself"
        )
        expectEqual(
            state.setBreakWaitSeconds(0), state.startBreak(minutes: 10),
            "and it is refused in exactly the words the length picker is"
        )
        expectEqual(state.config.breakWaitSeconds, 30, "with the number left where it was")

        clock.advance(seconds: 30)
        state.tickForTesting()
        expectNil(state.setBreakWaitSeconds(0), "waited out, the number can be changed")
        expectEqual(state.config.breakWaitSeconds, 0, "and it is what was asked for")
    }
}

/// Nought means no wait, and it means it from the second the window opens. This is the soft door:
/// somebody who set it to zero has decided, and the app does not argue.
@MainActor
private func testAConfiguredNoughtLetsTheCardStraightThrough() {
    withTempDir { dir in
        var config = webConfig()
        config.breakWaitSeconds = 0
        try? Store(directory: dir).saveConfig(config)
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()

        state.settingsWindowOpened()
        expectNil(state.breakWaitSecondsLeft, "the card opens live")
        expectNil(state.startBreak(minutes: 10), "and a break goes through at once")
        expect(state.breakEnd != nil, "with everything unblocked")
    }
}

/// Otherwise the wait could be started, abandoned and collected later — the gap waited out
/// somewhere else rather than crossed.
@MainActor
private func testClosingTheWindowPutsTheWaitBackOnTheCard() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()

        afterTheUnblockWait(state, clock)
        state.tickForTesting()
        expectNil(state.breakWaitSecondsLeft, "the visit waits its wait out")

        state.settingsWindowClosed()
        expectEqual(state.breakWaitSecondsLeft, 30, "and closing the window puts the whole thing back")
        expectEqual(
            state.startBreak(minutes: 10), "You can unblock in 0:30",
            "so the next visit pays for its own break"
        )
        expectNil(state.breakEnd, "with nothing unblocked")
    }
}

// MARK: - Fixtures

/// Wall and uptime moving together, which is every case here: none of them is about the clock
/// being changed, and `ClockReading.secondsSince` measures on uptime.
private func reading(at wall: Date) -> ClockReading {
    ClockReading(wall: wall, uptime: 10_000 + wall.timeIntervalSince(noon))
}
