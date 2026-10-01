import Foundation

/// Wall-clock time, and every question about a group's time windows that depends on it.
///
/// Split out of `RulesEngine` because it is the one part of the engine that holds no state: a
/// calendar and the arithmetic over it. Keeping the calendar here rather than in the engine is
/// also what keeps the rule in one place — weekdays, clock faces and window edges are always
/// read in the Gregorian calendar with the injected time zone, because a window is a promise
/// about the clock on the wall and a user on a Buddhist or Hebrew system calendar must get the
/// same answer as everyone else.
///
/// A value, not a class: it is rebuilt from a time zone and compares equal for the same one, so
/// nothing about the engine's picture of the week can drift between two of them.
struct WindowClock {
    /// The calendar every wall-clock question is read in. Also handed to `StreakScoring`: the
    /// week a pass is charged to and the day a window belongs to must be read the same way.
    let gregorian: Calendar

    init(timeZone: TimeZone) {
        gregorian = Calendar.sandglassGregorian(in: timeZone)
    }

    // MARK: - Reading the clock face

    func minutesOfDay(_ date: Date) -> Int {
        let parts = gregorian.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// 24-hour wall-clock text, built from components rather than a `DateFormatter`, so a Mac
    /// set to 12-hour time still gets "17:00" and not "5:00 PM".
    func clockText(for date: Date) -> String { clockText(minutes: minutesOfDay(date)) }

    func clockText(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    // MARK: - Which of a group's windows are open

    /// Every window of the group that is open at `date`, in the order the group lists them.
    ///
    /// A window is wall-clock, not an interval on the absolute timeline: the same window blocks
    /// 09:00–17:00 local on both sides of a DST switch and after a flight.
    ///
    /// A switched-off group has no open windows. That is what keeps a group nobody is using from
    /// freezing the settings screen every weekday morning — and it is checked here rather than at
    /// each call site so that every question about windows agrees.
    func openWindows(of settings: GroupSettings, at date: Date) -> [TimeWindow] {
        guard settings.enabled, !settings.timeWindows.isEmpty else { return [] }
        let parts = gregorian.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday else { return [] }
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return settings.timeWindows.filter { $0.contains(weekday: weekday, minutes: minutes) }
    }

    /// Whether the group is inside a deliberate hole in its own week.
    func isInBreakWindow(_ settings: GroupSettings, at date: Date) -> Bool {
        openWindows(of: settings, at: date).contains { $0.kind == .break }
    }

    /// The strict block over the group at `date`: the open `strictBlock` window that closes
    /// last, or `nil` when none is open — including when a break window outranks them all.
    ///
    /// Last to close, not first found: two overlapping blocks are one block to the person looking
    /// at the screen, and naming the earlier end is the app being wrong out loud.
    func strictWindow(_ settings: GroupSettings, at date: Date) -> TimeWindow? {
        let open = openWindows(of: settings, at: date)
        guard !open.contains(where: { $0.kind == .break }) else { return nil }
        let minutes = minutesOfDay(date)
        return open
            .filter { $0.kind == .strictBlock }
            .max { $0.minutesUntilEnd(from: minutes) < $1.minutesUntilEnd(from: minutes) }
    }

    /// When the block standing over the group ends, or that it does not. See `BlockEnd`.
    ///
    /// `window` is the one that closes last — `strictWindow` above — but the question asked here is
    /// about the group's **whole week**, because that is what decides whether the hour that window
    /// carries is ever reached at all. `TimeWindow.strictBlocksEveryMinute` is the rule, and it is
    /// the same rule the group editor uses to warn that a change would close the last gap: one
    /// answer, so the editor cannot say a week has no way out while the sidebar names an hour.
    func end(of window: TimeWindow, in settings: GroupSettings) -> BlockEnd {
        guard !TimeWindow.strictBlocksEveryMinute(of: settings.timeWindows) else { return .never }
        return .at(clockText(minutes: window.endMinutes))
    }

    // MARK: - When a spent day is worth anything again

    /// The wall-clock time a block that lasts until the day's counters come back actually ends
    /// at: the day's own boundary, or the end of whatever the group's windows are holding when it
    /// arrives — whichever is later.
    ///
    /// The counters return at `dayStartMinutes` and nothing about a schedule changes that. What a
    /// schedule changes is whether the returned budget can be spent, and the two came apart the
    /// moment somebody drew a bedtime window over a day that starts in the small hours: a day that
    /// begins at 01:00 and a video group blocked 23:30–12:00, so "Blocked until 01:00" named
    /// an hour at which nothing whatever could be opened, sixteen and a half of them early.
    ///
    /// The walk is `TimeWindow.firstUnblockedMinute`, which follows a chain of windows rather than
    /// naming the end of the first: one window closing where the next opens is not a way out.
    ///
    /// **A group whose week has no free minute in it answers with the boundary itself**, and that
    /// is unreachable rather than approximate. `RulesEngine.decision(for:)` asks this only after
    /// its strict-window branch has already declined to answer, which means no block is standing
    /// this second — and a minute this group is not shut out of is a minute the walk finds. The
    /// fallback is the one fact still true either way: the counters do come back then.
    func nextOpenText(_ settings: GroupSettings, dayStartMinutes: Int, at date: Date) -> String {
        clockText(minutes: nextOpenMinutes(settings, dayStartMinutes: dayStartMinutes, at: date))
    }

    private func nextOpenMinutes(
        _ settings: GroupSettings, dayStartMinutes: Int, at date: Date
    ) -> Int {
        guard settings.enabled, !settings.timeWindows.isEmpty else { return dayStartMinutes }
        let parts = gregorian.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday else { return dayStartMinutes }
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // The *next* boundary: one already reached today is one this block is on the far side of.
        let reset = minutes < dayStartMinutes ? weekday : TimeWindow.dayAfter(weekday)
        let free = TimeWindow.firstUnblockedMinute(
            of: settings.timeWindows, fromWeekday: reset, minutes: dayStartMinutes
        )
        return free?.minutes ?? dayStartMinutes
    }

    // The eight-day look-ahead that used to live here — `nextStart(of:after:)`, and the
    // component arithmetic under it that kept a DST switch from moving 09:00 to 10:00 — went with
    // its one caller. `RulesEngine` asked it where the next strict window opened so that a break
    // could be clamped to that moment; a break is not clamped to anything any more, and nothing
    // else ever needed to know.
}
