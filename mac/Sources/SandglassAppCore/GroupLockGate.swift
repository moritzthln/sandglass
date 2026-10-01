import SandglassCore
import Foundation

/// Where one group's own lock stands right now, as one value its editor redraws from.
///
/// The same three fields `SettingsLockState` has, about one group instead of about the app: the
/// two locks are the same device at two scopes, and a second shape for the same facts is how the
/// window's banner and the group's own notice would start disagreeing.
public struct GroupLockState: Equatable, Sendable {
    /// Seconds until this group's own timer lets go, or `nil` when it is off or has run out. The
    /// app-wide timer is **not** in here: it holds this group too, and it is asked first, so
    /// folding the two together would have the editor claim the group's lock for a wait that
    /// belongs to the window. Between them the longer one holds, which is what asking both gives.
    public var unlockSeconds: Int?
    /// Whether this group's passcode still has to be entered before the page opens.
    public var passcodeRequired: Bool
    /// Seconds until this group's forgotten passcode is cleared, or `nil` when nothing is waiting.
    public var resetSeconds: Int?

    public init(
        unlockSeconds: Int? = nil, passcodeRequired: Bool = false, resetSeconds: Int? = nil
    ) {
        self.unlockSeconds = unlockSeconds
        self.passcodeRequired = passcodeRequired
        self.resetSeconds = resetSeconds
    }

    /// Whether anything about this group is being held this second.
    public var holds: Bool { unlockSeconds != nil || passcodeRequired }
}

/// The lock one group carries: a wait measured from this visit, and a passcode answered once per
/// visit per group.
///
/// The third gate of a settings visit, beside `SettingsLockGate` and `BreakWaitGate`, and written
/// to the same contract: it knows nothing about the engine, the disk or a clock — the caller hands
/// in the group as it is stored and the reading it is asking about. That is what makes every rule
/// here reachable from a test without building a window around it.
///
/// **Once per visit, per group.** The answered codes are a set of group ids, cleared when the
/// window opens and when it goes away, exactly as `SettingsLockGate` clears its one flag: a code
/// entered for Social buys Social for the rest of this visit and buys nothing for Adult. There is
/// no standalone scope here — every one of these questions is asked inside the settings window,
/// which is the only place a group can be edited at all.
///
/// **The lock must never trap.** An emergency pass lifts both refusals, and the hour that clears a
/// forgotten code is on the door — see `GroupDoor`. A lock with no price is a trap rather than a
/// commitment device, and a group door with no way past a forgotten code is a reinstall.
///
/// A group may opt the app's unblocks out (`GroupSettings.ignoresAppWideUnblocks`), and then the
/// pass lifts neither refusal here. That leaves the hour as the only way past a forgotten code,
/// which is exactly why it is per group and cannot be switched off: the app-wide lock's
/// `allowForgot` has no twin down here, and `GroupDoor.Recovery` has no state that hides the offer.
///
/// The break the same setting now shuts out never reached this gate for **any** group: "Unblock
/// everything" lifts blocks and holds no setting, so there is nothing here for it to widen.
public struct GroupLockGate: Equatable {

    /// Why an edit to a group was refused, in the words the screen shows. No refusal names a
    /// number, for the reason `SettingsLockGate.Refusal` names none: a countdown built at the
    /// moment of the refusal is stale in the breath after it.
    public enum Refusal: Equatable {
        case timer(secondsLeft: Int)
        case passcode

        public func text(groupNamed name: String) -> String {
            switch self {
            case .timer:
                return "Held by the lock on \(name)"
            case .passcode:
                return "Enter the passcode for \(name) to change it"
            }
        }
    }

    /// When the settings window came up, or `nil` while none is open.
    private var openedAt: ClockReading?
    /// The groups whose passcode has been entered during this visit, and **when** — because for a
    /// group that has both halves of a lock, that moment is where its countdown starts. See
    /// `timerSecondsLeft`.
    private var answeredAt: [String: ClockReading] = [:]
    /// The groups whose own timer was switched on during this visit and whose page has not been
    /// left since — the exemption, before it arms. See `timerSwitchedOn(forGroup:)`.
    private var started: Set<String> = []
    /// When a freshly switched-on timer armed, per group: the moment its page was left. What its
    /// countdown is then measured from. See `leftGroup(_:at:)`.
    private var armedAt: [String: ClockReading] = [:]

    public init() {}

    // MARK: - One visit to the settings window

    /// The settings window came up. A repeated call must not restart the wait, for the reason
    /// `SettingsLockGate.windowOpened` refuses one: asking for a window that is already open
    /// brings the existing one forward, and clicking Settings again would otherwise be a way of
    /// putting every group's countdown back to full.
    ///
    /// An exemption left behind by a lock switched on with no window open goes the same way a
    /// code answered before the visit does: it was not this visit's to spend.
    public mutating func windowOpened(at reading: ClockReading) {
        guard openedAt == nil else { return }
        openedAt = reading
        answeredAt = [:]
        started = []
        armedAt = [:]
    }

