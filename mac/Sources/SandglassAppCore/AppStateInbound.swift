import SandglassCore
import Foundation

// The surface `AppBlocker` and the browser watcher are written against: everything they ask of
// the engine, and the three things they can spend.
//
// Split out of `AppState` when that file reached the size limit, along the seam it already
// marked. Nothing about the rule changed in the move, and nothing here decides anything: the
// questions are `TargetQuestions`', the spending is `OpenLedger`'s, and what this adds is the
// actor and the trail.
//
// The three collaborators it reaches are `internal` rather than `private` for exactly this
// reason, and they are the only ones that had to be: `engine` and `store` are still owned by
// `AppState` alone, which is the confinement the whole class exists to provide.

extension AppState {

    // `AppBlocker` and the browser watcher go through these and never touch `RulesEngine`
    // themselves. Two reasons: the engine is MainActor-confined by `AppState` and by nothing
    // else, and every path that spends or refuses an open has to leave the same trail — a
    // saved state, a re-derived menu bar, and a line in the event log.
    //
    // The four that only *ask* forward straight to `TargetQuestions`, which is where they and
    // the reasoning behind them live. They stay methods of the class because that is the
    // surface the blocker is written against.

    public func blockDecision(forBundleID bundleID: String) -> Decision {
        questions.decision(forBundleID: bundleID)
    }

    public func displayInfo(forBundleID bundleID: String) -> TargetDisplayInfo? {
        questions.displayInfo(forBundleID: bundleID)
    }

    public func blockDecision(forURL url: String) -> Decision {
        questions.decision(forURL: url)
    }

    public func webDisplayInfo(forURL url: String) -> TargetDisplayInfo? {
        questions.displayInfo(forURL: url)
    }

    /// Whether this application goes straight to the hide ladder on this activation, without
    /// being asked about.
    ///
    /// The fifth question, and the only one whose answer does not come from the engine: a hard
    /// block is standing, the permission it needs has been taken away, and this application is
    /// one the dead block covers — most sharply a browser, which no group can name as a target
    /// and which the engine therefore has no opinion about at all. The rule is `BluntBlock`, and
    /// `refreshStatus` is what keeps the answer a second old at most.
    public func hidesWhole(bundleID: String) -> Bool {
        bluntBlock.covers(bundleID)
    }

    // The four that change something are `OpenLedger`, which leaves the trail; what is added
    // here is `finishMutation`, so one user action re-derives the published state once.

    public func consumeOpen(forURL url: String) -> ConsumeResult {
        let result = ledger.consumeOpen(url: url)
        finishMutation()
        return result
    }

    public func recordDismissal(forURL url: String) {
        ledger.recordDismissal(url: url)
        finishMutation()
    }

    public func consumeOpen(targetID: String) -> ConsumeResult {
        let result = ledger.consumeOpen(targetID: targetID)
        finishMutation()
        return result
    }

    public func recordDismissal(targetID: String) {
        ledger.recordDismissal(targetID: targetID)
        finishMutation()
    }

    /// One second of a managed page, charged from inside the loop.
    ///
    /// The web counterpart of `ledger.recordSecond(inFrontmost:)`, and deliberately not finishing
    /// the mutation either: `pollFrontmostPage` runs inside `tick`, whose own `finishMutation`
    /// covers whatever this second changed — including the daily limit it may have just reached.
    public func recordPageSecond(forURL url: String) {
        ledger.recordSecond(onPage: url)
    }
}
