import Foundation

// MARK: - A session's life

// Every way a session starts and ends, split out of `RulesEngine` for the reason `ConfigSwap` and
// `GroupBudget` were: it is one subject, and the engine is long enough without it. What a session
// is worth when it ends is asked of the session — its `SessionKind` — and never of the group,
// because a group whose password asks only inside its strict windows holds both kinds in one day.

extension RulesEngine {

    func grantOpen(_ managed: GroupLookup.Managed) -> ConsumeResult {
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

    /// Opens a password group for its `accessMinutes`, and answers how long that is in seconds.
    /// The same session an open starts, so it relocks, warns and ends exactly like one — only
    /// nothing is spent from the day to buy it.
    ///
    /// **A password that asks only in the strict windows opens no more than the window.** The
    /// session ends with the window it was typed in, never later: past it, the group is a budget
    /// group again, and a password session running on would be a free open nobody paused for.
    /// One window, not a chain of them: a window that ends where the next begins asks again.
    func startAccessSession(_ managed: GroupLookup.Managed) -> Int {
        var seconds = managed.settings.accessMinutes * 60
        if case .inStrictWindows = managed.settings.passwordMode,
           let left = secondsLeftInStrictWindow(managed.settings) {
            seconds = min(seconds, left)
        }
        let ends = newDeadline(in: TimeInterval(seconds))
        state.sessions[managed.groupID] = ActiveSession(
            groupID: managed.groupID, startedAt: now,
            endsAt: ends.wall, endsAtUptime: ends.uptime, warned: false, kind: .password
        )
        return seconds
    }

    /// Seconds until the strict window standing over the group closes, or `nil` when none is.
    private func secondsLeftInStrictWindow(_ settings: GroupSettings) -> Int? {
        guard let window = windows.strictWindow(settings, at: now) else { return nil }
        let minutes = window.minutesUntilEnd(from: windows.minutesOfDay(now))
        return max(1, minutes * 60 - windows.gregorian.component(.second, from: now))
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

    /// A password session was not bought with an open, so leaving it starts no cooldown and
    /// earns none back. A bought one does both, whatever the group's password says.
    private func end(_ managed: GroupLookup.Managed, early: Bool) {
        guard let session = state.sessions.removeValue(forKey: managed.groupID),
              session.kind == .bought else { return }
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
    ///
    /// Only ever for a bought session: the cooldown is the wait between two opens, and a password
    /// session was not one. Left in place, it would hold the first open after a strict window.
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

    // MARK: - The reapers

    /// Ends every bought session of a group that has used up its day, and announces each end.
    ///
    /// No cooldown, unlike every other way a session ends: the group is blocked until 03:00
    /// anyway, so a wait measured in minutes would be a promise of an earlier return than the
    /// user is actually getting. Run from the catch-up as well as from `recordUsage`, because
    /// a limit can also be reached by lowering it below what the day has already spent.
    ///
    /// A password session is not judged by the budgets, so the limit ends none of those. A bought
    /// one is, in every group: outside its windows a window-password group spends its budget like
    /// any other, and its limit has to end what that budget bought.
    func reapSessionsOverTimeLimit() {
        for groupID in state.sessions.keys.sorted() {
            guard state.sessions[groupID]?.kind == .bought,
                  let settings = config.activeSettings(forGroup: groupID),
                  budget.isTimeLimitReached(groupID, settings) else { continue }
            state.sessions.removeValue(forKey: groupID)
            pendingEffects.append(.sessionEnded(groupID: groupID))
        }
    }

    /// Ends every password session of a window-only password once no strict window stands over
    /// its group — the end `startAccessSession` already set, kept true when the windows are edited
    /// under a running session. A break window is no end: the strict window is still there behind
    /// it. No cooldown, for the reason a password session never starts one.
    func reapPasswordSessionsPastTheirWindow() {
        for groupID in state.sessions.keys.sorted() where state.sessions[groupID]?.kind == .password {
            guard let settings = config.activeSettings(forGroup: groupID),
                  case .inStrictWindows = settings.passwordMode,
                  windows.strictWindow(settings, at: now) == nil,
                  !windows.isInBreakWindow(settings, at: now) else { continue }
            state.sessions.removeValue(forKey: groupID)
            pendingEffects.append(.sessionEnded(groupID: groupID))
        }
    }

    /// Relocks every group at once, announcing each end to the app.
    func endAllSessions() {
        for groupID in state.sessions.keys.sorted() {
            guard let session = state.sessions.removeValue(forKey: groupID) else { continue }
            if session.kind == .bought, let settings = config.settings(forGroup: groupID) {
                startCooldown(groupID, settings, from: now, uptime: reading.uptime)
            }
            pendingEffects.append(.sessionEnded(groupID: groupID))
        }
    }

    /// Relocks every session whose time is up. The cooldown is anchored at the session's
    /// end, so a late reap does not hand out extra quiet time.
    func reapExpiredSessions() {
        for groupID in state.sessions.keys.sorted() {
            guard let session = state.sessions[groupID], let endsAt = session.endsAt,
                  reading.hasPassed(endsAt, uptime: session.endsAtUptime) else { continue }
            state.sessions.removeValue(forKey: groupID)
            if session.kind == .bought, let settings = config.settings(forGroup: groupID) {
                startCooldown(groupID, settings, from: endsAt, uptime: session.endsAtUptime)
            }
            pendingEffects.append(.sessionEnded(groupID: groupID))
        }
    }

    /// The heads-up before a session relocks, emitted once per session. A session that is
    /// already over gets none: the reap above has just announced its end. How early it arrives
    /// is `Config.expiryWarningSeconds`, and `nil` there means the user asked for none.
    ///
    /// Two sessions get none at all. One no longer than the warning itself: its length was the
    /// news when it was granted, and "1 minute left" on the first tick says nothing new. And one
    /// the group cannot use — a strict window, a dated block or "Block everything" standing over
    /// it: a warning about time nobody can spend is noise. Such a session is still warned about
    /// if it comes out from under the block in time.
    func warningEffect(_ groupID: String) -> EngineEffect? {
        guard let threshold = config.expiryWarningSeconds, threshold > 0 else { return nil }
        guard let session = state.sessions[groupID], let endsAt = session.endsAt, !session.warned
        else { return nil }
        guard endsAt.timeIntervalSince(session.startedAt) > Double(threshold) else { return nil }
        let secondsLeft = reading.secondsUntil(endsAt, uptime: session.endsAtUptime)
        guard secondsLeft > 0, secondsLeft <= Double(threshold) else { return nil }
        guard let settings = config.activeSettings(forGroup: groupID),
              case .allowed = decision(for: GroupLookup.Managed(groupID: groupID, settings: settings))
        else { return nil }
        state.sessions[groupID]?.warned = true
        return .sessionWarning(groupID: groupID, secondsLeft: Int(secondsLeft.rounded(.up)))
    }
}
