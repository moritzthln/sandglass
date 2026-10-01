import Foundation

/// The single source of truth for what happens when a target is opened.
///
/// Pure Swift with an injected clock: no timers, no I/O, no persistence. The app drives
/// it (`tick()` once a second, `consumeOpen` when the user pushes through a pause screen)
/// and saves `state` afterwards.
///
/// Every public method first brings the engine up to date with the clock, so no answer is
/// ever based on a stale picture: a Mac that slept through a session is right on its first
/// question, not on its first tick. Whatever that catch-up produces — a session that ran
/// out, a new day — is queued and handed to the app by the next `tick()`.
///
/// Not thread-safe; confine it to one thread or actor. The app confines it to the
/// MainActor (Task 5).
public final class RulesEngine {
    public private(set) var config: Config
    public private(set) var state: EngineState

    private let clock: Clock
    private let calendar: Calendar

    /// Wall-clock arithmetic and every question about a group's time windows. See `WindowClock`
    /// for why the calendar lives there rather than here.
    private let windows: WindowClock

    /// Effects produced outside `tick()`. Drained by the next tick, so an effect can
    /// arrive up to a second late but is never lost.
    private var pendingEffects: [EngineEffect] = []

    /// What a finished day was worth, and the one home for the ISO week both the freeze and
    /// the emergency pass are charged to. See `StreakScoring`.
    private let streak: StreakScoring

    /// The engine's picture of the time: a wall clock that never runs backwards, and the uptime
    /// every countdown is measured against. Everything below reads the clock through this.
    private var time: EngineClock

    public init(config: Config, state: EngineState, clock: Clock, calendar: Calendar = .current) {
        self.config = config
        self.state = state
        self.clock = clock
        self.calendar = calendar
        time = EngineClock(clock: clock)
        let windows = WindowClock(timeZone: calendar.timeZone)
        self.windows = windows
        streak = StreakScoring(calendar: calendar, gregorian: windows.gregorian)
        // Uptime means nothing across a restart, and this is the one moment the engine can tell
        // that one happened: a state off disk whose twins were written at a reading this machine
        // has not reached. See `EngineState.dropUptimeTwins`.
        self.state.dropUptimeTwinsIfStale(at: clock.uptime)
    }

    /// The moment every decision below is read at. Never runs backwards; see `EngineClock`.
    private var now: Date { time.now }

    /// That same moment with the uptime it was read at, which is how every deadline in the state
    /// is compared. See `ClockReading`.
    private var reading: ClockReading { time.reading }

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

    private func advanceClock() {
        time.advance()
    }

    /// This moment's counters, as the arithmetic the decisions below are made of.
    private var budget: GroupBudget { GroupBudget(state: state, reading: reading) }

    /// The three timed blocks as they stand this second: what is still running, and what has run
    /// out. Built per question, like `budget` above. See `ReliefBlocks`.
    private var relief: ReliefBlocks { ReliefBlocks(state: state, reading: reading) }

    /// A deadline `seconds` from now, as the pair it is stored as. See `EngineState.deadline`.
    private func newDeadline(in seconds: TimeInterval) -> (wall: Date, uptime: TimeInterval) {
        state.deadline(in: seconds, at: reading)
    }

    // MARK: - Decisions

    /// What should happen if this target is opened right now.
    public func decision(targetID: String) -> Decision {
        advanceToNow()
        guard let managed = lookup.managed(targetID: targetID) else { return .notManaged }
        return decision(for: managed)
    }

    /// The same question for a page in a browser, asked about the whole address.
    ///
    /// `host/path`, because that is what an advanced rule can be about: `youtube.com/shorts` is
    /// a different answer from `youtube.com/watch`, and a matcher given only the host could
    /// never say so. Everything after the path — query and fragment — is dropped; see
    /// `RuleMatcher.normalize(url:)`.
    public func decision(url: String) -> Decision {
        advanceToNow()
        guard let managed = lookup.managed(url: url) else { return .notManaged }
        return decision(for: managed)
    }

    /// Same question for a bare browser host: `www.youtube.com` answers for `youtube.com`.
    ///
    /// A host is a URL with no path, so this delegates rather than matching a second way. Kept
    /// because plenty of the app asks about a site rather than a page.
    public func decision(domain: String) -> Decision {
        decision(url: domain)
    }

