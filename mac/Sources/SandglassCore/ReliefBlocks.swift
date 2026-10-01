import Foundation

/// The three blocks that are a deadline and nothing else: the week's emergency pass, a focus
/// session, and the protection break.
///
/// Split out of `RulesEngine` for the reason `GroupBudget` and `ConfigSwap` were: the engine holds
/// the precedence between the three — which of them outranks which, and what each does to the
/// sessions that were running — and this holds the one question all three answer the same way.
/// **Is this deadline still ahead of us**, asked against the uptime twin so that no wind of the
/// system clock can shorten any of them, and the writing of the pair that starts one.
///
/// The reads are an instance over a state and the moment they are about, built per question like
/// `GroupBudget`: `EngineState` is a value of copy-on-write dictionaries, so a snapshot costs a
/// retain, and one that could go stale between the mutation and the answer would be worse than
/// free. The three that start a block are `static` and take the state `inout`, the shape
/// `DayReset.handBackToday` already has — so no caller can read one of these off a copy taken
/// before its own write.
struct ReliefBlocks {
    let state: EngineState

    /// The moment this is about, and the uptime it was read at. Both halves are needed: the ends
    /// below are what the UI *names* an hour by, and the uptime is what they are measured against.
    let reading: ClockReading

    /// How long the pass lifts everything for. How often it may be spent is the engine's — see
    /// `RulesEngine.emergencyPassAvailable`, which reads the week it was charged to.
    static let emergencyPassMinutes = 60

    // MARK: - What is running

    /// When the running emergency pass is over, or `nil` when none is running.
    var emergencyPassEnd: Date? {
        stillAhead(state.emergencyPassEndsAt, uptime: state.emergencyPassEndsAtUptime)
    }

    /// When the running focus session is over, or `nil` when none is running.
    var focusSessionEnd: Date? {
        stillAhead(state.focusSessionEndsAt, uptime: state.focusSessionEndsAtUptime)
    }

    /// When the running protection break is over, or `nil` when protection is on.
    ///
    /// A break runs until its time is up and nothing else ends it early — a window opening
    /// underneath it included. This used to be two guards: the deadline, and a strict window
    /// standing anywhere. The second is gone with the refusal it belonged to. It is the only place
    /// the precedence in `RulesEngine.decision(for:)` is actually decided, because that method
    /// already asks about the break before it asks about the window; while this answered `nil`
    /// inside one, the ordering there was academic.
    var protectionPauseEnd: Date? {
        stillAhead(state.protectionPausedUntil, uptime: state.protectionPausedUntilUptime)
    }

    /// Whether a break that was started has since run out.
    ///
    /// Deliberately not `protectionPauseEnd == nil`, which is also true of an app with no break at
    /// all: this one is asked to decide whether there is something to clear.
    var pauseHasExpired: Bool {
        guard let until = state.protectionPausedUntil else { return false }
        return reading.hasPassed(until, uptime: state.protectionPausedUntilUptime)
    }

    private func stillAhead(_ deadline: Date?, uptime twin: TimeInterval?) -> Date? {
        guard let deadline, !reading.hasPassed(deadline, uptime: twin) else { return nil }
        return deadline
    }

    // MARK: - Clearing the ones that are over

    /// Drops whichever of the three has run out.
    ///
    /// All three are single dates rather than counters: once they are past they are cleared, so a
    /// finished block is never carried around in the persisted state. The pass's *week* marker is
    /// not touched — that is what makes it one a week, and it expires by the week changing.
    ///
    /// A break is dropped for one reason now: it ran out. It was also dropped for a second — a
    /// strict window standing anywhere suppressed it, and suppression deleted it so that a break
    /// the window cut short could not come back in the evening. Nothing suppresses one any more,
    /// so there is nothing to delete early.
    static func expire(_ state: inout EngineState, at reading: ClockReading) {
        let blocks = ReliefBlocks(state: state, reading: reading)
        if blocks.focusSessionEnd == nil { state.clearFocusSession() }
        if blocks.emergencyPassEnd == nil { state.clearEmergencyPass() }
        if blocks.pauseHasExpired { state.clearProtectionPause() }
    }

    // MARK: - Starting one

    /// Spends the week's pass, for `weekKey`. The caller decides whether there is one left.
    ///
    /// **A running focus session is outranked rather than ended**, which is the difference between
    /// lifting a block for an hour and cancelling it: the session stays in the state and blocks
    /// again when the hour is up, for whatever is left of it, exactly as a strict window does. It
    /// used to clear the session, which took a four-hour commitment away for good in exchange for
    /// a ten-minute emergency.
    static func spendEmergencyPass(
        _ state: inout EngineState, weekKey: String, at reading: ClockReading
    ) {
        state.emergencyPassUsedInWeek = weekKey
        state.setEmergencyPass(
            state.deadline(in: TimeInterval(emergencyPassMinutes * 60), at: reading)
        )
    }

    /// Hard-blocks everything for `minutes`, and answers whether anything was started — `false`
    /// for a length of nothing, which is not a focus session and must not end the running opens.
    ///
    /// **Never shortens**: a second, smaller focus session extends at worst by nothing. The two
    /// lengths are compared on the monotonic clock, so the pair that is written is the one that
    /// really has longer to run.
    ///
    /// Starting one while protection is paused ends the break: the explicit "block everything" is
    /// the newer and stronger of the two wishes. A running emergency pass ends with it, for the
    /// same reason — the week's pass stays spent, but its hour is over. What it does to the opens
    /// that were running is the caller's, because the sessions are: whatever is open right now
    /// ends at once, since a focus session that let the current YouTube session run out would be
    /// a lie.
    @discardableResult
    static func startFocusSession(
        _ state: inout EngineState, minutes: Int, at reading: ClockReading
    ) -> Bool {
        guard minutes > 0 else { return false }
        let requested = TimeInterval(minutes * 60)
        let blocks = ReliefBlocks(state: state, reading: reading)
        let running = blocks.focusSessionEnd
            .map { reading.secondsUntil($0, uptime: state.focusSessionEndsAtUptime) } ?? 0
        if requested >= running {
            state.setFocusSession(state.deadline(in: requested, at: reading))
        }
        state.clearProtectionPause()
        state.clearEmergencyPass()
        return true
    }

    /// Turns the engine off for `minutes`, or answers `false` because a focus session is
    /// running — which is the one block a break does not lift.
    ///
    /// **A strict window no longer refuses one, and no longer cuts one short.** It did both: a
    /// break was refused outright inside a window, and one taken before a window was clamped to
    /// its start, so an hour asked for at 08:55 ended at 09:00. That is the wrong shape for the
    /// control it belongs to. "Unblock everything" is the one thing in this app that means what
    /// it says, and a version of it that quietly means "unless a schedule disagrees" is worse
    /// than no button: it fails at exactly the moment it is reached for, and the friction it was
    /// bought with — the wait, and the passcode — was already paid by then. So the length asked
    /// for is the length granted, whatever any window says, and the windows come back the moment
    /// it runs out.
    ///
    /// What still holds a break off is the focus session, and it holds for the reason it always
    /// did: "Block everything" is the one commitment with no way out but the week's emergency
    /// pass, and a break that lifted it would leave the app with no commitment that cannot be
    /// undone in the next second.
    static func startPause(
        _ state: inout EngineState, minutes: Int, at reading: ClockReading
    ) -> Bool {
        guard minutes > 0 else { return false }
        guard ReliefBlocks(state: state, reading: reading).focusSessionEnd == nil else {
            return false
        }
        state.setProtectionPause(state.deadline(in: TimeInterval(minutes * 60), at: reading))
        return true
    }
}
