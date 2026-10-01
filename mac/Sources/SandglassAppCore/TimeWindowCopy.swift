import SandglassCore
import Foundation

/// How a time window is written down for a person to read.
///
/// Twelve-hour clock, on purpose and only here: a window is a shape of a day — "10 PM – 8 AM"
/// reads as a night, "22:00 – 08:00" reads as a database row. Every *decision* the engine
/// announces stays on the 24-hour clock it always used ("Blocked until 17:00"), because those
/// are answers about one moment rather than pictures of a week.
///
/// In the shared module rather than in a view because it is arithmetic with wording attached,
/// and because the sidebar card, the window list and the timeline legend all say the same
/// things and must say them identically.
public enum TimeWindowCopy {

    /// What the window does, in the words the option rows and the list use.
    public static func kind(_ kind: TimeWindow.Kind) -> String {
        switch kind {
        case .strictBlock: return "Strict block"
        case .break: return "Break"
        }
    }

    /// The one-line explanation under each kind in the chooser.
    ///
    /// "Apps" is not what a group holds — sites are the half of it the browser watch exists for —
    /// so the block says what happens to the group rather than naming one kind of member.
    public static func kindDetail(_ kind: TimeWindow.Kind) -> String {
        switch kind {
        case .strictBlock: return "Nothing in this group opens"
        case .break: return "Allow full access"
        }
    }

    public static func preset(_ preset: TimeWindow.Preset) -> String {
        switch preset {
        case .allDay: return "All day"
        case .workDay: return "Work day"
        case .bedtime: return "Bedtime"
        }
    }

    /// `Every day · 6 AM – 12 PM` — the whole of a window in one line.
    public static func schedule(_ window: TimeWindow) -> String {
        "\(days(window.weekdays)) · \(range(window))"
    }

    /// `6 AM – 12 PM`, and `All day` for a window that covers one whole day.
    public static func range(_ window: TimeWindow) -> String {
        if window.startMinutes == 0, window.endMinutes == TimeWindow.minutesInDay {
            return "All day"
        }
        return "\(endpoint(window.startMinutes)) – \(endpoint(window.endMinutes))"
    }

    /// The common shapes of a week are named; anything else is listed, Monday first.
    public static func days(_ weekdays: Set<Int>) -> String {
        switch weekdays {
        case []: return "No days"
        case TimeWindow.everyDay: return "Every day"
        case TimeWindow.workWeek: return "Weekdays"
        case [7, 1]: return "Weekends"
        default:
            let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
            return mondayFirst.filter(weekdays.contains).compactMap { names[$0] }.joined(separator: ", ")
        }
    }

    /// The way the week is read everywhere in this app. `Calendar.weekday` counts from Sunday.
    public static let mondayFirst = [2, 3, 4, 5, 6, 7, 1]

    /// One letter for a day, for the strips and the round day buttons. M and T each appear twice
    /// in a week, so these are labels rather than identifiers — the position is what identifies.
    public static func letter(_ weekday: Int) -> String {
        [1: "S", 2: "M", 3: "T", 4: "W", 5: "T", 6: "F", 7: "S"][weekday] ?? ""
    }

    /// The full name, for the screen reader — where position says nothing and "T" is useless.
    public static func dayName(_ weekday: Int) -> String {
        [1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday",
         5: "Thursday", 6: "Friday", 7: "Saturday"][weekday] ?? "Day"
    }

    /// The name of the far edge of a day — the one minute the 12-hour clock cannot spell.
    ///
    /// `hour12` wraps, so it prints `12 AM` for both 0 and 1440, and those are two different
    /// numbers: see `TimeWindow.endMinutes`. Everywhere the two can meet — the row, the field a
    /// window's end is typed into, the parser that reads it back — the far one is this word
    /// instead, which is a name a clock face has no way to be confused with.
    ///
    /// Lower case because it is read in the middle of a line: `9 AM – midnight`.
    public static let endOfDay = "midnight"

