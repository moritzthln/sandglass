import SandglassCore
import Foundation

// The pure half of `AppState`: every question the app asks the engine that publishes nothing,
// and the one value those questions add up to. `AppState` is left with the loop, the
// mutations and the disk.
//
// "Publishes nothing", not "changes nothing" — the difference matters. `RulesEngine.decision`
// begins with the engine's own catch-up, which can roll the day, expire a timed block or reap a
// session and queue the effects that go with it; the next `tick()` drains them. What no question
// here does is assign a published value, write to disk or tell the blocker anything.

/// Everything the UI shows, derived in one pass. Built by `EngineReadout.project(now:)`.
///
/// A value rather than a dozen derivations interleaved with the assignments that publish
/// them. Separating the two is the point: an assignment of an equal value still wakes every
/// observer, so `AppState.recompute` works out the whole picture first and then decides,
/// field by field, which observers actually have something new to hear.
public struct AppStateProjection: Equatable {
    /// The groups that are hard-blocked right now — the set the blocker is told about.
    public let blockedGroups: Set<String>
    /// The subset of those a strict window or a dated block is holding shut: the two reasons that
    /// mean "shut until a moment you named" rather than "spent for today".
    ///
    /// Carried out of the same walk rather than worked out again, because the only thing that
    /// reads it is `BluntBlock` and asking the engine a second time once a second would be a
    /// second walk over every group for one set. See `BluntBlock.hardReasons`.
    public let hardBlockedGroups: Set<String>
    public let stats: StatsSnapshot
    public let config: Config
    public let budgets: [BudgetRow]
    public let activeSession: SessionRow?
    public let focusSessionLine: String?
    /// The focus session an emergency pass is holding off, or `nil` when none is being held.
    ///
    /// The other half of `focusSessionLine`, which says what is blocking *right now* and therefore
    /// goes quiet through the pass. Without this the app would keep a four-hour block a secret for
    /// the hour it is lifted and then reimpose it out of nowhere — which is the app hiding a rule
    /// until the user walks into it, the fault every notice on these screens exists to avoid.
    public let heldFocusSessionLine: String?
    public let streakLine: String
    /// Where this week's emergency pass stands, in the words the settings section shows.
    public let emergencyPassLine: String
    /// Why a pause would be refused this instant, or `nil` when one would be granted.
    public let pauseBlock: PauseFriction.Block?
}

/// The questions the app asks the engine that publish nothing and write nothing down.
///
/// Each answer is derived from the engine and the clock at the moment it is asked, which is
/// what keeps an answer from outliving its cause — the same rule `PauseFriction` is built on.
/// They live here rather than as private methods on `AppState` because most of them are needed
/// in more than one of its paths, and because the loop reads better without them in the way.
///
/// "Pure" is a claim about this module, not about the engine: every `RulesEngine` question
/// begins by applying whatever the clock has made true — and may queue effects for the next
/// tick while doing so — which is exactly why these must only ever be asked from the actor that
/// owns the engine. `AppState` is that actor and holds the only readout.
///
/// That rule is the compiler's now rather than this paragraph's: `@MainActor` is where the
/// engine already lives, and `internal` keeps the type inside the module that owns it — one
/// consumer, `AppState`, and no way for a second one to appear from the outside.
@MainActor
struct EngineReadout {
    private let engine: RulesEngine
    private let calendar: Calendar

    init(engine: RulesEngine, calendar: Calendar) {
        self.engine = engine
        self.calendar = calendar
    }

    // MARK: - The one pass