    /// The same question asked about a whole group rather than about one thing in it.
    ///
    /// Every decision below is made of a group and its settings — nothing in `decision(for:)`
    /// reads the target that led there — so this is the honest way to ask "what is this group
    /// doing right now". The menu bar needs it: a group made of live categories has no targets
    /// of its own to ask about, and asking about none of them would have the app report no
    /// protection while the blocker is working.
    public func decision(groupID: String) -> Decision {
        advanceToNow()
        guard let settings = config.activeSettings(forGroup: groupID) else { return .notManaged }
        return decision(for: GroupLookup.Managed(groupID: groupID, settings: settings))
    }

    /// The one place the precedence lives: an emergency pass means the engine is off, a focus
    /// session outranks everything under it, paused protection means the engine is off again, a
    /// dated block outranks the whole of the group's week, the group's own break window means the
    /// engine is off for that group, a strict window outranks a running session, then the day's
    /// time limit, a session outranks a cooldown, a cooldown an empty budget, and everything left
    /// is the way in — a pause screen, or, for a group set to no pause, no screen at all.
    ///
    /// The hard blocks come first on purpose: a session bought before a window opened must
    /// not outlive it, or the window would be worth nothing on the days it matters. The
    /// engine never sets a focus session and a pause at the same time — but a hand-edited
    /// state file can, and then the block wins over the exemption.
    ///
    /// The two exemptions are held by one condition, not two: a group that ignores the app's
    /// app-wide ways out is passed over by **both** the pass and the break, so the cheaper door
    /// cannot open what the rationed one is refused.
    private func decision(for managed: GroupLookup.Managed) -> Decision {
        // Above even the emergency pass, and above every block under it. While the reported clock
        // and the engine's disagree, the app cannot honestly name when anything ends — and the
        // pass is a way out of a block, not a way out of not knowing the time. It lasts exactly as
        // long as the disagreement; putting the clock back is the way out.
        if config.preventTimeChange, time.wasChanged {
            return .blocked(reason: .clockTampered, untilText: "System clock was changed")
        }
        // Above everything the user can build, the four-hour focus session included: the pass is
        // the one way out of a block made to have none, and it lifts rather than ends — see
        // `useEmergencyPass`.
        //
        // **Unless the group has opted out of it.** A group set to ignore the pass is left exactly
        // where it was: the hour runs, every other group opens, and this one goes on being judged
        // by everything below — the focus session, its own week, its budget. The pass is not spent
        // any less for it; what changes is only how far it reaches. See
        // `GroupSettings.ignoresAppWideUnblocks`.
        if activeEmergencyPassEnd != nil, !managed.settings.ignoresAppWideUnblocks {
            return .notManaged
        }
        if let endsAt = activeFocusSessionEnd {
            return .blocked(
                reason: .focusSession, untilText: blocked(.at(windows.clockText(for: endsAt)))
            )
        }
        // Under the focus session, unlike the pass above it: an ordinary break is the thing
        // "Block everything" exists to be immune to, and `startFocusSession` ends a running one.
        //
        // **Held by the same opt-out as the pass**, and it has to be: a break is the cheaper of the
        // two doors by every measure — no rationing, no confirmation, a wait in front of it and
        // that is all — so a group the week's pass leaves alone that this opened would be immune
        // only until the next afternoon somebody pressed "Unblock everything" instead. The weaker
        // door must not open what the stronger one cannot. Same shape as the branch above: the
        // group falls through to everything below rather than out, so its dated block, its week and
        // its budget go on judging it, and the break itself is granted and runs its full length for
        // every other group.
        if activeProtectionPauseEnd != nil, !managed.settings.ignoresAppWideUnblocks {
            return .notManaged
        }
        // Above the week, both kinds of it — see `datedBlock(_:)`.
        if let dated = datedBlock(managed.settings) { return dated }
        // A break window is the group's own planned version of the pause above it: fully open,
        // no friction, nothing spent — and it outranks its own strict window, which is what
        // makes "free 20:00–22:00" expressible inside an otherwise blocked evening.
        if windows.isInBreakWindow(managed.settings, at: now) { return .notManaged }
        if let window = windows.strictWindow(managed.settings, at: now) {
            return .blocked(
                reason: .schedule,
                untilText: blocked(windows.end(of: window, in: managed.settings))
            )
        }
        // Ahead of the session on purpose: a time limit that let the session it interrupted
        // run to the end would be a limit only in name. `advanceToNow` has already ended it.
        if budget.isTimeLimitReached(managed.groupID, managed.settings) {
            return .blocked(
                reason: .timeLimit, untilText: blocked(.at(rolloverText(managed.settings)))
            )
        }
        if let remaining = budget.remainingSessionSeconds(managed.groupID) {
            return .allowed(remainingSessionSeconds: remaining)
        }
        if let minutes = budget.remainingCooldownMinutes(managed.groupID) {
            return .blocked(reason: .cooldown, untilText: "Next open in \(minutes) min")
        }
        if budget.isExhausted(managed.groupID, opensPerDay: managed.settings.opensPerDay) {
            return .blocked(
                reason: .budgetExhausted, untilText: blocked(.at(rolloverText(managed.settings)))
            )
        }
        // No computed wait is no screen at all — see `GroupBudget.countdownSeconds`, which is
        // where that rule lives so that a base of nought under escalation still meets one on the
        // second open of the day.
        guard let countdown = budget.countdownSeconds(managed.groupID, managed.settings) else {
            return .opensByItself
        }
        return .pause(
            countdownSeconds: countdown,
            budgetLine: budget.line(managed.groupID, managed.settings)
        )
    }

