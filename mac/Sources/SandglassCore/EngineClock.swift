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
    /// Persisted through `anchor`, and taken back up by a relaunch on the same boot. It used to
    /// live in memory only, on the argument that a relaunch is entitled to a fresh baseline — which
    /// made quitting, setting the clock and starting again the way round every wall-clock block.
    /// Within one boot the uptime counter vouches for the pair, so the relaunch goes on from it
    /// instead of believing a clock it never saw being set. A reboot is where that runs out, the
    /// same limit every uptime twin has.
    private var anchorWall: Date
    private var anchorUptime: TimeInterval

    /// The latest moment the engine has been asked about, and the reason `now` can never go
    /// backwards.
    ///
    /// It moves every second, and a state that moves every second is an fsync every second, so it
    /// reaches the disk only with the anchor — when one is taken, and then at most hourly. That is
    /// enough for what a relaunch needs from it: to know it is behind what was already seen.
    private var highWater: Date

    /// How far the reported clock may be from what the engine expected before it counts as having
    /// been moved rather than having drifted. Five minutes is far more than any NTP correction and
    /// far less than any clock change worth noticing, and both checks below use the same number.
    ///
    /// Measured from the anchor, which no longer follows every second — so it caps the **sum** of
    /// every step since the anchor was taken, not each step on its own. Walking the clock forward
    /// four minutes at a time buys four minutes, once.
    private static let toleranceSeconds: TimeInterval = 5 * 60

    /// How long the anchor is kept before it is taken again, and how much disagreement it may
    /// absorb when it is: one second per thousand elapsed. A Mac's crystal and NTP stay well
    /// inside that — tens of parts per million — and somebody stepping the clock by hand would
    /// have to wait the better part of a day for every extra minute.
    private static let reanchorSeconds: TimeInterval = 3600
    private static let followRate: Double = 0.001

    /// A fresh anchor on whatever the clock says, unless `stored` is one this boot can vouch for —
    /// then the engine goes on from it, mark and all, as though it had never stopped.
    init(clock: Clock, resuming stored: ClockAnchor? = nil) {
        self.clock = clock
        if let stored, stored.isVouched(by: clock) {
            anchorWall = stored.wall
            anchorUptime = stored.uptime
            highWater = stored.highWater
        } else {
            anchorWall = clock.now
            anchorUptime = clock.uptime
            highWater = clock.now
        }
        highWater = now
    }

    /// The pair the engine believes, with the boot it belongs to and the mark, as it is persisted.
    var anchor: ClockAnchor {
        ClockAnchor(
            wall: anchorWall, uptime: anchorUptime, bootSession: clock.bootSession,
            highWater: highWater
        )
    }

    /// What the wall clock would say if it had only ever ticked: the last reading the engine
    /// believed, plus the real seconds since.
    private var extrapolatedWall: Date {
        anchorWall.addingTimeInterval(clock.uptime - anchorUptime)
    }

    /// How far the reported clock is from that extrapolation, either way.
    private var disagreement: TimeInterval {
        abs(clock.now.timeIntervalSince(extrapolatedWall))
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
    var wasChanged: Bool { disagreement > Self.toleranceSeconds }

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

    /// Whether the system clock is currently behind what the engine has already seen.
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
    /// The anchor moves only while the two clocks agree, and then only hourly and only by as much
    /// as honest drift could explain. It used to follow the clock every second whenever the two
    /// were within the tolerance, which let a run of small steps walk it anywhere. While the
    /// clocks disagree it stays exactly where it was, and the extrapolation keeps running from it
    /// — which is what makes the wrong time cost nothing rather than shift everything by however
    /// far it was moved.
    mutating func advance() {
        let elapsed = clock.uptime - anchorUptime
        if !wasChanged, elapsed >= Self.reanchorSeconds,
           disagreement <= elapsed * Self.followRate {
            anchorWall = clock.now
            anchorUptime = clock.uptime
        }
        highWater = max(highWater, now)
    }
}
