import SandglassAppCore
import Foundation

// What happens to an application that is blocked with no way through. The calls into macOS are
// `AppHider` and cannot be reached from here — the test target does not link the executable — so
// what is pinned is the decision: which rungs are worth trying, in what order, and what counts as
// the app having actually gone away.

func runHideLadderTests() {
    fullscreenStep()
    sendAwayStep()
    theEscalationJoinsStepOne()
    wentAway()
    severalInstancesOfOneApp()
    exemptions()
}

// MARK: - Step one: coming out of fullscreen

private func fullscreenStep() {
    expectEqual(
        HideLadder.fullscreenRungs(
            accessibilityTrusted: true, isFullscreen: true, isFrontmost: true
        ),
        [.leaveFullscreen, .sendExitFullscreen, .spaceLeft],
        "fullscreen and frontmost tries all three, attribute write first"
    )
    // The two shortcuts are synthetic key events and a key event goes to whoever holds the
    // keyboard. Offering them for an app that is not in front would toggle *another* app's
    // fullscreen, or move the user's Space out from under them.
    expectEqual(
        HideLadder.fullscreenRungs(
            accessibilityTrusted: true, isFullscreen: true, isFrontmost: false
        ),
        [.leaveFullscreen],
        "not frontmost gets the attribute write and neither keystroke"
    )
    expectEqual(
        HideLadder.fullscreenRungs(
            accessibilityTrusted: true, isFullscreen: false, isFrontmost: true
        ),
        [],
        "nothing to come out of, so nothing is tried"
    )
    // The one that matters most: ⌃⌘F sent to a window that was not in fullscreen puts it *into*
    // fullscreen, so an unreadable answer has to be read as "not fullscreen".
    expectEqual(
        HideLadder.fullscreenRungs(
            accessibilityTrusted: true, isFullscreen: nil, isFrontmost: true
        ),
        [],
        "unknown is read as not fullscreen, so no keystroke is ever sent on a guess"
    )
    expectEqual(
        HideLadder.fullscreenRungs(
            accessibilityTrusted: false, isFullscreen: true, isFrontmost: true
        ),
        [],
        "without the Accessibility grant this step does not exist"
    )
}

// MARK: - Step two: sending it away

private func sendAwayStep() {
    expectEqual(
        HideLadder.sendAwayRungs(accessibilityTrusted: true),
        [.hide, .minimizeWindows],
        "hide first, minimise as the fallback"
    )
    // The rung that survives a stale grant, which is the case this whole thing has to hold in.
    expectEqual(
        HideLadder.sendAwayRungs(accessibilityTrusted: false),
        [.hide],
        "hide() needs no permission and is never dropped"
    )
    expect(
        !HideLadder.sendAwayRungs(accessibilityTrusted: false).isEmpty,
        "there is always something to try"
    )
    // Nothing on either step terminates anything: that is ruled out by design, so the rung does
    // not exist to be reached by accident.
    expect(
        !HideRung.allCases.contains { $0.rawValue.lowercased().contains("terminate") },
        "no rung terminates an app"
    )
}

// MARK: - Where the escalation's rungs go

private func theEscalationJoinsStepOne() {
    // The ordinary answer for an app whose read would not come back: nothing at all. The
    // escalation is the whole of step one for exactly that app.
    expectEqual(
        HideLadder.ordered(
            escalation: [.leaveFullscreen, .sendExitFullscreen],
            ordinary: HideLadder.fullscreenRungs(
                accessibilityTrusted: true, isFullscreen: nil, isFrontmost: true
            )
        ),
        [.leaveFullscreen, .sendExitFullscreen],
        "an unreadable app gets the escalation's rungs and no others"
    )
    // Where they do meet, the escalation leads — it is offered only about an app that has been
    // sent away once and stood there anyway — and nothing is climbed twice.
    expectEqual(
        HideLadder.ordered(
            escalation: [.leaveFullscreen, .spaceLeft],
            ordinary: [.leaveFullscreen, .sendExitFullscreen, .spaceLeft]
        ),
        [.leaveFullscreen, .spaceLeft, .sendExitFullscreen],
        "the escalation leads and nothing appears twice"
    )
    expectEqual(
        HideLadder.ordered(escalation: [], ordinary: [.leaveFullscreen]),
        [.leaveFullscreen],
        "no escalation leaves the ordinary step exactly as it was"
    )
    expectEqual(
        HideLadder.ordered(escalation: [], ordinary: []),
        [],
        "and nothing plus nothing is still nothing"
    )
}

// MARK: - Whether it actually went

