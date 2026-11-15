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
    /// A name for this boot of the machine, or `nil` where there is none to read.
    ///
    /// What tells "the same boot, so the uptime counter still means what it meant" from "a
    /// restart that happened to run longer than the last one had" — which comparing uptimes
    /// alone cannot. See `ClockAnchor.isVouched(by:)`.
    var bootSession: String? { get }
}

public extension Clock {
    /// No name by default, which leaves the uptime comparison to decide on its own.
    var bootSession: String? { nil }

    /// Uptime written as a `Date`: a moment on a line nobody can set, for the in-memory guards
    /// that only ever compare two moments taken in the same run — a two-second grace, a wait a
    /// block page is serving. The `Date` it names is meaningless as a time of day and must never
    /// be shown or stored; what it buys is that winding the system clock moves none of them.
    var steadyNow: Date { Date(timeIntervalSinceReferenceDate: uptime) }
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

    /// `kern.bootsessionuuid`, which the kernel draws fresh at every boot. Read once: it cannot
    /// change under a running process.
    public var bootSession: String? { Self.bootSessionUUID }

    private static let bootSessionUUID: String? = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }()
}

/// The last reading the engine believed, kept in `EngineState` so a relaunch on the same boot can
/// go on from it rather than believe whatever the clock says at launch.
///
/// A pair, a boot and a mark: the wall time and the uptime it was taken at — which together say
/// what the wall clock *should* read at any later uptime of the same boot — the boot they belong
/// to, and the latest moment the engine had been asked about when they were written.
public struct ClockAnchor: Codable, Equatable, Sendable {
    public let wall: Date
    public let uptime: TimeInterval
    /// `nil` for a clock that has no name for its boot; the uptime comparison then decides.
    public let bootSession: String?
    /// The high-water mark when the anchor was written. Never earlier than `wall`.
    public let highWater: Date

    public init(wall: Date, uptime: TimeInterval, bootSession: String?, highWater: Date) {
        self.wall = wall
        self.uptime = uptime
        self.bootSession = bootSession
        self.highWater = highWater
    }

    /// Whether `clock` is still on the boot this anchor was taken on, so its uptime can still be
    /// extrapolated from.
    ///
    /// Both names, where both exist, and they must match. Without them, the rule
    /// `EngineState.dropUptimeTwinsIfStale` already uses: a machine reporting less uptime than
    /// this restarted since.
    public func isVouched(by clock: Clock) -> Bool {
        if let mine = bootSession, let theirs = clock.bootSession { return mine == theirs }
        return clock.uptime >= uptime
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
