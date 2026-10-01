import Foundation

/// One running application, as much of it as the sweep's rule can see.
///
/// A value rather than an `NSRunningApplication`, for the reason every rule in this module is a
/// value: the three facts below are the whole of what the decision needs, and a rule written
/// against them can be tested without a Mac that happens to have Spotify open.
public struct SweepCandidate: Equatable, Sendable {

    /// `nil` for a transient helper, which is nothing any rule could name.
    public let bundleID: String?
    /// `NSRunningApplication.isHidden`. The whole definition of "the user can still see it".
    public let isHidden: Bool
    /// `activationPolicy == .regular`. Background agents are not apps anybody is looking at.
    public let isRegularApp: Bool

    public init(bundleID: String?, isHidden: Bool, isRegularApp: Bool) {
        self.bundleID = bundleID
        self.isHidden = isHidden
        self.isRegularApp = isRegularApp
    }
}

/// What the app layer answers about one application, in the two words the sweep can act on.
///
/// It is the same fork `AppBlocker.handle(activationOf:)` walks and deliberately in the same
/// order: the blunt response first, then the engine's decision through `BlockPresentation`.
public enum SweepVerdict: Equatable, Sendable {
    /// `AppState.hidesWhole` — a hard block is standing and the permission it needs is gone.
    /// It outranks the activation grace, exactly as it does on an activation.
    case hiddenWhole
    /// `BlockPresentation.sendAway`: blocked, and there is no button to press.
    case noWayThrough
    /// Anything else — a countdown, a group set to no pause, or nobody blocking it at all.
    case leaveAlone
}

/// Which applications the once-a-second sweep sends away again.
///
/// **Why a sweep exists at all.** Blocking used to be activation-driven: macOS posts
/// `didActivateApplication`, `AppBlocker` decides on the spot, and a hide that failed was retried
/// by nothing until the next activation. Two holes followed from that, and both turned up on
/// one night of real use with the Accessibility grant in place:
///
/// - a hide that does not land — an app in its own fullscreen Space — is never tried again, so
///   the app stands there until the user leaves fullscreen by hand;
/// - a window opening at 00:30 over an app that is *already* frontmost produces no activation at
///   all, so nothing ever looks at it.
///
/// A 1 Hz poll over the same ladder is what makes the block relentless, because it re-arms the
/// loop for every app that is still visible. This is that poll's rule.
///
/// ### The boundaries, each of them deliberate
///
/// - **Only the no-way-through states.** A pause screen with an Open button on it is a flow the
///   user is in the middle of; sweeping it would hide the app out from under the countdown. The
///   set swept is exactly the set an activation already hides.
/// - **The activation grace is respected**, so an open the user just paid for is not swept away a
///   second later — except under the blunt response, which grants no opens and therefore cannot
///   have issued one. See `ActivationGrace`.
/// - **`HideExemptions` holds**, in every mode and with no switch: Finder, System Settings,
///   Activity Monitor and Sandglass itself are never swept.
/// - **Nothing is ever terminated.** There is no rung for it; see `HideRung`.
///
/// `RecentlyHidden` is deliberately *not* consulted here. It exists to stop the recheck believing
/// a stale frontmost reading, and the sweep has better evidence than any window: `isHidden`. An app
/// that is visible is visible, whatever macOS said about it a second ago.
public enum HideSweep {

    /// Stage one, and the cheap half: the visible applications worth asking about, in the order
    /// the running list gave them, each bundle id once.
    ///
    /// Everything here is a field read. It runs before any decision is asked for, which is what
    /// keeps a dozen background agents from costing a dozen engine lookups a second — and what
    /// makes "an exempt app is never even asked about" a fact rather than a hope.
    public static func worthAsking(
        among candidates: [SweepCandidate], runningBundleID: String?
    ) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []
        for candidate in candidates {
            // An app the user cannot see is an app the block has already dealt with.
            guard !candidate.isHidden, let bundleID = candidate.bundleID else { continue }
            guard !seen.contains(bundleID) else { continue }
            // The same last gate `AppHider` keeps, applied before the ask rather than after it.
            guard HideExemptions.mayHide(
                bundleID: bundleID,
                isRegularApp: candidate.isRegularApp,
                runningBundleID: runningBundleID
            ) else { continue }
            seen.insert(bundleID)
            found.append(bundleID)
        }
        return found
    }

    /// The whole rule: which bundle ids get sent away again on this beat.
    ///
    /// - `graced`: the one application an open was just spent on, or `nil` — `ActivationGrace`
    ///   holds at most one. Peeked at, never spent: the grace belongs to the activation the open
    ///   is about to cause, and a sweep that consumed it would leave that activation unprotected.
    /// - `verdict`: asked only about what `worthAsking` returned, and only once per bundle id.
    public static func appsToSendAway(
        among candidates: [SweepCandidate],
        runningBundleID: String?,
        graced: String?,
        verdict: (String) -> SweepVerdict
    ) -> [String] {
        worthAsking(among: candidates, runningBundleID: runningBundleID).filter { bundleID in
            switch verdict(bundleID) {
            // Ahead of the grace, as on an activation: a hard block with a revoked permission
            // grants no opens, so there is no forgiven activation for this to swallow — and
            // where the two ever did meet, the blunt response is the answer.
            case .hiddenWhole: return true
            case .noWayThrough: return bundleID != graced
            case .leaveAlone: return false
            }
        }
    }
}
