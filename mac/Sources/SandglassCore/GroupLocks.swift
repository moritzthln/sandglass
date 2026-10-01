import Foundation

extension GroupSettings {

    /// How long a group's own lock may be set for, and where its off state is.
    ///
    /// Nought to four hours. The top is the app-wide lock's — a lock is worth walking into
    /// deliberately and not worth a whole day bought by a slipped keystroke — and the bottom is 0,
    /// which reads as its own word rather than as a minute. See `SettingsLock.timerRange`, whose
    /// bottom is 1 because a switch beside it carries its off state.
    public static let lockRange = 0...240

    /// Where the stepper lands from `minutes`, in the direction asked for. The app-wide lock's
    /// grid, so two waits that mean the same thing step the same way — minute by minute to 10,
    /// then fives to an hour, then quarter-hours.
    public static func lockMinutes(after minutes: Int, goingUp: Bool) -> Int {
        SettingsLock.timerMinutes(after: minutes, goingUp: goingUp)
    }

    /// Whether this group carries a lock of its own at all — either half of one.
    public var hasOwnLock: Bool { lockMinutes > 0 || passcode != nil }

    /// Whether this group's own wait is switched on. Nought is off — see `lockRange`, whose
    /// bottom is the off state this names. `SettingsLock.timerIsOn` one scope up.
    public var timerIsOn: Bool { lockMinutes > 0 }

    /// Seconds still to run before this group's forgotten passcode is cleared, or `nil` when
    /// nothing is waiting. The app-wide hour, and the same arithmetic — see
    /// `SettingsLock.forgotSecondsLeft`.
    ///
    /// Answers `nil` for a wait left behind on a group whose passcode has since gone: what it was
    /// for has happened, and a stale timestamp must not clear the *next* passcode the moment one
    /// is set.
    public func passcodeForgotSecondsLeft(at now: ClockReading) -> Int? {
        guard passcode != nil, let started = passcodeForgotStartedAt else { return nil }
        let left = TimeInterval(SettingsLock.forgotWaitMinutes * 60) - now.secondsSince(started)
        guard left > 0 else { return nil }
        return Int(left.rounded(.up))
    }

    /// Whether a running wait has finished and this group's passcode is now the app's to clear.
    public func passcodeForgotIsDue(at now: ClockReading) -> Bool {
        guard passcode != nil, passcodeForgotStartedAt != nil else { return false }
        return passcodeForgotSecondsLeft(at: now) == nil
    }

    /// Clears a passcode whose hour is up, and reports whether anything changed. The wait goes
    /// with it, for the reason `SettingsLock.clearForgottenPasscode` takes it away.
    public mutating func clearForgottenPasscode(at now: ClockReading) -> Bool {
        guard passcodeForgotIsDue(at: now) else { return false }
        passcode = nil
        passcodeForgotStartedAt = nil
        return true
    }
}

/// What a group's own lock has to know about an edit that is not a question of direction.
///
/// Two answers, and both are about **a pair of configurations** rather than about one: nothing
/// here reads a clock, a gate or a passcode. Which way an edit moves a group is `EditDirection`'s
/// — a lock holds loosening and only loosening — what a held group then refuses is
/// `GroupLockGate`'s, and where the three meet is `AppState.applyConfigEdit`, beside the app-wide
/// lock and outside the engine, which knows nothing about the user's own locks.
///
/// It used to carry a third: `touched`, every group whose definition differed either way, and
/// `shrunk` beside it for the category side door. Both went when the direction table came back —
/// a group that could only be made *stricter* is what the lock rule asks for, and asking "is this
/// group in the edit at all" cannot tell the two apart. The side door goes on being caught, by the
/// carried-contents comparison below, which `EditDirection` reads.
public enum GroupLocks {

    /// Every group whose own wait this edit **starts** — off before it, on after it.
    ///
    /// The third question, and the only one that is not about refusing anything: it names the
    /// groups a visit is let off, because the visit that switches a wait on is never held by it.
    /// See `SettingsLockGate.timerSwitchedOn` for the trap that answer exists to close.
    ///
    /// Starting one only. A wait that is already there and is raised, shortened or taken away is
    /// not in here — changing one is precisely what a running wait is there to hold, and a
    /// switch-on that counted as one would be a lock anybody could shake off by toggling it.
    ///
    /// A group that exists only in `proposed` counts as switching its lock on: it was not there a
    /// moment ago, so there is no wait behind it that anybody could have sat out.
    public static func timersSwitchedOn(from current: Config, to proposed: Config) -> Set<String> {
        var ids: Set<String> = []
        for (groupID, settings) in proposed.groupSettings where settings.timerIsOn {
            guard current.settings(forGroup: groupID)?.timerIsOn != true else { continue }
            ids.insert(groupID)
        }
        return ids
    }

    /// Everything a group's live categories actually carry, as target ids — the same vocabulary
    /// `Config.targets` answers in, and the same vocabulary an exception is written in.
    ///
    /// A set rather than a list: the order the lists happen to be in is not a fact about what is
    /// blocked, and reordering the Categories card must not read as taking something away.
    public static func carried(by settings: GroupSettings, in config: Config) -> Set<String> {
        var ids: Set<String> = []
        for categoryID in settings.categories {
            guard let category = config.category(id: categoryID) else { continue }
            let members = CategoryMembership.members(of: category, in: settings)
            ids.formUnion(members.domains.map { Target.id(ofKind: .domain, value: $0) })
            ids.formUnion(members.bundleIDs.map { Target.id(ofKind: .app, value: $0) })
        }
        return ids
    }
}
