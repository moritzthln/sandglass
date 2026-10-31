import Foundation

/// What typing a group's access password got somebody.
public enum AccessAttempt: Equatable, Sendable {
    /// The password matched and the group is open for this long. Also the answer for a group
    /// whose password session is already running: typing it again buys nothing and costs nothing.
    case unlocked(sessionSeconds: Int)
    /// It did not match. `attemptsLeft` is how many more may be tried before the wait; `0` means
    /// this one started it.
    case wrong(attemptsLeft: Int)
    /// Too many wrong ones in a row. Nothing is checked until the wait is over — not even a right
    /// password, or the wait would only slow down the guesses that were going to fail anyway.
    case lockedOut(secondsLeft: Int)
    /// The group is not asking for a password right now, so nothing was checked or counted. What
    /// it is doing instead rides along: a strict window, a dated block, "Block everything", or
    /// `.notManaged` under a pass. A password never opens a group a harder block is holding.
    case refused(Decision)
}

/// Wrong passwords per group, and the wait five of them in a row earn.
///
/// **In memory, deliberately.** It defends against somebody trying every four-digit code at the
/// prompt, and a minute between every five tries turns ten thousand guesses into more than a day.
/// Quitting to reset the count is possible and costs the keep-alive's restart each time, which is
/// slower than the wait it skips. Writing it to disk would add a file format for no real gain.
///
/// Measured on the uptime clock, so moving the system clock forward ends no wait.
public struct AccessAttempts: Equatable, Sendable {
    /// How many wrong passwords in a row are forgiven before the wait.
    public static let freeAttempts = 5
    /// How long the wait is. Short enough for somebody who mistyped, long enough for a guesser.
    public static let lockoutSeconds: TimeInterval = 60

    private var failures: [String: Int] = [:]
    private var lockedUntil: [String: TimeInterval] = [:]

    public init() {}

    /// Seconds still to wait before this group checks a password again, or `nil` when it will.
    public func secondsLeft(groupID: String, uptime: TimeInterval) -> Int? {
        guard let until = lockedUntil[groupID], until > uptime else { return nil }
        return Int((until - uptime).rounded(.up))
    }

    /// Checks `password`, unless the group is waiting out its last five wrong ones.
    ///
    /// The count starts again once a wait is over, so the sixth try gets a fresh five rather than
    /// a wait after every single miss: the wait is a brake on guessing, not a punishment for the
    /// person who mistyped. A right password clears the count too.
    public mutating func check(
        _ password: String, against hash: PasscodeHash, groupID: String, uptime: TimeInterval
    ) -> AccessAttempt? {
        if let wait = secondsLeft(groupID: groupID, uptime: uptime) { return .lockedOut(secondsLeft: wait) }
        lockedUntil.removeValue(forKey: groupID)
        guard !hash.matches(password) else {
            failures.removeValue(forKey: groupID)
            return nil
        }
        let count = (failures[groupID] ?? 0) + 1
        guard count >= Self.freeAttempts else {
            failures[groupID] = count
            return .wrong(attemptsLeft: Self.freeAttempts - count)
        }
        failures.removeValue(forKey: groupID)
        lockedUntil[groupID] = uptime + Self.lockoutSeconds
        return .wrong(attemptsLeft: 0)
    }
}

// MARK: - The engine's half

extension RulesEngine {

    /// Try a group's access password, asked about the group itself.
    public func tryAccessPassword(_ password: String, groupID: String) -> AccessAttempt {
        advanceToNow()
        guard let settings = config.activeSettings(forGroup: groupID) else {
            return .refused(.notManaged)
        }
        return tryAccess(password, GroupLookup.Managed(groupID: groupID, settings: settings))
    }

    /// The same, for an application or a target the configuration lists.
    public func tryAccessPassword(_ password: String, targetID: String) -> AccessAttempt {
        advanceToNow()
        guard let managed = lookup.managed(targetID: targetID) else { return .refused(.notManaged) }
        return tryAccess(password, managed)
    }

    /// The same, for a page in a browser — the group whichever rule claims the address belongs to.
    public func tryAccessPassword(_ password: String, url: String) -> AccessAttempt {
        advanceToNow()
        guard let managed = lookup.managed(url: url) else { return .refused(.notManaged) }
        return tryAccess(password, managed)
    }

    /// The password is only looked at while it is the one thing standing in the way. Anything
    /// harder is answered without reading it, so a guess made inside a strict window is neither
    /// checked nor counted — there was nothing for it to open.
    private func tryAccess(_ password: String, _ managed: GroupLookup.Managed) -> AccessAttempt {
        let current = decision(for: managed)
        guard let hash = managed.settings.accessPassword else { return .refused(current) }
        if case .allowed(let remaining) = current { return .unlocked(sessionSeconds: remaining) }
        guard case .blocked(.passwordRequired, _) = current else { return .refused(current) }
        if let failed = accessAttempts.check(
            password, against: hash, groupID: managed.groupID, uptime: reading.uptime
        ) {
            return failed
        }
        return .unlocked(sessionSeconds: startAccessSession(managed))
    }

    /// Seconds before this group checks a password again, or `nil` when it will. For the prompt,
    /// which says so instead of taking a password it is going to refuse.
    public func accessWaitSeconds(groupID: String) -> Int? {
        accessAttempts.secondsLeft(groupID: groupID, uptime: reading.uptime)
    }

    /// The rung `decision(for:)` asks between the hard blocks and the budgets, or `nil` for a
    /// group with no access password.
    ///
    /// **Over every budget**, in both directions: no pause, open or cooldown lets a password group
    /// through, and once the password has bought a session none of them — the daily time limit
    /// included — takes it away early. **Under every hard block**: the caller has already answered
    /// for a moved clock, "Block everything", the dated block and the strict window, so a right
    /// password never opens a group one of them is holding. The emergency pass and "Unblock
    /// everything" lift it like any other block, unless the group ignores them — the same opt-out,
    /// for the same reason: the app's safety net does not grow a hole because a block has a
    /// password on it, and a group meant to be immune says so in the switch that exists for that.
    /// A break window of the group's own opens it too: it is the owner's planned free time.
    func passwordGate(_ managed: GroupLookup.Managed) -> Decision? {
        guard managed.settings.accessPassword != nil else { return nil }
        let budget = GroupBudget(state: state, reading: reading)
        if let remaining = budget.remainingSessionSeconds(managed.groupID) {
            return .allowed(remainingSessionSeconds: remaining)
        }
        return .blocked(reason: .passwordRequired, untilText: "Opens with its password")
    }
}
