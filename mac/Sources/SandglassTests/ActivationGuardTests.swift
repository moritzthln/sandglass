import SandglassAppCore
import Foundation

/// The two guards that decide whether a frontmost application is news.
///
/// Small types, but the whole of gentle mode's usability sits on the first one and the
/// honesty of the dismissal count sits on the second, so both are pinned here rather than
/// left to a live run on somebody's Mac.
func runActivationGuardTests() {
    testGraceForgivesExactlyOneActivation()
    testPeekingAtTheGraceDoesNotSpendIt()
    testTheGraceNamesItsOwnApp()
    testGraceIsBoundToItsOwnApp()
    testGraceExpires()
    testGraceIsReplacedByTheNextOpen()
    testHiddenAppIsIgnoredOnlyBriefly()
    testHiddenAppIsForgottenOnPurpose()
    testAHideThatWasRefusedSuppressesNothing()
}

private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

// MARK: - ActivationGrace

/// The gentle loop this exists to break: an open grants no session, so the activation the
/// open itself performs would walk straight back into the same pause screen.
private func testGraceForgivesExactlyOneActivation() {
    var grace = ActivationGrace()
    expect(!grace.consume(bundleID: "com.apple.Notes", now: t0), "nothing is forgiven by default")

    grace.grant(bundleID: "com.apple.Notes", until: at(2))
    expect(
        grace.consume(bundleID: "com.apple.Notes", now: at(0.1)),
        "the activation the open performed is forgiven"
    )
    expect(
        !grace.consume(bundleID: "com.apple.Notes", now: at(0.2)),
        "and the next one is not — a second visit is a second pause screen"
    )
}

/// A recheck is a question nobody pressed a button for, so it may look at the grace but not
/// spend it — otherwise the activation the grace was granted for arrives unprotected, and a
/// gentle group meets the pause screen it just paid to clear.
private func testPeekingAtTheGraceDoesNotSpendIt() {
    var grace = ActivationGrace()
    expect(!grace.isPending(bundleID: "com.apple.Notes", now: t0), "nothing is pending by default")

    grace.grant(bundleID: "com.apple.Notes", until: at(2))
    expect(grace.isPending(bundleID: "com.apple.Notes", now: at(0.1)), "the grace is visible")
    expect(
        grace.isPending(bundleID: "com.apple.Notes", now: at(0.2)),
        "and looking at it twice does not use it up"
    )
    expect(
        grace.consume(bundleID: "com.apple.Notes", now: at(0.3)),
        "so the activation it was granted for still finds it"
    )
    expect(
        !grace.isPending(bundleID: "com.apple.Notes", now: at(0.4)),
        "and only then is it gone"
    )
}

/// The sweep walks a list of applications rather than asking about one, so it needs the grace
/// the other way round: which app has one outstanding. Still a peek — nothing is spent.
private func testTheGraceNamesItsOwnApp() {
    var grace = ActivationGrace()
    expectNil(grace.pendingBundleID(now: t0), "nobody has a grace by default")

    grace.grant(bundleID: "com.apple.Notes", until: at(2))
    expectEqual(
        grace.pendingBundleID(now: at(0.1)), "com.apple.Notes", "the grace names the app it is for"
    )
    expectNil(grace.pendingBundleID(now: at(3)), "and stops naming it when it runs out")

    grace.grant(bundleID: "com.apple.Notes", until: at(6))
    expectEqual(grace.pendingBundleID(now: at(5)), "com.apple.Notes", "asking does not spend it")
    expect(grace.consume(bundleID: "com.apple.Notes", now: at(5)), "the activation still finds it")
    expectNil(grace.pendingBundleID(now: at(5)), "and only the activation uses it up")
}

/// An app stealing focus between the open and its activation must not spend the grace: the
/// user has already paid for that open.
private func testGraceIsBoundToItsOwnApp() {
    var grace = ActivationGrace()
    grace.grant(bundleID: "com.apple.Notes", until: at(2))

    expect(
        !grace.consume(bundleID: "net.whatsapp.WhatsApp", now: at(0.1)),
        "another app's activation is not the forgiven one"
    )
    expect(
        grace.consume(bundleID: "com.apple.Notes", now: at(0.2)),
        "and it did not spend the grace either"
    )
}

private func testGraceExpires() {
    var grace = ActivationGrace()
    grace.grant(bundleID: "com.apple.Notes", until: at(2))
    expect(
        !grace.consume(bundleID: "com.apple.Notes", now: at(2)),
        "a grace nobody used is not owed forever"
    )
}

private func testGraceIsReplacedByTheNextOpen() {
    var grace = ActivationGrace()
    grace.grant(bundleID: "com.apple.Notes", until: at(2))
    grace.grant(bundleID: "com.apple.Safari", until: at(3))

    expect(!grace.consume(bundleID: "com.apple.Notes", now: at(1)), "only the last open counts")
    expect(grace.consume(bundleID: "com.apple.Safari", now: at(1)), "and it is the one forgiven")
}

// MARK: - RecentlyHidden

/// macOS keeps naming a hidden app as frontmost for about a second. A session ending fires a
/// recheck inside that gap, and believing it would raise a blocked screen over an app nobody
/// is looking at — whose only exit would log a dismissal the user never chose.
private func testHiddenAppIsIgnoredOnlyBriefly() {
    var hidden = RecentlyHidden(window: 2)
    expect(!hidden.isRecent("com.apple.Notes", now: t0), "an app nobody hid is never stale")

    hidden.record("com.apple.Notes", at: t0)
    expect(hidden.isRecent("com.apple.Notes", now: at(1.9)), "the stale reading is ignored")
    expect(!hidden.isRecent("com.apple.Notes", now: at(2)), "but only for as long as it is stale")
    expect(!hidden.isRecent("com.apple.Safari", now: at(1)), "and only for the app that was hidden")
}

/// The relock case that must keep working: the user goes straight back into the app that was
/// just hidden, and has to meet the cooldown screen rather than nothing at all.
private func testHiddenAppIsForgottenOnPurpose() {
    var hidden = RecentlyHidden(window: 2)
    hidden.record("com.apple.Notes", at: t0)

    hidden.forget("com.apple.Notes")
    expect(
        !hidden.isRecent("com.apple.Notes", now: at(0.5)),
        "a real activation ends the suppression, even inside the window"
    )
}

/// The caller's half of the same contract, stated from this side because the caller cannot be
/// reached from here: `AppBlocker.hideApp` records only when `NSRunningApplication.hide()`
/// actually returned true for some instance. A refused hide — an app owning a fullscreen Space
/// is the case that happens — records nothing, and this is what "nothing" then does: it
/// suppresses no recheck at all, so the relock pause screen appears over the Space instead of
/// waiting for the user to switch away and back.
private func testAHideThatWasRefusedSuppressesNothing() {
    var hidden = RecentlyHidden(window: 2)
    // No `record`, because macOS declined to hide anything.
    expect(
        !hidden.isRecent("com.apple.Notes", now: t0),
        "an app that never went away is not a stale frontmost reading"
    )
    expect(
        !hidden.isRecent("com.apple.Notes", now: at(1)),
        "and stays that way for the whole window the recheck would have skipped"
    )
}
