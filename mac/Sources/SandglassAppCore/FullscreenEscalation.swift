import Foundation

/// What to try on an application that a hide claimed to have sent away and that is still standing.
///
/// **The hole this closes.** `HideLadder.fullscreenRungs` offers a way out of fullscreen only when
/// the Accessibility read answers `true`, and reads `nil` as "not fullscreen" because ⌃⌘F sent at a
/// window that was *not* in fullscreen puts it into fullscreen — a block must not do that. The
/// caution is right and it ate the feature: for Electron and Catalyst apps in their own fullscreen
/// Space the read answers `nil` almost every time (measured: Telegram and WhatsApp, both
/// fullscreen, both listing zero Accessibility windows), so no exit was ever attempted, `hide()`
/// answered `true`, and the Space stood there all night. That is a real field report: Spotify,
/// WhatsApp and Claude stayed put until the user left fullscreen by hand.
///
/// **So the guess is replaced by evidence.** A hide that reported the app gone, followed by the
/// same app still visible on the next sweep tick, is not a reading anybody has to trust — it is
/// what a fullscreen Space looks like from outside. From that second on the app is treated as
/// stuck, and the rungs the read would have gated are offered.
///
/// ### The safety rules, which hold whatever the evidence says
///
/// - **A key event goes to whoever holds the keyboard.** ⌃⌘F and ⌃← are synthetic events posted to
///   the session tap, so they are offered only while the stuck app is frontmost. Sending one at a
///   background app would toggle *another* app's fullscreen or move the user's Space out from
///   under them.
/// - **Never on the first attempt.** The first hide is the ordinary ladder's; only a hide that
///   claimed success and did not deliver earns a keystroke.
/// - **Never against a `false` read.** `nil` is an app that would not answer, which is the stuck
///   case. `false` is Accessibility looking at the windows and seeing none in fullscreen — an app
///   that is genuinely in a window, and the one place ⌃⌘F would do the harm the whole caution is
///   about. It gets the attribute write and nothing else.
/// - **The attribute write is direction-safe.** `AXFullScreen = false` onto a window that is not
///   fullscreen is a no-op, so it is offered on every escalation tick whatever the read said and
///   whoever is in front.
/// - **Every other tick, and one shortcut at a time.** The exit animation runs about half a
///   second; a second ⌃⌘F inside it toggles the app straight back in, which is how a block turns
///   into an app flickering between two states forever. So a tick that sends a key event is
///   followed by one that sends only the write, and ⌃⌘F and ⌃← take turns rather than being
///   offered together — `AppHider` stops at the first rung that works, and a posted key event
///   always "works", so a list holding both would never reach the second one.
///
/// **Nothing here activates anything.** Bringing a stuck app to the front to make it reachable
/// and handing focus back afterwards would work; this does not, deliberately. Pulling an app the user
/// is not looking at onto the screen is a large, startling thing for a background app to do, and
/// the case that actually failed — a fullscreen app the user is sitting in front of at 00:30 — has
/// the app frontmost already. A stuck app nobody is looking at gets the attribute write every
/// second and the shortcuts the moment it is in front.
public struct FullscreenEscalation: Equatable, Sendable {

    /// How far the evidence against one application has got.
    public enum Stage: Equatable, Sendable {
        /// Nothing has been tried, or the last try did not claim to have worked. The ordinary
        /// ladder is the whole response and this offers nothing.
        case quiet
        /// A hide reported the app gone. Whether it really went is answered by the next tick:
        /// seeing it again is the evidence.
        case attempted
        /// Still standing after a hide that claimed success — de facto stuck in a fullscreen
        /// Space. The number counts the escalation ticks that have actually gone out with the
        /// keyboard available, which is what makes the shortcuts take turns and settle in
        /// between; an app that is never frontmost stays at zero and gets the write alone.
        case pressing(Int)
    }

