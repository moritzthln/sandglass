import SandglassCore
import Foundation

/// What is already refusing an edit on the group editor, said before a control is touched.
///
/// The page lives inside the settings window and inside a group at once, so three separate things
/// can have frozen it, and none of them used to be visible from it: the app-wide settings lock,
/// this group's own lock, and a focus session. The user found out by pressing something and
/// reading a refusal — which is the app keeping a rule the user set and then hiding it until they
/// break it.
///
/// Two of the three have a passcode half, and neither is a sentence anybody meets: with one owed,
/// `SettingsDoorView` or `GroupDoorView` is the whole screen and this page is not on it. Both
/// notices still answer for that case, and say there why.
///
/// A fourth used to be here: the group's own strict window, which froze the *direction* of every
/// control rather than the page. The window is gone — a window blocks apps and websites, and what
/// may be changed is the settings lock's question — but **the direction came back**, one lock up:
/// a running wait, app-wide or this group's, holds what loosens and lets what tightens through.
/// So two of the four freeze the page and two point it in a direction, and this is where a caller
/// finds out which. See `EditDirection` for the table itself.
///
/// Here rather than in the view for the reason every other line in this module is here: it is
/// wording plus the rule for which words apply, and a sentence written inside a `View` is a
/// sentence no test can read. Nothing here decides anything — `AppState.applyConfigEdit` does —
/// this only says out loud what it would answer.
public enum EditorFreeze {

    /// Every notice that applies, in the order the refusals are actually met.
    ///
    /// The app-wide lock comes first because `AppState.applyConfigEdit` asks it first: told about
    /// the group's own instead, somebody would satisfy that one and be refused a second time for a
    /// reason nobody had mentioned. Then the group's own, which is asked second. Then the focus
    /// session, which is the engine's and is asked last.
    ///
    /// An emergency pass is not asked about here either, and the reason is the same for all three:
    /// each arrives already lifted or already not, so a page the app would accept an edit on is
    /// never banded with a notice saying it would not. What changed is only that "already lifted"
    /// is no longer a foregone conclusion for the middle one — a group may opt out of the app's
    /// unblocks (`GroupSettings.ignoresAppWideUnblocks`), and `GroupLockGate` hands its notice
    /// straight through the hour. Which is exactly why this reads the state rather than the pass.
    ///
    /// All of them rather than the first: they lift at different times, and a page that revealed
    /// the next refusal only once the last one had gone would take three visits to explain itself.
    public static func notices(
        lock: SettingsLockState,
        groupLock: GroupLockState? = nil,
        focusSessionLine: String?
    ) -> [String] {
        [
            lockNotice(lock),
            groupLockNotice(groupLock),
            focusSessionLine.map { "\($0). Nothing on this page can change while it runs." },
        ].compactMap { $0 }
    }

    /// Whether one of these has frozen the page **whole** — nothing on it can be written, in
    /// either direction.
    ///
    /// Two of the four, and both for the same reason: they leave no direction open. A passcode
    /// that has not been answered is a question about *who is asking*, which nothing on the page
    /// can answer, and a focus session is the engine's. Neither of them is a sentence anybody
    /// ordinarily meets — with a code owed the door is the whole screen — so this is a fail-closed
    /// guard as much as a rule.
    ///
    /// It exists because the banner and the controls were saying different things. Under the lock
    /// the page read "Nothing can change until then" above seven knobs, a switch and a delete
    /// button, every one of them drawn exactly as it is drawn when it works — and each of them
    /// refused on the press. The page already argues that a control which cannot move should be
    /// drawn that way; this is what lets those freezes keep that promise.
    ///
    /// The two waits are **not** here, and that is the change: a wait holds what loosens, so the
    /// page under one is narrowed rather than killed. See `tighteningOnly`.
    public static func freezesEverything(
        lock: SettingsLockState, groupLock: GroupLockState? = nil, focusSessionLine: String?
    ) -> Bool {
        lock.passcodeRequired || groupLock?.passcodeRequired == true || focusSessionLine != nil
    }

