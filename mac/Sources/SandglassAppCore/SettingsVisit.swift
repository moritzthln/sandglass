import SandglassCore
import Foundation

/// One visit to the settings window, and both of the waits measured from it.
///
/// The window coming up is a single event with two consequences — `SettingsLockGate`'s timer
/// starts and its passcode is forgotten, `BreakWaitGate`'s wait starts over — and from then on the
/// two answer the same shape of question: may this happen yet, and if not, in what words. They are
/// held together because they are never used apart. The loop republishes both every second, the
/// window's seam opens and closes both, and one action — starting a break — is refused by either.
///
/// **Two gates inside rather than one, and deliberately.** The reason is written at
/// `BreakWaitGate`: the same event, but different acts held behind it, and each with exceptions the
/// other must not inherit. What is here is only that one visit owns both of them, so no caller can
/// tell one about the window and forget the other.
///
/// It knows nothing about the engine, the disk or a clock: the caller hands in the configuration as
/// it is stored and the reading it is asking about. That is the contract both gates are written to,
/// kept by the type that holds them — and it is what makes every rule here reachable from a test
/// without building an app around it.
struct SettingsVisit {

    /// When the window came up and whether the passcode has been answered since.
    private var lock = SettingsLockGate()
    /// When the window came up, and nothing else. See the type for why this is not a question on
    /// the gate above.
    private var wait = BreakWaitGate()
    /// The same visit again, per group: each group's own wait, and the codes answered for it. See
    /// `GroupLockGate` — a third gate rather than a field on the first, because "once per visit"
    /// is once per *group* here and the two must not be able to answer for each other.
    private var groups = GroupLockGate()

    // MARK: - The visit

    /// The settings window came up. Every wait starts from here; each decides for itself what a
    /// repeated call means, and none is restarted by one.
    mutating func windowOpened(at reading: ClockReading) {
        lock.windowOpened(at: reading)
        wait.windowOpened(at: reading)
        groups.windowOpened(at: reading)
    }

    /// The window went away: the timers start again from the next open, and every passcode
    /// entered during this visit is forgotten.
    mutating func windowClosed() {
        lock.windowClosed()
        wait.windowClosed()
        groups.windowClosed()
    }

    /// An edit is about to be saved: whichever waits it **starts** are not owed by this visit.
    ///
    /// One seam for both scopes, because one edit can start either or both — the page carries the
    /// app-wide toggle, and a group editor in the same window carries its own stepper. Why an
    /// exemption exists at all is `SettingsLockGate.timerSwitchedOn`; which groups an edit starts
    /// a wait for is `GroupLocks.timersSwitchedOn`. Neither gate is told anything else by it: a
    /// wait already running is untouched, and so is every passcode.
    ///
    /// Asked with the pair of configurations rather than with the result, for the reason
    /// `groupLockRefusal` is: off-to-on is a fact about two states and cannot be read off one.
    mutating func timersSwitchedOn(from current: Config, to proposed: Config) {
        if !current.settingsLock.timerIsOn, proposed.settingsLock.timerIsOn {
            lock.timerSwitchedOn()
        }
        for groupID in GroupLocks.timersSwitchedOn(from: current, to: proposed) {
            groups.timerSwitchedOn(forGroup: groupID)
        }
    }

    /// The user has left one group's page. A wait switched on for that group during this visit
    /// arms here, and counts from here; nothing else in the visit moves.
    ///
    /// The app-wide toggle has no equivalent and needs none: there is no page to leave, so its
    /// exemption ends where it always did, at the next window open. See
    /// `GroupLockGate.leftGroup(_:at:)`.
    mutating func leftGroup(_ groupID: String, at reading: ClockReading) {
        groups.leftGroup(groupID, at: reading)
    }

    /// Try the passcode. `true` means the settings are unlocked for the rest of this visit.
    mutating func accept(passcode: String, for config: Config) -> Bool {
        lock.accept(passcode: passcode, for: config.settingsLock)
    }