    /// The group's one-shot block, or `nil` when none is standing.
    ///
    /// While it stands it outranks **both** kinds of window: a week set aside is a week set aside,
    /// so the group's own break window does not punch a hole in it — a group tiled with a daytime
    /// break would otherwise be shut for a fortnight only at night. It sits under everything above
    /// it in `decision(for:)` for the reason a strict window does — the pass is the way out of a
    /// block made to have none, and the app-wide break is the user asking for all of it back at
    /// once — and above every budget, because a group nobody can open until Tuesday has no day to
    /// spend.
    ///
    /// `state.dayKey` rather than a second reading of the calendar: `advanceToNow` has just rolled
    /// it, so it is the day this moment is in, worked out by the arithmetic that decides when a
    /// budget comes back. That is what makes the end honour `dayStartMinutes`, follow it when it
    /// moves, and cost a DST switch nothing. See `DatedBlock`.
    private func datedBlock(_ settings: GroupSettings) -> Decision? {
        guard let day = DatedBlock.standing(settings.blockedUntilDay, onDay: state.dayKey) else {
            return nil
        }
        return .blocked(reason: .datedBlock, untilText: blocked(.onDay(DatedBlock.shortText(day))))
    }

    // MARK: - Spending an open

    /// Spend one open from the group's budget, or report why that is impossible.
    public func consumeOpen(targetID: String) -> ConsumeResult {
        advanceToNow()
        guard let managed = lookup.managed(targetID: targetID) else { return .denied(.notManaged) }
        return consume(managed)
    }

    /// The same, for a page in a browser. A URL a rule claimed spends from that rule's group,
    /// exactly as a target would — there is one budget per group and no second way to spend it.
    public func consumeOpen(url: String) -> ConsumeResult {
        advanceToNow()
        guard let managed = lookup.managed(url: url) else { return .denied(.notManaged) }
        return consume(managed)
    }

    private func consume(_ managed: GroupLookup.Managed) -> ConsumeResult {
        let current = decision(for: managed)
        switch current {
        case .allowed(let remainingSessionSeconds):
            // Joining a session already running costs nothing: the open is paid for.
            return .granted(sessionSeconds: remainingSessionSeconds)
        // The two shapes of "there is a way through, and it costs one open". They differ only in
        // what the user meets on the way — a countdown, or nothing at all — which is a question
        // for the screen and not for the budget.
        case .pause, .opensByItself:
            return grantOpen(managed)
        case .blocked(let reason, _):
            // Only an empty budget counts: a denied attempt is what busts the day's
            // streak, and that is meant to mean "kept going after the budget was gone",
            // not "walked into a wall the user themselves put up".
            if reason == .budgetExhausted { state.deniedAttempts[managed.groupID, default: 0] += 1 }
            return .denied(current)
        case .notManaged:
            return .denied(current)
        }
    }