    /// The settings window went away. Every timer starts again from the next open, every code
    /// entered during this visit is forgotten, and so is every exemption bought by switching a
    /// group's timer on during it.
    public mutating func windowClosed() {
        openedAt = nil
        answeredAt = [:]
        started = []
        armedAt = [:]
    }

    /// This group's timer was switched on during this visit, so it is not held by it **yet**.
    ///
    /// The app-wide rule at the scope of one group — see `SettingsLockGate.timerSwitchedOn`, where
    /// the trap it undoes is written out. Per group like everything else here: a lock started on
    /// Social this visit lets Social be picked over and buys nothing for Adult, which was locked
    /// before the window opened.
    ///
    /// Where the two scopes now part company is **when the exemption ends**. The app-wide toggle
    /// keeps the rule it was built with: the wait arms at the next window open. A group's does not
    /// wait that long — see `leftGroup(_:at:)`.
    public mutating func timerSwitchedOn(forGroup groupID: String) { started.insert(groupID) }

    /// The user has left this group's page — another group, another page, and that is where a
    /// freshly set wait arms.
    ///
    /// The refinement of the exemption above: setting the minutes must not lock straight away,
    /// because the user is still setting them — it takes hold when they switch groups. The
    /// exemption exists so that nobody is locked out of the stepper they are standing at; once they
    /// have walked away from it there is nothing left to protect, and a lock that waited for the
    /// whole window to close would leave the group open for the rest of a visit that might last an
    /// hour.
    ///
    /// **From this moment**, not from the window opening, which is the half that makes it a wait
    /// rather than a formality: the countdown the group then runs is the full one, measured from
    /// the step away.
    ///
    /// The window going away is the other end of it, and it needs no line here: `windowClosed`
    /// drops the exemption with everything else, and the wait is owed in full at the next open.
    /// Arming it to burn down while no window is open would be the opposite of a lock — close the
    /// window, wait, come back free.
    ///
    /// Only a group whose wait this visit **started** is armed. Leaving the page of a group that
    /// was already locked changes nothing: its countdown has been running since the window opened,
    /// or since its code was entered.
    public mutating func leftGroup(_ groupID: String, at reading: ClockReading) {
        guard started.remove(groupID) != nil else { return }
        armedAt[groupID] = reading
    }

    /// Try a group's passcode. `true` opens that group for the rest of this visit, and no other.
    ///
    /// A group with no passcode set accepts nothing: there is nothing to be right about, and
    /// answering `true` would let a caller believe it had opened something.
    ///
    /// The reading is kept because a coded group's wait is measured from it — and it is kept
    /// **once**: a second right answer during the same visit must not push the countdown forward,
    /// or somebody could hold a group open by retyping the code. There is nothing on screen that
    /// asks twice, which is exactly why the guard belongs here rather than in the caller.
    public mutating func accept(
        passcode: String, forGroup groupID: String, settings: GroupSettings, at reading: ClockReading
    ) -> Bool {
        guard let stored = settings.passcode, stored.matches(passcode) else { return false }
        if answeredAt[groupID] == nil { answeredAt[groupID] = reading }
        return true
    }

    // MARK: - What it refuses

    /// Why this group cannot be changed, or `nil` when it can.
    ///
    /// The timer first, matching `SettingsLockGate.refusal`: one refusal at a time, and the one
    /// with a countdown on it first — told to enter the passcode, somebody would enter it and be
    /// refused a second time for a reason nobody had mentioned.
    ///
    /// **`tightening` is the direction of the edit, and both halves let it through.** The app-wide
    /// rule at the scope of one group — see `EditDirection` for the lock rule
    /// behind it. Both halves rather than the timer alone, and that is the difference: the
    /// app-wide passcode puts a door in front of the whole window, so nothing arrives to be judged
    /// while it is owed, but this one stands in front of **one page** while the rest of the
    /// window edits freely. An edit reaching a coded group from somewhere else — a category grown
    /// in Presets → Categories, the all-at-once switch putting the groups back on — has never been
    /// asked to open that door, and the ones that block harder never should have been.
    ///
    /// Defaulted to the safe half, so a caller with no pair of configurations to compare is held
    /// exactly as before.
    public func refusal(
        for settings: GroupSettings, groupID: String, at now: ClockReading,
        emergencyPassRunning: Bool, tightening: Bool = false
    ) -> Refusal? {
        guard !lifted(by: emergencyPassRunning, for: settings), !tightening else { return nil }
        if let secondsLeft = timerSecondsLeft(for: settings, groupID: groupID, at: now) {
            return .timer(secondsLeft: secondsLeft)
        }
        return passcodeRequired(for: settings, groupID: groupID) ? .passcode : nil
    }

    /// Everything one group's editor shows about its own lock, in one value.
    public func state(
        for settings: GroupSettings, groupID: String, at now: ClockReading,
        emergencyPassRunning: Bool
    ) -> GroupLockState {
        let lifted = lifted(by: emergencyPassRunning, for: settings)
        return GroupLockState(
            unlockSeconds: lifted
                ? nil : timerSecondsLeft(for: settings, groupID: groupID, at: now),
            passcodeRequired: lifted
                ? false : passcodeRequired(for: settings, groupID: groupID),
            resetSeconds: settings.passcodeForgotSecondsLeft(at: now)
        )
    }

