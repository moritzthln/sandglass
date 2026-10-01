import SandglassCore
import Foundation

/// Where the settings lock stands right now, as one value the card redraws from.
///
/// One published value rather than three, for the reason `AppStateProjection` is one: the
/// countdowns move every second, and three separately-published fields would wake three
/// observers where one screen redraws.
public struct SettingsLockState: Equatable, Sendable {
    /// Seconds until the timer lets go, or `nil` when it is off or has already run out.
    public var unlockSeconds: Int?
    /// Whether the passcode still has to be entered before anything can be changed.
    public var passcodeRequired: Bool
    /// Seconds until a forgotten passcode is cleared, or `nil` when nothing is waiting.
    public var resetSeconds: Int?

    public init(
        unlockSeconds: Int? = nil, passcodeRequired: Bool = false, resetSeconds: Int? = nil
    ) {
        self.unlockSeconds = unlockSeconds
        self.passcodeRequired = passcodeRequired
        self.resetSeconds = resetSeconds
    }
}

/// Which of the two frictions something has to satisfy before it is allowed to happen.
///
/// They are not the same kind of condition, so they do not have the same reach.
///
/// The **passcode** asks "are you the person who set this rule?". That question has an answer
/// wherever it is put, and it is exactly as fair at a quit dialogue at 23:40 as it is on the
/// settings page. Every scope carries it.
///
/// The **timer** asks "have you sat with this for N minutes?", and it counts from the moment the
/// settings window came up. With no window open the question has no answer at all: the wait is not
/// merely unmet, it is unsatisfiable, and `SettingsLockGate.timerSecondsLeft` fails closed on a
/// window that never announced itself. A friction nobody can ever satisfy is not friction, it is a
/// button that does nothing — so the timer applies where it can be waited out, and nowhere else.
public enum SettingsLockScope: Equatable, Sendable {
    /// Something done inside the settings window: both frictions. Every edit to `config.json`,
    /// and every other control on that screen that loosens the rules.
    case settingsWindow
    /// A deliberate action taken with no settings window open — the quit dialogue's "Turn off
    /// and quit", and starting a break. The passcode applies; the timer does not.
    case deliberateAction

    /// Whether the wait applies to this scope. See above: only where there is a visit to wait out.
    var includesTimer: Bool { self == .settingsWindow }

    /// Whether the passcode is answered per action rather than remembered per visit.
    ///
    /// The same fact as `includesTimer` seen from the other side, and it is spelled out because
    /// the two follow from one thing: with no settings window there is no visit — nothing to
    /// measure a wait from, and nothing for "once per visit" to be once per. So a standalone
    /// action carries its own answer every time, and leaves no trace for the next one to reuse.
    var isStandalone: Bool { self == .deliberateAction }
}

/// The two frictions on changing what the app enforces, as a value: what they refuse, and when
/// they stop refusing it.
///
/// Both are per **settings-window session**, which is the whole design. The timer counts from the
/// moment the window comes up and resets when it goes away, so the friction is against the visit
/// that came to raise a limit rather than against the settings screen in general — with one
/// exception, the visit that switches the timer on, which is written out at `timerSwitchedOn`. The
/// passcode is asked for once per visit rather than once per keystroke, because a control that
/// asks on every click is a control nobody leaves switched on. Which is where they part company:
/// remembering per visit is not the same as *applying* only within one, and `SettingsLockScope`
/// is that difference.
///
/// It knows nothing about the engine, the disk or a clock: the caller hands in the lock as it is
/// stored and the reading it is asking about. That is what makes every rule here reachable from a
/// test without building an app around it — the same contract `PauseFriction` is written to.
///
/// **The lock must never trap.** An emergency pass lifts both refusals, which is what keeps a
/// forgotten passcode with recovery switched off from freezing the configuration for good: a lock
/// with no price is a trap rather than a commitment device. It is the only lock left for the pass
/// to lift — the engine refuses no edit at all now, see `RulesEngine.updateConfig` — which is also
/// what makes this type the whole of the app's commitment model.
public struct SettingsLockGate: Equatable {

    /// Why an edit was refused, in the words the screen shows.
    ///
    /// **No refusal names a number.** `.timer` used to answer "Settings unlock in 4:32", built at
    /// the moment of the refusal and then held in the screen's `problem` state, which nothing
    /// updates — so the one sentence in the app with a clock in it was the one sentence that had
    /// stopped. It says what is holding the edit instead — "Held by the settings lock" — and the
    /// countdown is read off the live lock in one place: the banner across the top of the main
    /// window.
    ///
    /// `secondsLeft` stays on the case even though no words come from it: it is what the gate
    /// worked out, and it is what a test asserts the arithmetic against.
    public enum Refusal: Equatable {
        case timer(secondsLeft: Int)
        case passcode
        /// One was offered and it was wrong. Only a standalone action can reach this — inside a
        /// settings visit a wrong passcode simply leaves the visit locked, and the row already
        /// says so.
        case wrongPasscode