    /// Try one group's passcode. `true` opens that group's page for the rest of this visit.
    ///
    /// The reading goes with it, because a group carrying both halves of a lock starts counting
    /// its wait from this moment — see `GroupLockGate.timerSecondsLeft`.
    mutating func accept(
        passcode: String, forGroup groupID: String, in config: Config, at reading: ClockReading
    ) -> Bool {
        guard let settings = config.settings(forGroup: groupID) else { return false }
        return groups.accept(
            passcode: passcode, forGroup: groupID, settings: settings, at: reading
        )
    }

    // MARK: - What the screens redraw from

    /// Where both gates stand this second, in the two values the loop publishes.
    ///
    /// One question rather than two, because they are answered against one reading: asked
    /// separately, two countdowns started by the same window open could be measured a clock tick
    /// apart and disagree about which second it is.
    func state(
        for config: Config, at now: ClockReading, emergencyPassRunning: Bool
    ) -> (lockState: SettingsLockState, breakWaitSecondsLeft: Int?) {
        (
            lock.state(
                for: config.settingsLock, at: now, emergencyPassRunning: emergencyPassRunning
            ),
            wait.secondsLeft(waitSeconds: config.breakWaitSeconds, at: now)
        )
    }

    /// Where every group's own lock stands this second, keyed by group id.
    ///
    /// One pass over the groups rather than one question per editor, for the reason
    /// `state(for:at:emergencyPassRunning:)` above answers two gates at once: they are read
    /// against one reading, and two countdowns started by the same window open must not be
    /// measured a clock tick apart.
    func groupLockStates(
        for config: Config, at now: ClockReading, emergencyPassRunning: Bool
    ) -> [String: GroupLockState] {
        var states: [String: GroupLockState] = [:]
        for (groupID, settings) in config.groupSettings {
            states[groupID] = groups.state(
                for: settings, groupID: groupID, at: now,
                emergencyPassRunning: emergencyPassRunning
            )
        }
        return states
    }

    /// Every group whose own lock is holding it this second — what the all-at-once switch has to
    /// leave alone, and the number it says so with.
    func heldGroups(
        for config: Config, at now: ClockReading, emergencyPassRunning: Bool
    ) -> Set<String> {
        groups.heldGroups(in: config, at: now, emergencyPassRunning: emergencyPassRunning)
    }

    // MARK: - What they refuse

    /// Why something guarded by the settings lock cannot go through, in the words the screen
    /// shows, or `nil` when it can. Which frictions a `scope` carries is `SettingsLockScope`.
    ///
    /// `proposed` is the configuration the edit would leave behind, and it is what decides the
    /// direction: an edit that hands nothing back is not what a lock is for, and the timer lets it
    /// through. A caller with nothing to compare — resetting today's counters, the quit dialogue,
    /// starting a break — passes `nil` and is judged as a loosening, which is the fail-closed half
    /// and is what each of those actually is.
    ///
    /// `today` is the day this moment is in, which the direction table needs for the one field
    /// whose meaning depends on when it is read — see `EditDirection.loosens(from:to:onDay:)`.
    func lockRefusal(
        for config: Config, at now: ClockReading, onDay today: String,
        emergencyPassRunning: Bool,
        scope: SettingsLockScope, answered: String? = nil, proposing proposed: Config? = nil
    ) -> String? {
        lock.refusal(
            for: config.settingsLock, at: now, emergencyPassRunning: emergencyPassRunning,
            scope: scope, answered: answered,
            tightening: proposed.map {
                !EditDirection.loosens(from: config, to: $0, onDay: today)
            } ?? false
        )?.text
    }

