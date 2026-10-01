import Foundation

/// An open, currently-running session for one group.
public struct ActiveSession: Codable, Equatable, Sendable {
    public var groupID: String
    public var startedAt: Date
    public var endsAt: Date?          // nil = gentle open (no relock)
    /// `endsAt` again, in uptime — the reading this session is actually relocked by. `nil` means
    /// there is none to go on (an old `state.json`, or a reboot), and the wall date decides.
    public var endsAtUptime: TimeInterval?
    public var warned: Bool

    public init(
        groupID: String,
        startedAt: Date,
        endsAt: Date?,
        endsAtUptime: TimeInterval? = nil,
        warned: Bool
    ) {
        self.groupID = groupID
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.endsAtUptime = endsAtUptime
        self.warned = warned
    }
}

/// All mutable runtime state; persisted as one JSON document next to `Config`.
public struct EngineState: Codable, Equatable, Sendable {
    public var version: Int
    public var dayKey: String                       // "2026-02-01"
    public var opensUsed: [String: Double]
    public var opensAvoided: Int
    public var sessions: [String: ActiveSession]
    public var cooldownUntil: [String: Date]
    public var focusSessionEndsAt: Date?
    public var protectionPausedUntil: Date?
    public var streakDays: Int
    public var freezeUsedInWeek: String?            // ISO week key "2026-W05"
    public var deniedAttempts: [String: Int]        // groupID → denied consume attempts today
    /// groupID → seconds spent in the group today. Cleared by the 03:00 roll, like every
    /// other daily counter.
    public var usageSecondsToday: [String: Int]
    /// The ISO week the emergency pass was spent in, or `nil` while it is still available.
    public var emergencyPassUsedInWeek: String?
    /// When the running emergency pass is over. Deliberately *not* `protectionPausedUntil`:
    /// a pause is clamped against strict windows and suppressed by them, and the whole point
    /// of the pass is that it outranks both.
    public var emergencyPassEndsAt: Date?

    // MARK: - Uptime twins
    //
    // Every deadline above is stored twice: once as the wall time the UI names it by, and once
    // as the uptime reading the engine actually measures it against. Setting the system clock
    // moves the first and not the second, which is what makes winding the clock forward worth
    // nothing. All of them are absent in a `state.json` written before they existed, and then
    // the wall dates decide on their own — see `ClockReading.secondsUntil`.

    public var focusSessionEndsAtUptime: TimeInterval?
    public var protectionPausedUntilUptime: TimeInterval?
    public var emergencyPassEndsAtUptime: TimeInterval?
    public var cooldownUntilUptime: [String: TimeInterval]

    /// The uptime the newest twin was written at, and the one thing that can tell a reboot from a
    /// deadline that simply has not come round yet.
    ///
    /// A pending twin is *always* ahead of the current uptime, so comparing against the twins
    /// themselves says nothing. Comparing against this does: no twin was written later than this
    /// reading, so a machine reporting less uptime than this has restarted since, and every twin
    /// is measured from a counter that no longer exists.
    public var uptimeAnchor: TimeInterval?

    public init(
        version: Int,
        dayKey: String,
        opensUsed: [String: Double],
        opensAvoided: Int,
        sessions: [String: ActiveSession],
        cooldownUntil: [String: Date],
        focusSessionEndsAt: Date?,
        protectionPausedUntil: Date?,
        streakDays: Int,
        freezeUsedInWeek: String?,
        deniedAttempts: [String: Int],
        usageSecondsToday: [String: Int] = [:],
        emergencyPassUsedInWeek: String? = nil,
        emergencyPassEndsAt: Date? = nil,
        focusSessionEndsAtUptime: TimeInterval? = nil,
        protectionPausedUntilUptime: TimeInterval? = nil,
        emergencyPassEndsAtUptime: TimeInterval? = nil,
        cooldownUntilUptime: [String: TimeInterval] = [:],
        uptimeAnchor: TimeInterval? = nil
    ) {
        self.version = version
        self.dayKey = dayKey
        self.opensUsed = opensUsed
        self.opensAvoided = opensAvoided
        self.sessions = sessions
        self.cooldownUntil = cooldownUntil
        self.focusSessionEndsAt = focusSessionEndsAt
        self.protectionPausedUntil = protectionPausedUntil
        self.streakDays = streakDays
        self.freezeUsedInWeek = freezeUsedInWeek
        self.deniedAttempts = deniedAttempts
        self.usageSecondsToday = usageSecondsToday
        self.emergencyPassUsedInWeek = emergencyPassUsedInWeek
        self.emergencyPassEndsAt = emergencyPassEndsAt
        self.focusSessionEndsAtUptime = focusSessionEndsAtUptime
        self.protectionPausedUntilUptime = protectionPausedUntilUptime
        self.emergencyPassEndsAtUptime = emergencyPassEndsAtUptime
        self.cooldownUntilUptime = cooldownUntilUptime
        self.uptimeAnchor = uptimeAnchor
    }