        public var text: String {
            switch self {
            case .timer:
                return "Held by the settings lock"
            case .passcode:
                return "Enter the passcode to change settings"
            case .wrongPasscode:
                return "That passcode doesn't match"
            }
        }
    }

    /// When the settings window came up, or `nil` while none is open.
    private var openedAt: ClockReading?
    /// Whether the passcode has been entered during this visit.
    private var passcodeAccepted = false
    /// Whether the timer was switched on during this visit, which is what exempts it from the
    /// wait it just started. See `timerSwitchedOn`.
    private var timerStartedThisVisit = false

    public init() {}

    // MARK: - One visit to the settings window

    /// The settings window came up.
    ///
    /// Asking for a window that is already open brings the existing one forward rather than
    /// opening a second, so a repeated call must not restart the wait — otherwise clicking
    /// "Settings" in the menu again would be a way of resetting the countdown to full, which is
    /// the opposite of what it is for. Only a close reopens the question.
    ///
    /// A passcode accepted before the window existed is forgotten here, which is what keeps
    /// "once per visit" true: one typed for a `.deliberateAction` — the quit dialogue asks for it
    /// — buys that action and nothing after it, and least of all a settings visit that had not
    /// begun when it was typed.
    ///
    /// An exemption left behind by a timer switched on with no window open is dropped for the
    /// same reason, and fails closed the same way `timerSecondsLeft` does: a visit that had not
    /// begun cannot have been the one that armed it.
    public mutating func windowOpened(at reading: ClockReading) {
        guard openedAt == nil else { return }
        openedAt = reading
        passcodeAccepted = false
        timerStartedThisVisit = false
    }

    /// The settings window went away. The timer starts again from the next open, a passcode
    /// entered during this visit is forgotten, and so is an exemption bought by switching the
    /// timer on during it.
    public mutating func windowClosed() {
        openedAt = nil
        passcodeAccepted = false
        timerStartedThisVisit = false
    }

    /// The timer was switched on during this visit, so this visit is not held by it.
    ///
    /// **The one exception to "the countdown starts every time the window opens", and it is the
    /// visit that starts it.** The wait is measured from the window coming up, which by then has
    /// already happened, so switching the timer on used to land the whole default as an unpaid
    /// debt — and the default was held by the same wait as everything else, "Locked for"
    /// included. Nobody chose ten minutes; they were given ten minutes and then could not change
    /// them without sitting out ten minutes.
    ///
    /// So the visit that arms it picks freely, and the countdown arms from the **next** window
    /// open. Nothing else moves: switching the timer off, or changing its length, on any later
    /// visit costs the wait exactly as before, which is the half the whole feature is for.
    ///
    /// Once set, the mark stands until the window goes away — the same shape `passcodeAccepted`
    /// has, and for the same reason: an exemption is a fact about one visit.
    public mutating func timerSwitchedOn() { timerStartedThisVisit = true }

    /// Try the passcode. `true` unlocks the settings for the rest of this visit.
    ///
    /// A lock with no passcode set accepts nothing: there is nothing to be right about, and
    /// answering `true` would let a caller believe it had unlocked something.
    public mutating func accept(passcode: String, for lock: SettingsLock) -> Bool {
        guard matches(passcode: passcode, for: lock) else { return false }
        passcodeAccepted = true
        return true
    }

    /// Whether the passcode is right, **remembering nothing**. What a one-off challenge outside
    /// the settings window asks — today, starting a break.
    ///
    /// It has to be separate from `accept`, and the reason is the visit flag. "Once per visit" is
    /// only true because `windowOpened` and `windowClosed` clear the flag, and a break is started
    /// from a popover, which opens no window: a break answered through `accept` would set a flag
    /// that nothing then clears, so the *first* break after launch would be challenged and every
    /// one after it waved through — for the rest of the process, settings visits included. A
    /// challenge that asks once and then never again is not a challenge.
    ///
    /// So this one neither sets the flag nor reads it: every break asks, however many have been
    /// taken, and answering one buys that break and nothing else.
    public func matches(passcode: String, for lock: SettingsLock) -> Bool {
        guard let stored = lock.passcode else { return false }
        return stored.matches(passcode)
    }

    // MARK: - What it refuses

