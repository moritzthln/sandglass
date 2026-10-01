import SandglassAppCore
import AppKit

/// Starting a break, with the settings passcode in front of it when the user asked for that.
///
/// One menu offers a break — the Unblock card's, and only once the card's own wait has run out.
/// This stays a type of its own because the *enforcement* is `AppState.startBreak`, which refuses
/// on its own however it is reached, and this is only the way to satisfy it, put where the
/// friction is felt. The same split the quit dialogue makes.
@MainActor
enum BreakStarter {

    /// Asks for the passcode if one is owed, then unblocks. A passcode refused or never entered
    /// leaves everything blocked, which is the state the user can still do something about — and
    /// the refusal comes back through the note the card already shows.
    ///
    /// The answer is **handed to** `startBreak` rather than used to unlock anything, so it buys
    /// this break and no other. It used to go through `unlockSettings`, which records the passcode
    /// for the rest of a settings visit, so nothing ever cleared the record: the first break after
    /// launch asked, and every one after it went straight through.
    ///
    /// The card's wait is already over by the time anything here runs — the menu that calls this
    /// does not exist until then — which is what puts the two frictions in series rather than in
    /// competition: one costs time, the other costs intent.
    static func start(minutes: Int, appState: AppState) {
        guard appState.breakNeedsPasscode else {
            appState.startBreak(minutes: minutes)
            return
        }
        let (alert, field) = NSAlert.passcodeForBreak()
        // An accessory app is never the active one, and an inactive alert can end up behind
        // whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        // Cancelling is the one silent way out: it is the user saying never mind, and a note
        // explaining a break they just called off would be noise.
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        appState.startBreak(minutes: minutes, passcode: field.stringValue)
    }

    /// How a length reads in the menu.
    static func label(forMinutes minutes: Int) -> String {
        minutes == 60 ? "1 hour" : "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
