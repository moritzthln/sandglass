import Foundation

/// One group hard-blocked until a chosen day — the third statement about when a group blocks.
///
/// Weekly windows repeat; a dated block happens once. Everything in the group is shut until the
/// chosen day *begins*, and then the ordinary week takes over again. No new concept beside the
/// windows: while it stands it simply outranks them.
///
/// **A calendar day, not an instant**, and that is the whole of the design. The end is "when that
/// day begins by `Config.dayStartMinutes`", so moving the start of the day moves the end with it,
/// which is the honest reading of a promise made in days. The day is stored in the spelling
/// `EngineState.dayKey` already uses for every budget in this app — `yyyy-MM-dd`, Gregorian,
/// shifted by the day start — and the engine compares it against the day key it is already
/// holding. One piece of calendar arithmetic, so there is no second one to disagree with it: a
/// DST switch, a flight and a changed day start are all handled exactly as a day's budget handles
/// them, by the end not being a duration at all.
///
/// The words are here rather than in the app for the reason `BlockEnd.clause` is: the engine's own
/// sentence carries the date, and one home for how a day is spelled is what keeps the sidebar, the
/// menu bar and the group editor from wording the same fact three ways.
public enum DatedBlock {

    // MARK: - The day this moment is in

    /// The day a moment belongs to. `EngineState.dayKey` under a name that reads in this feature's
    /// vocabulary — forwarded rather than spelled out again, so the block's end and the budget's
    /// rollover can never draw the boundary in two places.
    public static func today(at date: Date, calendar: Calendar, dayStartMinutes: Int) -> String {
        EngineState.dayKey(for: date, calendar: calendar, dayStartMinutes: dayStartMinutes)
    }

    /// The stored day while the block is still standing, or `nil` when there is none — **or when
    /// the day has arrived**.
    ///
    /// A past day reads as absent everywhere: the engine's decision, every screen, and the
    /// direction table a lock is judged by. It is dropped by the next save, the way the retired
    /// keys are, so nothing has to remember it was ever there.
    ///
    /// Strictly later, because the block ends when the named day *begins*: on the morning of the
    /// 25th the day key already reads `2026-08-25`, and that is the moment the group opens again.
    public static func standing(_ day: String?, onDay today: String) -> String? {
        guard let day, day > today else { return nil }
        return day
    }

    // MARK: - What a stored day may be