    private func grantOpen(_ managed: GroupLookup.Managed) -> ConsumeResult {
        state.opensUsed[managed.groupID] = budget.opensUsed(managed.groupID) + 1
        guard let seconds = budget.grantedSessionSeconds(managed.groupID, managed.settings) else {
            return .granted(sessionSeconds: nil)   // gentle: allowed, but nothing to relock
        }
        let ends = newDeadline(in: TimeInterval(seconds))
        state.sessions[managed.groupID] = ActiveSession(
            groupID: managed.groupID,
            startedAt: now,
            endsAt: ends.wall,
            endsAtUptime: ends.uptime,
            warned: false
        )
        return .granted(sessionSeconds: seconds)
    }

    /// End the group's session. `early` marks the user's own "I'm done" — the only way
    /// to earn half an open back. Ending nothing is a no-op, and a session that already
    /// ran out was ended by the catch-up above, so a late "I'm done" changes nothing.
    public func endSession(targetID: String, early: Bool) {
        advanceToNow()
        guard let managed = lookup.managed(targetID: targetID) else { return }
        end(managed, early: early)
    }

    /// The same, asked about the group rather than about something in it.
    ///
    /// What the "I'm done" button needs: a group made of live categories has no target to name,
    /// and a button that quietly did nothing there would be the one place in the app where
    /// ending a session early is impossible.
    public func endSession(groupID: String, early: Bool) {
        advanceToNow()
        guard let settings = config.activeSettings(forGroup: groupID) else { return }
        end(GroupLookup.Managed(groupID: groupID, settings: settings), early: early)
    }

    private func end(_ managed: GroupLookup.Managed, early: Bool) {
        guard let session = state.sessions.removeValue(forKey: managed.groupID) else { return }
        startCooldown(managed.groupID, managed.settings, from: now, uptime: reading.uptime)
        guard early, managed.settings.earnBackEnabled else { return }
        creditEarnBack(session, groupID: managed.groupID)
    }

    /// Half an open back for leaving inside the first half of the session.
    ///
    /// How much is left is the monotonic answer, so the half is a half of real time: neither
    /// winding the clock forward (to claim the session is nearly over) nor back (to claim it has
    /// barely started) changes what leaving now is worth.
    private func creditEarnBack(_ session: ActiveSession, groupID: String) {
        guard let endsAt = session.endsAt else { return }
        let total = endsAt.timeIntervalSince(session.startedAt)
        let elapsed = total - reading.secondsUntil(endsAt, uptime: session.endsAtUptime)
        guard total > 0, elapsed < total / 2 else { return }
        state.opensUsed[groupID] = max(0, budget.opensUsed(groupID) - 0.5)
    }

    /// The cooldown runs from the moment the session actually ended, not from the moment
    /// the engine noticed. One that already elapsed while the Mac slept is not recorded:
    /// waking up must not resurrect a wait that is over.
    ///
    /// `uptime` is that same anchor read on the monotonic clock, and it is optional because the
    /// session it follows may have had no twin of its own — an old `state.json`, or a reboot. A
    /// cooldown with no twin is a wall-clock cooldown, exactly as it was before.
    private func startCooldown(
        _ groupID: String,
        _ settings: GroupSettings,
        from anchor: Date,
        uptime anchorUptime: TimeInterval?
    ) {
        guard settings.cooldownMinutes > 0 else { return }
        let seconds = TimeInterval(settings.cooldownMinutes * 60)
        let until = anchor.addingTimeInterval(seconds)
        let untilUptime = anchorUptime.map { $0 + seconds }
        guard reading.secondsUntil(until, uptime: untilUptime) > 0 else { return }
        state.cooldownUntil[groupID] = until
        // Assigning nil removes the key, which is what a cooldown with no twin has to leave
        // behind: a stale twin from an earlier one would outlive the wait it belonged to.
        state.cooldownUntilUptime[groupID] = untilUptime
        if untilUptime != nil { state.uptimeAnchor = reading.uptime }
    }

    /// The user closed a pause screen instead of pushing through it. The caller asserts
    /// that a pause screen was actually showing (Task 9 filters the raw signals).
    ///
    /// Ignored while protection is paused: no pause screen can be showing then, so such a
    /// signal is stale — and counting it would mark the day as practised on the strength
    /// of a window that was closed for other reasons.
    public func recordDismissal(targetID: String) {
        advanceToNow()
        guard activeProtectionPauseEnd == nil else { return }
        guard lookup.managed(targetID: targetID) != nil else { return }
        state.opensAvoided += 1
    }

