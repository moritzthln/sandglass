import SandglassCore
import Foundation

/// The rules a control follows when the value it is handed is not one it offers, and the span it
/// is allowed to offer at all.
///
/// They are here rather than in the views for the reason this whole target exists: `Sandglass`
/// is an executable and nothing can import it, so a rule written inside a `View` is a rule no
/// test can reach. Each is one expression; what earns them a name is that the first two were got
/// wrong once, in the same way — a control that quietly rewrites what it could not display — and
/// that the value can now arrive from a keyboard as well as from a file.
///
/// The shared principle: **the stored value is always reachable.** A `config.json` is a file
/// somebody can open, and this build's menus are not the only numbers it can hold — a hand-edited
/// value, or one an older build offered and this one no longer does. Showing it and letting the
/// user move away from it keeps the file's truth on screen. Snapping it to the nearest thing the
/// control likes hides an edit nobody asked for behind a screen they only came to look at.
public enum ControlRules {

    /// The menu, with `selection` appended when it is missing from it.
    ///
    /// A `Picker` whose selection matches no tag renders with nothing chosen, and then writes
    /// back whichever row is touched next — so the value is first invisible and then gone. Three
    /// of the app's four selects had noticed and were injecting the current value themselves; the
    /// settings lock's "Lock for" was not, which is why the rule moved into the control and this
    /// function is what the control calls.
    public static func menu<Value: Equatable>(_ options: [Value], containing selection: Value) -> [Value] {
        options.contains(selection) ? options : options + [selection]
    }

    /// The span a stepper offers, widened at whichever end is needed to hold `value`.
    ///
    /// `Stepper(value:in:)` disables the arrow that would leave its bounds, so a value already
    /// outside them has one dead arrow and no way back into the ordinary span — a 600-second
    /// pause with a 5...120 stepper beside it can only be looked at. Widening keeps the number
    /// honest *and* lets the user walk it back, which clamping the display would not: that would
    /// have the row claim a number the file does not hold.
    public static func reachableRange(_ range: ClosedRange<Int>, holding value: Int) -> ClosedRange<Int> {
        min(value, range.lowerBound)...max(value, range.upperBound)
    }

    // MARK: - A number that was typed rather than stepped

    /// A number read off the field, and whether the span had to hold it back.
    public struct TypedNumber: Equatable {
        /// What to write. Always inside the span it was read into.
        public let value: Int
        /// Whether the typed number lay outside that span. The field says so when it did.
        public let wasClamped: Bool

        public init(value: Int, wasClamped: Bool) {
            self.value = value
            self.wasClamped = wasClamped
        }
    }

    /// What a typed string comes to, held inside the span the arrows may reach.
    ///
    /// `nil` is "that was not a number", which the field answers by putting back the value it
    /// already held. An empty field, a stray letter, a bare minus sign, a number too long to be an
    /// `Int`: none of them is an amount, and a control that turned one into `0` would invent an
    /// answer out of a slip. There is nothing to dismiss, because nothing happened.
    ///
    /// A number outside the span is **clamped rather than dropped**, and `wasClamped` is how the
    /// field knows to say so out loud. Dropping it silently is the fault this whole file exists to
    /// argue against — the user typed something and the app appeared to ignore them — and refusing
    /// it with an error state would cost a dialogue for a slipped keystroke. Landing on the bound
    /// and naming the bound is the honest middle: it is a number the arrows could have reached.
    ///
    /// The span is the **reachable** one rather than the row's written range, which is the point of
    /// taking it as an argument. Under a running lock `GroupDetailColumn` hands the arrows a range
    /// that only permits tightening, and a typed number that stepped past it would make the
    /// keyboard a way to loosen a commitment the arrows refuse.
    public static func typed(_ text: String, into range: ClosedRange<Int>) -> TypedNumber? {
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let held = min(range.upperBound, max(range.lowerBound, number))
        return TypedNumber(value: held, wasClamped: held != number)
    }

    // MARK: - A time that was typed rather than stepped

