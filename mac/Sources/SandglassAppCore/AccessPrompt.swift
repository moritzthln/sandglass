import SandglassCore
import Foundation

/// The "Enter password" presses on block pages that have already raised a prompt.
///
/// The press is a link to the same block page with a fresh `ask` nonce on the end, and the poll
/// reads it off the address once a second. Without a memory of the nonces already answered, the
/// prompt would come back every second for as long as the tab sat there, and again after every
/// reload. Pressing the button again makes a new nonce, so asking twice is always possible.
///
/// Several rather than one, so two tabs each parked on a press do not take turns raising the
/// prompt while somebody switches between them. Bounded, because the nonces are only worth
/// remembering for as long as a tab could still be showing one.
///
/// **A press carries the moment it was made**, because the memory above is gone after a relaunch
/// — and the keep-alive agent relaunches within seconds of any quit. A tab still showing a press
/// from before then would raise the prompt unasked. The page writes the nonce as
/// `<milliseconds since 1970>.<random>`, and a press older than `freshSeconds` is taken as
/// answered. A nonce without the moment, from a page built before this, is judged as it always was.
public struct AnsweredAsks: Equatable, Sendable {
    public static let capacity = 16

    /// How long after the page made it a press is still a question worth a window.
    public static let freshSeconds: TimeInterval = 60

    private var answered: [String] = []

    public init() {}

    /// Whether this press is one nobody has answered yet, and from now on it has been.
    public mutating func isNew(_ nonce: String?, now: Date = Date()) -> Bool {
        guard let nonce, !nonce.isEmpty, !answered.contains(nonce) else { return false }
        answered.append(nonce)
        if answered.count > Self.capacity { answered.removeFirst(answered.count - Self.capacity) }
        if let made = Self.madeAt(nonce), now.timeIntervalSince(made) > Self.freshSeconds {
            return false
        }
        return true
    }

    /// The moment a timestamped nonce was made, or `nil` for one that carries none.
    static func madeAt(_ nonce: String) -> Date? {
        guard let dot = nonce.firstIndex(of: "."), let millis = Int64(nonce[..<dot]) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }
}

/// Which navigation failures have been written to the event log lately.
///
/// `TabNavigator` writes a line for every refusal, and a refusal can repeat once a second: a
/// browser that will not be told where to go, behind a window that is not active, is asked again
/// on every poll and refuses again. The same sentence sixty times a minute buries everything else
/// in the log and says nothing the first line did not. The same line is written once per
/// `quietSeconds`; a different failure is written at once.
public struct NavigationFailures: Equatable, Sendable {
    public static let quietSeconds: TimeInterval = 60

    private var written: [String: Date] = [:]

    public init() {}

    /// Whether this line is worth writing now, and from now on it has been written.
    public mutating func shouldRecord(_ line: String, now: Date) -> Bool {
        written = written.filter { abs(now.timeIntervalSince($0.value)) < Self.quietSeconds }
        guard written[line] == nil else { return false }
        written[line] = now
        return true
    }
}

/// What the password field says after a try that did not open the group.
///
/// No scolding, for the reason `PasscodeSheet` has none: a wrong password is a typing mistake far
/// more often than an attack, and the wait after five of them is the whole of the defence.
public enum AccessCopy {

    /// The line under the field, or `nil` when there is nothing to say — the group opened, or the
    /// thing in its way is no longer the password and the caller shows that instead.
    public static func problem(after attempt: AccessAttempt) -> String? {
        switch attempt {
        case .unlocked:
            return nil
        case .wrong(let attemptsLeft) where attemptsLeft == 0:
            return lockedOut(seconds: Int(AccessAttempts.lockoutSeconds))
        case .wrong(let attemptsLeft) where attemptsLeft <= 2:
            let tries = attemptsLeft == 1 ? "1 more try" : "\(attemptsLeft) more tries"
            return "That password doesn't match. \(tries) before a one-minute wait."
        case .wrong:
            return "That password doesn't match."
        case .lockedOut(let seconds):
            return lockedOut(seconds: seconds)
        case .noSettingsPasscode:
            return noSettingsPasscode
        case .refused(.blocked(_, let untilText)):
            return untilText
        case .refused:
            return nil
        }
    }

    /// A group that opens with the settings passcode while none is set. Setting one again is the
    /// way back — see `EditDirection`, which lets exactly that through.
    public static let noSettingsPasscode =
        "This group opens with the settings passcode, and none is set. Set one in Settings → Settings lock."

    /// What removing the settings passcode would do to the groups that open with it, or `nil`
    /// when none does. Asked before the removal rather than after: the groups are not blocked by
    /// anything the removal would show, they simply never open again until a new one is set.
    public static func removingSettingsPasscode(strands names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: names)
        let they = names.count == 1 ? "\(list) opens" : "\(list) open"
        return "\(they) with the settings passcode. Without one, nothing opens "
            + (names.count == 1 ? "it" : "them") + " until a new passcode is set."
    }

    public static func lockedOut(seconds: Int) -> String {
        "Too many tries. Try again in \(SettingsLockGate.countdownText(seconds))."
    }
}