    /// The same, from a web pause screen.
    public func recordDismissal(url: String) {
        advanceToNow()
        guard activeProtectionPauseEnd == nil else { return }
        guard lookup.managed(url: url) != nil else { return }
        state.opensAvoided += 1
    }

    // MARK: - Usage and the daily time limit

    /// Add time actually spent in a group to today's total.
    ///
    /// The app calls this once a second for whatever is frontmost, and once a second for the
    /// page in the frontmost browser — so the number is counted, never estimated, and a Mac that
    /// slept cannot inflate it: no tick ran, so no second was added.
    ///
    /// Time for a group the configuration does not know is dropped rather than stored: the
    /// engine acts on nothing it has no settings for, and `state.json` should not carry totals
    /// for groups that do not exist.
    public func recordUsage(groupID: String, seconds: Int) {
        advanceToNow()
        guard seconds > 0, config.activeSettings(forGroup: groupID) != nil else { return }
        state.usageSecondsToday[groupID, default: 0] += seconds
        // The catch-up above ran before the seconds landed, so the limit is re-checked here.
        reapSessionsOverTimeLimit()
    }

    /// Ends the session of every group that has used up its day, and announces each end.
    ///
    /// No cooldown, unlike every other way a session ends: the group is blocked until 03:00
    /// anyway, so a wait measured in minutes would be a promise of an earlier return than the
    /// user is actually getting. Run from the catch-up as well as from `recordUsage`, because
    /// a limit can also be reached by lowering it below what the day has already spent.
    private func reapSessionsOverTimeLimit() {
        for groupID in state.sessions.keys.sorted() {
            guard let settings = config.activeSettings(forGroup: groupID),
                  budget.isTimeLimitReached(groupID, settings) else { continue }
            state.sessions.removeValue(forKey: groupID)
            pendingEffects.append(.sessionEnded(groupID: groupID))
        }
    }

    // MARK: - The emergency pass

    /// Lift every block for an hour, or refuse because this week's pass is already spent.
    ///
    /// The safety net strict mode otherwise lacks: a focus session cannot be cancelled, which is
    /// the point of it — right up until the evening something actually goes wrong. One per ISO
    /// week keeps it a net rather than a habit, and the week is the same one the streak freeze is
    /// charged to.
    ///
    /// **A running focus session is outranked rather than ended**, and the other direction still
    /// ends rather than outranks — `startFocusSession` clears a running pass. One rule covers
    /// both: the later, more deliberate wish wins, and which of the two it is follows from whose
    /// job is over. The pass's is, once the user asks to be blocked again; the session's is not,
    /// so it waits. It used to unlock `updateConfig` and the undo of today for its hour as well;
    /// neither is locked by anything the engine holds any more, so what it lifts is blocks — and,
    /// one level up, the settings lock. See `SettingsLockGate`, and `updateConfig`.
    @discardableResult
    public func useEmergencyPass() -> Bool {
        advanceToNow()
        guard emergencyPassAvailable else { return false }
        ReliefBlocks.spendEmergencyPass(&state, weekKey: weekKey(for: now), at: reading)
        return true
    }

    /// When the running emergency pass is over, or `nil` when none is running. Derived from the
    /// clock, like the other getters, so it needs no catch-up first.
    public var emergencyPassEndsAt: Date? { activeEmergencyPassEnd }

    /// Whether a pass can be spent right now. `false` for the rest of the week it was spent in,
    /// including while it is running.
    public var emergencyPassAvailable: Bool {
        state.emergencyPassUsedInWeek != weekKey(for: now)
    }

    private var activeEmergencyPassEnd: Date? { relief.emergencyPassEnd }

    // MARK: - Focus sessions

    /// Hard-block every managed target for `minutes`.
    ///
    /// Whatever is open right now ends at once — a focus session that let the current YouTube
    /// session run out would be a lie. That end is not the user's own "I'm done", so it earns
    /// nothing back, and the cooldown it starts runs from now. Everything else the request does —
    /// what a second one means, and the break and the pass it ends — is `ReliefBlocks`.
    public func startFocusSession(minutes: Int) {
        advanceToNow()
        // A focus session of no length is not a focus session: `false` here keeps a slipped zero
        // from ending the running sessions for nothing.
        guard ReliefBlocks.startFocusSession(&state, minutes: minutes, at: reading) else { return }
        endAllSessions()
    }

