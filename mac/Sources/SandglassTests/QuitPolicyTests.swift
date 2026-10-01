import SandglassAppCore
import SandglassCore
import Foundation

/// Strict enforcement, from the app's side: whether Sandglass may be quit, and whether it comes
/// back after it goes away.
///
/// **The first half is now always yes**, by a deliberate decision — see `QuitPolicy`. Half of this
/// file used to pin the refusal and
/// the hour it named; those cases are still here, standing in exactly the same blocks, asserting
/// that the app goes away anyway — a rule nobody exercises is a rule nobody notices has changed.
/// Every one of them is driven through the real engine with a real block standing, and says so
/// with a second assertion, because "quit is allowed" is the answer a test that built nothing
/// would also get.
///
/// Both halves are rules rather than pixels, so both are here rather than in a manual test.
/// What is *not* here is `LaunchAgentManager` itself — the plist it writes and the drift it
/// corrects are pinned in `LaunchAgentTests`, and whether launchd accepts the job is
/// `mac/scripts/test-keepalive.sh`'s. What this file pins is everything on the app's side of the
/// seam.
func runQuitPolicyTests() {
    MainActor.assumeIsolated {
        testQuitIsAllowedWhenNothingIsLocked()
        testQuitGoesThroughInsideAStrictWindow()
        testQuitGoesThroughDuringAFocusSession()
        testAnEmergencyPassLiftsWhatAFocusSessionHolds()
        testAFocusSessionAndAScheduleTogetherStillLetTheAppGo()
                testAStrictWindowNoLongerOutranksAnInstalledAgent()
        testASystemInitiatedQuitIsNeverAskedAnything()
        testQuitAsksBeforeAnAgentBringsTheAppBack()
        testAPausedProtectionDoesNotUnlockQuitting()
        testARefusedAgentLeavesTheToggleHonest()
        testARefusedRemovalLeavesTheToggleOn()
        testKeepAliveIsReadFromTheAgentAtLaunch()
    }
}

// MARK: - Who may quit

@MainActor
private func testQuitIsAllowedWhenNothingIsLocked() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        expectEqual(state.quitDecision(), .allowed, "an ordinary afternoon is quittable")
    }
}

/// The case that used to read "quitting inside a strict window is refused, and says until when".
///
/// The block is real and is still doing its job — the group is blocked on the schedule — and the
/// app goes away regardless. Refusing the quit bought nothing: the window lives in `config.json`,
/// so it is still standing when the app comes back.
@MainActor
private func testQuitGoesThroughInsideAStrictWindow() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let state = makeState(dir, clock: FakeClock(august(11, 10, 30)))   // inside 10:00-11:00
        state.prime()

        expectEqual(
            state.budgetsByGroup.first?.line, "Blocked until 11:00",
            "the window is standing, and the group is blocked by it"
        )
        expectEqual(
            state.quitDecision(), .allowed,
            "and quitting is not one of the things it holds"
        )
    }
}

@MainActor
private func testQuitGoesThroughDuringAFocusSession() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        state.startFocusSession(minutes: 25)

        expectEqual(
            state.focusSessionLine, "Everything is blocked until 12:25",
            "everything is blocked, and the app says so"
        )
        expectEqual(
            state.quitDecision(), .allowed,
            "and the app may still be quit — it comes back within seconds, and the block with it"
        )
    }
}

/// The pass lifts every block in the app, and quitting is no longer one of the things it lifts,
/// because quitting was not held. What the pass does to the rest is still pinned here: nothing in
/// `QuitPolicy` mentions it, and nothing else has to be told twice.
@MainActor
private func testAnEmergencyPassLiftsWhatAFocusSessionHolds() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()
        state.startFocusSession(minutes: 4 * 60)
        expectEqual(state.quitDecision(), .allowed, "the four-hour block does not hold the quit")
        expect(state.useEmergencyPass(), "the pass is spent")

        expectEqual(state.quitDecision(), .allowed, "and it is no more allowed than it already was")
        expectNil(state.focusSessionLine, "nothing on screen says everything is blocked")
        expectEqual(
            state.heldFocusSessionLine, "Blocking everything again at 13:00, until 16:00",
            "but the card that started it says what is waiting, and both ends of it"
        )
        expectNil(state.pauseBlockedReason, "and a break is no longer refused by a lifted block")

        // The line is published rather than derived on demand, so it wants the beat that
        // republishes it — unlike the quit decision, which is worked out when it is asked.
        clock.advance(seconds: 3600 + 1)
        state.tickForTesting()
        expectEqual(
            state.focusSessionLine, "Everything is blocked until 16:00",
            "the hour over, the session that is left blocks everything again"
        )
        expectEqual(state.quitDecision(), .allowed, "and still does not hold the quit")
    }
}

