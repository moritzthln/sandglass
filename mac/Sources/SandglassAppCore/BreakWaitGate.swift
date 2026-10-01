import SandglassCore
import Foundation

/// The wait the Unblock card sits behind, measured from the moment the settings window opened.
///
/// The wait used to start on a button press, with the length chosen first: the impulse picked how
/// long to unblock for and then sat out a gap it had already crossed. It starts with the window
/// now — running while the user is doing whatever else they opened the window for — and the length
/// is chosen at the end of it, out of a card that could not be operated until then.
///
/// **A second gate rather than a second question on `SettingsLockGate`**, and deliberately. The two
/// waits are measured off the same event and share the seam that reports it — `AppState
/// .settingsWindowOpened()` and the window delegate behind it — but they gate different acts: one
/// stands in front of changing what is enforced, the other in front of switching it off for a
/// while, and one of them is optional where the other is always there. Folded into one value they
/// would have to carry each other's exceptions: the settings lock is lifted by an emergency pass
/// and applies to a scope this knows nothing about, and this one is a plain number with no
/// on/off switch at all.
///
/// It knows nothing about the engine, the disk or a clock: the caller hands in the wait as it is
/// configured and the reading it is asking about. That is what makes every rule here reachable
/// from a test without building an app around it — the same contract `SettingsLockGate` and
/// `PauseFriction` are written to.
public struct BreakWaitGate: Equatable {

    /// When the settings window came up, or `nil` while none is open.
    private var openedAt: ClockReading?

    public init() {}

    /// The settings window came up.
    ///
    /// Asking for a window that is already open brings the existing one forward rather than
    /// opening a second, so a repeated call must not restart the wait — clicking "Settings" in the
    /// menu again would otherwise be a way of *lengthening* it, which is nobody's intent, and the
    /// same call arrives on every reopen of the same window. Only a close reopens the question.
    public mutating func windowOpened(at reading: ClockReading) {
        guard openedAt == nil else { return }
        openedAt = reading
    }

    /// The settings window went away, and the wait starts again from the next open.
    ///
    /// It has to reset, or the wait could be started, abandoned and collected later: open the
    /// window, walk away, come back to a card that is already live. That is the gap not being
    /// crossed, only waited out somewhere else.
    public mutating func windowClosed() {
        openedAt = nil
    }

    /// Seconds still owed before the card can be operated, or `nil` when it is live.
    ///
    /// **A wait of nought is live at once**, window or no window. That is the setting's whole
    /// point: somebody who set it to zero has decided, and a gate that argued would be enforcing a
    /// commitment nobody made.
    ///
    /// Otherwise a window that has not announced itself owes the wait in full. Fail-closed for the
    /// reason `SettingsLockGate.timerSecondsLeft` is: the card lives in the settings window and
    /// `WindowPresenter` announces every open, so the only way to reach this with nothing open is
    /// a path that forgot to — and a wait those get waved through is not a wait.
    ///
    /// Asked against the configured wait every time rather than against one copied when the window
    /// opened, so a change to the number is measured against **this** visit rather than deferred
    /// to the next one. Both directions follow from that and neither needs a rule of its own:
    /// raising it can put seconds back on a card that had already come alive, when the new wait is
    /// longer than the visit so far, and lowering it never takes seconds off one that has not —
    /// what has been sat through has been sat through either way.
    public func secondsLeft(waitSeconds: Int, at now: ClockReading) -> Int? {
        guard waitSeconds > 0 else { return nil }
        let whole = TimeInterval(waitSeconds)
        guard let openedAt else { return Int(whole) }
        let left = whole - now.secondsSince(openedAt)
        guard left > 0 else { return nil }
        return Int(left.rounded(.up))
    }

    // MARK: - Copy

    /// The one sentence the wait is said in: on the card while it runs, and as the refusal behind
    /// anything on the card that is reached anyway.
    public static func waitText(_ seconds: Int) -> String {
        "You can unblock in \(countdownText(seconds))"
    }

    /// The app's one countdown shape, borrowed rather than written again so that three countdowns
    /// in one app read the same way.
    public static func countdownText(_ seconds: Int) -> String {
        SettingsLockGate.countdownText(seconds)
    }
}
