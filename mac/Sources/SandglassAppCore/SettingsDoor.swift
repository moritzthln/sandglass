import SandglassCore
import Foundation

/// The door in front of the settings window: whether it is shut, and the one way past it offered
/// to somebody who cannot open it.
///
/// The passcode used to be asked on the first refusal — the window opened, everything was
/// readable, and a sheet appeared the moment something was changed. It is asked at the door now,
/// which makes two things true that were not: without the passcode **nothing** is reachable, the
/// group settings and the numbers screen included, and there is exactly one place the code is
/// typed. The second one is why the lock card's "Settings are locked. [Unlock…]" row is gone —
/// two ways in to the same passcode is one too many.
///
/// **Only the passcode holds this door.** The timer is the other friction and it stays where it
/// was: entering the code lets you in, and "Locked for" goes on refusing changes until it runs
/// out. They ask different questions — who you are, and how long you have sat with it — and only
/// the first one is worth asking of somebody who came to read.
///
/// It knows nothing about a clock or the disk: the caller hands in the lock as it is stored and
/// the state `SettingsLockGate` published this second. That is what makes every rule here reachable
/// from a test without building a window around it.
public struct SettingsDoor: Equatable, Sendable {

    /// The way out of a passcode nobody can remember. Exactly one of these is on the screen,
    /// because a door with two escapes on it is a door somebody reads twice.
    public enum Recovery: Equatable, Sendable {
        /// Recovery is allowed and nothing has been asked for yet: the hour is there to start.
        case offer
        /// The hour is running, and this is what is left of it.
        case waiting(secondsLeft: Int)
        /// Recovery is switched off. The week's emergency pass is the only thing that still
        /// lifts this lock, so the door has to offer it — the settings page is where the pass
        /// lives, and the settings page is now behind this screen. See `Recovery.note`.
        case emergencyPassOnly
    }

    /// Whether the window shows this screen and nothing else.
    ///
    /// The same fact as `SettingsLockState.passcodeRequired`, named for what it now decides. That
    /// value answers "is a passcode still owed", which used to be a question about the next edit
    /// and is now a question about the whole window — including the two cases that make the door
    /// disappear rather than open: a lock with no passcode set, and a running emergency pass.
    public var isClosed: Bool
    public var recovery: Recovery

    public init(lock: SettingsLock, state: SettingsLockState) {
        isClosed = state.passcodeRequired
        // In this order because a wait can only ever be running while recovery is on:
        // `SettingsLock.forgotSecondsLeft` refuses to count one left behind by somebody who has
        // since switched it off, so a running countdown is proof of the setting.
        if let secondsLeft = state.resetSeconds {
            recovery = .waiting(secondsLeft: secondsLeft)
        } else {
            recovery = lock.allowForgot ? .offer : .emergencyPassOnly
        }
    }

    // MARK: - Copy

    /// What the screen calls itself. No prose under it: the wordmark says which app is asking and
    /// this says what it wants, which is the whole screen.
    public static let title = "Enter your passcode"

    /// A wrong code, in the words the rest of the app already uses for one.
    public static let wrongPasscode = SettingsLockGate.Refusal.wrongPasscode.text
}

extension SettingsDoor.Recovery {

    /// The words on the one control. Every state has exactly one, including the running wait —
    /// what a countdown offers is calling it off.
    public var actionTitle: String {
        switch self {
        case .offer: return "Forgot your passcode?"
        case .waiting: return "Cancel"
        case .emergencyPassOnly: return "Use emergency pass"
        }
    }

    /// The line beside or above the control. A wait counts itself down; recovery switched off has
    /// to say what it left standing, because the pass is the only thing that does.
    public var note: String? {
        switch self {
        case .offer:
            return nil
        case .waiting(let secondsLeft):
            return "Passcode clears in \(SettingsLockGate.countdownText(secondsLeft))"
        case .emergencyPassOnly:
            return "Resetting a forgotten passcode is switched off. This week's emergency pass is"
                + " the only thing that still unlocks these settings."
        }
    }

    /// What starting the hour costs, said before it is started rather than after.
    public var help: String? {
        switch self {
        case .offer: return "Clears the passcode an hour from now. Nothing else changes."
        case .waiting: return "The hour cannot be shortened by changing the clock."
        case .emergencyPassOnly: return nil
        }
    }
}

