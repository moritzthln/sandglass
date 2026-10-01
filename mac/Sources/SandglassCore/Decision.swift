import Foundation

/// Why a target is hard-blocked right now.
///
/// Every case can name a moment it is over, which is the point: a block with no end is a wall,
/// and this app does not build those. An early `alwaysBlock` flag was the exception and is gone —
/// "always" is now a `.strictBlock` time window over all seven days, which ends at midnight
/// and starts again, so `.schedule` describes it honestly.
///
/// `clockTampered` is the one case that names a condition rather than a time, and it is the honest
/// answer: it ends when the clock agrees again, and only the person who moved it knows when that
/// will be. See `Config.preventTimeChange`.
/// `datedBlock` is the one-shot cousin of `schedule`: a day the user chose, until which the whole
/// group is shut. It has a reason of its own rather than borrowing `schedule` because the two are
/// different things to do something about — a window is redrawn, a date is removed — and because
/// the sentence in front of it names a date instead of an hour. See `DatedBlock`.
/// `CaseIterable` so that a reason added later cannot quietly arrive without words of its own: the
/// suite walks every case and insists each has a distinct clause. See `BlockCopy.why`.
public enum BlockReason: String, Codable, Sendable, CaseIterable {
    case schedule, datedBlock, budgetExhausted, cooldown, focusSession, timeLimit, clockTampered
}

/// What the engine says should happen when a target is opened.
public enum Decision: Equatable, Sendable {
    case allowed(remainingSessionSeconds: Int)
    case pause(countdownSeconds: Int, budgetLine: String?)
    /// The pause case with no wait in it: no screen, no press, no button.
    ///
    /// Not a shorter `pause` — a different answer to the same question. Whoever reads this
    /// spends the open on the spot and leaves the app or the page where it is; everything
    /// downstream of the spend is unchanged, so the session starts, the relock warning fires,
    /// and an emptied budget is still a wall with a screen on it.
    ///
    /// It is `GroupBudget.countdownSeconds` answering `nil`, and nowhere else.
    case opensByItself
    case blocked(reason: BlockReason, untilText: String)
    /// Target unknown to the config, or protection is paused — do nothing at all.
    case notManaged
}

/// Outcome of spending one open from the budget.
public enum ConsumeResult: Equatable, Sendable {
    /// `sessionSeconds == nil` means a gentle open: allowed, but no session and no relock.
    case granted(sessionSeconds: Int?)
    case denied(Decision)
}

/// Side effects the engine emits as time passes.
public enum EngineEffect: Equatable, Sendable {
    case sessionEnded(groupID: String)
    case sessionWarning(groupID: String, secondsLeft: Int)
    case dayRolledOver
}

// The engine used to refuse two things and now refuses neither, so the error it refused them with
// is gone. `EngineError.lockedByStrictWindow` said a group was inside its own strict window and
// its settings frozen; `.lockedByFocusSession` said "Block everything" was running and the
// configuration frozen whole. Both blocks still block; neither freezes a setting, because under
// the lock rule only a settings lock or a passcode does. See `RulesEngine.updateConfig`, and
// `EditDirection`.

/// Read-only view of today's numbers for the menu bar and stats screen.
public struct StatsSnapshot: Equatable, Sendable {
    public var opensUsedToday: [String: Double]
    public var opensAvoidedToday: Int
    public var streakDays: Int
    public var freezesLeft: Int
    /// groupID → seconds spent in the group today, counted rather than estimated: one second
    /// per second the app was frontmost, plus fifteen per heartbeat from a browser tab.
    public var usageSecondsToday: [String: Int]

    public init(
        opensUsedToday: [String: Double],
        opensAvoidedToday: Int,
        streakDays: Int,
        freezesLeft: Int,
        usageSecondsToday: [String: Int] = [:]
    ) {
        self.opensUsedToday = opensUsedToday
        self.opensAvoidedToday = opensAvoidedToday
        self.streakDays = streakDays
        self.freezesLeft = freezesLeft
        self.usageSecondsToday = usageSecondsToday
    }
}