    /// Walks every managed group once and turns what the engine says into what the screens
    /// show. One walk rather than several: `decision(targetID:)` is the expensive question
    /// here, and the block set, the budget rows and the pause refusal all need the same answer.
    func project(now: Date) -> AppStateProjection {
        var blocked: Set<String> = []
        var hardBlocked: Set<String> = []
        var rows: [BudgetRow] = []

        for group in representativeGroups {
            // A group with no settings is `.notManaged`; it gets no row, and it is not counted
            // as protected either — see `managedTargetCount`.
            guard engine.config.activeSettings(forGroup: group.id) != nil else { continue }
            let decision = engine.decision(groupID: group.id)
            var blockReason: BlockReason?
            if case .blocked(let reason, _) = decision {
                blocked.insert(group.id)
                blockReason = reason
                if BluntBlock.hardReasons.contains(reason) { hardBlocked.insert(group.id) }
            }
            rows.append(BudgetRow(
                id: group.id,
                name: group.name,
                line: line(for: decision, groupID: group.id),
                reason: blockReason,
                // The group has settings and they are switched on — that was checked above — so
                // `.notManaged` here can only mean the engine is standing down this instant: a
                // break window over the group, or a pause over the whole app.
                isOpen: decision == .notManaged
            ))
        }

        let stats = engine.statsSnapshot()
        return AppStateProjection(
            blockedGroups: blocked,
            hardBlockedGroups: hardBlocked,
            stats: stats,
            config: engine.config,
            budgets: rows,
            activeSession: sessionCountdown(now: now),
            // "Everything is blocked until 12:25", not "Focus session until 12:25". The feature
            // is called a focus session everywhere inside this app and nowhere the user can see
            // it: the name says what it is for, and the line has to say what it does.
            focusSessionLine: focusSessionEndsAt.map {
                "Everything is blocked until \(clockText(for: $0))"
            },
            heldFocusSessionLine: heldFocusSessionLine,
            streakLine: streakLine(from: stats),
            emergencyPassLine: emergencyPassLine,
            pauseBlock: pauseBlock
        )
    }

    // A fourth line stood here: `undoLockText`, what was holding the three app-wide undos —
    // resetting today's counters, the start of the day and the clock guard's off switch. Nothing
    // holds them. A running "Block everything" blocks apps and websites and freezes no setting,
    // so all three are live for the whole of one. See `RulesEngine.updateConfig`.

    /// What a running pass is holding off, said while it holds it — see
    /// `AppStateProjection.heldFocusSessionLine` for why it has to be said at all.
    ///
    /// Both ends, because both are facts the reader needs and neither implies the other: when the
    /// blocking comes back, and how long it then has to run. "Blocks everything again at 13:00"
    /// alone would leave somebody planning their afternoon around the wrong number.
    private var heldFocusSessionLine: String? {
        guard let passEnd = engine.emergencyPassEndsAt,
              let sessionEnd = engine.focusSessionEndsAt else { return nil }
        return "Blocking everything again at \(clockText(for: passEnd)), until \(clockText(for: sessionEnd))"
    }

    /// The three things the emergency pass can be: running, spent, or there for the taking.
    ///
    /// "Monday" needs no arithmetic — an ISO week starts on one, so the next week's pass is
    /// always a Monday away. Which Monday is not worth spelling out: it is either tomorrow or
    /// within six days, and the sentence is about whether the net is there, not about a date.
    ///
    /// **"Everything" is only said where it is true.** A group may opt out of the app's unblocks
    /// (`GroupSettings.ignoresAppWideUnblocks`), and a line claiming the app is standing aside over
    /// a group it is still blocking is the same fault as an icon claiming protection that is not
    /// there, read from the other end. Which groups those are is not named: the sidebar says so
    /// group by group, and this is one caption.
    private var emergencyPassLine: String {
        if let endsAt = engine.emergencyPassEndsAt {
            guard !hasImmuneGroup else {
                return "Unblocked until \(clockText(for: endsAt)),"
                    + " except the groups that ignore it"
            }
            return "Everything is unblocked until \(clockText(for: endsAt))"
        }
        return engine.emergencyPassAvailable
            ? "One pass left this week"
            : "Used this week · available again on Monday"
    }

    /// Whether any group the engine would otherwise act on has opted out of the app's unblocks. A
    /// group that is switched off is not one: it blocks nothing with or without a pass, so it
    /// cannot be an exception to one.
    private var hasImmuneGroup: Bool {
        engine.config.groupSettings.keys.contains {
            engine.config.activeSettings(forGroup: $0)?.ignoresAppWideUnblocks == true
        }
    }

