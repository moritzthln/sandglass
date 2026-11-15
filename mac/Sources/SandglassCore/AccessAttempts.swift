import Foundation

/// Wrong passwords per secret, and the wait five of them in a row earn.
///
/// **One counter per secret, for every place it is typed** — the pause screen, the block page's
/// prompt, the group's settings door and the keep-alive switch — so moving between them buys no
/// extra guesses. Per secret rather than per group: three groups that open with the settings
/// passcode are three doors in front of one secret, and counting each door on its own would give
/// a guesser fifteen tries a minute at it instead of five.
///
/// **Kept in `EngineState`, so on disk.** It defends against somebody trying every four-digit
/// code at the prompt, and a minute between every five tries turns ten thousand guesses into more
/// than a day. A count that lived in memory was reset by quitting, and the keep-alive's restart
/// made quitting cheap; written down, a relaunch picks the count and the wait up where they were.
///
/// Measured on the uptime clock, so moving the system clock forward ends no wait. Each wait is
/// stored as a wall date with an uptime twin, like every other deadline in the state: after a
/// reboot the twin is dropped and the wall date — a minute at most — decides on its own.
public struct AccessAttempts: Codable, Equatable, Sendable {
    /// How many wrong passwords in a row are forgiven before the wait.
    public static let freeAttempts = 5
    /// How long the wait is. Short enough for somebody who mistyped, long enough for a guesser.
    public static let lockoutSeconds: TimeInterval = 60

    private var failures: [String: Int] = [:]
    private var lockedUntil: [String: Date] = [:]
    private var lockedUntilUptime: [String: TimeInterval] = [:]

    public init() {}

    /// Whether there is nothing worth writing down: no miss counted and no wait standing.
    public var isEmpty: Bool { failures.isEmpty && lockedUntil.isEmpty }

    /// Seconds still to wait before this secret is checked again, or `nil` when it will be.
    public func secondsLeft(secret: String, at reading: ClockReading) -> Int? {
        guard let until = lockedUntil[secret] else { return nil }
        let left = reading.secondsUntil(until, uptime: lockedUntilUptime[secret])
        guard left > 0 else { return nil }
        return Int(left.rounded(.up))
    }

    /// Checks `typed` against one password, unless its secret is waiting out its last five wrong
    /// ones. `nil` means it matched.
    ///
    /// The count starts again once a wait is over, so the sixth try gets a fresh five rather than
    /// a wait after every single miss: the wait is a brake on guessing, not a punishment for the
    /// person who mistyped. A right password clears the count too.
    public mutating func check(
        _ typed: String, against password: AccessPassword, settingsPasscode: PasscodeHash?,
        at reading: ClockReading
    ) -> AccessAttempt? {
        checkAny(typed, against: [password], settingsPasscode: settingsPasscode, at: reading)
    }

    /// The same, for one entry meant for **any one** of several passwords — the keep-alive switch,
    /// which does not ask whose. `nil` means one of them matched.
    ///
    /// Every secret is compared before anything is counted, so a right password costs nothing,
    /// whichever group it belongs to. A miss is then counted **once per secret**: the entry was a
    /// guess at each of them, and charging fewer would hand out guesses nobody counted. A secret
    /// that is waiting is neither compared nor counted, so the switch is no way around its wait.
    public mutating func checkAny(
        _ typed: String, against passwords: [AccessPassword], settingsPasscode: PasscodeHash?,
        at reading: ClockReading
    ) -> AccessAttempt? {
        var seen = Set<String>()
        var outcome: AccessAttempt?
        var missed: [String] = []
        for password in passwords where seen.insert(password.attemptKey).inserted {
            let secret = password.attemptKey
            if let wait = secondsLeft(secret: secret, at: reading) {
                outcome = outcome ?? .lockedOut(secondsLeft: wait)
                continue
            }
            switch password.matches(typed, settingsPasscode: settingsPasscode) {
            case true?:
                forgive(secret)
                return nil
            case false?:
                missed.append(secret)
            case nil:
                outcome = outcome ?? .noSettingsPasscode
            }
        }
        for secret in missed { outcome = countMiss(secret, at: reading) }
        return outcome
    }

    /// Forgets the uptime half of every wait, for the reason `EngineState.dropUptimeTwins` does.
    public mutating func dropUptimeTwins() {
        lockedUntilUptime = [:]
    }

    private mutating func forgive(_ secret: String) {
        failures.removeValue(forKey: secret)
        lockedUntil.removeValue(forKey: secret)
        lockedUntilUptime.removeValue(forKey: secret)
    }

    private mutating func countMiss(_ secret: String, at reading: ClockReading) -> AccessAttempt {
        lockedUntil.removeValue(forKey: secret)
        lockedUntilUptime.removeValue(forKey: secret)
        let count = (failures[secret] ?? 0) + 1
        guard count >= Self.freeAttempts else {
            failures[secret] = count
            return .wrong(attemptsLeft: Self.freeAttempts - count)
        }
        failures.removeValue(forKey: secret)
        let until = reading.deadline(in: Self.lockoutSeconds)
        lockedUntil[secret] = until.wall
        lockedUntilUptime[secret] = until.uptime
        return .wrong(attemptsLeft: 0)
    }

    // MARK: - On disk

    // Every key optional, and each map read on its own, so a file this build cannot fully read
    // keeps whatever part of the count it can rather than losing all of it.

    private enum CodingKeys: String, CodingKey { case failures, lockedUntil, lockedUntilUptime }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        failures = (try? container.decodeIfPresent([String: Int].self, forKey: .failures)) ?? [:]
        lockedUntil = (try? container.decodeIfPresent([String: Date].self, forKey: .lockedUntil)) ?? [:]
        lockedUntilUptime =
            (try? container.decodeIfPresent([String: TimeInterval].self, forKey: .lockedUntilUptime))
            ?? [:]
    }
}

extension AccessPassword {
    /// Which counter a try at this password lands on: one for the settings passcode, however many
    /// groups open with it, and one for each password of a group's own. A custom password is
    /// known by its salt, which is unique to it and says nothing about the password itself.
    var attemptKey: String {
        switch self {
        case .settingsPasscode: return "settingsPasscode"
        case .custom(let hash): return "custom:" + hash.salt.base64EncodedString()
        }
    }
}