    /// Whether a wait is standing over this page — in which case every control may still be turned
    /// towards more friction and none of them back.
    ///
    /// The honest drawing of a lock that holds a **direction** is per control: a stepper keeps the
    /// arrow that tightens and loses the one that does not, and a switch whose only remaining move
    /// would hand something back goes dead. Nothing here decides anything — `AppState
    /// .applyConfigEdit` refuses either way — this only stops a control claiming it can do
    /// something the save behind it will turn down.
    ///
    /// **After the outright freezes, and never beside them.** Under a passcode or a focus session
    /// the page is dead whichever way a knob points, and a page drawn half-live under one of those
    /// would be two rules arguing on one screen.
    public static func tighteningOnly(
        lock: SettingsLockState, groupLock: GroupLockState? = nil, focusSessionLine: String?
    ) -> Bool {
        guard !freezesEverything(
            lock: lock, groupLock: groupLock, focusSessionLine: focusSessionLine
        ) else { return false }
        return lock.unlockSeconds != nil || groupLock?.unlockSeconds != nil
    }

    /// The timer before the passcode, matching `SettingsLockGate.refusal`: one refusal at a time,
    /// and the one with a countdown on it first.
    ///
    /// The passcode half is a **fail-closed guard rather than a sentence anybody meets**, and has
    /// been since the passcode moved to the door: `SettingsDoorView` stands in front of the whole
    /// window while one is owed, so a page reached with `passcodeRequired` set is a page that
    /// should not have been drawn at all. It is kept for the same reason
    /// `SettingsLockGate.timerSecondsLeft` fails closed on a window that never announced itself —
    /// a lock that quietly draws a live control on the one path nobody predicted is not a lock.
    /// What it no longer does is name where the passcode is entered: it used to send the reader to
    /// a row on the Settings page, and that row is gone.
    ///
    /// Nor does it count. "Settings unlock in 1:35. Nothing can change until then." was a snapshot
    /// in a banner nothing redraws on the second, and it was the third copy of a sentence the app
    /// now says once, live, across the top of the window. "While it runs" rather than "until
    /// then": with the number gone there is no "then" to point at.
    ///
    /// **It no longer says "nothing can change", because that stopped being true.** A wait holds
    /// loosening and only loosening, so the sentence has to name the half that still moves — every
    /// knob on this page can still be turned towards more friction while it runs, and a banner
    /// that said otherwise over live controls would be the same disagreement the greying-out was
    /// introduced to end.
    private static func lockNotice(_ lock: SettingsLockState) -> String? {
        if lock.unlockSeconds != nil {
            return "Held by the settings lock. Only changes that block harder go through"
                + " while it runs."
        }
        guard lock.passcodeRequired else { return nil }
        return "Settings are locked. Enter the passcode to change anything."
    }

    /// The group's own lock, which holds this page exactly as the app-wide one does — and says so
    /// in the same shape, one scope down: the wait narrows it, the passcode stops it.
    ///
    /// The passcode half is a **fail-closed guard rather than a sentence anybody meets**, for the
    /// reason `lockNotice`'s is: with a code owed, `GroupDoorView` is the whole page and these
    /// cards are not on it. A page reached with `passcodeRequired` set is a page that should not
    /// have been drawn, and a lock that quietly draws a live control on the one path nobody
    /// predicted is not a lock.
    ///
    /// It names no number for the reason nothing else here does: a snapshot in a sentence nothing
    /// redraws is the fault that took the last one away. The number is the band's, which counts
    /// this wait down whenever it is the longer of the two standing over the page — see
    /// `LockBanner`, and the two halves of one sentence it describes.
    private static func groupLockNotice(_ lock: GroupLockState?) -> String? {
        guard let lock else { return nil }
        if lock.unlockSeconds != nil {
            return "Held by this group's own lock. Only changes that block harder go"
                + " through while it runs."
        }
        guard lock.passcodeRequired else { return nil }
        return "This group is locked. Enter its passcode to change anything."
    }
}