/// The door in front of one group's editor page: whether it is shut, and the two ways past it.
///
/// The same shape `SettingsDoor` has, at the scope of one group — a passcode set on a group gates
/// its whole page, not just the controls on it, which is the answer the app already gives for the
/// window as a whole. Only the passcode holds this door; the group's own timer goes on refusing
/// *changes* behind it, exactly as "Locked for" does behind the settings door. They ask different
/// questions — who you are, and how long you have sat with it — and only the first is worth
/// asking of somebody who came to read.
///
/// **Two escapes rather than one, and this is where it parts company with `SettingsDoor`.** That
/// screen shows exactly one, because it is the whole window and a door with two ways out is a door
/// somebody reads twice. This one is a page inside a window that is otherwise open: the hour that
/// clears a forgotten code is here, and so is the week's emergency pass — which lifts every lock
/// in the app and would otherwise have to be found on another page, by somebody who has just been
/// told they cannot get in.
public struct GroupDoor: Equatable, Sendable {

    /// The hour that clears a forgotten passcode: offered, or running.
    ///
    /// No third state. The app-wide lock has a switch that takes recovery away — see
    /// `SettingsLock.allowForgot` — and a group deliberately has none: the window is a room you
    /// can decide to lock yourself out of, a group is one page of it, and a per-group trap would
    /// be bought for nothing.
    public enum Recovery: Equatable, Sendable {
        case offer
        case waiting(secondsLeft: Int)
    }

    /// Whether the page shows this screen and nothing else.
    public var isClosed: Bool
    public var recovery: Recovery
    /// What the group is called, which is the one thing on this screen that says which door it is.
    public var name: String
    /// Whether the week's pass is worth offering here at all.
    ///
    /// `false` for a group that has opted out of it (`GroupSettings.ignoresAppWideUnblocks`): the
    /// pass would be spent, the rest of the app would unblock, and this door would still be shut.
    /// A button that costs the week's one net and does not open the thing it is drawn on is worse
    /// than no button — so it is not drawn, and the line in its place says why.
    public var offersEmergencyPass: Bool

    public init(name: String, state: GroupLockState, ignoresAppWideUnblocks: Bool = false) {
        self.name = name
        isClosed = state.passcodeRequired
        offersEmergencyPass = !ignoresAppWideUnblocks
        if let secondsLeft = state.resetSeconds {
            recovery = .waiting(secondsLeft: secondsLeft)
        } else {
            recovery = .offer
        }
    }

    // MARK: - Copy

    /// What the screen calls itself. The group's name is the whole title: this door stands inside
    /// a window that already says which app is asking.
    public var title: String { "Enter the passcode for \(name)" }

    /// The one line under it. `SettingsDoor` needs none — a window has no context to give — and
    /// this one does: the sidebar is still there, and somebody who clicked the wrong group has to
    /// be able to tell that is what happened.
    public var subtitle: String { "This group's settings are behind its own passcode." }

    /// A wrong code, in the words the rest of the app already uses for one.
    public static let wrongPasscode = SettingsLockGate.Refusal.wrongPasscode.text

    /// What stands where the pass control would be, on a group that has opted out of it.
    ///
    /// It names the escape that is left rather than only stating the absence, because somebody
    /// reading this screen is somebody who cannot get in: told what is gone and not what remains,
    /// they would reach for the pass on the settings page and spend it for nothing.
    ///
    /// **Both doors, not just the one that is missing from this screen.** The switch shuts the
    /// break out as well now, and somebody standing here with no way in will think of it — so the
    /// sentence rules it out before they walk to the other page for it. It never opened this door
    /// for any group; what is new is that it will not lift the group's blocks either.
    public static let appWideUnblocksDoNotApply =
        "This group ignores the app's ways out, so spending the week's pass would not open it, and"
        + " unblocking everything would not lift its blocks. The hour above is the way past a code"
        + " you have forgotten."
}

extension GroupDoor.Recovery {

    /// The words on the control. Both states have exactly one — what a countdown offers is
    /// calling it off.
    public var actionTitle: String {
        switch self {
        case .offer: return "Forgot this group's passcode?"
        case .waiting: return "Cancel"
        }
    }

    public var note: String? {
        switch self {
        case .offer:
            return nil
        case .waiting(let secondsLeft):
            return "Passcode clears in \(SettingsLockGate.countdownText(secondsLeft))"
        }
    }

    /// What starting the hour costs, said before it is started rather than after.
    public var help: String {
        switch self {
        case .offer: return "Clears this group's passcode an hour from now. Nothing else changes."
        case .waiting: return "The hour cannot be shortened by changing the clock."
        }
    }
}
