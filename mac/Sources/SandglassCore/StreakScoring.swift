import Foundation

/// The streak, as arithmetic over the day that just ended.
///
/// Split out of `RulesEngine` because none of it decides anything: the engine hands over a day
/// the 03:00 rollover has finished with, and this says what it was worth. It is also the one
/// home for the ISO week — the streak freeze and the emergency pass are charged to the same
/// week, and two spellings of "which week is this" would eventually let them disagree.
///
/// Only the time zone of the calendars is used. A day key is an internal identifier and is
/// always Gregorian, so a user on a Buddhist or Hebrew system calendar gets the same
/// `yyyy-MM-dd` string as everyone else — the same rule `EngineState.dayKey` follows.
///
/// A type of its own rather than an extension of the engine: this codebase splits by moving
/// behaviour into a collaborator, because a file-scoped `private` does not reach across files
/// and widening every member to satisfy a split is the worse trade.
struct StreakScoring {

    /// The streak survives one busted day per ISO week.
    static let freezesPerWeek = 1

    /// Shared instead of rebuilt per call: only its time zone is replaced, and a week key is
    /// asked for on every stats read.
    private static let isoCalendar = Calendar(identifier: .iso8601)

    private let calendar: Calendar
    private let gregorian: Calendar

    init(calendar: Calendar, gregorian: Calendar) {
        self.calendar = calendar
        self.gregorian = gregorian
    }

    /// What the day that just ended left behind. Taken as a copy before the counters are
    /// cleared, so scoring reads the day it is judging no matter where in the rollover it
    /// happens to run.
    struct DayLedger {
        let dayKey: String
        let opensUsed: [String: Double]
        let opensAvoided: Int
        let deniedAttempts: [String: Int]

        init(_ state: EngineState) {
            dayKey = state.dayKey
            opensUsed = state.opensUsed
            opensAvoided = state.opensAvoided
            deniedAttempts = state.deniedAttempts
        }

        /// Anything at all happened: an open spent, a pause screen walked away from, or a
        /// denied attempt. All three are a day of practice.
        var wasObserved: Bool { !opensUsed.isEmpty || opensAvoided > 0 || !deniedAttempts.isEmpty }

        /// The user kept knocking after the budget was gone — not merely spent it.
        var wasBusted: Bool { deniedAttempts.values.contains { $0 > 0 } }
    }

    /// Turns the day that just ended into streak arithmetic.
    ///
    /// The first bust of an ISO week costs that week's freeze instead of the streak; the
    /// second costs the streak. Days the engine never saw (Mac off for a week) are neither
    /// practice nor a slip: only a day that directly precedes the new one and actually had
    /// traffic extends the streak, and a quiet gap leaves it exactly where it was.
    func score(
        _ ended: DayLedger,
        newDayKey: String,
        into state: inout EngineState
    ) {
        if ended.wasBusted {
            // A day key too damaged to name a week cannot be charged to one: spending the
            // current week's freeze on it would take a freeze the user may still need for
            // a day they actually lived. One unscored day is the cheaper mistake.
            guard let week = weekKey(forDayKey: ended.dayKey) else { return }
            if state.freezeUsedInWeek == week {
                state.streakDays = 0
            } else {
                state.freezeUsedInWeek = week
            }
            return
        }
        guard ended.wasObserved, dayKey(ended.dayKey, immediatelyPrecedes: newDayKey)
        else { return }
        state.streakDays += 1
    }

    /// The ISO week a moment belongs to, as `2026-W05`.
    func weekKey(for date: Date) -> String {
        var iso = Self.isoCalendar
        iso.timeZone = calendar.timeZone
        let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    /// Whether the two keys name consecutive logical days.
    ///
    /// A day key is already a calendar date — `EngineState.dayKey` shifts the moment back by the
    /// start of day and then prints year-month-day — so "the day after" is one day of arithmetic
    /// on the key itself, and the start of day does not come into it.
    ///
    /// It used to send the candidate back through `EngineState.dayKey`, which applied the shift a
    /// second time. `date(forDayKey:)` answers local noon, so with a start of day **later than
    /// noon** that moment falls in the previous logical day and the comparison could never match:
    /// the streak stopped advancing entirely. Unreachable from the dropdown, which offers
    /// midnight to 06:00 — and reachable by hand, which is the only reason `config.json` values
    /// are read defensively everywhere else.
    private func dayKey(_ endedKey: String, immediatelyPrecedes newDayKey: String) -> Bool {
        guard let ended = date(forDayKey: endedKey),
              let next = gregorian.date(byAdding: .day, value: 1, to: ended) else { return false }
        let parts = gregorian.dateComponents([.year, .month, .day], from: next)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        ) == newDayKey
    }

    /// Local noon of the calendar date a day key names — far enough from both midnight and
    /// the 03:00 rollover that no DST switch can push it into a neighbouring day.
    private func date(forDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private func weekKey(forDayKey key: String) -> String? {
        date(forDayKey: key).map(weekKey(for:))
    }
}