    /// Minutes since midnight, read off a clock face somebody typed, or `nil` when what they typed
    /// is not a time the field can hold.
    ///
    /// This is the rule `typed(_:into:)` above could not be. The two ends of a window are the pair
    /// of numbers in the app whose stored value is not the value on screen — minutes since midnight
    /// under a label reading 9 AM — so the plain integer parser would have taken "9" for nine
    /// minutes past twelve, and the field was switched off rather than made to lie. Inverting the
    /// clock is this function.
    ///
    /// **The grammar.** Whitespace anywhere is ignored and case does not matter. What is left is:
    ///
    /// - One or two digits are an **hour**: `9` is 09:00 and `21` is 21:00. This is the ambiguity
    ///   that kept the field off, settled in favour of what somebody typing a window start means.
    ///   Nobody schedules anything for nine minutes past midnight, and anybody who does can type
    ///   `0:09`.
    /// - Three or four digits are hours and minutes: `930` is 09:30, `2130` is 21:30. Five or more
    ///   are nothing.
    /// - `:`, `.` and `,` all separate the two halves — `9:30`, `9.30`, `9,30` — and the minutes
    ///   after one may be written with or without their leading zero. A separator has already said
    ///   the rest is minutes, so `9:5` is five past nine; reading it as 9:50 would mean inventing a
    ///   trailing zero, which no clock notation does.
    /// - A trailing `am` or `pm` reads a 1...12 hour as a 12-hour one: `9pm` is 21:00, `12am` is
    ///   midnight, `12pm` is noon, `930pm` is 21:30. On any other hour it is nonsense rather than a
    ///   hint — `13 pm` is not a time, and guessing 13:00 from it would be the field inventing a
    ///   clock the user was not typing on.
    /// - Hours run 0...24 and minutes 0...59, and hour 24 only with no minutes at all: `24:00` is
    ///   the end of the day and `24:30` is not a time.
    /// - The word **`midnight`** is a face too, and the only one that is not digits. It is what the
    ///   field is handed for the far edge of the day, so it has to be readable back — see
    ///   `TimeWindowCopy.endOfDay` for why that edge needs a name at all, and the last paragraph
    ///   here for which of the two midnights it comes to.
    ///
    /// **Out of range reverts rather than clamping**, which is where this parts company with
    /// `typed(_:into:)` and its `wasClamped`. An amount past a bound has an honest nearest
    /// neighbour — 900 minutes of countdown is "as long as you will let me", and the bound is a
    /// fair reading of it. A clock face has none: `25:00` is not a wish for 23:59, it is a typo,
    /// and landing on a bound would leave a window covering hours nobody asked for. The two ends of
    /// a window differ by exactly one minute of range and the difference is load-bearing — see
    /// `TimeWindow.startRange`: a start of 24:00 is not late, it is tomorrow, so clamping it to
    /// 23:59 would keep a day the user did not type.
    ///
    /// Which leaves midnight, which each field spells its own way. `0:00` and `24:00` are the same
    /// instant and **different numbers**, the near and the far edge of the day, and both are
    /// meaningful: a start of 0:00 is a window that begins as the day does, an end of 24:00 is one
    /// that runs to the end of it, and `startMinutes == endMinutes` is a window 24 hours long. So
    /// neither is translated into the other. The end field's range holds both and the start field's
    /// holds only 0, which is the whole of what the range argument decides here.
    ///
    /// The word resolves by that same range: in the end field it is 1440, in the start field 0. It
    /// has to pick one, because a window has two ends and English has one word, and picking the far
    /// edge where the field reaches it is the reading that costs nothing — an end of 0 and an end of
    /// 1440 shut a group in exactly the same minutes (`TimeWindow.contains` reads them identically)
    /// while only 1440 also prints "All day", lights the All day chip and leaves
    /// `crossesMidnight` false. Where the field cannot reach it, 0 is the only midnight on offer.
    public static func typedClock(_ text: String, into range: ClosedRange<Int>) -> Int? {
        let body = text.lowercased().filter { !$0.isWhitespace }
        if body == TimeWindowCopy.endOfDay {
            let edge = range.contains(TimeWindow.minutesInDay) ? TimeWindow.minutesInDay : 0
            return range.contains(edge) ? edge : nil
        }
        guard let minutes = clockFace(body) else { return nil }
        return range.contains(minutes) ? minutes : nil
    }

