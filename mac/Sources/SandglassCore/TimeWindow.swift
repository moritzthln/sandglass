import Foundation

/// A recurring stretch of local time in which one group behaves differently from the rest of
/// its day.
///
/// Replaces V1's single `BlockSchedule` plus its separate always-block switch. A group owns a
/// list of these, which is strictly more expressive *and* strictly less to hold in your head:
/// "blocked 06:00–12:00, budgeted the rest of the day" is two windows, "free 20:00–22:00" is
/// one, and always-block is a `.strictBlock` window over all seven days.
///
/// **Wall-clock, not an interval on the absolute timeline.** 09:00 means 09:00 local on both
/// sides of a DST switch and after a flight, exactly as V1's schedule did.
///
/// **Windows may cross midnight**, which V1 could not express at all: `endMinutes <=
/// startMinutes` means the window runs on into the next day, so 22:00–08:00 is a bedtime
/// window rather than a window that matches nothing.
///
/// **`weekdays` names the day a window *starts* on.** A bedtime window with Monday ticked
/// covers Monday 22:00–24:00 *and* Tuesday 00:00–08:00. That is the reading someone ticking
/// "Monday" for "block me on Monday night" expects; attributing the tail to Tuesday would put
/// half of Monday night under a tick the user did not make.
public struct TimeWindow: Codable, Equatable, Sendable, Identifiable {

    /// What the window does while it is open. Where two overlap, the higher kind here wins:
    /// **break > strictBlock** — see `RulesEngine`.
    ///
    /// Two kinds, and there is nothing between them: a window is either harder than the rest of
    /// the week or softer than it. A third case — `limit`, "the group's ordinary budget applies"
    /// — was carried for two waves and appeared nowhere in the engine, because that is exactly
    /// what happens with no window at all. It was the first row of the chooser, so a user's first
    /// window was a decoration the timeline then confirmed with a coloured band. See
    /// `DecodedTimeWindow` for what becomes of the ones already on disk.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Hard-blocked: no opens at all, and the group's settings are frozen until it closes.
        case strictBlock
        /// Fully open: no pause screen, no budget spent, no friction of any kind.
        case `break`