    /// One end of a window, in the notation the row prints **and the field is typed in**.
    ///
    /// The single spelling of a window's ends, which is the whole point of it: `FieldNotation.clock`
    /// drafts with this function, so what a row shows at rest and what a keyboard is handed the
    /// moment it is clicked into cannot be two different notations. They were, and the row changed
    /// face under the cursor — `9:30 AM` at rest and `09:30` while typing.
    ///
    /// It could not simply be `hour12` for the reason `endOfDay` exists: a 12-hour draft that
    /// printed 1440 as `12 AM` would read it back as 0, and clicking into an all-day window's end
    /// and out again would quietly turn it into a window crossing midnight — losing "All day" off
    /// the row and the All day chip with it. Naming that one minute is what buys the other 1440
    /// their own clock.
    public static func endpoint(_ minutes: Int) -> String {
        minutes == TimeWindow.minutesInDay ? endOfDay : hour12(minutes)
    }

    /// `6 AM`, `12 PM`, `10:30 PM`. Midnight is `12 AM`, and the minutes are dropped when there are
    /// none — a strip of "6:00 AM" labels is noise.
    ///
    /// Wraps, so it answers about a *moment* rather than about a number a window holds: 1440 comes
    /// back as `12 AM`, the same as 0. Anything printing one end of a window wants `endpoint` above,
    /// which keeps the two apart.
    public static func hour12(_ minutes: Int) -> String {
        let wrapped = ((minutes % TimeWindow.minutesInDay) + TimeWindow.minutesInDay)
            % TimeWindow.minutesInDay
        let hour24 = wrapped / 60
        let minute = wrapped % 60
        let suffix = hour24 < 12 ? "AM" : "PM"
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return minute == 0 ? "\(hour12) \(suffix)" : String(format: "%d:%02d %@", hour12, minute, suffix)
    }

    /// The warning under the two time controls when the end has walked past the start.
    public static let crossesMidnightHint = "Crosses midnight — it ends the next morning."

    /// The question asked before a change closes the last gap in a group's week — put here
    /// rather than in either screen because two screens ask it now, the window sheet on the way
    /// in and the list's trash button on the way out, and the same trap deserves the same words.
    public static let aroundTheClockTitle = "This blocks around the clock"
    public static let aroundTheClockMessage = "This group's other settings stay locked for as long as it applies, which is every minute of the week. Changing the window itself is the way back — that is the one thing a block does not freeze."

    /// What a group's windows add up to, for the one line under its name in the sidebar.
    /// `nil` for a group with none, which is a group that behaves the same way all week.
    ///
    /// **Both halves of it used to be unreadable.** One window printed its hours and not its kind,
    /// so a nightly break and a nightly block were the same line — "10 PM – 8 AM" over a group
    /// that was either locked all night or deliberately free all night. Several printed
    /// "2 time windows", which is a count of rows in a list the reader is not looking at rather
    /// than anything about their week.
    ///
    /// The days are left to the strip beside it, which draws all seven of them; putting them here
    /// as well would be the same fact twice in a 320-point column.
    public static func summary(_ windows: [TimeWindow]) -> String? {
        guard !windows.isEmpty else { return nil }
        guard let dominant = TimeWindowList.dominantKind(in: windows) else {
            // Every window names no day, so none of them applies at any moment. The editor warns
            // about exactly this state; the card must not paper over it with an hour range.
            return "No days chosen"
        }
        guard windows.count > 1 else { return "\(kind(windows[0].kind)) · \(range(windows[0]))" }
        let matching = windows.filter { $0.kind == dominant }
        let line = "\(kind(dominant)) · \(days(TimeWindowList.weekdays(in: matching)))"
        let others = windows.count - matching.count
        guard others > 0 else { return line }
        return "\(line) · +\(others) \(kind(dominant.other).lowercased())\(others == 1 ? "" : "s")"
    }
}
