import CryptoKit
import Foundation

/// A passcode as it is kept on disk: a salt, and a hash. Never the passcode.
///
/// **The threat model, plainly.** This defends against your own impulse at 23:40 — the moment
/// you open Settings to raise a budget you set with a clear head. It does not defend against
/// somebody with your filesystem: the same person can delete `config.json` and start again with
/// no passcode at all, and no amount of cryptography in a local file changes that. Storing the
/// hash rather than the passcode is still worth doing, because a passcode is a thing people
/// re-use and a plaintext one lying in a JSON file would be a small betrayal.
///
/// Deliberately **not** the Keychain. This build is ad-hoc signed with no stable identity, so a
/// Keychain item does not survive a rebuild reliably — and a first write can raise a system
/// dialogue, which is exactly the kind of surprise a menu-bar app must not spring on somebody.
/// A salted hash beside the settings it guards is honest about what it is.
public struct PasscodeHash: Codable, Equatable, Sendable {
    /// 32 bytes from CryptoKit's generator. Per passcode, so two people choosing 1234 do not
    /// produce the same digest, and so a precomputed table is worth nothing here.
    public var salt: Data
    /// SHA-256 over salt + passcode.
    public var digest: Data

    public init(salt: Data, digest: Data) {
        self.salt = salt
        self.digest = digest
    }

    /// Short enough to type twice from memory, long enough not to be the first thing tried.
    public static let minimumLength = 4

    /// Hashes a new passcode, or `nil` when it is too short to be one.
    ///
    /// The length rule lives here rather than in the sheet that asks for it, so no second way in
    /// can skip it.
    public static func make(_ passcode: String) -> PasscodeHash? {
        guard passcode.count >= minimumLength else { return nil }
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return PasscodeHash(salt: salt, digest: Self.digest(salt: salt, passcode: passcode))
    }

    public func matches(_ passcode: String) -> Bool {
        Self.digest(salt: salt, passcode: passcode) == digest
    }

    private static func digest(salt: Data, passcode: String) -> Data {
        Data(SHA256.hash(data: salt + Data(passcode.utf8)))
    }
}

/// The two frictions on **changing the configuration**, and the way back from the second one.
///
/// Both are off by default and neither blocks anything on their own: they are about the settings
/// screen, not about YouTube. What they buy is the gap between wanting to raise a limit and being
/// able to — the same trade the pause screen makes, applied to the one screen that can undo every
/// other one.
///
/// Stored in `config.json` beside the settings it guards. See `SettingsLockGate` for when each
/// one refuses, and `PasscodeHash` for what is and is not being defended against.
public struct SettingsLock: Codable, Equatable, Sendable {
    /// How long after the settings window opens edits are refused, or `nil` when the timer is off.
    public var timerMinutes: Int?
    /// The passcode every change has to be unlocked with, or `nil` when none is set.
    public var passcode: PasscodeHash?
    /// Whether a forgotten passcode can be cleared from inside the app, after the wait below.
    public var allowForgot: Bool
    /// When the wait that clears a forgotten passcode was started, or `nil` when none is running.
    ///
    /// A reading rather than a date: an hour that could be skipped by setting the clock forward
    /// would not be an hour. See `ClockReading.secondsSince`.
    public var forgotStartedAt: ClockReading?

    /// Whether starting a break asks for the passcode too.
    ///
    /// Off by default, and off is the honest default: a break is the one control that is *meant*
    /// to be easy, and most people who set a passcode set it against raising a limit at 23:40
    /// rather than against ten minutes of Instagram. But "disable blocking for an hour" is the
    /// largest loosening there is short of quitting, so anybody who wants the same question in
    /// front of it can have it.
    ///
    /// Only the passcode, never the wait — a break can be started from the menu bar with no
    /// settings window open, and a countdown measured from a window that is not there is a
    /// friction nobody can satisfy. See `SettingsLockScope.deliberateAction`. Ending a break
    /// early is never asked about: that direction only ever puts the blocks back.
    public var coversQuickDisable: Bool

    public init(
        timerMinutes: Int? = nil,
        passcode: PasscodeHash? = nil,
        allowForgot: Bool = true,
        forgotStartedAt: ClockReading? = nil,
        coversQuickDisable: Bool = false
    ) {
        self.timerMinutes = timerMinutes
        self.passcode = passcode
        self.allowForgot = allowForgot
        self.forgotStartedAt = forgotStartedAt
        self.coversQuickDisable = coversQuickDisable
    }

