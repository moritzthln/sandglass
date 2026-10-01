import SandglassCore
import Foundation

// One visit to the settings window, as `AppState` sees it: when to tell the visit that the window
// moved, how the two edits the lock's own machinery needs reach the disk, and every question asked
// of it — each at the reading of this second, because a published countdown is a tick old and a
// refusal is for deciding with.
//
// Split out of `AppState` when that file reached the size limit, along the seam it already marked,
// exactly as `AppStateInbound` was. Nothing about the rule changed in the move: what each friction
// refuses is `SettingsVisit`'s and `SettingsLockGate`'s, and what is here is only the actor and
// the disk.
//
// The members it reaches are `internal` rather than `private` for that reason, and they are the
// only ones that had to be — `engine` and `store` are still owned by `AppState` alone, which is
// the confinement the whole class exists to provide.

extension AppState {

    /// The moment as both clocks read it. Every deadline in this app is measured against the
    /// second half — see `ClockReading`.
    var reading: ClockReading { ClockReading(wall: clock.now, uptime: clock.uptime) }

    /// The day this moment is in, as `DatedBlock` spells one.
    ///
    /// Read from the running configuration's own day start, so it is the same boundary the engine
    /// rolls the budgets on. Two things need it: the direction table, for the one field whose
    /// meaning depends on the date, and the group editor's row.
    public var today: String {
        DatedBlock.today(
            at: clock.now, calendar: calendar, dayStartMinutes: config.dayStartMinutes
        )
    }

    /// Whether an emergency pass is lifting everything, the settings lock included.
    var emergencyPassRunning: Bool { readout.emergencyPassEndsAt != nil }

    /// The one place the lock is asked, so every guarded action refuses in the same words.
    ///
    /// `proposing` is the configuration the edit would leave behind, where there is one: the
    /// timer holds what loosens and lets what tightens through, and it can only tell the two apart
    /// with both halves in hand. Everything with no configuration behind it — resetting today's
    /// counters, the keep-alive row, the quit dialogue — leaves it out and is judged as a
    /// loosening, which is what each of them is.
    func lockRefusal(
        _ scope: SettingsLockScope, answered: String? = nil, proposing proposed: Config? = nil
    ) -> String? {
        visit.lockRefusal(
            for: config, at: reading, onDay: today, emergencyPassRunning: emergencyPassRunning,
            scope: scope, answered: answered, proposing: proposed
        )
    }

    /// Whether starting a break would ask for the passcode.
    public var breakNeedsPasscode: Bool {
        visit.breakNeedsPasscode(for: config, emergencyPassRunning: emergencyPassRunning)
    }

    /// Whether an action with no settings window behind it still owes the passcode.
    public var standaloneActionNeedsPasscode: Bool {
        visit.standaloneActionNeedsPasscode(
            for: config, emergencyPassRunning: emergencyPassRunning
        )
    }

    /// The settings window came up, or went away. Every wait this app measures is measured per
    /// visit, so one seam reports the visit and `SettingsVisit` tells all three gates about it.
    public func settingsWindowOpened() {
        visit.windowOpened(at: reading)
        finishMutation()
    }

    public func settingsWindowClosed() {
        visit.windowClosed()
        finishMutation()
    }

    /// The user has moved off one group's page — another group, or another page of the window.
    ///
    /// The third thing a visit has to hear about, beside the window coming up and going away, and
    /// it is here for the same reason: a wait switched on for that group arms as the user steps
    /// away from the stepper that set it, and counts from that second. Which page is showing is
    /// `MainWindowView`'s own state rather than anything published, so the seam is a call rather
    /// than a value to observe. See `GroupLockGate.leftGroup(_:at:)`.
    public func settingsGroupLeft(_ groupID: String) {
        visit.leftGroup(groupID, at: reading)
        finishMutation()
    }

    /// Try the passcode. `true` means the settings are unlocked for the rest of this visit.
    public func unlockSettings(passcode: String) -> Bool {
        guard visit.accept(passcode: passcode, for: config) else { return false }
        finishMutation()
        return true
    }