private func wentAway() {
    expect(
        !HideLadder.wentAway(wasFullscreen: false, leftFullscreen: false, sentAway: false),
        "nothing was sent away, so nothing went away"
    )
    expect(
        HideLadder.wentAway(wasFullscreen: false, leftFullscreen: false, sentAway: true),
        "an ordinary window that was hidden is gone"
    )
    // The whole reason this is not just "did hide() return true": hide() answers true for an app
    // that owns a fullscreen Space and leaves the Space standing. Writing that down as a hide
    // would make the next recheck ignore a frontmost reading that is not stale at all, and
    // swallow the pause screen a relock had just earned.
    expect(
        !HideLadder.wentAway(wasFullscreen: true, leftFullscreen: false, sentAway: true),
        "hidden but still in its own Space is not gone"
    )
    expect(
        HideLadder.wentAway(wasFullscreen: true, leftFullscreen: true, sentAway: true),
        "out of fullscreen and hidden is gone"
    )
    expect(
        HideLadder.wentAway(wasFullscreen: nil, leftFullscreen: false, sentAway: true),
        "nobody could tell it was fullscreen, so the hide is the whole story"
    )
}

// MARK: - Several running instances behind one bundle id

private func severalInstancesOfOneApp() {
    expectEqual(
        HideOutcome.folded([]), .nothing, "nothing behind that id was there to hide"
    )
    expectEqual(
        HideOutcome.folded([
            HideOutcome(wentAway: false, fullscreenRead: nil),
            HideOutcome(wentAway: true, fullscreenRead: nil),
        ]),
        HideOutcome(wentAway: true, fullscreenRead: nil),
        "the question was about a bundle id, and something behind it moved"
    )
    // Erring towards `true` and `nil` is erring towards escalating, which is the direction the
    // sweep is going in; erring towards `false` would silence the keystrokes again.
    expectEqual(
        HideOutcome.folded([
            HideOutcome(wentAway: true, fullscreenRead: false),
            HideOutcome(wentAway: true, fullscreenRead: true),
        ]).fullscreenRead,
        true,
        "one instance in fullscreen makes the whole id fullscreen"
    )
    expectEqual(
        HideOutcome.folded([
            HideOutcome(wentAway: true, fullscreenRead: nil),
            HideOutcome(wentAway: true, fullscreenRead: false),
        ]).fullscreenRead,
        false,
        "an instance that answered outranks one that would not"
    )
    expectNil(
        HideOutcome.folded([
            HideOutcome(wentAway: true, fullscreenRead: nil),
            HideOutcome(wentAway: true, fullscreenRead: nil),
        ]).fullscreenRead,
        "and it is unknown only when nobody answered at all"
    )
}

// MARK: - The apps that are never hidden

private func exemptions() {
    let running = "io.github.moritzthln.sandglass.dev"

    expect(
        !HideExemptions.mayHide(
            bundleID: HideExemptions.packagedBundleID, isRegularApp: true, runningBundleID: running
        ),
        "Sandglass's packaged id is never hidden"
    )
    // A development build has an id of its own, and a rule that only knew the packaged one would
    // let the blocker hide itself in exactly the runs it is tested in.
    expect(
        !HideExemptions.mayHide(bundleID: running, isRegularApp: true, runningBundleID: running),
        "the running binary's own id is never hidden either"
    )
    expect(
        !HideExemptions.mayHide(
            bundleID: "com.apple.finder", isRegularApp: true, runningBundleID: running
        ),
        "Finder is never hidden, so files stay reachable"
    )
    expect(
        !HideExemptions.mayHide(
            bundleID: "com.apple.systempreferences", isRegularApp: true, runningBundleID: running
        ),
        "System Settings is never hidden, so the permission panes stay reachable"
    )
    // Background agents and helpers are not apps anybody is looking at; hiding one achieves
    // nothing and risks something.
    expect(
        !HideExemptions.mayHide(
            bundleID: "com.example.helper", isRegularApp: false, runningBundleID: running
        ),
        "only a regular app is ever touched"
    )
    expect(
        !HideExemptions.mayHide(bundleID: nil, isRegularApp: true, runningBundleID: running),
        "an app with no bundle id is nothing a rule could name"
    )
    expect(
        HideExemptions.mayHide(
            bundleID: "com.apple.Safari", isRegularApp: true, runningBundleID: running
        ),
        "an ordinary app is hidden"
    )
    expect(
        !HideExemptions.mayHide(
            bundleID: "com.apple.ActivityMonitor", isRegularApp: true, runningBundleID: running
        ),
        "Activity Monitor is the way out of a block that has gone wrong, and is never hidden"
    )
    // Nothing switches the exemptions off, so the set is the whole of the promise.
    expectEqual(
        HideExemptions.essentialBundleIDs,
        [
            "io.github.moritzthln.sandglass", "com.apple.finder", "com.apple.systempreferences",
            "com.apple.ActivityMonitor",
        ],
        "the exempt set is exactly the four"
    )
}