    /// Decoded by hand for the two `Bool`s, which are not `Optional`: a hand-edited block without
    /// either must keep loading rather than take the whole `config.json` down with it. See the
    /// schema-evolution rule in `SandglassJSON`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timerMinutes = try container.decodeIfPresent(Int.self, forKey: .timerMinutes)
        passcode = try container.decodeIfPresent(PasscodeHash.self, forKey: .passcode)
        allowForgot = try container.decodeIfPresent(Bool.self, forKey: .allowForgot) ?? true
        forgotStartedAt = try container.decodeIfPresent(ClockReading.self, forKey: .forgotStartedAt)
        // A file written before the break could be gated did not gate it, and this is a decision
        // the user makes deliberately or not at all.
        coversQuickDisable =
            try container.decodeIfPresent(Bool.self, forKey: .coversQuickDisable) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case timerMinutes, passcode, allowForgot, forgotStartedAt, coversQuickDisable
    }

    /// Whether the wait is switched on at all.
    ///
    /// Named once here because it is two facts rather than one — no timer, and a timer of no
    /// minutes — and every reader of them has to agree: the gate that counts the wait down, and
    /// the edit that notices somebody switching one on.
    public var timerIsOn: Bool { (timerMinutes ?? 0) > 0 }

    /// How long the way back from a forgotten passcode takes.
    ///
    /// An hour, and not a minute of it can be spent doing something else on the same screen —
    /// which is the point. It is long enough that "I forgot it" is never the quick way through a
    /// lock you asked for, and short enough that a genuinely forgotten passcode is an evening's
    /// inconvenience rather than a reinstall.
    public static let forgotWaitMinutes = 60

    /// How long the timer may be set for, and where it starts.
    ///
    /// It was a list of six — 1, 5, 10, 30, 60, 180 — which is somebody else's opinion about how
    /// long an impulse lasts, offered as the only opinions available. A minute to four hours,
    /// freely. Four hours because the same reasoning bounds "Block everything for…": a lock is
    /// worth walking into deliberately and not worth a whole day bought by a slipped keystroke.
    public static let timerRange = 1...240
    public static let defaultTimerMinutes = 10

    /// Where one press of the stepper lands, from `minutes`, in the direction asked for.
    ///
    /// The step grows with the number, because a minute means something at 5 and nothing at 180:
    /// minute by minute to 10, then fives to an hour, then quarter-hours. Forty-five minutes is
    /// seven presses from the default rather than a number the app declined to offer.
    ///
    /// It answers the **next value on the grid** rather than a step size, and the difference shows
    /// on the two cases a size would get wrong. A press and its undo have to be each other, so
    /// going down asks about the value one below: 60 steps down to 55 and 55 back up to 60, where
    /// reading the band off 60 in both directions would step down to 45 and back up to 50. And a
    /// number that is on no grid at all — a hand-edited 11, or 61 — steps *onto* the nearest one
    /// rather than carrying its offset up and down the span forever.
    public static func timerMinutes(after minutes: Int, goingUp: Bool) -> Int {
        guard goingUp else {
            let step = band(around: minutes - 1)
            return ((minutes - 1) / step) * step
        }
        let step = band(around: minutes)
        return ((minutes / step) + 1) * step
    }

    private static func band(around minutes: Int) -> Int {
        switch minutes {
        case ..<10: return 1
        case ..<60: return 5
        default: return 15
        }
    }

    /// Seconds still to run before a forgotten passcode is cleared, or `nil` when nothing is
    /// waiting. Rounded up, so a wait with half a second left still reads as a second.
    ///
    /// Answers `nil` for a wait left behind by somebody who has since switched recovery off:
    /// the setting is what decides whether there is a way back, and a stale timestamp in the
    /// file must not become one.
    public func forgotSecondsLeft(at now: ClockReading) -> Int? {
        guard allowForgot, passcode != nil, let started = forgotStartedAt else { return nil }
        let left = TimeInterval(Self.forgotWaitMinutes * 60) - now.secondsSince(started)
        guard left > 0 else { return nil }
        return Int(left.rounded(.up))
    }

    /// Whether a running wait has finished and the passcode is now the app's to clear.
    public func forgotIsDue(at now: ClockReading) -> Bool {
        guard allowForgot, passcode != nil, forgotStartedAt != nil else { return false }
        return forgotSecondsLeft(at: now) == nil
    }

    /// Clears a passcode whose hour is up, and reports whether anything changed.
    ///
    /// The wait goes with it: what it was for has happened, and a timestamp left behind would
    /// clear the *next* passcode the moment one was set.
    public mutating func clearForgottenPasscode(at now: ClockReading) -> Bool {
        guard forgotIsDue(at: now) else { return false }
        passcode = nil
        forgotStartedAt = nil
        return true
    }
}