        /// The other one. There are two, and a summary that names one often has to name what is
        /// left — spelling that as a `switch` at each call site is one more place to update if a
        /// third kind ever earns its place.
        public var other: Kind { self == .strictBlock ? .break : .strictBlock }
    }

    /// A one-tap shape: three sets of values the editor's chips fill the fields with.
    ///
    /// **Not a field on the window.** It used to be stored beside the values it described, which
    /// is two places for one fact, and they drifted on the first click: `make(.custom, …)` fell
    /// back to the work-day values while labelling them Custom, so every new window opened on
    /// Mon–Fri 9-to-5 with the Work day chip unlit. `livePreset` reads it back off the values
    /// instead — the rule a group's own preset already follows.
    ///
    /// There is no `custom` case for the same reason there is no Custom chip: "matches none of
    /// them" is `livePreset == nil`, which is a state to be in rather than one to choose.
    public enum Preset: String, Sendable, CaseIterable { case allDay, workDay, bedtime }

    public var id: String
    public var kind: Kind
    /// `Calendar.weekday`: 1 = Sunday … 7 = Saturday. The day the window *starts* on.
    public var weekdays: Set<Int>
    /// Minutes from local midnight; 540 = 09:00.
    public var startMinutes: Int
    /// Minutes from local midnight; 1020 = 17:00, 1440 = the end of the day.
    ///
    /// `endMinutes <= startMinutes` crosses midnight. Equal ends are not empty but 24 hours
    /// long — 08:00–08:00 runs from one morning to the next — because an empty window is
    /// something the editor must not be able to produce by nudging one control.
    public var endMinutes: Int

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        weekdays: Set<Int>,
        startMinutes: Int,
        endMinutes: Int
    ) {
        self.id = id
        self.kind = kind
        self.weekdays = weekdays
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    // MARK: - Containment

    public static let minutesInDay = 24 * 60

    /// The minutes a window may **start** at: one of the day's 1440, and never 24:00.
    ///
    /// 24:00 is not a later start than 23:59 — it is 00:00 the following day, and `contains`
    /// below reads it exactly that way. `crossesMidnight` is true for any window starting there,
    /// so its head can never match (no minute of a day is `>= 1440`) and only its tail applies,
    /// on the day *after* every weekday it is ticked for. Ticking Monday would block Tuesday, and
    /// the row would read "midnight – 8 AM" over a window that keeps neither that hour nor that
    /// day. The far edge of a day is an end and only an end.
    ///
    /// The **end** has no such problem and keeps the full span: 24:00 there is the end of the
    /// ticked day, which is what `.allDay` means by it.
    public static let startRange = 0...(minutesInDay - 1)
    public static let endRange = 0...minutesInDay

    /// Every day of the week, as `Calendar.weekday` numbers.
    public static let everyDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    /// Monday to Friday.
    public static let workWeek: Set<Int> = [2, 3, 4, 5, 6]

    public var crossesMidnight: Bool { endMinutes <= startMinutes }

    /// Whether a moment — given as its weekday and its minutes from midnight — is inside this
    /// window.
    ///
    /// A window that names no day matches nothing. That is a state the editor can be left in
    /// mid-edit, and it has to mean "off" rather than "every day".
    public func contains(weekday: Int, minutes: Int) -> Bool {
        guard !weekdays.isEmpty else { return false }
        guard crossesMidnight else {
            return weekdays.contains(weekday) && minutes >= startMinutes && minutes < endMinutes
        }
        // The head, on the day the window is ticked for …
        if minutes >= startMinutes, weekdays.contains(weekday) { return true }
        // … and the tail, which belongs to the day before.
        return minutes < endMinutes && weekdays.contains(TimeWindow.dayBefore(weekday))
    }

    /// Minutes from a moment inside the window until it closes.
    ///
    /// Measured forwards from a time of day rather than as a difference between two wall-clock
    /// times, so a window that crosses midnight answers "nine hours" at 23:00 rather than a
    /// negative number. Used to pick the block that lifts last where several overlap, and to
    /// stay right across a DST switch: both sides of the comparison are measured from the same
    /// moment.
    public func minutesUntilEnd(from minutes: Int) -> Int {
        let delta = endMinutes - minutes
        return delta > 0 ? delta : delta + TimeWindow.minutesInDay
    }

    public static func dayBefore(_ weekday: Int) -> Int { weekday == 1 ? 7 : weekday - 1 }

    public static func dayAfter(_ weekday: Int) -> Int { weekday == 7 ? 1 : weekday + 1 }

    /// The first minute of the week, at or after the one given, at which no strict block in this
    /// list is standing — as the weekday and the minute of day it falls on. `nil` where the list
    /// leaves no such minute anywhere in the week.
    ///
    /// What a block that lasts "until the day's counters come back" has to be measured against: the
    /// counters return at the day's start whatever the schedule says, but a group cannot be opened
    /// in a minute a window has shut. See `WindowClock.nextOpenMinutes`.
    ///
    /// Breaks are subtracted, exactly as `WindowClock.strictWindow` subtracts them: a deliberate
    /// hole in the week is a minute the group is fully open in, and it is a way out of a block that
    /// arrives before the block's own end.
    ///
    /// Every minute is walked rather than each window's end jumped to, for that last reason and for
    /// the reason the two rules above are: `contains(weekday:minutes:)` is the one place the
    /// reading of a window is written down, and a second implementation of it could disagree. A
    /// week is 10,080 minutes and the walk stops at the first free one, which for every schedule a
    /// person would draw is a few hundred.
    public static func firstUnblockedMinute(
        of windows: [TimeWindow], fromWeekday weekday: Int, minutes: Int
    ) -> (weekday: Int, minutes: Int)? {
        var weekday = weekday
        var minutes = minutes
        for _ in 0..<(7 * minutesInDay) {
            if !isStrictlyBlocked(windows, weekday, minutes) { return (weekday, minutes) }
            minutes += 1
            if minutes == minutesInDay { minutes = 0; weekday = dayAfter(weekday) }
        }
        return nil
    }

    /// Whether these windows, taken together, hard-block **every minute of the week** — the
    /// shape that leaves a group's settings locked for good, since the lock keys off "a strict
    /// window is open right now" and one never closes.
    ///
    /// The union of the list, not one window: two half-days, or a bedtime plus an office-hours
    /// block, can add up to the same gapless week that one all-day window does. Break windows
    /// are subtracted, because they outrank a block in `RulesEngine.activeStrictWindow` — a
    /// deliberate hole in the week is a way out, and the guard rail must not cry trap over one.
    ///
    /// Every minute is walked rather than the intervals merged: windows cross midnight, name
    /// the day they *start* on, and may be listed in any order, and the one place that reading
    /// is written down is `contains(weekday:minutes:)`. Ten thousand calls to it on a button
    /// press is cheaper than a second implementation of the same rule that could disagree.
    public static func strictBlocksEveryMinute(of windows: [TimeWindow]) -> Bool {
        guard windows.contains(where: { $0.kind == .strictBlock }) else { return false }
        for weekday in 1...7 {
            for minute in 0..<minutesInDay where !isStrictlyBlocked(windows, weekday, minute) {
                return false
            }
        }
        return true
    }

    private static func isStrictlyBlocked(
        _ windows: [TimeWindow], _ weekday: Int, _ minute: Int
    ) -> Bool {
        var blocked = false
        for window in windows where window.contains(weekday: weekday, minutes: minute) {
            if window.kind == .break { return false }
            if window.kind == .strictBlock { blocked = true }
        }
        return blocked
    }

    /// Whether these windows, taken together, cover **every minute of the week** — the shape in
    /// which the group's own friction is never reached at all.
    ///
    /// `RulesEngine.decision(for:)` answers `.notManaged` inside a break window and `.blocked`
    /// inside a strict one, and only falls through to the pause countdown, the opens budget, the
    /// cooldown and the session length when *neither* is open. A week with no gap in it therefore
    /// runs on none of them, whatever numbers they hold. See `EditorCards`, which answers it by
    /// taking the card that holds them off the page rather than leaving seven live-looking knobs
    /// to imply otherwise.
    ///
    /// **Both kinds count.** That is what makes this a different question from
    /// `strictBlocksEveryMinute` above, which subtracts breaks because a break is a way back into
    /// a locked settings screen. Here a break covers its minute exactly as a block does: fully
    /// open spends no budget and shows no pause screen, so it is as far from the knobs as a block
    /// is. A week of one all-day break reaches them precisely as often as a week of one all-day
    /// block — never.
    ///
    /// Every minute is walked rather than the intervals merged, for the reason the rule above is:
    /// windows cross midnight, name the day they *start* on, and may overlap in any order, and
    /// `contains(weekday:minutes:)` is the one place that reading is written down. No windows at
    /// all is the ordinary case and answers `false` on the first minute tried.
    public static func coversEveryMinute(of windows: [TimeWindow]) -> Bool {
        for weekday in 1...7 {
            for minute in 0..<minutesInDay where !isCovered(windows, weekday, minute) {
                return false
            }
        }
        return true
    }

    private static func isCovered(
        _ windows: [TimeWindow], _ weekday: Int, _ minute: Int
    ) -> Bool {
        windows.contains { $0.contains(weekday: weekday, minutes: minute) }
    }

    // MARK: - Comparing two weeks

    /// One window with its identity left out: the kind, and the stretch of the week it covers.
    ///
    /// Two lists describe the same week when they hold the same shapes — whatever ids those
    /// windows carry, and whatever order they are listed in. Neither is a fact about what is
    /// blocked: `RulesEngine` reads a list as a set, and `ConfigSwap` says the same thing about
    /// the scope a group carries.
    ///
    /// Comparing `[TimeWindow]` directly cannot answer that question at all, because every window
    /// carries a `UUID` of its own and applying a preset *copies* its windows onto the group — so
    /// an identically drawn week compares unequal, and the group would show as Custom the moment
    /// it was put on the preset. See `ConfigBuilder.presetID(matching:in:)`.
    public struct Shape: Hashable, Comparable, Sendable {
        public let kind: Kind
        /// Sorted, so that two spellings of the same set of days are one shape.
        public let weekdays: [Int]
        public let startMinutes: Int
        public let endMinutes: Int

        /// A total order, so two lists can be compared element by element after sorting. What it
        /// puts first means nothing beyond being the same first for the same set of windows.
        public static func < (lhs: Shape, rhs: Shape) -> Bool {
            if lhs.startMinutes != rhs.startMinutes { return lhs.startMinutes < rhs.startMinutes }
            if lhs.endMinutes != rhs.endMinutes { return lhs.endMinutes < rhs.endMinutes }
            if lhs.kind != rhs.kind { return lhs.kind == .strictBlock }
            return lhs.weekdays.lexicographicallyPrecedes(rhs.weekdays)
        }
    }

    public var shape: Shape {
        Shape(
            kind: kind,
            weekdays: weekdays.sorted(),
            startMinutes: startMinutes,
            endMinutes: endMinutes
        )
    }

    /// Every window's shape, in an order that depends on the shapes and not on the list.
    public static func shapes(of windows: [TimeWindow]) -> [Shape] {
        windows.map(\.shape).sorted()
    }

    // MARK: - Presets

    /// The values behind a one-tap preset. The one place the presets become numbers, so the
    /// editor's chips, `livePreset` and the migration below cannot drift apart.
    public static func values(
        for preset: Preset
    ) -> (weekdays: Set<Int>, startMinutes: Int, endMinutes: Int) {
        switch preset {
        case .allDay: return (everyDay, 0, minutesInDay)
        case .workDay: return (workWeek, 9 * 60, 17 * 60)
        case .bedtime: return (everyDay, 22 * 60, 8 * 60)
        }
    }

    /// Which one-tap shape this window *is*, or `nil` for a shape of its own.
    ///
    /// Read off the values every time rather than stored beside them, so a chip can never be lit
    /// over numbers it does not describe — and a hand-edited `config.json` cannot carry a label
    /// that stopped being true. The kind is deliberately no part of it: a preset is the shape of a
    /// week, and the same 22:00–08:00 is a bedtime block or an evening off.
    public var livePreset: Preset? {
        Preset.allCases.first { preset in
            let values = TimeWindow.values(for: preset)
            return values.weekdays == weekdays
                && values.startMinutes == startMinutes
                && values.endMinutes == endMinutes
        }
    }

    /// A window built from a preset.
    public static func make(
        _ preset: Preset, kind: Kind, id: String = UUID().uuidString
    ) -> TimeWindow {
        let values = TimeWindow.values(for: preset)
        return TimeWindow(
            id: id,
            kind: kind,
            weekdays: values.weekdays,
            startMinutes: values.startMinutes,
            endMinutes: values.endMinutes
        )
    }

    // MARK: - Coding

    /// `preset` is listed and never read. Files written before the chip was derived carry a label
    /// beside the values; leaving it out of both halves below is what stops a dead key being
    /// written back on every save for the rest of the app's life.
    private enum CodingKeys: String, CodingKey {
        case id, kind, weekdays, startMinutes, endMinutes, preset
    }

    /// `weekdays` is a `Set`, and a `Set` iterates in an order that changes from one process to
    /// the next. Sorting on the way out is what keeps config.json from looking edited on every
    /// launch; the way back in is a plain `Set`, so a hand-edited file may list its days in any
    /// order and repeat them.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(weekdays.sorted(), forKey: .weekdays)
        try container.encode(startMinutes, forKey: .startMinutes)
        try container.encode(endMinutes, forKey: .endMinutes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        weekdays = Set(try container.decode([Int].self, forKey: .weekdays))
        startMinutes = try container.decode(Int.self, forKey: .startMinutes)
        endMinutes = try container.decode(Int.self, forKey: .endMinutes)
    }
}