    /// Why this cannot go through, or `nil` when it can. `scope` says which of the two frictions
    /// are being asked, and why only some of them are is written at `SettingsLockScope`.
    ///
    /// The timer is asked first because it is the one with a countdown: told "enter the
    /// passcode", somebody would enter it and be refused a second time for a reason nobody had
    /// mentioned. One refusal at a time, and the more temporary one first.
    ///
    /// `answered` is the passcode typed for **this** action, and it is what a `.deliberateAction`
    /// is judged on — the visit flag is neither read nor written there. "Once per visit" needs a
    /// visit, and an action started from the menu bar has none: judged on the flag, the first
    /// break after launch would be challenged and every one after it waved through. Inside the
    /// settings window the flag still decides, which is what keeps a settings visit from asking
    /// on every keystroke.
    ///
    /// **`tightening` is the direction of the edit, and the timer lets it through.** The lock
    /// rule: making things stricter must always work, only making them looser is held. A wait exists
    /// against the self who came to raise a limit at 23:40, and standing in the way of somebody
    /// adding a site or setting a passcode is the app arguing with the only wish it serves. Which
    /// way an edit moves is `EditDirection`'s to answer; this only takes the answer.
    ///
    /// It reaches the **timer alone**, and the default is the safe half: an action with no
    /// configuration behind it to compare — resetting today's counters, the quit dialogue —
    /// arrives as `false` and is held exactly as before. The passcode is not asked about because
    /// nobody meets it here: with one owed, `SettingsDoorView` is the whole window, so there is no
    /// edit of either direction to let through.
    public func refusal(
        for lock: SettingsLock, at now: ClockReading, emergencyPassRunning: Bool,
        scope: SettingsLockScope, answered: String? = nil, tightening: Bool = false
    ) -> Refusal? {
        guard !emergencyPassRunning else { return nil }
        guard !scope.isStandalone else { return standaloneRefusal(for: lock, answered: answered) }
        if !tightening, let secondsLeft = timerSecondsLeft(for: lock, at: now) {
            return .timer(secondsLeft: secondsLeft)
        }
        return passcodeRequired(for: lock) ? .passcode : nil
    }

    /// The passcode question asked of one action, answered here and remembered nowhere.
    private func standaloneRefusal(for lock: SettingsLock, answered: String?) -> Refusal? {
        guard lock.passcode != nil else { return nil }
        guard let answered else { return .passcode }
        return matches(passcode: answered, for: lock) ? nil : .wrongPasscode
    }

    /// Everything the settings screen shows about the lock, in one value.
    public func state(
        for lock: SettingsLock, at now: ClockReading, emergencyPassRunning: Bool
    ) -> SettingsLockState {
        SettingsLockState(
            unlockSeconds: emergencyPassRunning ? nil : timerSecondsLeft(for: lock, at: now),
            passcodeRequired: emergencyPassRunning ? false : passcodeRequired(for: lock),
            resetSeconds: lock.forgotSecondsLeft(at: now)
        )
    }

    /// Seconds the timer still holds edits for, or `nil` when it is off or has run out.
    ///
    /// A lock whose window has not announced itself is treated as one that just opened, rather
    /// than as one with no timer. Fail-closed on purpose: every window that can edit the
    /// configuration says so (`WindowPresenter` does it for the main window and for setup), so
    /// the only way to reach this with nothing open is a path that forgot to — and a lock that
    /// quietly lets those through is not a lock. The emergency pass is the way out either way.
    ///
    /// The visit that switched the timer on is answered `nil` outright rather than a smaller
    /// number: the wait is not shorter for them, it is not theirs. Which is also why the banner
    /// needs no rule of its own — it draws what this answers. See `timerSwitchedOn`.
    ///
    /// **After the unannounced-window branch, and that is the whole of its safety.** The
    /// exemption is a fact about a visit, so with no window open there is no visit to have earned
    /// one in and the fail-closed answer above stands: the timer can be switched on from a path
    /// with no window — `AppState.applyConfigEdit` never insisted on one — and a mark that
    /// counted there would turn the fail-closed branch into a way round it.
    private func timerSecondsLeft(for lock: SettingsLock, at now: ClockReading) -> Int? {
        guard lock.timerIsOn, let minutes = lock.timerMinutes else { return nil }
        let whole = TimeInterval(minutes * 60)
        guard let openedAt else { return Int(whole) }
        guard !timerStartedThisVisit else { return nil }
        let left = whole - now.secondsSince(openedAt)
        guard left > 0 else { return nil }
        return Int(left.rounded(.up))
    }

    private func passcodeRequired(for lock: SettingsLock) -> Bool {
        lock.passcode != nil && !passcodeAccepted
    }

    // MARK: - Copy

    /// `m:ss` while there are minutes left, `0:07` at the end — the same shape the popover
    /// counts a session down in, so two countdowns in one app read the same way.
    public static func countdownText(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}
