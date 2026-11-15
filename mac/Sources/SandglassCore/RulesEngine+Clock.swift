import Foundation

// What the engine says about the clock itself, rather than about a target: whether it believes the
// clock, the zone it reads it in, and how long a running session has left on the guarded reading.
//
// Split out of `RulesEngine` when that file reached the size limit. Everything here is a read; the
// two things that change the clock's picture — `advanceClock` and `adoptTimeZone` — stay beside
// the state they write.

extension RulesEngine {

    /// Whether the system clock is currently behind what this run has already seen.
    ///
    /// **Read by the tests and by nothing else**, as is `clockWasChanged` below — the app asks
    /// `clockWarningLine`, which is the answer with the words on it. They stay `public` rather than
    /// becoming `internal` because `SandglassTests` is an ordinary executable target that imports
    /// this module: there is no `@testable` on this toolchain, so `internal` here means untestable.
    /// What they buy is a check on the two states *separately* — held-and-warning is one line, and
    /// a warning that appeared for the wrong one of the two would read the same.
    public var clockMovedBackwards: Bool { time.movedBackwards }

    /// Whether the system clock has been set rather than left to run — in either direction. See
    /// `EngineClock.wasChanged`, and `Config.preventTimeChange` for what is done about it. Read by
    /// the tests only; see above.
    public var clockWasChanged: Bool { time.wasChanged }

    /// The line the menu bar shows while the clock and the engine disagree, or `nil`.
    public var clockWarningLine: String? { time.warningLine }

    /// The zone every wall-clock question is read in right now. See `adoptTimeZone(_:)`.
    public var timeZone: TimeZone { calendar.timeZone }

    /// How long a running session still has, measured the way the engine relocks it — against
    /// its uptime twin where it has one. `nil` for a gentle open, which has no end.
    ///
    /// For the screens. The session row used to count down to the wall `endsAt` against the raw
    /// clock, so winding the clock forward hid a session the engine was still running and took
    /// "End early" away with it.
    public func secondsLeft(in session: ActiveSession) -> TimeInterval? {
        guard let endsAt = session.endsAt else { return nil }
        return reading.secondsUntil(endsAt, uptime: session.endsAtUptime)
    }
}