    /// When the running focus session is over, or `nil` when none is running.
    ///
    /// Derived rather than read straight from the state, so it is right without a call to
    /// `advanceToNow()` first — a getter must not have side effects.
    public var focusSessionEndsAt: Date? { activeFocusSessionEnd }

    private var activeFocusSessionEnd: Date? { relief.focusSessionEnd }

    /// Relocks every group at once, announcing each end to the app.
    private func endAllSessions() {
        for groupID in state.sessions.keys.sorted() {
            state.sessions.removeValue(forKey: groupID)
            if let settings = config.settings(forGroup: groupID) {
                startCooldown(groupID, settings, from: now, uptime: reading.uptime)
            }
            pendingEffects.append(.sessionEnded(groupID: groupID))
        }
    }

    // MARK: - Pausing protection

    /// Turn the engine off for `minutes`, or refuse. `false` means a focus session is running,
    /// which is the one block a break does not lift — see `ReliefBlocks.startPause` for why, and
    /// for the two things a strict window stopped doing to a break.
    public func pauseProtection(minutes: Int) -> Bool {
        advanceToNow()
        return ReliefBlocks.startPause(&state, minutes: minutes, at: reading)
    }

    /// End the running pause now. The user asking for their blocks back is never refused, and
    /// there is nothing to refuse when no pause is running.
    public func endPauseEarly() {
        advanceToNow()
        state.clearProtectionPause()
    }

    /// When the running protection pause is over, or `nil` when protection is on.
    public var protectionPausedUntil: Date? { activeProtectionPauseEnd }

    private var activeProtectionPauseEnd: Date? { relief.protectionPauseEnd }

    // MARK: - Time windows

    /// The strict block over one group right now: how long it still has to run, and when it is
    /// over. `nil` when the group is not inside one.
    ///
    /// Two values rather than one because they answer different questions. `end` is what the user
    /// reads, and it may be `.never` — see `BlockEnd`. `minutesLeft` is how two blocks are compared,
    /// and the only honest comparison once a window may cross midnight: "08:00" is later than
    /// "17:00" when the former is tomorrow's. It counts to a window's edge even for a block that
    /// never lets go, so a caller comparing two has to let `.never` win first.
    public func strictBlock(forGroup groupID: String) -> (minutesLeft: Int, end: BlockEnd)? {
        advanceToNow()
        guard let settings = config.activeSettings(forGroup: groupID),
              let window = windows.strictWindow(settings, at: now) else { return nil }
        return (
            window.minutesUntilEnd(from: windows.minutesOfDay(now)),
            windows.end(of: window, in: settings)
        )
    }

    // MARK: - Reconfiguration

    /// Replace the configuration. **It refuses nothing.**
    ///
    /// Two locks used to live here and neither does. A strict window froze the group inside it
    /// against loosening, and a running focus session froze the configuration whole. The
    /// commitment model moved house: a time window and "Block everything" *block apps and
    /// websites*, and whether the configuration may change is the settings lock's question —
    /// app-wide, or per group, both of which are asked in `AppState.applyConfigEdit` before
    /// anything reaches here. The lock rule, and the sentence every case is judged against: every
    /// setting is always editable unless a lock or a passcode is set. See `EditDirection`.
    ///
    /// So deleting the window that is blocking lifts the block on the spot, a group can be
    /// switched off in the middle of one, and a four-hour "Block everything" goes on blocking
    /// everything while the settings behind it are edited freely. What it does not do is stop
    /// blocking: the focus session is untouched, and only the editing was freed.
    ///
    /// The emergency pass therefore has one job less. It still lifts blocks and the settings
    /// lock; there is no configuration lock left for it to lift.
    public func updateConfig(_ newConfig: Config) {
        advanceToNow()
        let dayStartMoved = newConfig.dayStartMinutes != config.dayStartMinutes
        config = newConfig
        ConfigSwap.apply(newConfig, to: &state)
        if dayStartMoved { rebaseDayKey() }
    }