    /// Where one press of a time control lands, from `minutes`, in the direction asked for: the
    /// next quarter-hour.
    ///
    /// The grid was half-hours, which put 9:15 out of reach of a control whose only job is to
    /// choose a time. A quarter-hour is the smallest unit anybody names a window in.
    ///
    /// A destination rather than a step size, for the reason `SettingsLock.timerMinutes(after:
    /// goingUp:)` is one, and now for a second: a value on no grid at all — typed, which these two
    /// numbers can be as of this change — steps *onto* the nearest grid line rather than carrying
    /// its offset up and down the day forever, and a press and its undo are each other, because
    /// going down asks about the minute below rather than reading the same grid line twice.
    ///
    /// Flat, where the lock's duration bands, and that is the difference between a length and a
    /// clock. Five minutes means nothing at three hours, so a duration's step grows with it; but
    /// 00:15 is exactly as nameable an hour as 15:00, and a grid that coarsened towards the evening
    /// would put 21:15 out of reach for no reason at all. A whole day is 96 presses, which is what
    /// the field above these arrows and the preset chips beside it are for.
    public static func clockMinutes(after minutes: Int, goingUp: Bool) -> Int {
        let step = 15
        return goingUp ? ((minutes / step) + 1) * step : ((minutes - 1) / step) * step
    }

    /// Minutes since midnight for a face somebody wrote, before anything knows which of the two
    /// fields it was written into. The whole of the digit grammar, and none of the range.
    ///
    /// Takes the text already lowercased and stripped of whitespace, because the one face that is
    /// not digits — `midnight` — has to be recognised against exactly the same cleaning, and doing
    /// it twice is two spellings of "ignores whitespace" waiting to disagree.
    private static func clockFace(_ cleaned: String) -> Int? {
        var body = cleaned
        let meridiem = Meridiem.allCases.first { body.hasSuffix($0.rawValue) }
        if let meridiem { body.removeLast(meridiem.rawValue.count) }
        guard let face = hourAndMinute(body), (0...59).contains(face.minute),
              let hour = hour24(face.hour, meridiem),
              hour < 24 || face.minute == 0
        else { return nil }
        return hour * 60 + face.minute
    }

    /// The two halves as they were written, by digit count and by separator. No range check yet:
    /// `2500` is a shape this reads and `clockFace` refuses.
    private static func hourAndMinute(_ body: String) -> (hour: Int, minute: Int)? {
        let parts = body.split(omittingEmptySubsequences: false) { ":.,".contains($0) }
        switch parts.count {
        case 1:
            guard let whole = wholeNumber(parts[0]) else { return nil }
            switch parts[0].count {
            case 1, 2: return (whole, 0)
            case 3, 4: return (whole / 100, whole % 100)
            default: return nil
            }
        case 2:
            guard parts[0].count <= 2, parts[1].count <= 2,
                  let hour = wholeNumber(parts[0]), let minute = wholeNumber(parts[1])
            else { return nil }
            return (hour, minute)
        default: return nil
        }
    }

    /// Digits and nothing else. `Int(_:)` alone would take "+9" and "-9", which are not faces of a
    /// clock, and a run of digits too long to hold is a paste rather than a time.
    private static func wholeNumber(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// A written hour on the 24-hour clock, or `nil` when the two notations disagree.
    private static func hour24(_ hour: Int, _ meridiem: Meridiem?) -> Int? {
        guard let meridiem else { return (0...24).contains(hour) ? hour : nil }
        guard (1...12).contains(hour) else { return nil }
        switch meridiem {
        case .am: return hour == 12 ? 0 : hour
        case .pm: return hour == 12 ? 12 : hour + 12
        }
    }

    private enum Meridiem: String, CaseIterable { case am, pm }

    // MARK: - The span a held number may still reach

    /// A number a running lock lets grow: the control keeps the direction that adds friction and
    /// loses the one that takes it away. Not held, the full span the row was written with.
    ///
    /// The floor is the value the group is running **right now** rather than a remembered one,
    /// which is what makes this honest without any state of its own: every edit on the group
    /// editor is saved the instant it is made, so what is on screen is what the lock compares
    /// against. `max` with the written top, so a stored value already above it stays reachable.
    ///
    /// It belonged to the strict windows and went with them; it is back because a lock holds a
    /// **direction** now — see `EditDirection`. Here rather than in the view because the narrowed
    /// span is what the typed field clamps into as well as what the arrows step through: a field
    /// reading the row's written range instead would be a one-keystroke way round a lock the
    /// arrows refuse, and a rule two controls depend on is a rule that has to be reachable by a
    /// test.
    public static func upwards(
        _ full: ClosedRange<Int>, from value: Int, tighteningOnly: Bool
    ) -> ClosedRange<Int> {
        guard tighteningOnly else { return full }
        return value...max(full.upperBound, value)
    }

    /// The same the other way, for the three numbers where less is stricter: a smaller opens
    /// budget, a shorter open, fewer minutes in the day.
    public static func downwards(
        _ full: ClosedRange<Int>, to value: Int, tighteningOnly: Bool
    ) -> ClosedRange<Int> {
        guard tighteningOnly else { return full }
        return min(full.lowerBound, value)...value
    }
}

/// How a field's number is written for the keyboard, and read back off it.
///
/// Two halves of one decision, kept together because they have to agree. Whatever `draft` puts in
/// the field, `read` has to give back unchanged, or clicking into a row and out of it again would
/// rewrite a number somebody only looked at. `ControlRulesTests` walks every minute of the day
/// through the pair to say so.
///
/// It replaces the `acceptsTyping` flag, which was a `Bool` because there was only ever one way to
/// write a number down — and which was off in exactly one place, the two ends of a time window,
/// for want of the second way. There is no third: a row either holds a quantity or holds a time.
public struct FieldNotation {
    /// What the field holds while it is being typed into. The row's own wording — "20 min",
    /// "9:30 AM" — is what it shows at rest; this is what a keyboard can add a digit to.
    public let draft: (Int) -> String
    /// What comes back out, held inside the span the arrows may reach, or `nil` for something that
    /// is not a value at all — which the field answers by putting back what it already held.
    public let read: (String, ClosedRange<Int>) -> ControlRules.TypedNumber?