    // MARK: - Targets and groups

    /// One entry per group worth showing, in configuration order: the groups the targets name
    /// first, then the ones that block something without a target of their own.
    ///
    /// The second half is what a group made of chips needs, and a group made of advanced rules,
    /// or the adult list needs it for exactly the same reason: no target, so
    /// walking the targets leaves it out of the budget rows and out of the blocked set — a group
    /// that blocks seventeen sites and appears nowhere. That cost more than a missing row. A
    /// strict window over such a group is in nobody's blocked set, so `pauseBlock` cannot see it
    /// and every break ended its thirty-second wait with "Protection couldn't be paused" — while
    /// the engine, which reads `groupSettings` and not the targets, refused it perfectly
    /// knowingly. See `GroupSettings.claimsWithoutTargets`.
    ///
    /// Groups that hold nothing at all stay out: an empty group the user made in the sidebar has
    /// nothing to report.
    ///
    /// The name is the **group's**, not the first target's. Both spellings agree until somebody
    /// renames a group, and then the target's is simply wrong: the sidebar card, the editor's
    /// header and a pause screen all say "Evenings" while the popover row still says "Notes".
    /// `Config.groupDisplayName` falls back to that first target, so nothing else changes.
    var representativeGroups: [(id: String, name: String)] {
        var seen: Set<String> = []
        var groups = engine.config.targets
            .filter { seen.insert($0.groupID).inserted }
            .map { (id: $0.groupID, name: groupName($0.groupID)) }
        for groupID in engine.config.groupSettings.keys.sorted() {
            guard engine.config.groupSettings[groupID]?.claimsWithoutTargets == true,
                  seen.insert(groupID).inserted else { continue }
            groups.append((id: groupID, name: groupName(groupID)))
        }
        return groups
    }

    /// Things the engine will actually act on. A group with no settings, or one switched off, is
    /// `.notManaged` — counting it would have the menu bar claim protection that is not there,
    /// which is the one thing this app must never do.
    ///
    /// A live category counts as the websites it carries and none of its apps: a domain always
    /// applies, while a bundle id only means anything if that app is installed and the engine
    /// has no way to know which are. Undercounting is the safe direction for a line that claims
    /// protection.
    var managedTargetCount: Int {
        let targets = engine.config.targets
            .filter { engine.config.activeSettings(forGroup: $0.groupID) != nil }
            .count
        let carried = engine.config.groupSettings.keys.sorted()
            .compactMap { engine.config.activeSettings(forGroup: $0) }
            .reduce(0) { $0 + CategoryMembership.carriedDomains($1, in: engine.config).count }
        return targets + carried
    }

    func groupName(_ groupID: String) -> String {
        engine.config.groupDisplayName(forGroup: groupID) ?? groupID
    }

    /// A hard block says more than a budget does, and the engine already wrote that sentence
    /// ("Blocked until 17:00", "Next open in 8 min"). Otherwise the day's budget, in the
    /// engine's words — `RulesEngine.budgetLine(forGroup:)` is the only home for that string.
    private func line(for decision: Decision, groupID: String) -> String {
        if case .blocked(_, let untilText) = decision { return untilText }
        return engine.budgetLine(forGroup: groupID) ?? "No limit"
    }

    // MARK: - Sessions

    /// The session that relocks first, and the one the group editor's row is about.
    ///
    /// Gentle opens carry no end date and never appear here — there is nothing to count down
    /// to. The tie-break on group id is what keeps two sessions ending in the same second
    /// from swapping places between ticks: `Dictionary.values` has no order of its own.
    func nextRelockingSession(now: Date) -> (groupID: String, endsAt: Date)? {
        engine.state.sessions.values
            .compactMap { session -> (groupID: String, endsAt: Date)? in
                guard let endsAt = session.endsAt, endsAt > now else { return nil }
                return (session.groupID, endsAt)
            }
            .min { ($0.endsAt, $0.groupID) < ($1.endsAt, $1.groupID) }
    }