    /// Puts back the configuration **and the state** that were running before an edit which then
    /// could not be written to disk. The caller takes both before it asks — see
    /// `AppState.updateConfig`.
    ///
    /// Both halves, because `ConfigSwap.apply` has already run: a group the refused edit did not
    /// know has had its sessions, its cooldowns and its spent opens filtered out of the state, and
    /// bringing the group back without them would hand today's budget out a second time — which
    /// is what `resetToday` is for, behind a confirmation nobody saw here.
    ///
    /// Deliberately unable to refuse, and deliberately **not** advancing the clock first. The
    /// locks exist to stop the rules of the moment being loosened, and going back to what is
    /// still on disk loosens nothing; a catch-up here would run against the configuration that
    /// was just refused, ending a running break under a window from the failed edit or reaping a
    /// session against its daily limit. What the catch-up inside the refused edit already did is
    /// rolled back with the state and done again by the next tick, under rules that are real.
    public func revertConfig(to previous: Config, restoring previousState: EngineState) {
        config = previous
        state = previousState
    }

    /// Adopts the day the new `dayStartMinutes` puts us in, **without rolling into it**.
    ///
    /// Moving the start of the day changes which logical day this moment belongs to, so the next
    /// `rollDayIfNeeded` would see a key it has never seen and do the whole ceremony: clear
    /// today's opens, usage and denied attempts, and score the streak for a day that did not
    /// end — a day the user was in the middle of. Changing a preference is not a day passing.
    ///
    /// So the key is moved and nothing else is. Two things follow, and both are the safe
    /// direction. The counters are **kept**, so no budget is handed back — which matters, because
    /// handing one back is exactly what `resetToday` is for and it sits behind a confirmation the
    /// user would never have seen here. And the streak is not scored, so its record stays a
    /// record of days rather than of settings changes. Somebody who does want a fresh day still
    /// has the button that says so.
    private func rebaseDayKey() {
        state.dayKey = EngineState.dayKey(
            for: now, calendar: calendar, dayStartMinutes: config.dayStartMinutes
        )
    }

    // MARK: - Time passing

    /// Applies everything the clock has made true since the last call. Runs at the top of
    /// every public method — the two derived getters need no catch-up, they compute their
    /// answer from the clock instead of mutating. `tick()` is how the resulting effects
    /// reach the app, not how the state gets corrected.
    ///
    /// The high-water mark moves first, so everything below reads one moment and that moment is
    /// never earlier than the last one. A clock that jumped backwards therefore rolls no day and
    /// clears no counter: `rollDayIfNeeded` is asked about the mark, not about the system clock.
    private func advanceToNow() {
        advanceClock()
        rollDayIfNeeded()
        ReliefBlocks.expire(&state, at: reading)
        reapExpiredSessions()
        reapSessionsOverTimeLimit()
    }

    /// Called once a second by the app: hands over the effects the catch-up produced and
    /// adds the one-minute warning for sessions still running.
    public func tick() -> [EngineEffect] {
        advanceToNow()
        var effects = drainPendingEffects()
        for groupID in state.sessions.keys.sorted() {
            if let warning = warningEffect(groupID) { effects.append(warning) }
        }
        return effects
    }

    private func drainPendingEffects() -> [EngineEffect] {
        defer { pendingEffects.removeAll() }
        return pendingEffects
    }

    /// Relocks every session whose time is up. The cooldown is anchored at the session's
    /// end, so a late reap does not hand out extra quiet time.
    private func reapExpiredSessions() {
        for groupID in state.sessions.keys.sorted() {
            guard let session = state.sessions[groupID], let endsAt = session.endsAt,
                  reading.hasPassed(endsAt, uptime: session.endsAtUptime) else { continue }
            state.sessions.removeValue(forKey: groupID)
            if let settings = config.settings(forGroup: groupID) {
                startCooldown(groupID, settings, from: endsAt, uptime: session.endsAtUptime)
            }
            pendingEffects.append(.sessionEnded(groupID: groupID))
        }
    }

    /// The heads-up before a session relocks, emitted once per session. A session that is
    /// already over gets none: the reap above has just announced its end. How early it arrives
    /// is `Config.expiryWarningSeconds`, and `nil` there means the user asked for none.
    private func warningEffect(_ groupID: String) -> EngineEffect? {
        guard let threshold = config.expiryWarningSeconds, threshold > 0 else { return nil }
        guard let session = state.sessions[groupID], let endsAt = session.endsAt, !session.warned else { return nil }
        let secondsLeft = reading.secondsUntil(endsAt, uptime: session.endsAtUptime)
        guard secondsLeft > 0, secondsLeft <= Double(threshold) else { return nil }
        state.sessions[groupID]?.warned = true
        return .sessionWarning(groupID: groupID, secondsLeft: Int(secondsLeft.rounded(.up)))
    }