/// A window as a file may still hold it, or **nothing** where it names a kind this build has
/// dropped. Decode `[DecodedTimeWindow]` and `compactMap` it; see `GroupSettings.init(from:)`.
///
/// One kind has been dropped so far: `limit`, which meant "the group's ordinary budget applies"
/// and was therefore indistinguishable from having no window at all. It changed nothing while it
/// existed, so a stored one is dropped rather than translated — there is no behaviour to preserve
/// and inventing a `strictBlock` in its place would start blocking hours the user never asked to
/// lose. What goes with it is a coloured band on the timeline and a row in the list.
///
/// A wrapper rather than a forgiving `Kind` decoder, because leaving an element out is a decision
/// only the *array* can take: `TimeWindow.init(from:)` has no way to decline to exist. And a
/// wrapper rather than nothing at all, because `Store` reads a document it cannot decode as
/// corruption and renames it to `.bad` — one obsolete window would cost the user every group.
public struct DecodedTimeWindow: Decodable, Sendable {
    public let window: TimeWindow?

    private enum CodingKeys: String, CodingKey { case kind }

    /// Kinds this build no longer honours, by the name they were written under.
    private static let dropped: Set<String> = ["limit"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind)
        if let kind, Self.dropped.contains(kind) {
            window = nil
        } else {
            window = try TimeWindow(from: decoder)
        }
    }
}