    /// A stored day this build can read, or `nil` for anything else.
    ///
    /// Every comparison here is a string comparison, which is a date comparison only while the
    /// string is a real `yyyy-MM-dd`. So a hand-edited `config.json` — or a key from some future
    /// build — is read as no dated block rather than as a block whose end nothing can name, and
    /// the value is re-derived on the way in for the reason `Target.id` is: `2026-8-5` and
    /// `2026-08-05` are the same day and must not sort as two.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw, let parts = parts(of: raw) else { return nil }
        return key(year: parts.year, month: parts.month, day: parts.day)
    }

    /// `yyyy-MM-dd`, the one spelling — `EngineState.dayKey`'s, written the same way.
    private static func key(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The three numbers behind a day key, or `nil` where they are not a day.
    ///
    /// A round trip through the calendar rather than a range check on each field: `2027-02-29` is
    /// three plausible numbers and not a date, and a lenient calendar answers it with 1 March. Only
    /// a day that comes back as itself is a day.
    private static func parts(of raw: String) -> (year: Int, month: Int, day: Int)? {
        let fields = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, let year = Int(fields[0]), let month = Int(fields[1]),
              let day = Int(fields[2]), year > 0 else { return nil }
        let wanted = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = readingCalendar.date(from: wanted) else { return nil }
        let back = readingCalendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return (year, month, day)
    }

    /// The calendar every day key is read in here: Gregorian in UTC.
    ///
    /// A day key names a day and carries no hour, so the zone it is read back in only has to be the
    /// same one it is read back in everywhere — noon keeps a DST switch from moving the date under
    /// either end. Which zone the *key itself* was worked out in is `EngineState.dayKey`'s question
    /// and is answered there, from the running calendar.
    private static let readingCalendar = Calendar.sandglassGregorian(
        in: TimeZone(secondsFromGMT: 0) ?? .current
    )

    /// Midday on a stored day, in the given zone — what a date picker is seeded with and reads
    /// back. Noon rather than midnight, so no zone or DST switch can land it on the day before.
    public static func date(_ day: String, calendar: Calendar) -> Date? {
        guard let parts = parts(of: day) else { return nil }
        return Calendar.sandglassGregorian(in: calendar.timeZone).date(
            from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)
        )
    }

    /// The day a picked date names — the calendar day it is drawn on, with **no** day-start shift.
    ///
    /// Deliberately not `today(at:…)`: a date picker draws calendar days, so a click on the 25th
    /// means the 25th. Read through the day start instead, midnight on the 25th would fall in the
    /// day that began at 01:00 on the 24th and the picked date would come back a day early.
    public static func day(picked date: Date, calendar: Calendar) -> String {
        let parts = Calendar.sandglassGregorian(in: calendar.timeZone)
            .dateComponents([.year, .month, .day], from: date)
        return key(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    // MARK: - The spans the control offers

    /// The one-tap lengths offered before the date picker, in the order they are shown.
    ///
    /// **Every one of them resolves to a date before anything is saved**, which is what makes them
    /// honest rather than a trap: "1 day" chosen at 23:00 lands on tomorrow's day start a couple of
    /// hours away, and the row says which day that is while there is still time to pick another.
    /// No special case for a late evening, because the answer is on screen.
    public enum Span: String, CaseIterable, Sendable {
        case day, threeDays, week, twoWeeks, month

        public var title: String {
            switch self {
            case .day: return "1 day"
            case .threeDays: return "3 days"
            case .week: return "1 week"
            case .twoWeeks: return "2 weeks"
            case .month: return "1 month"
            }
        }

        /// How far the span reaches, as the calendar unit it is counted in. A month is a month
        /// rather than thirty days, because that is what somebody choosing it means.
        var step: (component: Calendar.Component, value: Int) {
            switch self {
            case .day: return (.day, 1)
            case .threeDays: return (.day, 3)
            case .week: return (.day, 7)
            case .twoWeeks: return (.day, 14)
            case .month: return (.month, 1)
            }
        }
    }

    /// The day a span reaches, counted from the day `today` names. `nil` only for a `today` that
    /// is not a day at all.
    public static func day(_ span: Span, from today: String) -> String? {
        guard let parts = parts(of: today) else { return nil }
        let start = DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)
        guard let from = readingCalendar.date(from: start),
              let reached = readingCalendar.date(
                  byAdding: span.step.component, value: span.step.value, to: from
              ) else { return nil }
        let landed = readingCalendar.dateComponents([.year, .month, .day], from: reached)
        return key(year: landed.year ?? 0, month: landed.month ?? 0, day: landed.day ?? 0)
    }

    // MARK: - How a day is written down

    /// `Mon 24 Aug` — the engine's own sentence, read in the narrow places: a sidebar card, the
    /// menu bar, the block page. A date rather than an hour, because the end may be a week away.
    public static func shortText(_ day: String) -> String {
        guard let parts = parts(of: day), let weekday = weekday(of: parts) else { return day }
        return "\(shortDays[weekday] ?? "") \(parts.day) \(shortMonths[parts.month] ?? "")"
    }

    /// `Monday, 24 August` — the group editor's row, which has the width for it.
    public static func longText(_ day: String) -> String {
        guard let parts = parts(of: day), let weekday = weekday(of: parts) else { return day }
        return "\(longDays[weekday] ?? ""), \(parts.day) \(longMonths[parts.month] ?? "")"
    }

    /// `Blocked until Monday, 24 August` — the whole of the group editor's row when one is set.
    ///
    /// Through `BlockEnd.clause`, which is the one place that decides how a block's end is worded.
    /// The row and the engine's own sentence are the same statement at two widths, and two spellings
    /// of one fact is how a card and the sidebar beside it start disagreeing.
    public static func rowText(_ day: String) -> String {
        "Blocked \(BlockEnd.onDay(longText(day)).clause)"
    }

    /// `1 week · Mon 31 Aug` — a span with the day it actually reaches.
    ///
    /// The date is on the menu rather than worked out after the press, which is what makes the
    /// spans honest: "1 day" chosen late in the evening buys a couple of hours, and the row it is
    /// chosen from says which morning that is before anything is saved.
    public static func spanTitle(_ span: Span, from today: String) -> String {
        guard let reached = day(span, from: today) else { return span.title }
        return "\(span.title) · \(shortText(reached))"
    }

    private static func weekday(of parts: (year: Int, month: Int, day: Int)) -> Int? {
        let wanted = DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)
        guard let date = readingCalendar.date(from: wanted) else { return nil }
        return readingCalendar.dateComponents([.weekday], from: date).weekday
    }

    // Written out rather than taken from a `DateFormatter`, for the reason `WindowClock.clockText`
    // builds its own 24-hour text: every sentence this app says is English, and a Mac set to
    // another locale would otherwise get half a sentence in each. `Calendar.weekday` counts from
    // Sunday, exactly as `TimeWindowCopy` reads it.

    private static let shortDays = [
        1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat",
    ]

    private static let longDays = [
        1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday",
        5: "Thursday", 6: "Friday", 7: "Saturday",
    ]

    private static let shortMonths = [
        1: "Jan", 2: "Feb", 3: "Mar", 4: "Apr", 5: "May", 6: "Jun",
        7: "Jul", 8: "Aug", 9: "Sep", 10: "Oct", 11: "Nov", 12: "Dec",
    ]

    private static let longMonths = [
        1: "January", 2: "February", 3: "March", 4: "April", 5: "May", 6: "June",
        7: "July", 8: "August", 9: "September", 10: "October", 11: "November", 12: "December",
    ]
}
