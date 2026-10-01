import AppKit

// The three alerts the quit policy puts on screen.
//
// Their own file rather than a tail on `main.swift`: that file is the entry point and the
// delegate, and the delegate is about *deciding*. What a decision looks like is a different
// question, and copy is the part most likely to be reworded.
//
// There were four. `locked` said "Sandglass can be quit once the block is over", and over a group
// blocked around the clock that was a moment that never came — so the refusal went, and this went
// with it. See `QuitPolicy`.
//
// All three are run modally by `AppDelegate.show(_:)`, which is safe here for the reason spelled
// out there: a logout, restart or shutdown never reaches any of them.
extension NSAlert {
    /// Buttons are returned in the order they are added: first is rightmost and the default.
    static func keepAliveConfirmation() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit Sandglass?"
        alert.informativeText = """
            Sandglass restarts automatically within seconds unless you turn off \
            "Start at login and keep running".
            """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Turn off and quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// The settings passcode, asked for before a break.
    ///
    /// A modal alert rather than the settings sheet, for the reason the quit dialogue uses one: a
    /// break is startable from the menu bar with no window on screen to put a sheet in. One
    /// prompt in both places, so "a break asks for the passcode" is one sentence wherever you
    /// started it.
    static func passcodeForBreak() -> (alert: NSAlert, field: NSSecureTextField) {
        passcodeAlert(
            informative: "Unblocking everything is protected by the settings passcode.",
            confirm: "Unblock"
        )
    }

    /// The settings passcode, asked for at the quit dialogue.
    ///
    /// The passcode guards "Turn off and quit" for the same reason it guards the settings page —
    /// the question is whether you are the person who set the rule, and it is the same question
    /// at 23:40 with no window open. Which means it has to be *askable* here: enforcing a
    /// friction with no way to satisfy it would leave the button permanently dead. The lock's
    /// other half, the wait, is deliberately not asked — see `SettingsLockScope`.
    ///
    /// The field is returned with the alert rather than read off `accessoryView` afterwards, so
    /// the caller cannot get at the text without also having put it on screen.
    static func passcodeForKeepAlive() -> (alert: NSAlert, field: NSSecureTextField) {
        passcodeAlert(
            informative: #""Start at login and keep running" is protected by the settings passcode."#,
            confirm: "Turn off and quit"
        )
    }

    /// The shape both passcode prompts share: one secure field, one confirm, one cancel.
    private static func passcodeAlert(
        informative: String, confirm: String
    ) -> (alert: NSAlert, field: NSSecureTextField) {
        let alert = NSAlert()
        alert.messageText = "Enter your passcode"
        alert.informativeText = informative
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        // Without this the field is not focused and the first thing typed goes nowhere.
        alert.window.initialFirstResponder = field
        return (alert, field)
    }

    /// "Turn off and quit" that could not turn it off. The quit is cancelled with it, so the
    /// wording has to say what is still true rather than what went wrong.
    static func keepAliveStillOn(_ problem: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Sandglass is still set to keep running"
        alert.informativeText = """
            Nothing was quit, because quitting now would only have brought it back.
            \(problem)
            """
        alert.addButton(withTitle: "OK")
        return alert
    }
}
