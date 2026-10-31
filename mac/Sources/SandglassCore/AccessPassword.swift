import Foundation

/// Which password a group that opens only with one opens with.
///
/// Two sources, because the person who holds the password is often the person who already holds
/// the app's settings passcode, and a second secret for the same person is one more to forget.
///
/// - `settingsPasscode` — the app-wide settings passcode, read from `Config.settingsLock` every
///   time it is checked. No copy is kept here, so changing the settings passcode changes this
///   group's password with it. With no settings passcode set **nothing opens the group**: it stays
///   blocked until one is set again. Never the other way round — a missing secret is not an open
///   door.
/// - `custom` — a password of the group's own, salted and hashed like every passcode in the app.
///   See `PasscodeHash` for what that does and does not defend against.
public enum AccessPassword: Codable, Equatable, Sendable {
    case settingsPasscode
    case custom(PasscodeHash)

    /// Whether `typed` is this password, or `nil` when there is nothing to compare it with — a
    /// group relying on a settings passcode that is not set.
    public func matches(_ typed: String, settingsPasscode: PasscodeHash?) -> Bool? {
        switch self {
        case .custom(let hash): return hash.matches(typed)
        case .settingsPasscode: return settingsPasscode?.matches(typed)
        }
    }

    // MARK: - On disk

    // `{"source": "settingsPasscode"}` or `{"source": "custom", "hash": {…}}`. Decoded by hand so
    // a value this build cannot read stays a password rather than taking the whole document down
    // or — worse — reading as no password at all: an unknown source with a hash beside it is that
    // hash, and without one it is the settings passcode. Either way the group stays shut.

    private enum CodingKeys: String, CodingKey { case source, hash }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try? container.decodeIfPresent(String.self, forKey: .source)
        let hash = try? container.decodeIfPresent(PasscodeHash.self, forKey: .hash)
        if source != "settingsPasscode", let hash {
            self = .custom(hash)
        } else {
            self = .settingsPasscode
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .settingsPasscode:
            try container.encode("settingsPasscode", forKey: .source)
        case .custom(let hash):
            try container.encode("custom", forKey: .source)
            try container.encode(hash, forKey: .hash)
        }
    }
}

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
    /// The group opens with the settings passcode and none is set, so nothing can open it until
    /// one is. Not counted as a wrong try: there was nothing to be wrong about.
    case noSettingsPasscode
    /// The group is not asking for a password right now, so nothing was checked or counted. What
    /// it is doing instead rides along: a strict window, a dated block, "Block everything". A
    /// password never opens a group a harder block is holding.
    case refused(Decision)
}

/// Wrong passwords per group, and the wait five of them in a row earn.
///
/// **One counter for every place the password is typed** — the pause screen, the block page's
/// prompt, the group's settings door and the keep-alive switch — so moving between them buys no
/// extra guesses.
///
/// **In memory, deliberately.** It defends against somebody trying every four-digit code at the
/// prompt, and a minute between every five tries turns ten thousand guesses into more than a day.
/// Quitting to reset the count costs the keep-alive's restart each time, which is slower than the
/// wait it skips — and switching the keep-alive off asks for the password too.
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

    /// Checks `typed` against the group's password, unless the group is waiting out its last five
    /// wrong ones. `nil` means it matched.
    ///
    /// The count starts again once a wait is over, so the sixth try gets a fresh five rather than
    /// a wait after every single miss: the wait is a brake on guessing, not a punishment for the
    /// person who mistyped. A right password clears the count too.
    public mutating func check(
        _ typed: String, against password: AccessPassword, settingsPasscode: PasscodeHash?,
        groupID: String, uptime: TimeInterval
    ) -> AccessAttempt? {
        if let wait = secondsLeft(groupID: groupID, uptime: uptime) { return .lockedOut(secondsLeft: wait) }
        lockedUntil.removeValue(forKey: groupID)
        guard let matched = password.matches(typed, settingsPasscode: settingsPasscode) else {
            return .noSettingsPasscode
        }
        guard !matched else {
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

    /// Checks a group's access password **without opening anything**, through the same counter —
    /// for the group's settings door and the keep-alive switch, which the password guards too.
    /// `nil` means it matched. A group with no access password answers `.refused(.notManaged)`.
    ///
    /// Asked of the group whether or not it is switched on: switching a password group off is one
    /// of the things its password holds, and turning it back on is a tightening anyone may make.
    public func verifyAccessPassword(_ typed: String, groupID: String) -> AccessAttempt? {
        advanceToNow()
        guard let password = config.settings(forGroup: groupID)?.accessPassword else {
            return .refused(.notManaged)
        }
        return accessAttempts.check(
            typed, against: password, settingsPasscode: config.settingsLock.passcode,
            groupID: groupID, uptime: reading.uptime
        )
    }

    /// The password is only looked at while it is the one thing standing in the way. Anything
    /// harder is answered without reading it, so a guess made inside a strict window is neither
    /// checked nor counted — there was nothing for it to open.
    private func tryAccess(_ typed: String, _ managed: GroupLookup.Managed) -> AccessAttempt {
        let current = decision(for: managed)
        guard let password = managed.settings.accessPassword else { return .refused(current) }
        if case .allowed(let remaining) = current { return .unlocked(sessionSeconds: remaining) }
        guard case .blocked(.passwordRequired, _) = current else { return .refused(current) }
        if let failed = accessAttempts.check(
            typed, against: password, settingsPasscode: config.settingsLock.passcode,
            groupID: managed.groupID, uptime: reading.uptime
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
    /// password never opens a group one of them is holding.
    ///
    /// **The emergency pass and "Unblock everything" never reach this line**: a password implies
    /// the group's opt-out of both (`GroupSettings.shutsOutAppWideUnblocks`), so the caller judges
    /// it by what is below them. Otherwise the week's pass would be the password's way around. A
    /// break window of the group's own still opens it: that is the owner's planned free time, and
    /// drawing a new one is a loosening the password guards.
    func passwordGate(_ managed: GroupLookup.Managed) -> Decision? {
        guard managed.settings.accessPassword != nil else { return nil }
        let budget = GroupBudget(state: state, reading: reading)
        if let remaining = budget.remainingSessionSeconds(managed.groupID) {
            return .allowed(remainingSessionSeconds: remaining)
        }
        return .blocked(reason: .passwordRequired, untilText: "Opens with its password")
    }
}

// MARK: - Across the configuration

extension Config {

    /// Whether any group opens with the settings passcode. While one does, the passcode's
    /// forgot hour does not clear it: that hour recovers the settings, not the site.
    public var opensAGroupWithSettingsPasscode: Bool {
        groupSettings.values.contains { $0.accessPassword == .settingsPasscode }
    }

    /// The switched-on groups that open only with a password, sorted — the ones whose password
    /// switching off the keep-alive asks for. A switched-off one is left out: switching it off
    /// already took its password, and it blocks nothing.
    public var passwordGroups: [String] {
        groupSettings.keys.sorted().filter { activeSettings(forGroup: $0)?.accessPassword != nil }
    }
}