    /// Why a group's own lock will not have this edit, or `nil` when none of them objects.
    ///
    /// **Every edit that loosens a locked group**, which covers the one side door that is not an
    /// edit to the group at all: a category shrinking under a group that carries it. Which way an
    /// edit moves each group is `EditDirection`'s; what a held group then says is
    /// `GroupLockGate.Refusal`. Neither of them reads the other's half, and this is the one place
    /// they meet.
    ///
    /// It used to ask which groups an edit *touched*, in either direction, and refuse the lot.
    /// That is the half of the rule that was wrong at first: a lock is a commitment device against the
    /// weaker self, so a longer pause, one more site, one more category or a passcode on top all
    /// go through while it stands, and only the move that hands something back is refused.
    ///
    /// The **current** settings decide, never the proposed ones: a group is held by the lock it
    /// has, not by the lock an edit would give it. Read the other way round, taking a lock off
    /// would be its own permission slip — and setting one up would be refused by a lock that does
    /// not exist yet.
    ///
    /// Sorted, so an edit that loosens two held groups always names the same one.
    func groupLockRefusal(
        from current: Config, to proposed: Config, at now: ClockReading, onDay today: String,
        emergencyPassRunning: Bool
    ) -> String? {
        for groupID in current.groupSettings.keys.sorted() {
            guard let settings = current.settings(forGroup: groupID) else { continue }
            guard let refusal = groups.refusal(
                for: settings, groupID: groupID, at: now,
                emergencyPassRunning: emergencyPassRunning,
                tightening: !EditDirection.loosens(
                    group: groupID, from: current, to: proposed, onDay: today
                )
            ) else { continue }
            return refusal.text(groupNamed: current.groupDisplayName(forGroup: groupID) ?? groupID)
        }
        return nil
    }

    /// Why the Unblock card cannot be operated yet, or `nil` when it can.
    ///
    /// Asked at the reading it is given rather than read off the published countdown, which is a
    /// tick old: the published value is for drawing a countdown, and a refusal is for deciding.
    func breakWaitRefusal(for config: Config, at now: ClockReading) -> String? {
        wait
            .secondsLeft(waitSeconds: config.breakWaitSeconds, at: now)
            .map(BreakWaitGate.waitText)
    }

    /// Both frictions in front of a break, **in series and in this order**, or `nil` when neither
    /// refuses.
    ///
    /// The wait comes first because it is the one with a countdown — told to enter the passcode,
    /// somebody would enter it and be refused a second time for a reason nobody had mentioned. It
    /// is measured from the settings window that carries the only menu offering a length, and it is
    /// asked here rather than only drawn as a dead control: a wait a screen enforces by greying
    /// something out is not a wait, it is a suggestion.
    ///
    /// Then the settings passcode, when the user asked for it — see
    /// `SettingsLock.coversQuickDisable`. `.deliberateAction`, because it is answered per break
    /// rather than remembered per visit: `answered` buys **this** one and nothing after it, so every
    /// break asks. A wrong one is a refusal in its own words rather than a silent no-op, because a
    /// menu item that does nothing and says nothing reads as a broken button.
    func breakRefusal(
        for config: Config, at now: ClockReading, emergencyPassRunning: Bool, answered: String?
    ) -> String? {
        if let refusal = breakWaitRefusal(for: config, at: now) { return refusal }
        guard config.settingsLock.coversQuickDisable else { return nil }
        // No configuration to compare, so the day it would be compared on decides nothing: a break
        // is judged as a loosening whatever the date says, which is what it is.
        return lockRefusal(
            for: config, at: now, onDay: "", emergencyPassRunning: emergencyPassRunning,
            scope: .deliberateAction, answered: answered
        )
    }

    // MARK: - The same questions, asked before the act

    // What the menus read, so the question is put in front of the user rather than the refusal
    // behind them. Both ask about the lock and not about the visit, which is what makes them true
    // of **every** break rather than of the first one: reading `SettingsLockState.passcodeRequired`
    // here meant a passcode entered once — for a break, or in the quit dialogue — left the menus
    // saying nothing was owed for the rest of the process.

    /// Whether starting a break would ask for the passcode.
    func breakNeedsPasscode(for config: Config, emergencyPassRunning: Bool) -> Bool {
        config.settingsLock.coversQuickDisable
            && standaloneActionNeedsPasscode(for: config, emergencyPassRunning: emergencyPassRunning)
    }

    /// Whether an action with no settings window behind it still owes the passcode. See
    /// `SettingsLockScope.isStandalone` — there is no visit for an answer to be remembered in.
    func standaloneActionNeedsPasscode(for config: Config, emergencyPassRunning: Bool) -> Bool {
        config.settingsLock.passcode != nil && !emergencyPassRunning
    }
}