    // MARK: - Writing a deadline
    //
    // A deadline and its uptime twin are written together or not at all. A wall date left behind
    // by a cleared twin — or the other way round — is a wait measured by whichever half survived,
    // which is the one way this could go quietly wrong. These six are how the engine touches the
    // three timed blocks; the sessions carry their own pair, and the cooldowns are a dictionary.

    /// A deadline `seconds` from `reading`, as the pair it is stored as — and the note of when the
    /// pair was written, which is what the reboot check on the next launch reads. The three are
    /// only ever written together, which is why the anchor is set here rather than by each caller.
    public mutating func deadline(
        in seconds: TimeInterval, at reading: ClockReading
    ) -> (wall: Date, uptime: TimeInterval) {
        uptimeAnchor = reading.uptime
        return reading.deadline(in: seconds)
    }

    public mutating func setFocusSession(_ deadline: (wall: Date, uptime: TimeInterval)) {
        focusSessionEndsAt = deadline.wall
        focusSessionEndsAtUptime = deadline.uptime
    }

    public mutating func clearFocusSession() {
        focusSessionEndsAt = nil
        focusSessionEndsAtUptime = nil
    }

    public mutating func setProtectionPause(_ deadline: (wall: Date, uptime: TimeInterval)) {
        protectionPausedUntil = deadline.wall
        protectionPausedUntilUptime = deadline.uptime
    }

    public mutating func clearProtectionPause() {
        protectionPausedUntil = nil
        protectionPausedUntilUptime = nil
    }

    public mutating func setEmergencyPass(_ deadline: (wall: Date, uptime: TimeInterval)) {
        emergencyPassEndsAt = deadline.wall
        emergencyPassEndsAtUptime = deadline.uptime
    }

    public mutating func clearEmergencyPass() {
        emergencyPassEndsAt = nil
        emergencyPassEndsAtUptime = nil
    }

    /// Forgets every uptime twin, leaving the wall dates to speak for themselves.
    ///
    /// The reboot path, and the honest best effort: uptime restarts at zero when the Mac does, so
    /// a twin written before the restart is measured from a counter that no longer exists and
    /// would keep a ten-minute cooldown running for hours. What is left is the wall clock, which
    /// is what this app ran on until now — and which somebody who reboots to shave a cooldown can
    /// indeed still change. The alternative, keeping the twins, would block for a length of time
    /// nobody chose.
    /// The same, unless this machine can still vouch for them: a reading at or past the anchor
    /// means no restart has happened since the newest twin was written. A state with no anchor at
    /// all — one written before the twins existed — has nothing to drop and nothing to prove.
    public mutating func dropUptimeTwinsIfStale(at uptime: TimeInterval) {
        if let anchor = uptimeAnchor, uptime >= anchor { return }
        dropUptimeTwins()
    }

    public mutating func dropUptimeTwins() {
        focusSessionEndsAtUptime = nil
        protectionPausedUntilUptime = nil
        emergencyPassEndsAtUptime = nil
        cooldownUntilUptime = [:]
        uptimeAnchor = nil
        for groupID in sessions.keys { sessions[groupID]?.endsAtUptime = nil }
    }

