import SandglassCore
import Foundation

/// The arithmetic behind the Time windows card: adding one, taking one out, and the two pictures
/// drawn from the list.
///
/// It is here rather than in the views because every step of it is a rule the user would only
/// discover by being blocked at the wrong hour — an edit that reordered the list under them, a
/// strip that claimed a day nothing applies on, a bar that drew a bedtime window as one block
/// running off the end of the day. A view that owned this would be a rule nobody could test, and
/// the time windows are exactly the feature that turned out not to work.
///
/// Nothing here reads a clock. Whether a window is *open* is `WindowClock`'s question, and it is
/// the engine's; this is about the list as the editor sees it.
public enum TimeWindowList {

    // MARK: - Editing

    /// The list with `window` added, or replaced in place when it is already in it.
    ///
    /// In place, so an edit cannot reorder the list under the user — the list is what the strip
    /// underneath is drawn from, and a row that jumped on save would read as a different window.
    public static func merging(_ window: TimeWindow, into windows: [TimeWindow]) -> [TimeWindow] {
        var updated = windows
        if let index = updated.firstIndex(where: { $0.id == window.id }) {
            updated[index] = window
        } else {
            updated.append(window)
        }
        return updated
    }

    public static func removing(_ windowID: String, from windows: [TimeWindow]) -> [TimeWindow] {
        windows.filter { $0.id != windowID }
    }

    /// Whether a change would leave the group's week without one uncovered minute, when the list
    /// it replaces still had one.
    ///
    /// Asked of the two whole *lists* rather than of the window being touched, because that is
    /// the only form of the question that is true of every way in. Two windows can add up to a
    /// gapless week that neither is on its own — so it cannot be asked of one window — and a week
    /// can be closed by **taking a window out** as easily as by putting one in: delete the one
    /// break holding a seven-day block open and the result is the same trap, which is why gating
    /// on "a strict block is being saved" missed the delete button entirely.
    ///
    /// What it warns about: a group blocked around the clock has its knobs, its switch and its
    /// delete button locked for as long as that is true, and only its window list stays reachable.
    /// A week that was already gapless before the change raises nothing — the user is in that
    /// state already, and warning about it every time they redraw the list is how a warning
    /// becomes something to click past.
    public static func closesTheWeek(_ updated: [TimeWindow], replacing current: [TimeWindow]) -> Bool {
        TimeWindow.strictBlocksEveryMinute(of: updated)
            && !TimeWindow.strictBlocksEveryMinute(of: current)
    }

    // MARK: - Drawing

    /// Every weekday any window in the list has an opinion about — the sidebar card's strip.
    ///
    /// The union, whatever the opinion is: one glance says which days this group behaves
    /// differently on. A window naming no day contributes none, which is what keeps the strip
    /// from lighting up for a window that applies at no moment at all.
    public static func weekdays(in windows: [TimeWindow]) -> Set<Int> {
        windows.reduce(into: Set<Int>()) { $0.formUnion($1.weekdays) }
    }

    /// What the list is mostly about, for the one-line summaries that can only name one thing.
    ///
    /// **Minutes, not a count of windows.** One seven-day block with three lunch breaks cut out of
    /// it is a blocked group with holes in it, and a sidebar card naming Break because there are
    /// three of them would be wrong about the only thing that card is for. A tie goes to the
    /// strict block: it is the more consequential of the two and the one somebody scanning the
    /// list is looking for.
    ///
    /// `nil` when the list is empty, and also when every window in it names no day — those apply
    /// at no moment, so there is nothing to be mostly.
    public static func dominantKind(in windows: [TimeWindow]) -> TimeWindow.Kind? {
        var minutes: [TimeWindow.Kind: Int] = [:]
        for window in windows {
            for weekday in 1...7 {
                for span in spans(of: window, onWeekday: weekday) {
                    minutes[window.kind, default: 0] += span.end - span.start
                }
            }
        }
        let blocked = minutes[.strictBlock] ?? 0
        let free = minutes[.break] ?? 0
        guard blocked > 0 || free > 0 else { return nil }
        return free > blocked ? .break : .strictBlock
    }

    /// Where one window sits **on one weekday**, in minutes from that day's midnight.
    ///
    /// A window that crosses midnight is two spans on two different days: the evening on the day
    /// it is ticked for, and the morning on the day after. Both halves are here because both are
    /// asked of every weekday — Tuesday's row of a Mon–Fri bedtime block carries Monday night's
    /// tail *and* Tuesday night's head, which is exactly what the engine does with it and what
    /// `TimeWindow.contains(weekday:minutes:)` says.
    ///
    /// The weekday is the whole point. This used to be asked of the window alone, which drew every
    /// window on one composite bar: a Monday-to-Friday block and a Saturday break landed on the
    /// same strip, so the picture said the group was both blocked and free every day of the week.
    /// A window naming no day draws nothing on any day — it applies at no moment, and a bar
    /// claiming otherwise would be the app being wrong out loud.
    public static func spans(
        of window: TimeWindow, onWeekday weekday: Int
    ) -> [(start: Int, end: Int)] {
        var spans: [(start: Int, end: Int)] = []
        if window.weekdays.contains(weekday) {
            let end = window.crossesMidnight ? TimeWindow.minutesInDay : window.endMinutes
            if end > window.startMinutes { spans.append((window.startMinutes, end)) }
        }
        if window.crossesMidnight, window.endMinutes > 0,
           window.weekdays.contains(TimeWindow.dayBefore(weekday)) {
            spans.append((0, window.endMinutes))
        }
        return spans
    }

    /// The same, as fractions of the day, for one kind of window at a time.
    ///
    /// One kind at a time because a row is drawn in precedence order — strict block, then break —
    /// so what sits on top where two windows overlap is what the engine would actually do.
    public static func segments(
        ofKind kind: TimeWindow.Kind, in windows: [TimeWindow], onWeekday weekday: Int
    ) -> [(start: Double, width: Double)] {
        let day = Double(TimeWindow.minutesInDay)
        let spans: [(start: Int, end: Int)] = windows
            .filter { $0.kind == kind }
            .flatMap { self.spans(of: $0, onWeekday: weekday) }
        return spans.map { span in
            (start: Double(span.start) / day, width: Double(span.end - span.start) / day)
        }
    }
}
