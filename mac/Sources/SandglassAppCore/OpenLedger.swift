import SandglassCore
import Foundation

/// Spending an open, turning one down, and the seconds spent afterwards — the three things that
/// change what today looks like, and the trail each of them has to leave.
///
/// Split out of `AppState` because the trail is the part that goes quietly wrong. Every path
/// that spends or refuses an open has to do the same three things in the same order: ask the
/// engine, write the event, and hand the caller back an answer. Five call sites doing that by
/// hand is five chances for one of them to forget the log, and a statistics screen that
/// under-reports is worse than one that is not there.
///
/// What is deliberately **not** here is `finishMutation`: re-deriving the published state,
/// telling the blocker and saving belong to the loop, so `AppState` calls this and then finishes
/// the mutation itself. That keeps a single re-derivation per user action rather than one per
/// engine call.
///
/// `@MainActor` and `internal` for the reason `EngineReadout` is: the engine and the store are
/// both confined to the actor that owns them, and `AppState` is that actor.
@MainActor
struct OpenLedger {
    private let engine: RulesEngine
    private let persistence: StatePersistence
    private let questions: TargetQuestions
    /// The app's own clock rather than the engine's: the app owns wall-clock time, which also
    /// keeps a test's events on the same timeline as the state they describe.
    private let clock: Clock

    init(
        engine: RulesEngine,
        persistence: StatePersistence,
        questions: TargetQuestions,
        clock: Clock
    ) {
        self.engine = engine
        self.persistence = persistence
        self.questions = questions
        self.clock = clock
    }

    // MARK: - An application

    /// Spend one open, and log it if it was actually spent.
    func consumeOpen(targetID: String) -> ConsumeResult {
        let result = engine.consumeOpen(targetID: targetID)
        if case .granted = result { appendEvent(EventKind.open, targetID: targetID) }
        return result
    }

    /// The user turned back at the pause screen. The caller asserts that one was showing.
    func recordDismissal(targetID: String) {
        engine.recordDismissal(targetID: targetID)
        appendEvent(EventKind.dismissal, targetID: targetID)
    }

    /// Charges one second to whatever the user is actually looking at, and reports whether it
    /// landed anywhere.
    ///
    /// One second per tick rather than a stopwatch, which is what makes the total honest: a Mac
    /// that slept, or an app that was killed, ran no ticks and so accrued no time. The caller
    /// answers `nil` for everything that is not somebody using an app — a locked screen, and
    /// Sandglass's own overlay — see `AppBlocker`.
    ///
    /// Counted whether or not the engine is blocking. A break and the week's emergency pass lift
    /// the *blocking*; they do not lift the hour. An hour spent under a pass that showed as "0m
    /// used today" would be the app lying about the one number it exists to tell the truth
    /// about — and a daily limit that shrinks after a break spent scrolling is the limit working,
    /// not double billing.
    func recordSecond(inFrontmost bundleID: String?) {
        guard let bundleID, let groupID = questions.groupID(forBundleID: bundleID) else { return }
        engine.recordUsage(groupID: groupID, seconds: 1)
    }

    // MARK: - A page in a browser

    // The same three, asked about a URL. A URL is turned into a group by the engine — the same
    // matcher its decisions use — and everything after that is the app path above, so an open
    // spent on a website leaves exactly the trail an open spent in an app does.

    /// Spend one open on a page. An unclaimed URL is refused the way the engine refuses one.
    func consumeOpen(url: String) -> ConsumeResult {
        let result = engine.consumeOpen(url: url)
        if case .granted = result, let match = engine.webMatch(forURL: url) {
            appendEvent(EventKind.open, groupID: match.groupID)
        }
        return result
    }

    /// The user turned back at a web pause screen. The caller asserts that one was showing.
    func recordDismissal(url: String) {
        guard let match = engine.webMatch(forURL: url) else { return }
        engine.recordDismissal(url: url)
        appendEvent(EventKind.dismissal, groupID: match.groupID)
    }

    /// Charges one second to the group a page belongs to. An unclaimed URL is dropped.
    ///
    /// There is one counting path, and it is the tick above: the same beat that charges the
    /// frontmost app also asks what page is in front, so there is no second reporter whose
    /// seconds could land on top of these. This used to be the browser extension's heartbeat
    /// alongside the app's own reading of the tab, and the two could charge the same page twice.
    func recordSecond(onPage url: String) {
        guard let match = engine.webMatch(forURL: url) else { return }
        engine.recordUsage(groupID: match.groupID, seconds: 1)
    }

    // MARK: - The log

    // Best-effort by design: `Store.appendEvent` cannot fail loudly, because no statistic is
    // worth failing an open over.

    func appendEvent(_ kind: String, groupID: String) {
        persistence.appendEvent(Event(ts: clock.now, kind: kind, groupID: groupID))
    }

    private func appendEvent(_ kind: String, targetID: String) {
        // An unknown target belongs to no group, and the log counts by group.
        guard let groupID = questions.groupID(forTargetID: targetID) else { return }
        appendEvent(kind, groupID: groupID)
    }
}