    /// Every group being held this second — what the all-at-once switch leaves alone, and what it
    /// counts when it says so.
    ///
    /// Asked per group rather than answered `[]` on the strength of a running pass, because the
    /// pass no longer reaches every group: one set to ignore it is held through the hour and has
    /// to go on being left behind by the switch. See `lifted(by:for:)`.
    public func heldGroups(
        in config: Config, at now: ClockReading, emergencyPassRunning: Bool
    ) -> Set<String> {
        Set(
            config.groupSettings
                .filter {
                    refusal(
                        for: $0.value, groupID: $0.key, at: now,
                        emergencyPassRunning: emergencyPassRunning
                    ) != nil
                }
                .map(\.key)
        )
    }

    /// Whether a running pass lifts this group's lock at all.
    ///
    /// **The one question every answer above runs through**, so the three cannot drift: a group
    /// that has opted out keeps its door shut and its wait counting for the whole hour, exactly as
    /// if no pass had been spent. Which is the half of the toggle that makes it worth
    /// having — the pass unblocks by ending blocks, so a group whose blocks stand but whose
    /// configuration lay open for an hour would be one click from being switched off anyway.
    ///
    /// The group's own forgot flow is untouched by this and always has been: `resetSeconds` is read
    /// off the stored settings rather than through here, and `GroupDoor.Recovery` has no state that
    /// takes it away. That is what keeps this from being a trap — see
    /// `GroupSettings.ignoresAppWideUnblocks`.
    private func lifted(by emergencyPassRunning: Bool, for settings: GroupSettings) -> Bool {
        emergencyPassRunning && !settings.ignoresAppWideUnblocks
    }

    /// Seconds this group's own timer still holds it for, or `nil` when it is off or has run out.
    ///
    /// **A wait switched on this visit counts from the moment its page was left**, which is where
    /// it arms — see `leftGroup(_:at:)` — and until then it is not counting at all.
    ///
    /// **A group with a passcode counts from the moment the code was entered**, not from the
    /// window opening: when a passcode is required, the time only starts going down once the code
    /// has been entered. With both halves set the wait was toothless — it ran while
    /// the door stood shut, so by the time anybody had typed the code it had usually lapsed, and
    /// the group was open the instant it was opened. Once per visit, from the first right answer;
    /// a group with a wait and no code goes on counting from the window, because there is no other
    /// moment to count from.
    ///
    /// With a code owed and none entered there is no countdown at all rather than a full one, and
    /// nothing is let through by that: `refusal` asks this first and answers `.passcode` when it
    /// comes back empty. A number there would have the editor count down a wait nobody has started.
    ///
    /// A window that has not announced itself is treated as one that just opened, rather than as
    /// one with no timer — fail-closed, for the reason `SettingsLockGate.timerSecondsLeft` fails
    /// closed: the only way to reach this with nothing open is a path that forgot to say so, and a
    /// lock that quietly lets those through is not a lock.
    ///
    /// The visit that switched this group's timer on is answered `nil` outright rather than a
    /// smaller number: the wait is not shorter for them, it is not theirs. Which is also why the
    /// editor's own notice needs no rule of its own — `EditorFreeze` reads what this answers. See
    /// `timerSwitchedOn(forGroup:)`.
    ///
    /// **After the unannounced-window branch**, for the reason `SettingsLockGate.timerSecondsLeft`
    /// puts it there: a lock switched on with no window open earns no exemption, because an
    /// exemption is a fact about a visit. The all-at-once switch is what would notice — it asks
    /// `heldGroups` from wherever it is pressed — and a group locked a moment ago must not be one
    /// it sweeps away.
    private func timerSecondsLeft(
        for settings: GroupSettings, groupID: String, at now: ClockReading
    ) -> Int? {
        guard settings.timerIsOn else { return nil }
        let whole = TimeInterval(settings.lockMinutes * 60)
        guard openedAt != nil else { return Int(whole) }
        guard !started.contains(groupID) else { return nil }
        guard let from = countsFrom(settings, groupID: groupID) else { return nil }
        let left = whole - now.secondsSince(from)
        guard left > 0 else { return nil }
        return Int(left.rounded(.up))
    }

    /// The moment this group's wait is measured from, in the order the three answers outrank each
    /// other: the page being left where a wait armed there this visit, the code being entered where
    /// there is one, the window opening otherwise.
    ///
    /// Arming wins because it is the latest fact and the most specific — a wait set at 12:00 and
    /// armed at 12:02 is a wait that starts at 12:02, whether or not a code was entered at 11:58.
    ///
    /// `nil` while a code is owed: the wait has not started, and `refusal` answers with the code
    /// instead.
    private func countsFrom(_ settings: GroupSettings, groupID: String) -> ClockReading? {
        if let armedAt = armedAt[groupID] { return armedAt }
        guard settings.passcode != nil else { return openedAt }
        return answeredAt[groupID]
    }

    private func passcodeRequired(for settings: GroupSettings, groupID: String) -> Bool {
        settings.passcode != nil && answeredAt[groupID] == nil
    }
}
