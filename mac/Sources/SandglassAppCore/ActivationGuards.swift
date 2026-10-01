import Foundation

// Two small pieces of bookkeeping that exist for one reason: some of what macOS reports about
// the frontmost application is caused by Sandglass itself, and only the app layer can know it.
// The engine must never learn about either of them — an open is an open and a block is a
// block, whoever happened to move the windows.
//
// They live here, away from AppKit, because the rules in them are arithmetic on a bundle id
// and a date, and rules that decide whether a pause screen appears deserve tests.
//
// Deliberately two types rather than one. The grace forgives exactly one *real* activation;
// the hidden list suppresses only a *stale frontmost reading*, and must never suppress a real
// activation — that would swallow the cooldown pause screen the user gets by going straight
// back into an app the moment its session relocked it.

/// The one activation the blocker caused itself.
///
/// Granting an open hides the overlay and activates the app the user just paid for. From
/// `NSWorkspace`'s side that activation is indistinguishable from the user reaching for the
/// app — and for a gentle group, which gets no session, evaluating it would put the very
/// pause screen back that the open just cleared, and again, and again.
///
/// So exactly one activation is forgiven, and only within a short window. Any later
/// activation is evaluated normally, which is precisely gentle's intended friction: a pause
/// screen per visit.
public struct ActivationGrace: Equatable, Sendable {
    private var bundleID: String?
    private var expiresAt: Date?

    public init() {}

    /// Forgive the next activation of `bundleID`, up to `expiresAt`. Replaces any earlier
    /// grace: only the most recent open can be the one that caused an activation.
    public mutating func grant(bundleID: String, until expiresAt: Date) {
        self.bundleID = bundleID
        self.expiresAt = expiresAt
    }

    /// Whether a grace for this application is still outstanding, without spending it.
    ///
    /// For the callers that are not an activation. A recheck asks "what is in front right
    /// now?", which is a question nobody pressed a button for — answering it out of the grace
    /// would leave the real activation, arriving milliseconds later, with nothing to protect
    /// it, and the gentle loop would be back with no visible cause.
    public func isPending(bundleID: String, now: Date) -> Bool {
        pendingBundleID(now: now) == bundleID
    }

    /// The same fact turned around: *which* application has a grace outstanding, or `nil`.
    ///
    /// For the sweep, which walks a list of applications rather than asking about one of them.
    /// A grace covers at most one app, so this is the whole of it as a value — and taking it as
    /// a value is what keeps the sweep from having to spend or even name anything.
    public func pendingBundleID(now: Date) -> String? {
        guard let bundleID, let expiresAt, now < expiresAt else { return nil }
        return bundleID
    }

    /// Whether this activation is the forgiven one — true at most once per `grant`.
    ///
    /// A grace for a different application is left alone rather than spent: an unrelated app
    /// stealing focus in between must not make the user pay for an open they already bought.
    /// It expires on its own.
    public mutating func consume(bundleID: String, now: Date) -> Bool {
        guard isPending(bundleID: bundleID, now: now) else { return false }
        self.bundleID = nil
        self.expiresAt = nil
        return true
    }
}

/// The applications the blocker has just sent away.
///
/// `NSWorkspace.frontmostApplication` goes on naming a hidden application for about a second
/// after `hide()` returns, and a session ending fires a recheck inside exactly that gap — the
/// blocked set has just changed. Believing the stale answer would put a blocked screen in
/// front of an app the user is no longer looking at, and the only way out of that screen,
/// "Back to work", would log a dismissal they never chose.
///
/// Consulted only by the recheck path. A real activation of the same app means the user went
/// back to it on purpose and must still be evaluated — that is the cooldown pause screen the
/// relock exists for — so an activation forgets the entry instead of being suppressed by it.
public struct RecentlyHidden: Equatable, Sendable {
    private let window: TimeInterval
    private var hiddenAt: [String: Date] = [:]

    public init(window: TimeInterval) {
        self.window = window
    }

    public mutating func record(_ bundleID: String, at now: Date) {
        // Nothing else ever removes an entry for an app the user never went back to; a
        // handful of bundle ids is not a leak, but it is not tidy either.
        hiddenAt = hiddenAt.filter { now.timeIntervalSince($0.value) < window }
        hiddenAt[bundleID] = now
    }

    /// Whether macOS may still be naming this application as frontmost out of habit.
    public func isRecent(_ bundleID: String, now: Date) -> Bool {
        guard let at = hiddenAt[bundleID] else { return false }
        return now.timeIntervalSince(at) < window
    }

    /// The user is back in it on purpose; whatever macOS still believed is now moot.
    public mutating func forget(_ bundleID: String) {
        hiddenAt.removeValue(forKey: bundleID)
    }
}
