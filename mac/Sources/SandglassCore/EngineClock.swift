import Foundation

/// The engine's own picture of the time, and the only thing in it that reads a `Clock`.
///
/// macOS will not let an app without admin rights stop anybody changing the system clock, so the
/// honest subset is this: the engine refuses to *believe* a clock that moved. What it does
/// instead has two halves, and they cover different things.
///
/// - **Durations** — a session, a cooldown, a break, the emergency pass — are not measured here
///   at all. They carry an uptime twin and are measured against that; see `ClockReading`.
/// - **Wall-clock facts** — the 03:00 day boundary, the weekday windows — genuinely mean local
///   time and cannot go monotonic. They get the two things below: an anchor the reported time has
///   to agree with, and a high-water mark so time never runs backwards for the engine.
///
/// A value rather than a class, held by the engine and advanced once per catch-up.
struct EngineClock {
    private let clock: Clock

    /// The last reading the engine believed: a wall time, and the uptime it was taken at.
    ///
    /// In memory rather than in `EngineState`, like the mark below, and for the same reason. A
    /// relaunch anchors on whatever the clock says at launch — the app cannot audit a change it
    /// was not running for, and pretending otherwise would mean starting every launch suspicious
    /// of a clock that is probably right.
    private var anchorWall: Date
    private var anchorUptime: TimeInterval

    /// The latest moment this run has been asked about, and the reason `now` can never go
    /// backwards.
    ///
    /// In memory rather than in `EngineState`: it moves every second, and a state that moves
    /// every second is an fsync every second — `StatePersistence` is built on the opposite. The
    /// mark is a guard about a clock that moved *while the app was watching*, which is what the
    /// design asks for, and a relaunch is entitled to a fresh baseline.
    private var highWater: Date

    /// How far the reported clock may be from what this run expected before it counts as having
    /// been moved rather than having drifted. Five minutes is far more than any NTP correction and
    /// far less than any clock change worth noticing, and both checks below use the same number.
    private static let toleranceSeconds: TimeInterval = 5 * 60

    init(clock: Clock) {
        self.clock = clock
        highWater = clock.now
        anchorWall = clock.now
        anchorUptime = clock.uptime
    }

    /// What the wall clock would say if it had only ever ticked: the last reading the engine
    /// believed, plus the real seconds since.
    private var extrapolatedWall: Date {
        anchorWall.addingTimeInterval(clock.uptime - anchorUptime)
    }

    /// Whether the system clock was **set** rather than left to run.
    ///
    /// Sleep is not a false positive: uptime counts it (see `SystemClock.uptime`), so both clocks
    /// come back from a night with the lid shut having moved by the same eight hours. NTP
    /// corrections are seconds and are swallowed by the tolerance. What is left — a wall clock
    /// that moved while a counter with no user interface did not — is somebody in the Date & Time
    /// pane, in either direction.
    ///
    /// Derived rather than latched: it says itself out of existence the moment the two agree
    /// again, which is what makes putting the clock back the way out.
    var wasChanged: Bool {
        abs(clock.now.timeIntervalSince(extrapolatedWall)) > Self.toleranceSeconds
    }

    /// The wall time every decision is read at, which never runs backwards and never jumps.
    ///
    /// While the reported clock disagrees, this is the extrapolation instead — the day boundary
    /// and the weekday windows are then read against the time it *would* be, so an evening block
    /// cannot be skipped past by typing a new time into System Settings. And the high-water mark
    /// underneath means a clock set backwards hands back no budget and rolls no day over.
    var now: Date { max(wasChanged ? extrapolatedWall : clock.now, highWater) }

    /// The moment and the uptime it was read at, always taken together: one names the deadline,
    /// the other measures it.
    var reading: ClockReading { ClockReading(wall: now, uptime: clock.uptime) }

    /// Whether the system clock is currently behind what this run has already seen.
    ///
    /// Derived rather than latched, like every other warning in this app: it says itself out of
    /// existence the moment the real clock catches up, and a warning that outlived its cause
    /// would be worse than none.
    var movedBackwards: Bool {
        clock.now < highWater.addingTimeInterval(-Self.toleranceSeconds)
    }

    /// The line the menu bar shows while the clock and the engine disagree, or `nil` when they do
    /// not. Backwards is named as such, because it is the more specific thing to be able to say.
    var warningLine: String? {
        if movedBackwards { return "System clock moved backwards — counters held" }
        return wasChanged ? "System clock was changed — blocks held" : nil
    }

    /// Brings the picture up to date. Called at the top of every catch-up, before anything below
    /// it reads a moment, so that everything in one pass reads the same one.
    ///
    /// The anchor moves only while the two clocks agree. While they do not it stays exactly where
    /// it was, and the extrapolation keeps running from it — which is what makes the wrong time
    /// cost nothing rather than shift everything by however far it was moved.
    mutating func advance() {
        if !wasChanged {
            anchorWall = clock.now
            anchorUptime = clock.uptime
        }
        highWater = max(highWater, now)
    }
}