    /// Rounded up and clamped to at least one second: a session with 0.4 seconds left is
    /// still running, and "0:00 left" next to a live session reads as a stuck clock.
    private func sessionCountdown(now: Date) -> SessionRow? {
        guard let next = nextRelockingSession(now: now) else { return nil }
        let seconds = Int(next.endsAt.timeIntervalSince(now).rounded(.up))
        return SessionRow(
            groupID: next.groupID,
            name: groupName(next.groupID),
            secondsLeft: max(1, seconds),
            // The group's own switch, so the button can stop naming a reward two of the three
            // seeded presets never pay. Whether *this* moment is still inside the session's first
            // half is deliberately not asked: the credit also needs that, but a label that
            // changed halfway through a countdown would be a second thing to watch.
            earnsBack: engine.config.activeSettings(forGroup: next.groupID)?.earnBackEnabled == true
        )
    }

    private func streakLine(from stats: StatsSnapshot) -> String {
        let freezes = stats.freezesLeft == 1 ? "1 freeze left" : "\(stats.freezesLeft) freezes left"
        guard stats.streakDays > 0 else { return "No streak yet · \(freezes)" }
        return "Day \(stats.streakDays) · \(freezes)"
    }

    // MARK: - Blocks the user cannot talk their way out of

    /// Whether a break would be refused *this instant*.
    ///
    /// One block can refuse one now, where there were two: a scheduled block used to be the
    /// other, and a break overrides those. So the answer is the focus session or nothing, and it
    /// no longer needs to be told what the walk over the groups found — which is what retired
    /// `scheduleBlockActive`, a second walk over every group asked only to answer this.
    ///
    /// It is asked before the press rather than after, so the control can say why it is dead
    /// instead of failing silently on the far side of the wait. Nothing about the answer is
    /// kept — see `PauseFriction` for why.
    var pauseBlock: PauseFriction.Block? {
        focusSessionEndsAt.map { .focusSession(untilText: clockText(for: $0)) }
    }

    /// When the focus session that is blocking right now ends, or `nil` when none is running —
    /// **or while an emergency pass is lifting one**.
    ///
    /// Lifted rather than raw, because the engine is: it answers `.notManaged` and accepts an edit
    /// through the pass (`RulesEngine.decision(for:)`, `updateConfig`), so a screen that read the
    /// stored session would say "everything is blocked" over an app that is blocking nothing, and
    /// keep the group editor frozen over controls the engine would accept. Both of those are
    /// callers of this. A third was the quit refusal, which is gone — quitting no longer asks what
    /// is blocked at all.
    ///
    /// The session itself is untouched and comes back when the hour is over — this is what is
    /// *holding* right now, not what is stored.
    var focusSessionEndsAt: Date? {
        engine.emergencyPassEndsAt == nil ? engine.focusSessionEndsAt : nil
    }

    /// When the running protection pause is over, or `nil` when protection is on.
    var protectionPausedUntil: Date? { engine.protectionPausedUntil }

    /// When the running emergency pass is over, or `nil` when none is running.
    var emergencyPassEndsAt: Date? { engine.emergencyPassEndsAt }

    /// Whether this week's emergency pass can still be spent.
    var emergencyPassAvailable: Bool { engine.emergencyPassAvailable }

    /// What to say while the system clock is behind what the engine has already seen, or `nil`
    /// when it is not. Derived every time it is asked, so it clears itself the moment the clock
    /// is put right.
    var clockWarningLine: String? { engine.clockWarningLine }

    // `lockText(_:)` stood here, turning the engine's refusal of an edit into the sentence a
    // screen shows. The engine refuses no edit, so there is nothing left to translate: what a
    // failed edit can still be is a disk that would not take the file, and that arrives as a
    // `ConfigWriteFailure` already carrying its own words.

    // MARK: - Time

    /// 24-hour wall-clock text, matching the engine's own "Blocked until 17:00" wording even
    /// on a Mac set to 12-hour time.
    func clockText(for date: Date) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