/// Both kinds of block at once — a focus session running past the end of a strict window — which
/// used to be the case that decided *which* of them the refusal named. There is no refusal to
/// name anything now; what is left to pin is that two of them together are not one of them twice.
@MainActor
private func testAFocusSessionAndAScheduleTogetherStillLetTheAppGo() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        // 10:45, inside the 10:00-11:00 window, with a focus session running past its end.
        let state = makeState(dir, clock: FakeClock(august(11, 10, 45)))
        state.prime()
        state.startFocusSession(minutes: 30)

        expectEqual(
            state.focusSessionLine, "Everything is blocked until 11:15",
            "the session outlasts the window it is standing in"
        )
        expectNil(state.resetTodaysCounters(), "and holds no undo — it blocks and nothing more")
        expectEqual(state.quitDecision(), .allowed, "and the app may still be quit")
    }
}
/// This case is inverted, and the inversion is the decision. A lock used to have to win here, or
/// "a strict window is answerable with a dialog that has a Quit button in it" — which is now
/// exactly what happens, on purpose. The dialogue is honest about the only thing still true: the
/// agent brings the app back within seconds.
@MainActor
private func testAStrictWindowNoLongerOutranksAnInstalledAgent() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let state = makeState(
            dir, clock: FakeClock(august(11, 10, 30)), keepAlive: RecordingKeepAlive(installed: true)
        )
        state.prime()

        expect(state.keepAliveEnabled, "the agent is installed")
        expectEqual(
            state.quitDecision(), .confirmKeepAlive,
            "and inside a strict window the answer is the keep-alive question, not a refusal"
        )
    }
}

/// A logout, a restart and a shutdown are the system asking, and the difference that still matters
/// is the dialogue: a user's quit is worth one question, a shutdown sequence is not — macOS gives
/// an app seconds to answer and a modal alert does not answer.
///
/// Whether a given quit request *is* one of those is `AppDelegate`'s to work out from the Apple
/// event, and cannot be reached without really logging the user out. What is pinned here is that
/// the answer, once worked out, skips the question — from the strictest state the app can be in.
@MainActor
private func testASystemInitiatedQuitIsNeverAskedAnything() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let state = makeState(
            dir, clock: FakeClock(august(11, 10, 30)), keepAlive: RecordingKeepAlive(installed: true)
        )
        state.prime()
        state.startFocusSession(minutes: 60)   // ends 11:30, past the window's own 11:00

        expectEqual(
            state.quitDecision(), .confirmKeepAlive,
            "a focus session inside a strict window still lets the user's own quit through, asking"
        )
        expectEqual(
            state.quitDecision(systemInitiated: true), .allowed,
            "and the same second lets a logout straight through — no dialog to stall it"
        )
    }
}

/// A protection pause turns the engine off, and it must not turn the quit policy off with it —
/// but nothing is left for it to turn off, so what is pinned is that a pause on an ordinary
/// afternoon leaves quitting exactly as allowed as it already was.
@MainActor
private func testAPausedProtectionDoesNotUnlockQuitting() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()
        afterTheUnblockWait(state, clock)
        expectNil(state.startBreak(), "the wait is over and a break goes through")

        var paused = false
        if case .paused = state.statusKind { paused = true }
        expect(paused, "and protection is off")
        expectEqual(state.quitDecision(), .allowed, "quitting was already allowed and stays so")
    }
}

// MARK: - The agent that brings it back

@MainActor
private func testQuitAsksBeforeAnAgentBringsTheAppBack() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let agent = RecordingKeepAlive(installed: true)
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)
        state.prime()

        expectEqual(
            state.quitDecision(), .confirmKeepAlive,
            "quitting an app that re-opens itself is worth one question"
        )
        expectNil(
            state.setKeepAlive(false, requiring: .deliberateAction),
            "turning the agent off reports no problem"
        )
        expectEqual(agent.asked, [false], "and the manager was asked exactly once")
        expectEqual(state.quitDecision(), .allowed, "after which quitting is quitting")
    }
}

@MainActor
private func testKeepAliveIsReadFromTheAgentAtLaunch() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: RecordingKeepAlive(installed: true))

        expect(state.keepAliveEnabled, "an agent installed by a previous run shows as on")
    }
}

/// `launchctl` can decline. The toggle then has to go back to showing what is installed rather
/// than what was asked for, or the settings screen is lying about the one thing it exists for.
@MainActor
private func testARefusedAgentLeavesTheToggleHonest() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let agent = RecordingKeepAlive(refusal: "launchd said no")
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)
        state.prime()

        expectEqual(
            state.setKeepAlive(true, requiring: .deliberateAction), "launchd said no",
            "the reason reaches the screen"
        )
        expect(!state.keepAliveEnabled, "and the toggle shows what is actually installed")
        expectEqual(state.quitDecision(), .allowed, "nothing will bring the app back, so no question")
    }
}

/// The same rule in the other direction, and the direction that matters more. `launchctl bootout`
/// can decline, and a job that is still loaded goes on restarting the app within seconds — so the
/// toggle has to stay on. Showing "off" over a live agent would leave the user watching Sandglass
/// come back with nothing left on screen to switch off.
///
/// `LaunchAgentManager` is what keeps the two in step: it asks launchd whether the job is really
/// gone and keeps the plist when it is not. What is pinned here is the app's side of that seam.
@MainActor
private func testARefusedRemovalLeavesTheToggleOn() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let agent = RecordingKeepAlive(installed: true, refusal: "launchd still has the job")
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)
        state.prime()

        expectEqual(
            state.setKeepAlive(false, requiring: .deliberateAction), "launchd still has the job",
            "the reason reaches the screen"
        )
        expectEqual(agent.asked, [false], "the manager was asked exactly once")
        expect(state.keepAliveEnabled, "and the toggle still shows the agent that is still there")
        expectEqual(
            state.quitDecision(), .confirmKeepAlive,
            "so quitting still asks the question it exists for"
        )
    }
}
