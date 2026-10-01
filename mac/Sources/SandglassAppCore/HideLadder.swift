import Foundation

/// One thing the app can do to an application that is blocked with no way through.
///
/// **Never terminate.** A polite `terminate()` raises a save dialog on unsaved work and then
/// leaves the app open, which is a block that fails visibly, and `forceTerminate()` costs data.
/// Hiding is honest about what it is.
public enum HideRung: String, Hashable, Sendable, CaseIterable {
    /// `AXFullScreen = false` on every fullscreen window of the app.
    case leaveFullscreen
    /// ⌃⌘F, the system shortcut for the same thing. Catalyst and Electron windows reject the
    /// attribute write above and answer this, because it travels through their own menu handling.
    case sendExitFullscreen
    /// ⌃←, "move one Space left". Some games and custom windows answer only that.
    case spaceLeft
    /// `NSRunningApplication.hide()`, on every running instance of the bundle id.
    case hide
    /// `kAXMinimizedAttribute = true` on every window. The user gets them back from the Dock in
    /// exactly the state they were in.
    case minimizeWindows
}

/// Sending a blocked application away, as a decision with no way of carrying it out.
///
/// It lives here, away from AppKit, for the reason `ActivationGuards` does: choosing what to try
/// is arithmetic on three facts, and a rule that decides whether a blocked app actually goes away
/// deserves a test rather than a look. What is left in `AppHider` is the calls into macOS.
///
/// **Two steps in sequence, not two alternatives.** Fullscreen comes out first and then everything
/// is hidden — `hide()` succeeds on a fullscreen app and leaves its Space standing, so the user
/// watches the block do nothing at all. The fallbacks live inside each step.
public enum HideLadder {

    /// Step one: getting the app out of fullscreen, first rung that works winning — or nothing,
    /// when there is nothing to get it out of and nothing to do it with.
    ///
    /// - `accessibilityTrusted`: every rung needs it. macOS gates event posting behind the same
    ///   grant as attribute writing, so without it this step does not exist. **Which is the one
    ///   limit of the blunt response** in `BluntBlock`: with the grant revoked under a standing
    ///   hard block, an app that is already in fullscreen owns a Space nothing in user space can
    ///   take it out of, and `hide()` answers `true` while leaving that Space exactly where it is.
    ///   It is hidden the moment it leaves fullscreen, and until then it is honestly out of reach.
    /// - `isFullscreen`: `nil` means it could not be told — a hidden app exposes no AX windows,
    ///   and neither does one that refused to answer. Unknown is read as "not fullscreen": the
    ///   cost of guessing the other way is ⌃⌘F sent to a window that was not in fullscreen, which
    ///   puts it *into* fullscreen. A block must not do that.
    /// - `isFrontmost`: both shortcuts are synthetic key events, and a key event goes to whoever
    ///   holds the keyboard. Sending one while another app is in front would toggle *that* app's
    ///   fullscreen, or move the user's Space out from under them — so they are offered only when
    ///   the app being sent away is the app the event would actually reach.
    public static func fullscreenRungs(
        accessibilityTrusted: Bool, isFullscreen: Bool?, isFrontmost: Bool
    ) -> [HideRung] {
        guard accessibilityTrusted, isFullscreen == true else { return [] }
        return isFrontmost ? [.leaveFullscreen, .sendExitFullscreen, .spaceLeft] : [.leaveFullscreen]
    }

    /// Step two: sending it away, first rung that works winning. Never empty — `hide()` needs no
    /// permission at all, which is the one rung that still works on a Mac where the Accessibility
    /// grant has gone stale.
    public static func sendAwayRungs(accessibilityTrusted: Bool) -> [HideRung] {
        accessibilityTrusted ? [.hide, .minimizeWindows] : [.hide]
    }

    /// Step one's rungs and whatever `FullscreenEscalation` added, as one list with nothing in it
    /// twice.
    ///
    /// The escalation leads, because it is offered only about an app that has already been sent
    /// away once and stood there anyway — the more specific answer of the two. In practice they
    /// barely meet: a `true` read is the only thing that fills the ordinary list, and an app whose
    /// read says `true` and which will not come out reports its hide as refused, which is exactly
    /// what ends an escalation.
    public static func ordered(escalation: [HideRung], ordinary: [HideRung]) -> [HideRung] {
        var seen: Set<HideRung> = []
        return (escalation + ordinary).filter { seen.insert($0).inserted }
    }

