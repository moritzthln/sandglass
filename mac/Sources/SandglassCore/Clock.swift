import Foundation

/// The two readings the engine is allowed to take of the time.
///
/// Two, because they answer different questions. `now` is what a human calls a moment — "until
/// 14:32", "the day starts at 03:00", "blocked on weekdays" — and it is also the one anybody can
/// change in System Settings. `uptime` names no moment at all and can only go forward, which is
/// what makes it the honest way to measure a *length*: five minutes of session, ten of cooldown,
/// an hour of emergency pass.
public protocol Clock: Sendable {
    var now: Date { get }
    /// Seconds since the machine started. Has no user interface, and no meaning across a reboot.
    var uptime: TimeInterval { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }

    /// `CLOCK_MONOTONIC_RAW` rather than `ProcessInfo.systemUptime`, which is the same counter
    /// *minus the time the Mac spent asleep*: measured here on a Mac that had been up for 6.5
    /// days, `systemUptime` said 3.3. Sleep has to count. A five-minute session must not survive
    /// a night with the lid shut, and a counter that stopped during sleep would make every single
    /// wake look like the wall clock had jumped forward by however long the nap was — which is
    /// exactly the signal `EngineClock` reads as somebody setting the clock.
    public var uptime: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}

/// One moment as the engine reads it: the wall time everything is *named* after, and the uptime
/// everything is *measured* against.
public struct ClockReading: Codable, Equatable, Sendable {
    public let wall: Date
    public let uptime: TimeInterval

    public init(wall: Date, uptime: TimeInterval) {
        self.wall = wall
        self.uptime = uptime
    }

    /// How long a deadline still has to run.
    ///
    /// Measured against uptime wherever the deadline has an uptime twin — the wall date is then
    /// only the sentence the UI reads out — and against the wall clock where it has none: a
    /// `state.json` written before the twins existed, or one whose twins a reboot invalidated
    /// (see `EngineState.dropUptimeTwins`). Winding the clock forward therefore ends no session,
    /// no cooldown, no break and no emergency pass early.
    public func secondsUntil(_ deadline: Date, uptime twin: TimeInterval?) -> TimeInterval {
        guard let twin else { return deadline.timeIntervalSince(wall) }
        return twin - uptime
    }

    /// Whether a deadline is behind us.
    public func hasPassed(_ deadline: Date, uptime twin: TimeInterval?) -> Bool {
        secondsUntil(deadline, uptime: twin) <= 0
    }

    /// A deadline `seconds` from this moment, as the pair it is stored as.
    public func deadline(in seconds: TimeInterval) -> (wall: Date, uptime: TimeInterval) {
        (wall.addingTimeInterval(seconds), uptime + seconds)
    }

    /// How long has run since an earlier reading.
    ///
    /// The other way round from `secondsUntil`, and for waits that are stored as their *start*
    /// rather than as their end — the settings lock's forgotten-passcode hour is the one. Same
    /// rule: uptime decides, so winding the clock forward buys none of it.
    ///
    /// A later reading can only report *less* uptime than an earlier one if the Mac restarted in
    /// between, which leaves the pair measured against a counter that no longer exists. The wall
    /// clock is then all there is — the same trade `EngineState.dropUptimeTwins` makes, and the
    /// same honest limit: somebody who reboots to shave a wait is back to a clock they can set.
    public func secondsSince(_ start: ClockReading) -> TimeInterval {
        let byUptime = uptime - start.uptime
        guard byUptime < 0 else { return byUptime }
        return max(0, wall.timeIntervalSince(start.wall))
    }
}