    /// Rolls into a new logical day once the clock has crossed the day's start; see `DayReset`.
    private func rollDayIfNeeded() {
        guard dayReset.rollIfNeeded(at: now, &state) else { return }
        pendingEffects.append(.dayRolledOver)
    }

    /// The day boundary as the configuration currently draws it. Built per call, like `budget`
    /// and `lookup`: a held copy would outlive an edit to `dayStartMinutes`.
    private var dayReset: DayReset {
        DayReset(streak: streak, calendar: calendar, dayStartMinutes: config.dayStartMinutes)
    }

    /// Hands today's budget back. **It refuses nothing**, exactly as a configuration edit no
    /// longer does.
    ///
    /// For setting the app up, where the first hour is spent walking into your own budget on
    /// purpose. What it clears, and the one counter it leaves standing, is `DayReset`.
    ///
    /// It used to be locked like an edit, on the grounds that handing back a spent budget while
    /// everything is blocked defeats that block as thoroughly as raising the budget would. Under
    /// the lock rule that is the settings lock's argument to make and not this one's — a
    /// running "Block everything" is neither a lock nor a passcode. See `updateConfig`. The
    /// settings lock is still asked, one level up in `AppState.resetTodaysCounters`.
    public func resetToday() {
        advanceToNow()
        DayReset.handBackToday(&state)
    }

    // MARK: - Lookup

    /// Which group a target or a URL belongs to. Pure — no catch-up, because it reads the
    /// configuration and never the clock. See `GroupLookup`.
    private var lookup: GroupLookup { GroupLookup(config: config) }

    // MARK: - Budget arithmetic

    /// The day's budget for a group, in the exact words the pause screen shows. `nil` for a group
    /// with neither budget on — there is nothing to report.
    ///
    /// Public because the menu bar needs this same sentence outside a `.pause` decision:
    /// while a session is running, while protection is paused, and on a group nobody has
    /// opened today. One home for the string; a second copy in the app is how the popover and
    /// the overlay start disagreeing.
    public func budgetLine(forGroup groupID: String) -> String? {
        advanceToNow()
        guard let settings = config.activeSettings(forGroup: groupID) else { return nil }
        return budget.line(groupID, settings)
    }

    // MARK: - User-facing copy

    // The engine's answers carry finished English text, which the overlay shows verbatim.
    // A port to another language (or to iOS) turns these into data.

    /// An end rather than an hour, so that the one block which has none cannot be handed one here
    /// by accident. Three of the four callers end by construction; the schedule asks. See `BlockEnd`.
    private func blocked(_ end: BlockEnd) -> String { "Blocked \(end.clause)" }

    /// When this group is worth opening again, as wall-clock text — for the two blocks that last
    /// "until the day rolls over", the daily time limit and an exhausted budget. Read from the day
    /// boundary rather than written as a literal "03:00", and read through the group's own week
    /// rather than off the boundary alone, because a window standing when the counters come back
    /// holds the budget they hand out. Which of the two it is: `WindowClock.nextOpenText`.
    private func rolloverText(_ settings: GroupSettings) -> String {
        windows.nextOpenText(settings, dayStartMinutes: config.dayStartMinutes, at: now)
    }

    // MARK: - Stats

    /// Reading the numbers also brings the engine up to date: it may end a finished
    /// session or roll the day over first, and hands what that produced to the next tick.
    public func statsSnapshot() -> StatsSnapshot {
        advanceToNow()
        let freezeSpent = state.freezeUsedInWeek == weekKey(for: now)
        return StatsSnapshot(
            opensUsedToday: state.opensUsed,
            opensAvoidedToday: state.opensAvoided,
            streakDays: state.streakDays,
            freezesLeft: freezeSpent ? 0 : StreakScoring.freezesPerWeek,
            usageSecondsToday: state.usageSecondsToday
        )
    }

    /// The ISO week a moment belongs to. Forwarded to `StreakScoring` rather than spelled out
    /// again: the emergency pass and the streak freeze are charged to the same week.
    private func weekKey(for date: Date) -> String { streak.weekKey(for: date) }
}