    public init(
        draft: @escaping (Int) -> String,
        read: @escaping (String, ClosedRange<Int>) -> ControlRules.TypedNumber?
    ) {
        self.draft = draft
        self.read = read
    }

    /// A quantity: seconds, minutes, opens. The bare integer, clamped into the span it was read
    /// into — see `ControlRules.typed(_:into:)` for why a number out of range lands on the bound.
    public static let number = FieldNotation(
        draft: { String($0) }, read: ControlRules.typed
    )

    /// A time of day, stored as minutes since midnight. Out of range **reverts** here rather than
    /// clamping, so `wasClamped` is never true and the row's "Most is…" note never fires for one:
    /// there is no nearest sensible time to 25:00.
    ///
    /// The draft is `TimeWindowCopy.endpoint` itself rather than a second spelling of the same
    /// clock, which is the fix for the notation the row used to change into under the cursor: at
    /// rest it printed `9:30 AM` and a click handed the keyboard `09:30`, so the same row said the
    /// time two ways depending on whether it was being read or written. There is nothing left to
    /// keep in step — the row's function *is* the draft, so a change to how a window's hours are
    /// written reaches the field for free.
    public static let clock = FieldNotation(
        draft: TimeWindowCopy.endpoint,
        read: { text, range in
            ControlRules.typedClock(text, into: range)
                .map { ControlRules.TypedNumber(value: $0, wasClamped: false) }
        }
    )
}

/// A number that has to survive its own switch being turned off.
///
/// Three settings are an optional number behind a switch — the open length, the daily opens
/// goal and the daily time limit — and `nil` is a real answer for each of them ("no relock",
/// "unlimited"), which is why they are switches rather than a zero on a stepper. The cost was
/// that switching one off threw the number away: 30 minutes off and on again came back as 5,
/// because the default is all the setting has left to say. Anybody flicking a switch to see what
/// it does lost the value they had chosen, silently.
///
/// Kept here rather than in `GroupSettings` deliberately. What was switched off is a fact about
/// *this visit to the editor*, not about the group: writing it to `config.json` would put a
/// number in the file for a setting that is off, which is the sort of thing that later reads as a
/// bug — and a `nil` that remembers something is no longer a `nil`. So it lives in the view's
/// `@State`, which the main window already rebuilds per group (`MainWindowView` gives the editor
/// an `.id`), and a fresh visit starts from the defaults again.
public struct RememberedNumber: Equatable {
    /// Where a switch turned on with nothing to remember lands.
    public let fallback: Int
    public private(set) var remembered: Int?

    public init(fallback: Int) {
        self.fallback = fallback
    }

    /// What the setting should hold after the switch is flipped, and the memory brought up to
    /// date in the same move. `current` is what it holds at this moment — `nil` when the switch
    /// is already off.
    ///
    /// `current` wins over the memory when there is one, so a flip that changes nothing changes
    /// nothing: the number on screen is always the one the file holds.
    public mutating func flipped(to isOn: Bool, from current: Int?) -> Int? {
        guard isOn else {
            if let current { remembered = current }
            return nil
        }
        return current ?? remembered ?? fallback
    }
}