    /// Whether the app can be said to have gone away, given what each step managed.
    ///
    /// The question `RecentlyHidden` is asked, and the reason it is not simply "did `hide()`
    /// return true": `hide()` returns true for an app that owns a fullscreen Space and leaves it
    /// standing there. Recording that as a hide would make the next recheck ignore a frontmost
    /// reading that is not stale at all — the app is still on screen — and swallow the pause
    /// screen a relock had just earned.
    public static func wentAway(
        wasFullscreen: Bool?, leftFullscreen: Bool, sentAway: Bool
    ) -> Bool {
        guard sentAway else { return false }
        // Not fullscreen, or nobody could tell: `hide()` is the whole story and it worked.
        guard wasFullscreen == true else { return true }
        return leftFullscreen
    }
}

/// What one hide amounted to: whether the application can be said to have gone, and what the
/// fullscreen read answered on the way past.
///
/// The second half exists for `FullscreenEscalation`, which will not send a keystroke at an app
/// whose read came back `false` — Accessibility looking at the windows and finding none of them
/// in fullscreen, which is a genuinely windowed app and the one place ⌃⌘F does harm. Carried out
/// of the hide rather than asked for separately: the read happens in there anyway, and asking a
/// second time is a second round of Accessibility traffic for the same answer.
public struct HideOutcome: Equatable, Sendable {
    public let wentAway: Bool
    public let fullscreenRead: Bool?

    public init(wentAway: Bool, fullscreenRead: Bool?) {
        self.wentAway = wentAway
        self.fullscreenRead = fullscreenRead
    }

    /// Nothing behind that bundle id was there to hide.
    public static let nothing = HideOutcome(wentAway: false, fullscreenRead: nil)

    /// Several running instances of one bundle id, as the one answer the caller asked for.
    ///
    /// `wentAway` when any of them went: the question was about a bundle id, and something behind
    /// it moved. The read is the most alarming answer any instance gave — one instance in
    /// fullscreen makes the id fullscreen, and it is unknown only when nobody answered at all.
    /// Erring towards `true` and `nil` is erring towards escalating, which is the direction this
    /// whole change is going in; erring towards `false` would silence the keystrokes again.
    public static func folded(_ outcomes: [HideOutcome]) -> HideOutcome {
        HideOutcome(wentAway: outcomes.contains { $0.wentAway }, fullscreenRead: read(outcomes))
    }

    private static func read(_ outcomes: [HideOutcome]) -> Bool? {
        if outcomes.contains(where: { $0.fullscreenRead == true }) { return true }
        if outcomes.contains(where: { $0.fullscreenRead == false }) { return false }
        return nil
    }
}

/// The applications this app will not hide, whatever any rule says about them.
///
/// An entry added by hand could otherwise lock the user out of their own settings, or make the
/// blocker hide itself. It holds however the group is configured, and there is no switch for it.
///
/// The evidence is not hypothetical — a published review of another Mac blocker describes losing
/// two hours of work to a Mac where every app was blocked and the system panes would not open
/// either.
public enum HideExemptions {

    /// What the packaged bundle calls itself — `scripts/Info.plist`. Written down rather than
    /// read from `Bundle.main`, which answers `nil` for a raw SwiftPM build and would leave the
    /// app unprotected in exactly the runs used to test it.
    public static let packagedBundleID = "io.github.moritzthln.sandglass"

    /// Always exempt, so the machine stays operable: Sandglass, Finder, System Settings, and
    /// Activity Monitor.
    ///
    /// The first three keep the Mac usable — files, the permission panes, and the app holding the
    /// block. **Activity Monitor is the way out**, and it is on this list deliberately rather than
    /// by omission. Cold Turkey blocks it on purpose so its blocks cannot be killed, and the
    /// documented result is users rebooting into safe mode to escape their own blocker; the worst
    /// report of the kind is two hours of lost work behind a block that had swallowed even the
    /// system panes. This is a tool somebody points at themselves. It
    /// has to be possible to walk out of it without a reboot, and the honest place to say so is
    /// here — a block that cannot be escaped is a block that gets uninstalled instead.
    public static let essentialBundleIDs: Set<String> = [
        packagedBundleID,
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
    ]

    /// Whether this application may be sent away.
    ///
    /// - `isRegularApp` is `activationPolicy == .regular`, which is an AppKit fact the rule cannot
    ///   see for itself. Background agents and helpers are not apps anybody is looking at, and
    ///   hiding one achieves nothing while risking something.
    /// - `runningBundleID` is `Bundle.main.bundleIdentifier`, carried so a development build whose
    ///   id differs from the packaged one still cannot be told to hide itself.
    public static func mayHide(
        bundleID: String?, isRegularApp: Bool, runningBundleID: String? = nil
    ) -> Bool {
        guard isRegularApp, let bundleID else { return false }
        guard !essentialBundleIDs.contains(bundleID) else { return false }
        return bundleID != runningBundleID
    }
}
