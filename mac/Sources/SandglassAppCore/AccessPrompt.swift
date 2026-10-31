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
public struct AnsweredAsks: Equatable, Sendable {
    public static let capacity = 16

    private var answered: [String] = []

    public init() {}

    /// Whether this press is one nobody has answered yet, and from now on it has been.
    public mutating func isNew(_ nonce: String?) -> Bool {
        guard let nonce, !nonce.isEmpty, !answered.contains(nonce) else { return false }
        answered.append(nonce)
        if answered.count > Self.capacity { answered.removeFirst(answered.count - Self.capacity) }
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
        case .refused(.blocked(_, let untilText)):
            return untilText
        case .refused:
            return nil
        }
    }

    public static func lockedOut(seconds: Int) -> String {
        "Too many tries. Try again in \(SettingsLockGate.countdownText(seconds))."
    }
}
