import Foundation

/// The one ticking line across the top of the main window: what it counts down, and in what words.
///
/// **One line, and never two numbers.** The app-wide wait had a band and a group's own had nothing
/// — somebody sat in front of held controls with no idea how long, because `EditorFreeze
/// .groupLockNotice` deliberately names no number and there was no live copy of it anywhere. The
/// obvious fix was a second band, and it was refused before it was built: if the app-wide wait is
/// longer than the group's, show the app-wide one, otherwise just the group's — two times make no
/// sense.
///
/// So the band shows the **effective** wait over whatever page is being looked at: on a group's
/// page, the longer of the two, because the longer one is the one that is actually still refusing
/// things; everywhere else, the app-wide one alone, because no group is on screen for a second
/// number to be about. Which page that is, is `MainWindowView`'s own state rather than anything
/// published, so it is handed in.
///
/// The two are compared rather than added, and the maximum is the honest answer for the same reason
/// `AppState.applyConfigEdit` asks both gates: an edit that loosens a group has to satisfy the
/// app-wide lock **and** that group's, so the moment both stop refusing is the later of the two
/// moments. They start at different times — a group's counts from its code being entered, or from
/// its page being left — so either one can be the longer, and neither order is the special case.
///
/// Here rather than in the view for the reason `EditorFreeze` and `GroupSummary` are here: it is a
/// rule with wording attached, and a rule written inside a `View` is a rule no test can read.
public enum LockBanner {

    /// Seconds the band counts down over this page, or `nil` when nothing is holding it.
    ///
    /// `group` is that page's own wait where a group is on screen and `nil` everywhere else — and
    /// it is `nil` on a group's page too whenever its wait is not actually holding: switched off,
    /// run out, not yet armed, or waiting behind a code nobody has entered. `GroupLockState
    /// .unlockSeconds` is already exactly that answer, so the band inherits every one of those
    /// lifecycle rules without restating any of them. Only a wait that holds is counted, because a
    /// band counting down a wait that is refusing nothing is the app inventing friction.
    public static func secondsLeft(global: Int?, group: Int? = nil) -> Int? {
        switch (global, group) {
        case (let global?, let group?): return max(global, group)
        case (let global?, nil): return global
        case (nil, let group?): return group
        case (nil, nil): return nil
        }
    }

    /// The band's whole sentence.
    ///
    /// **The same words for both locks, and they are true of both.** "Settings unlock in 4:32" says
    /// what the number means for the page being looked at, which is the only question its reader
    /// has; naming *which* lock it is would be a second fact nobody can act on, and one the two
    /// notices under it already carry — `EditorFreeze` says which lock is holding the page and this
    /// says for how much longer, which is one sentence in two halves.
    public static func text(_ seconds: Int) -> String {
        "Settings unlock in \(SettingsLockGate.countdownText(seconds))"
    }
}
