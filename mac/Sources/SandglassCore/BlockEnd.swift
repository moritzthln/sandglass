import Foundation

/// When a block lifts — or that it does not.
///
/// **A block whose windows leave no gap has no end that can be named.** One strict window over all
/// seven days from 00:00 to 00:00 covers all 10,080 minutes of the week and never closes, but its
/// `endMinutes` is still a number, and every screen that read that number said "Blocked until
/// 00:00" — at noon, about a block that had never lifted and never would. It reads as a promise
/// that this clears at midnight. A group blocked around the clock is exactly that shape, and six
/// screens were making that promise about it.
///
/// So the hour is not a `String` a caller may print; it is a case of this, and the other case
/// exists so that the question has to be answered. `WindowClock.end(of:in:)` is the one place it is
/// decided, from `TimeWindow.strictBlocksEveryMinute` — the rule the group editor already used to
/// dim the knobs such a group can never reach.
///
/// Breaks count as a way out, because they are one: a strict block and a break that tile the week
/// between them leave the group fully open for the break's whole length, so the block genuinely
/// does close at the hour it names. A night-time group blocked 00:30–08:00 and free the rest of
/// the day is that shape, and it keeps its 08:00.
/// A **dated block** is the third case, and it is the reason an hour was never enough on its own:
/// a group shut until a day next week does end, and no clock face can say when. See `DatedBlock`.
public enum BlockEnd: Equatable, Sendable {
    /// It lifts, at this wall-clock time — the 24-hour text the engine has always printed.
    case at(String)
    /// It lifts when a named day begins — `Mon 24 Aug`, in `DatedBlock.shortText`'s spelling.
    ///
    /// A date rather than an hour because the end may be a week off, and the day rather than a
    /// moment because that is what is stored: the block ends when the day begins by
    /// `Config.dayStartMinutes`, so the hour it lifts at is a consequence rather than the promise.
    case onDay(String)
    /// It does not: the windows over this group hard-block every minute of the week.
    case never

    /// The clause that follows the verb — `Blocked until 17:00`, `Locked around the clock`.
    ///
    /// A clause rather than a finished sentence because three screens put three different verbs in
    /// front of the same fact: the engine's "Blocked", the settings page's "Locked" and the quit
    /// alert's "Sandglass is locked". One place decides how a block's end is worded, and none of
    /// them can name an hour without coming through here.
    public var clause: String {
        switch self {
        case .at(let clockText): return "until \(clockText)"
        case .onDay(let dayText): return "until \(dayText)"
        case .never: return "around the clock"
        }
    }
}