    /// Decoded by hand only because of `usageSecondsToday`, which V1.1 added and which is not
    /// an `Optional` — the synthesised decoder would demand it and refuse every `state.json` a
    /// V1 build wrote, which `Store` would then rename to `.bad` and treat as corruption. The
    /// two optional fields need no help; see the schema-evolution rule in `SandglassJSON`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        dayKey = try container.decode(String.self, forKey: .dayKey)
        opensUsed = try container.decode([String: Double].self, forKey: .opensUsed)
        opensAvoided = try container.decode(Int.self, forKey: .opensAvoided)
        sessions = try container.decode([String: ActiveSession].self, forKey: .sessions)
        cooldownUntil = try container.decode([String: Date].self, forKey: .cooldownUntil)
        focusSessionEndsAt = try container.decodeIfPresent(Date.self, forKey: .focusSessionEndsAt)
        protectionPausedUntil = try container.decodeIfPresent(Date.self, forKey: .protectionPausedUntil)
        streakDays = try container.decode(Int.self, forKey: .streakDays)
        freezeUsedInWeek = try container.decodeIfPresent(String.self, forKey: .freezeUsedInWeek)
        deniedAttempts = try container.decode([String: Int].self, forKey: .deniedAttempts)
        usageSecondsToday =
            try container.decodeIfPresent([String: Int].self, forKey: .usageSecondsToday) ?? [:]
        emergencyPassUsedInWeek =
            try container.decodeIfPresent(String.self, forKey: .emergencyPassUsedInWeek)
        emergencyPassEndsAt = try container.decodeIfPresent(Date.self, forKey: .emergencyPassEndsAt)
        focusSessionEndsAtUptime =
            try container.decodeIfPresent(TimeInterval.self, forKey: .focusSessionEndsAtUptime)
        protectionPausedUntilUptime =
            try container.decodeIfPresent(TimeInterval.self, forKey: .protectionPausedUntilUptime)
        emergencyPassEndsAtUptime =
            try container.decodeIfPresent(TimeInterval.self, forKey: .emergencyPassEndsAtUptime)
        cooldownUntilUptime =
            try container.decodeIfPresent([String: TimeInterval].self, forKey: .cooldownUntilUptime)
            ?? [:]
        uptimeAnchor = try container.decodeIfPresent(TimeInterval.self, forKey: .uptimeAnchor)
    }

    /// How far into the calendar day a day — and a week — starts when nobody has said
    /// otherwise: 03:00 local, not midnight, because 02:00 belongs to the night that came
    /// before it.
    ///
    /// Still the default rather than the rule: `Config.dayStartMinutes` is what the engine
    /// actually runs on, and this is the value a configuration that never mentions it gets.
    /// `Store.weekStart` measures from the same number. The two must stay in step, or "opens
    /// this week" would count a different set of moments than "opens today" does.
    public static let dayStartOffsetSeconds: TimeInterval = 3 * 3600

    /// The same default, as minutes from midnight — the unit `Config` stores it in.
    public static let defaultDayStartMinutes = Int(dayStartOffsetSeconds / 60)

    /// The day a moment belongs to, where a day runs from `dayStartMinutes` to the same time
    /// the next morning.
    ///
    /// The shift is raw arithmetic rather than calendar arithmetic: it is total (no
    /// optional to unwrap) and has no edge cases of its own. The trade-off is that on the
    /// two DST switch days the rollover lands an hour early or late, which is harmless for a
    /// per-day open budget.
    ///
    /// Only the time zone of `calendar` is used. The key is always Gregorian, so a user
    /// on a Buddhist or Hebrew system calendar gets the same `yyyy-MM-dd` string as
    /// everyone else — the key is an internal identifier, never shown to anyone.
    public static func dayKey(
        for date: Date, calendar: Calendar, dayStartMinutes: Int = defaultDayStartMinutes
    ) -> String {
        let gregorian = Calendar.sandglassGregorian(in: calendar.timeZone)
        let shifted = date.addingTimeInterval(-TimeInterval(dayStartMinutes * 60))
        let parts = gregorian.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A clean slate for the day containing `now`.
    public static func initial(
        now: Date, calendar: Calendar, dayStartMinutes: Int = defaultDayStartMinutes
    ) -> EngineState {
        EngineState(
            version: 1,
            dayKey: dayKey(for: now, calendar: calendar, dayStartMinutes: dayStartMinutes),
            opensUsed: [:],
            opensAvoided: 0,
            sessions: [:],
            cooldownUntil: [:],
            focusSessionEndsAt: nil,
            protectionPausedUntil: nil,
            streakDays: 0,
            freezeUsedInWeek: nil,
            deniedAttempts: [:]
        )
    }
}
