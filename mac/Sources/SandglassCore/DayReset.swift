import Foundation

/// What a day passing clears, and what the reset button hands back.
///
/// The two lists side by side, because they are **not** the same list and sharing one function is
/// how they stopped being right: the reset cleared `deniedAttempts` along with everything else,
/// which un-blew a day the user had already blown. Written out twice, in full, so the difference
/// is something a reader can see rather than something they have to remember.
///
/// A collaborator rather than three methods on the engine, for the reason `StreakScoring` is one:
/// none of this decides anything. The engine says when a day has passed and whether an undo is
/// allowed; this says what either of them does to the counters.
struct DayReset {
    /// What the day that just ended was worth.
    let streak: StreakScoring
    /// Where the day boundary falls. Both come from the configuration, which is why the engine
    /// builds this per call rather than holding one — see `RulesEngine.dayReset`.
    let calendar: Calendar
    let dayStartMinutes: Int

    /// Rolls into the day `now` belongs to when the state is still in an earlier one, scoring the
    /// day that ended. `false` means no boundary was crossed and nothing was touched.
    ///
    /// Sessions and cooldowns survive on purpose: both are running clocks rather than daily
    /// counters. A session started at 02:50 keeps running past 03:00, and a cooldown started at
    /// 02:55 still has to be waited out.
    ///
    /// **Forward only.** A day key is a record of days lived, and a moment that reads as an
    /// earlier day — a clock within the tolerance of the 03:00 edge, a relaunch after a reboot on a
    /// clock set back, a flight west — leaves the day and its counters where they are. Rolling
    /// back used to clear every counter, so setting the clock back a day was a fresh budget.
    func rollIfNeeded(at now: Date, _ state: inout EngineState) -> Bool {
        let key = day(at: now, after: state.dayKey)
        guard key != state.dayKey else { return false }
        guard key > state.dayKey || !Self.isDayKey(state.dayKey) else {
            // Only the let-go below reaches here, and it is not a day passing: no score, and the
            // counters stay until a real boundary clears them.
            state.dayKey = key
            return false
        }
        // Everything the scoring needs, taken before the clearing below gets to it.
        let ended = StreakScoring.DayLedger(state)
        state.dayKey = key
        state.opensUsed = [:]
        state.opensAvoided = 0
        state.deniedAttempts = [:]
        state.usageSecondsToday = [:]
        streak.score(ended, newDayKey: key, into: &state)
        return true
    }

    /// The day the engine is in at `now`, when the state was last in `stored`: the later of the
    /// two, because the day only moves forward.
    ///
    /// Keys sort as dates, so "later" is a string comparison. The one exception is a stored day
    /// more than a week ahead of `now`, which no clock this Mac really ran on could have reached:
    /// a clock set into the future across a reboot and then put right. Holding it would freeze
    /// the budget until that date arrived, so it is let go — without a roll, see above.
    func day(at now: Date, after stored: String) -> String {
        let key = EngineState.dayKey(for: now, calendar: calendar, dayStartMinutes: dayStartMinutes)
        // A key too damaged to read as a date sorts wherever its letters put it, and is no day
        // anybody lived: it is rolled out of, the way it always was.
        guard stored > key, Self.isDayKey(stored) else { return key }
        let weekAhead = EngineState.dayKey(
            for: now.addingTimeInterval(Self.letGoSeconds), calendar: calendar,
            dayStartMinutes: dayStartMinutes
        )
        return stored > weekAhead ? key : stored
    }

    /// How far ahead of the clock a stored day may be before it is let go rather than held.
    private static let letGoSeconds: TimeInterval = 7 * 86_400

    /// Whether `key` has the `yyyy-MM-dd` shape every key `EngineState.dayKey` prints, which is
    /// what makes comparing two of them as strings compare them as dates.
    private static func isDayKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        return parts.map(\.count) == [4, 2, 2] && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Hands today's budget back: opens, time, the pause screens turned away from, and every
    /// waiting cooldown.
    ///
    /// **`deniedAttempts` are left exactly where they are**, which is the one difference from a
    /// day passing and the whole reason these two are written out separately. They are the record
    /// of knocking after the budget was gone — `StreakScoring.DayLedger.wasBusted` reads nothing
    /// else — so clearing them had a day already over budget score at 03:00 as a neutral one and
    /// cost the week's freeze nothing. Resetting counters is for a setup mistake, not for erasing
    /// a day you lived, and the streak is the one number in this app that must never be quietly
    /// rewritten.
    ///
    /// The cooldowns do go, unlike at a rollover: a wait bought by an open that no longer counts
    /// is a wait for nothing.
    static func handBackToday(_ state: inout EngineState) {
        state.opensUsed = [:]
        state.opensAvoided = 0
        state.usageSecondsToday = [:]
        state.cooldownUntil = [:]
        state.cooldownUntilUptime = [:]
    }
}