    /// Start, or call off, the hour that clears a forgotten passcode. `nil` means it went
    /// through; anything else is the reason it did not.
    ///
    /// Deliberately not through `applyConfigEdit`: a passcode nobody can remember must not be
    /// what guards its own way out. The engine's own locks still apply, because those have an
    /// escape of their own.
    @discardableResult
    public func setPasscodeReset(_ running: Bool) -> String? {
        var newConfig = config
        newConfig.settingsLock.forgotStartedAt = running ? reading : nil
        return saveEdit(newConfig)
    }

    /// Clears any passcode whose hour is up — the app's own, and every group's.
    ///
    /// Called from the loop rather than from the screen that started the wait, which is what
    /// makes the wait survive quitting: an hour started last night is over on the next launch,
    /// with or without a settings window open to watch it. A refusal from the engine — a focus
    /// session is the only one that reaches here — is left for the next tick to retry.
    ///
    /// One edit for however many are due, because one edit is what the disk takes: two hours that
    /// happen to end in the same second must not cost two writes and two rollback chances.
    func expirePasscodeResetIfDue() {
        var newConfig = config
        var due = newConfig.settingsLock.clearForgottenPasscode(at: reading)
        for groupID in newConfig.groupSettings.keys {
            guard newConfig.groupSettings[groupID]?.clearForgottenPasscode(at: reading) == true
            else { continue }
            due = true
        }
        guard due else { return }
        saveEdit(newConfig)
    }

    // MARK: - One group's own lock

    // The same visit, asked about one group: `GroupLockGate` holds the wait and the codes, and
    // `GroupLocks` decides what an edit reaches. What is here is the actor and the disk, exactly
    // as above.

    /// Why one of the groups this edit touches will not have it, or `nil` when none objects.
    ///
    /// Asked in `applyConfigEdit`, after the app-wide lock and before the engine — the app-wide
    /// one is the wider statement, and one refusal at a time means the wider one first.
    func groupLockRefusal(for newConfig: Config) -> String? {
        visit.groupLockRefusal(
            from: config, to: newConfig, at: reading, onDay: today,
            emergencyPassRunning: emergencyPassRunning
        )
    }

    /// Every group its own lock is holding **out of the press the all-at-once switch would make
    /// next** — what it leaves alone, and the number it says so with.
    ///
    /// The press has a direction, and a lock only ever holds one of them. Switching every group
    /// off is a loosening and is held per group exactly as before; switching them back **on** is
    /// a tightening, so nothing is left behind and the sentence has no held groups to name. Asked
    /// here rather than inside `AllGroupsSwitch` for the reason the held set has always been
    /// handed in: a second opinion about what a lock forbids is one that will one day disagree
    /// with the first.
    ///
    /// Takes the configuration rather than reading the published one, because the pass that
    /// republishes everything asks this about the projection it is in the middle of building.
    func heldGroups(in config: Config) -> Set<String> {
        guard AllGroupsSwitch.direction(in: config) == .off else { return [] }
        return visit.heldGroups(
            for: config, at: reading, emergencyPassRunning: emergencyPassRunning
        )
    }

    /// Try one group's passcode. `true` opens that group's page for the rest of this visit — and,
    /// for a group that also carries a wait, starts that wait counting from this second.
    public func unlockGroup(_ groupID: String, passcode: String) -> Bool {
        guard visit.accept(passcode: passcode, forGroup: groupID, in: config, at: reading)
        else { return false }
        finishMutation()
        return true
    }

    /// Start, or call off, the hour that clears one group's forgotten passcode. `nil` means it
    /// went through; anything else is the reason it did not.
    ///
    /// Deliberately not through `applyConfigEdit`, for the reason `setPasscodeReset` is not: a
    /// passcode nobody can remember must not be what guards its own way out.
    @discardableResult
    public func setGroupPasscodeReset(_ groupID: String, running: Bool) -> String? {
        var newConfig = config
        guard newConfig.groupSettings[groupID] != nil else { return nil }
        newConfig.groupSettings[groupID]?.passcodeForgotStartedAt = running ? reading : nil
        return saveEdit(newConfig)
    }
}
