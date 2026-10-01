import SandglassAppCore
import Foundation

// The state machine that decides what to try on an app a hide claimed to have sent away and which
// is still on screen. The calls into macOS are `AppHider` and cannot be reached from the test
// target; what is pinned is when a keystroke is earned, which one goes out, and what makes the
// evidence lapse.

func runFullscreenEscalationTests() {
    theRungTable()
    nothingIsEscalatedOnTheFirstAttempt()
    stillStandingEarnsTheKeystroke()
    onlyTheFrontmostAppIsSentKeyEvents()
    aWindowedReadNeverEarnsAKeystroke()
    theShortcutsTakeTurnsAndSettleInBetween()
    aRefusedHideEndsTheEvidence()
    theGrantGatesEverything()
    theEvidenceIsPerApp()
    itIsForgottenWhenTheAppGoes()
}

private let spotify = "com.spotify.client"
private let claude = "com.anthropic.claudefordesktop"

/// A machine with one app already stuck: a hide reported it gone, with the unreadable fullscreen
/// answer that is the whole reason this exists.
private func stuck(read: Bool? = nil, _ bundleID: String = spotify) -> FullscreenEscalation {
    var escalation = FullscreenEscalation()
    escalation.record(bundleID, wentAway: true, fullscreenRead: read)
    return escalation
}

/// One sweep tick against a stuck app: what it offers, having advanced the machine.
private func tick(
    _ escalation: inout FullscreenEscalation, _ bundleID: String = spotify,
    frontmost: Bool = true, trusted: Bool = true
) -> [HideRung] {
    escalation.rungs(
        forStillStanding: bundleID, isFrontmost: frontmost, accessibilityTrusted: trusted
    )
}

// MARK: - The rule on its own

private func theRungTable() {
    expectEqual(
        FullscreenEscalation.rungs(step: 0, mayPressKeys: true),
        [.leaveFullscreen, .sendExitFullscreen],
        "the first escalation tick writes the attribute and presses control-command-F"
    )
    // The exit animation runs about half a second and a second shortcut inside it toggles the app
    // straight back into fullscreen, which is a block that flickers instead of blocking.
    expectEqual(
        FullscreenEscalation.rungs(step: 1, mayPressKeys: true),
        [.leaveFullscreen],
        "the tick after a keystroke sends none, so an exit still animating is left alone"
    )
    // Never in the same list as control-command-F: `AppHider` stops at the first rung that works
    // and a posted key event always works, so the second would never be reached.
    expectEqual(
        FullscreenEscalation.rungs(step: 2, mayPressKeys: true),
        [.leaveFullscreen, .spaceLeft],
        "the next keystroke is the Space shortcut, on its own"
    )
    expectEqual(
        FullscreenEscalation.rungs(step: 3, mayPressKeys: true),
        [.leaveFullscreen],
        "and it settles again"
    )
    expectEqual(
        FullscreenEscalation.rungs(step: 4, mayPressKeys: true),
        [.leaveFullscreen, .sendExitFullscreen],
        "the cycle is four ticks long and starts over"
    )
    expectEqual(
        FullscreenEscalation.rungs(step: 0, mayPressKeys: false),
        [.leaveFullscreen],
        "with no keyboard to reach, only the direction-safe attribute write"
    )
    expectEqual(
        FullscreenEscalation.rungs(step: 7, mayPressKeys: false),
        [.leaveFullscreen],
        "however long it has stood there"
    )
}

// MARK: - The evidence

/// The rule the whole caution rests on: control-command-F at a window that is not in fullscreen
/// puts it *into* fullscreen, so it is never sent on a guess.
private func nothingIsEscalatedOnTheFirstAttempt() {
    var escalation = FullscreenEscalation()
    expectEqual(escalation.stage(of: spotify), .quiet, "nothing is known about a fresh app")
    expectEqual(
        tick(&escalation), [], "an app nothing has been tried on earns nothing at all"
    )
    // Even after a hide that worked: the app went, so there is no evidence against it.
    escalation.record(spotify, wentAway: true, fullscreenRead: nil)
    expectEqual(
        escalation.stage(of: spotify), .attempted,
        "the hide claimed it had gone, which the next tick judges"
    )
}

private func stillStandingEarnsTheKeystroke() {
    var escalation = stuck()
    expectEqual(
        tick(&escalation),
        [.leaveFullscreen, .sendExitFullscreen],
        "a hide that claimed success and an app still on screen is a stuck fullscreen Space"
    )
    expectEqual(escalation.stage(of: spotify), .pressing(1), "and the machine has moved on")
}

// MARK: - Where a key event may go

private func onlyTheFrontmostAppIsSentKeyEvents() {
    var escalation = stuck()
    expectEqual(
        tick(&escalation, frontmost: false),
        [.leaveFullscreen],
        "a background app gets the attribute write and no keystroke"
    )
    expectEqual(
        tick(&escalation, frontmost: false),
        [.leaveFullscreen],
        "and still none a second later"
    )
    // The step did not move while there was no keyboard to reach, so the moment the app comes
    // forward it presses the shortcut that matters rather than landing on a settling tick.
    expectEqual(
        escalation.stage(of: spotify), .pressing(0), "a background app never spends the cycle"
    )
    expectEqual(
        tick(&escalation, frontmost: true),
        [.leaveFullscreen, .sendExitFullscreen],
        "it presses control-command-F on the first tick it is actually in front"
    )
}

