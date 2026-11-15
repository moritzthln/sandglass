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

/// Whether a group opens with a password, and when the password is what holds it.
///
/// One value rather than an optional password beside a switch, because the switch meant nothing
/// without the password and every reader had to remember to ask both. Three cases, and each place
/// that cares — the decision ladder, the reapers, earn-back, the app's unblocks, the lock rule —
/// says what it does with each of them.
///
/// - `none` — the ordinary group, opened through its budget.
/// - `always` — the password is the only way through, at every hour.
/// - `inStrictWindows` — the password is the way through the group's strict windows, and outside
///   them the group is an ordinary budget group. A group with no strict windows never asks.
public enum PasswordMode: Equatable, Sendable {
    case none
    case always(AccessPassword)
    case inStrictWindows(AccessPassword)

    /// The two keys it is stored as, read back into one value. A scope with no password is
    /// `.none`: there is nothing for it to narrow.
    public init(_ password: AccessPassword?, onlyInStrictWindows: Bool) {
        guard let password else {
            self = .none
            return
        }
        self = onlyInStrictWindows ? .inStrictWindows(password) : .always(password)
    }

    /// The password either mode asks for, or `nil` for `.none`.
    public var password: AccessPassword? {
        switch self {
        case .none: return nil
        case .always(let password), .inStrictWindows(let password): return password
        }
    }
}

/// What typing a group's access password got somebody.
public enum AccessAttempt: Equatable, Sendable {
    /// The password matched and opened the group for this long. Only ever the answer to a
    /// password that was checked: a group already open answers `.refused(.allowed)`, unchecked
    /// and uncounted, so a wrong password never reads as one that opened something.
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
    /// for the group's settings door, which the password guards too. `nil` means it matched. A
    /// group with no access password answers `.refused(.notManaged)`.
    ///
    /// Asked of the group whether or not it is switched on: switching a password group off is one
    /// of the things its password holds, and turning it back on is a tightening anyone may make.
    public func verifyAccessPassword(_ typed: String, groupID: String) -> AccessAttempt? {
        verifyAnyAccessPassword(typed, groupIDs: [groupID])
    }

    /// The same for one entry that any one of several groups' passwords may answer — the
    /// keep-alive switch, which asks for "a password" without asking whose. `nil` means one
    /// matched. See `AccessAttempts.checkAny` for what a miss costs each of them.
    public func verifyAnyAccessPassword(_ typed: String, groupIDs: [String]) -> AccessAttempt? {
        advanceToNow()
        let passwords = groupIDs.compactMap { config.settings(forGroup: $0)?.accessPassword }
        guard !passwords.isEmpty else { return .refused(.notManaged) }
        return countingAttempts {
            $0.checkAny(
                typed, against: passwords, settingsPasscode: config.settingsLock.passcode, at: reading
            )
        }
    }

    /// The password is only looked at while it is the one thing standing in the way. Anything
    /// else is answered without reading it, so a guess made inside a strict window is neither
    /// checked nor counted — there was nothing for it to open — and neither is one typed at a
    /// group that is already open, which is told so rather than told it was unlocked.
    private func tryAccess(_ typed: String, _ managed: GroupLookup.Managed) -> AccessAttempt {
        let current = decision(for: managed)
        guard let password = managed.settings.accessPassword,
              case .blocked(.passwordRequired, _) = current else { return .refused(current) }
        if let failed = countingAttempts({
            $0.check(typed, against: password, settingsPasscode: config.settingsLock.passcode, at: reading)
        }) {
            return failed
        }
        return .unlocked(sessionSeconds: startAccessSession(managed))
    }

    /// Runs one check against the counter the state carries, and writes back what it left. A
    /// wait it started is a fresh uptime twin, so the reboot check's anchor moves with it.
    private func countingAttempts(
        _ check: (inout AccessAttempts) -> AccessAttempt?
    ) -> AccessAttempt? {
        var attempts = state.accessAttempts ?? AccessAttempts()
        let result = check(&attempts)
        if result == .wrong(attemptsLeft: 0) { state.uptimeAnchor = reading.uptime }
        state.accessAttempts = attempts.isEmpty ? nil : attempts
        return result
    }

    /// Seconds before this group checks a password again, or `nil` when it will. For the prompt,
    /// which says so instead of taking a password it is going to refuse.
    public func accessWaitSeconds(groupID: String) -> Int? {
        guard let password = config.settings(forGroup: groupID)?.accessPassword else { return nil }
        return state.accessAttempts?.secondsLeft(secret: password.attemptKey, at: reading)
    }

    /// The rung `decision(for:)` asks between the hard blocks and the budgets, or `nil` for a
    /// group whose password does not ask at every hour.
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
        guard case .always = managed.settings.passwordMode else { return nil }
        let budget = GroupBudget(state: state, reading: reading)
        if let remaining = budget.remainingSessionSeconds(managed.groupID) {
            return .allowed(remainingSessionSeconds: remaining)
        }
        return .blocked(reason: .passwordRequired, untilText: "Opens with its password")
    }

    /// The same rung for a group whose password asks only inside its strict windows, asked by
    /// `decision(for:)` while one is standing. `nil` leaves the window's own block in force.
    ///
    /// **Only a session the password bought runs on through the window.** An ordinary open made
    /// just before the window began is held by it as it always was — otherwise every window
    /// would start with a free twenty minutes for whoever opened the group at a minute to. And
    /// the password's session goes no further than the window: see `startAccessSession`.
    func windowPasswordGate(_ managed: GroupLookup.Managed, untilText: String) -> Decision? {
        guard case .inStrictWindows = managed.settings.passwordMode else { return nil }
        let budget = GroupBudget(state: state, reading: reading)
        if state.sessions[managed.groupID]?.kind == .password,
           let remaining = budget.remainingSessionSeconds(managed.groupID) {
            return .allowed(remainingSessionSeconds: remaining)
        }
        return .blocked(reason: .passwordRequired, untilText: untilText + " · opens with its password")
    }
}

// MARK: - Across the configuration

extension Config {

    /// Whether any group opens with the settings passcode. While one does, the passcode's
    /// forgot hour does not clear it: that hour recovers the settings, not the site.
    public var opensAGroupWithSettingsPasscode: Bool {
        !groupsOpeningWithSettingsPasscode.isEmpty
    }

    /// The groups that open with the settings passcode, sorted — every one of which nothing can
    /// open while no settings passcode is set. Switched-off ones included: switching one back on
    /// is a tightening anyone may make, and it would come back shut.
    public var groupsOpeningWithSettingsPasscode: [String] {
        groupSettings.keys.sorted().filter { groupSettings[$0]?.accessPassword == .settingsPasscode }
    }

    /// The switched-on groups that open only with a password, sorted — the ones whose password
    /// switching off the keep-alive asks for. A switched-off one is left out: switching it off
    /// already took its password, and it blocks nothing.
    public var passwordGroups: [String] {
        groupSettings.keys.sorted().filter { activeSettings(forGroup: $0)?.accessPassword != nil }
    }
}