    private struct Evidence: Equatable, Sendable {
        var stage: Stage
        /// What the fullscreen read answered on the last attempt. Carried rather than asked for
        /// again: the read happens inside the hide anyway, and one a second old is the same
        /// answer for a Space that has not moved.
        var fullscreenRead: Bool?
    }

    private var evidence: [String: Evidence] = [:]

    public init() {}

    /// How far this application has got. `quiet` for one nothing is known about.
    public func stage(of bundleID: String) -> Stage { evidence[bundleID]?.stage ?? .quiet }

    /// The application is visible again and about to be sent away: take that as the evidence it
    /// is, and answer what to try on top of the ordinary ladder.
    ///
    /// Mutating, because being asked *is* the still-standing half of the state machine. An app
    /// nothing is known about answers with nothing — the first attempt is never an escalated one.
    public mutating func rungs(
        forStillStanding bundleID: String, isFrontmost: Bool, accessibilityTrusted: Bool
    ) -> [HideRung] {
        // Every rung needs the grant: macOS gates event posting behind the same one as attribute
        // writing. Without it the evidence keeps, and nothing is spent pretending otherwise.
        guard accessibilityTrusted, var found = evidence[bundleID] else { return [] }
        guard let step = Self.step(of: found.stage) else { return [] }
        let mayPressKeys = isFrontmost && found.fullscreenRead != false
        // The step advances only when a keystroke was actually available. A background app that
        // sat at this rung for an hour should press ⌃⌘F the second it comes forward, not land
        // mid-cycle on a settling tick.
        found.stage = .pressing(mayPressKeys ? step + 1 : step)
        evidence[bundleID] = found
        return Self.rungs(step: step, mayPressKeys: mayPressKeys)
    }

    /// What one attempt amounted to, recorded for the next tick to judge.
    ///
    /// `wentAway` is `HideLadder.wentAway` rather than "a call returned true", which is what makes
    /// the evidence mean anything: an app whose fullscreen read said `true` and which did not come
    /// out reports `false` here, and it needs no escalation at all — the ordinary ladder is
    /// already offering it every rung there is.
    public mutating func record(_ bundleID: String, wentAway: Bool, fullscreenRead: Bool?) {
        guard wentAway else {
            // The hide was refused openly, so there is no claim to hold against it. Whatever the
            // app is doing, it is not the case this exists for.
            evidence[bundleID] = nil
            return
        }
        let stage = stage(of: bundleID)
        evidence[bundleID] = Evidence(
            stage: stage == .quiet ? .attempted : stage, fullscreenRead: fullscreenRead
        )
    }

    /// The application went away, or nothing blocks it any more. Nothing is held against it.
    public mutating func forget(_ bundleID: String) { evidence.removeValue(forKey: bundleID) }

    /// The same for everything the sweep no longer names — an app that finally went, one the user
    /// closed, and one whose block ended while it stood there.
    public mutating func forgetAll(except standing: Set<String>) {
        evidence = evidence.filter { standing.contains($0.key) }
    }

    // MARK: - The rule

    /// Which escalation tick this is, or `nil` while there is no evidence to escalate on.
    private static func step(of stage: Stage) -> Int? {
        switch stage {
        case .quiet: return nil
        case .attempted: return 0
        case .pressing(let step): return step
        }
    }

    /// What one escalation tick offers. Pure arithmetic on the two facts, so the cadence can be
    /// read off rather than inferred from a run.
    ///
    /// The write leads every tick: it is free, it is direction-safe, and where the app does list
    /// its windows it is the rung that needs nobody in front of anything. What follows it is a
    /// four-tick cycle — ⌃⌘F, settle, ⌃←, settle — which is the throttle the exit animation needs
    /// written at the rate the sweep runs at.
    public static func rungs(step: Int, mayPressKeys: Bool) -> [HideRung] {
        guard mayPressKeys else { return [.leaveFullscreen] }
        switch step % 4 {
        case 0: return [.leaveFullscreen, .sendExitFullscreen]
        case 2: return [.leaveFullscreen, .spaceLeft]
        default: return [.leaveFullscreen]
        }
    }
}