/// `nil` is an app that would not answer, which is the stuck case. `false` is Accessibility
/// looking at the windows and seeing none in fullscreen — a genuinely windowed app, and the one
/// place the shortcut would do the harm the whole caution is about.
private func aWindowedReadNeverEarnsAKeystroke() {
    var windowed = stuck(read: false)
    expectEqual(
        tick(&windowed),
        [.leaveFullscreen],
        "a read that saw the windows and found none fullscreen earns no keystroke"
    )
    expectEqual(
        tick(&windowed), [.leaveFullscreen], "and never does, however long it stands there"
    )
    expectEqual(windowed.stage(of: spotify), .pressing(0), "it does not spend the cycle either")

    var unreadable = stuck(read: nil)
    expectEqual(
        tick(&unreadable),
        [.leaveFullscreen, .sendExitFullscreen],
        "an app that would not answer is the case this exists for"
    )
    // A fullscreen read that came back true and a hide that still reported success: the app came
    // out and was hidden, so seeing it again is evidence like any other.
    var readable = stuck(read: true)
    expectEqual(
        tick(&readable),
        [.leaveFullscreen, .sendExitFullscreen],
        "a true read is no reason to hold back either"
    )
}

// MARK: - The cadence

private func theShortcutsTakeTurnsAndSettleInBetween() {
    var escalation = stuck()
    let eight = (1...8).map { _ in tick(&escalation) }
    expectEqual(
        eight,
        [
            [.leaveFullscreen, .sendExitFullscreen],
            [.leaveFullscreen],
            [.leaveFullscreen, .spaceLeft],
            [.leaveFullscreen],
            [.leaveFullscreen, .sendExitFullscreen],
            [.leaveFullscreen],
            [.leaveFullscreen, .spaceLeft],
            [.leaveFullscreen],
        ],
        "eight seconds of a stuck app: a keystroke every other one, the two taking turns"
    )
    expect(
        eight.allSatisfy { $0.first == .leaveFullscreen },
        "the direction-safe write leads every single tick"
    )
    expect(
        eight.allSatisfy { !($0.contains(.sendExitFullscreen) && $0.contains(.spaceLeft)) },
        "the two shortcuts are never offered together"
    )
    expect(
        !eight.contains { $0.contains(.hide) || $0.contains(.minimizeWindows) },
        "the escalation is about fullscreen only — sending away is the ordinary ladder's half"
    )
}

// MARK: - What ends it

private func aRefusedHideEndsTheEvidence() {
    var escalation = stuck()
    _ = tick(&escalation)
    expectEqual(escalation.stage(of: spotify), .pressing(1), "it is escalating")

    // A hide that was refused outright is a different problem: the fullscreen read answered true
    // and the app would not come out, which the ordinary ladder is already giving every rung.
    escalation.record(spotify, wentAway: false, fullscreenRead: true)
    expectEqual(escalation.stage(of: spotify), .quiet, "a refused hide is no claim to hold against")
    expectEqual(tick(&escalation), [], "so nothing is escalated on it")
}

private func theGrantGatesEverything() {
    var escalation = stuck()
    expectEqual(
        tick(&escalation, trusted: false),
        [],
        "without the Accessibility grant there is no rung to offer"
    )
    // The evidence keeps: revoking the grant is not a reason to forget what the app did.
    expectEqual(escalation.stage(of: spotify), .attempted, "and the evidence is not spent on it")
    expectEqual(
        tick(&escalation, trusted: true),
        [.leaveFullscreen, .sendExitFullscreen],
        "so the grant coming back escalates immediately"
    )
}

private func theEvidenceIsPerApp() {
    var escalation = FullscreenEscalation()
    escalation.record(spotify, wentAway: true, fullscreenRead: nil)
    expectEqual(escalation.stage(of: claude), .quiet, "one app's evidence says nothing about another")
    expectEqual(tick(&escalation, claude), [], "and earns it nothing")
    expectEqual(
        tick(&escalation, spotify),
        [.leaveFullscreen, .sendExitFullscreen],
        "while the one that is stuck escalates on its own"
    )
    expectEqual(escalation.stage(of: claude), .quiet, "still nothing against the other")
}

private func itIsForgottenWhenTheAppGoes() {
    var escalation = stuck()
    _ = tick(&escalation)
    escalation.forget(spotify)
    expectEqual(escalation.stage(of: spotify), .quiet, "an app that finally went is let go of")

    escalation.record(spotify, wentAway: true, fullscreenRead: nil)
    escalation.record(claude, wentAway: true, fullscreenRead: nil)
    // What the sweep calls once a tick: everything it no longer names has either gone away or
    // stopped being blocked, and neither is something to hold evidence about.
    escalation.forgetAll(except: [claude])
    expectEqual(escalation.stage(of: spotify), .quiet, "no longer swept, so no longer pressed")
    expectEqual(escalation.stage(of: claude), .attempted, "the one still standing keeps its record")

    escalation.forgetAll(except: [])
    expectEqual(escalation.stage(of: claude), .quiet, "and a quiet tick clears the last of it")
}
