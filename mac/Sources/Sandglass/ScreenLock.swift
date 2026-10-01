import AppKit

/// Whether anybody is actually at the Mac.
///
/// Its own type because both halves of the blocker ask it and neither owns it. macOS goes on
/// naming a frontmost application while the screen is locked, so without this a Mac left on
/// YouTube overnight would spend its whole daily limit — once for the application, in
/// `AppBlocker.frontmostBundleID`, and once for the page, in `PageBlocker`.
enum ScreenLock {

    /// Reads the window server's own view of the session. Absent or unreadable is taken as
    /// unlocked: the answer is only ever used to *stop* counting, and a Mac in use must not be
    /// silently untracked because a private key changed its name.
    ///
    /// `CGSSessionScreenIsLocked` covers a screensaver too whenever it asks for a password, which
    /// is the only case a screensaver is a lock.
    static var isOn: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Int == 1
    }
}
