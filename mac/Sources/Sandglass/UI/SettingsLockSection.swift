import SandglassAppCore
import SandglassCore
import SwiftUI

/// The settings lock, inside the Protection card: two frictions on changing anything, and the
/// way back from the second one.
///
/// Both off by default and neither of them touches what is blocked. What they are for is the
/// gap between wanting to raise a limit and being able to — the pause screen's trade, applied to
/// the one screen that can undo every other one.
///
/// The one live line comes first, because it is the part that changes while you are looking at
/// it. The refusals themselves are `AppState.applyConfigEdit`'s; nothing here decides anything.
@MainActor
struct SettingsLockSection: View {
    let appState: AppState

    @State private var sheet: PasscodeSheet.Mode?
    /// Why the last change here did not take. Owned by this section rather than pushed to the
    /// page's banner: a refusal describes one click, and the banner is at the top of a scroll
    /// view that this card can sit well below.
    @State private var problem: String?

    private var lock: SettingsLock { appState.config.settingsLock }
    private var state: SettingsLockState { appState.settingsLockState }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hasLiveLine {
                liveLine
                separator
            }
            if let problem {
                SettingsStateRow(text: problem, tone: .warning)
                separator
            }
            timerRows
            separator
            passcodeRows
        }
        .sheet(item: $sheet) { mode in
            PasscodeSheet(mode: mode, submit: submit(mode), dismiss: { sheet = nil })
        }
    }

    /// The line every other card on this page puts between two rows — the Protection card, the
    /// General card, the Unblock card directly above this one.
    ///
    /// This section used to have exactly one of them, in the middle, which made it the only card
    /// in the app that ran its rows together. With a passcode set and the timer counting down it
    /// stacked five separate things — a countdown, a locked notice with a button, a recovery link,
    /// a toggle and a stepper — with nothing between any of them, and read as text on top of text.
    private var separator: some View {
        Divider().overlay(Palette.hairline).padding(.vertical, 6)
    }

    /// Whether `liveLine` will draw anything, so the divider under it is not left hanging over
    /// nothing on the ordinary visit where no lock is running at all.
    private var hasLiveLine: Bool { state.resetSeconds != nil }

    // MARK: - The rows

    @ViewBuilder
    private var timerRows: some View {
        SettingsRow(
            "Lock settings when this window opens",
            help: "For the first few minutes after this window opens, nothing here can be made easier — long enough for the impulse that opened it to pass. Making something harder always goes through: a longer pause, one more site, a passcode on top. The countdown starts again every time the window opens, and applies to nothing done outside one. Switching it on is the one visit it does not hold: the wait starts from the next time this window opens, so the length below can be picked now."
        ) {
            SettingsToggle(isOn: timerOn, label: "Lock settings when this window opens")
        }
        if lock.timerMinutes != nil {
            separator
            SettingsRow(
                "Locked for",
                help: "How long the wait above lasts, counted from the moment this window opens. It starts again on every visit — a second click on Settings brings this window forward rather than restarting the countdown, so waiting it out and going away costs the wait again. The visit that switched the wait on is the one it does not hold: pick a length freely now, and every visit after it waits — the one that comes to shorten this number included, because a longer one it lets through.\n\nIt holds every change on these pages that would make something easier, until it runs out, and it applies nowhere else: starting a break from the menu bar and the quit dialogue ask for the passcode only, because a countdown measured from a window that is not open is a wait nobody can sit out."
            ) {
                StepperControl(
                    value: timerMinutes,
                    range: SettingsLock.timerRange,
                    nextValue: SettingsLock.timerMinutes(after:goingUp:),
                    format: Self.label(forMinutes:)
                )
            }
        }
    }

    @ViewBuilder
    private var passcodeRows: some View {
        SettingsRow(
            "Require a passcode",
            help: "It is asked once per visit, at the door: with one set, this window opens on the passcode screen and nothing here is readable until it is entered. It is stored as a hash — Sandglass cannot read it back to you. It guards against your own impulse, not against somebody who has your Mac: the same person can delete the settings file and start again."
        ) {
            SettingsToggle(isOn: passcodeOn, label: "Require a passcode")
        }
        separator
        SettingsRow(
            "Ask for the passcode before unblocking",
            help: "Unblocking everything for a while asks for the passcode first. Putting the blocks back never does.",
            caption: quickDisableCaption
        ) {
            SettingsToggle(
                isOn: coversQuickDisable, label: "Ask for the passcode before unblocking"
            )
            .disabled(lock.passcode == nil)
        }
        if lock.passcode != nil {
            separator
            SettingsRow(
                "Change passcode",
                help: "Asks for the current passcode, then for the new one twice.\n\nIt does not shorten a wait that is running. Changing a passcode is a removal and a setting in one edit, and the removal half is the way out of the lock — so “Locked for” refuses it until the countdown ends, and the sheet says so rather than saving quietly. Setting a first passcode is the other direction and goes through at once. An hour waiting to clear a forgotten passcode is called off, because it was waiting for the passcode this replaces."
            ) {
                SecondaryPillButton(title: "Change…") { sheet = .change }
            }
            separator
            SettingsRow(
                "Allow resetting a forgotten passcode",
                help: "A forgotten passcode can be cleared from here, an hour after you ask, and the hour cannot be shortened by changing the clock. Switched off, the week's emergency pass is the only thing left that unlocks these settings — which is why switching it back on is a change a running wait holds, and switching it off is one it lets through.",
                caption: forgotCaption
            ) {
                SettingsToggle(
                    isOn: allowForgot, label: "Allow resetting a forgotten passcode"
                )
            }
        }
    }

    // MARK: - What is true this second

    /// **Nothing here asks for the passcode any more.** This card used to carry a "Settings are
    /// locked. [Unlock…]" row and a "Forgot passcode" link beside it, both of which only ever
    /// appeared while `state.passcodeRequired` — and that is now what puts `SettingsDoorView` in
    /// front of this whole window, so neither could be reached from here again. Both moved to the
    /// door, where they are the only two things on the screen instead of the fourth and fifth
    /// lines of a card.
    ///
    /// **Nor does it count the timer down.** "Settings unlock in 4:32" was the top line here, and
    /// the wait it names holds every page in the window rather than this card — so it reads across
    /// the top of the window now, once, where the group editor and the presets can see it too. See
    /// `MainWindowView.lockBanner`.
    ///
    /// The reset countdown stays, and the difference is worth saying: it is a different clock. The
    /// unlock timer is measured from this visit and would be over before the user finished reading
    /// about it; the hour that clears a forgotten passcode belongs to the passcode, outlives the
    /// door and outlives the app — an hour started last night is still running when today's visit
    /// is unlocked with a code the user has since remembered, and calling it off from the row that
    /// reports it is exactly what they want.
    @ViewBuilder
    private var liveLine: some View {
        if let seconds = state.resetSeconds {
            HStack(spacing: 10) {
                SettingsStateRow(
                    text: "Passcode clears in \(SettingsLockGate.countdownText(seconds))"
                )
                Button("Cancel") { problem = appState.setPasscodeReset(false) }
                    .buttonStyle(.link)
            }
        }
    }

    /// The one state worth a line under the label: switched off, there is a way out the user has
    /// just closed, and closing it is a promise they should be making deliberately. Switched on it
    /// says nothing — what the switch does is the info button's job.
    private var forgotCaption: String? {
        lock.allowForgot ? nil : "Off: only the emergency pass unlocks these settings."
    }

    /// A switch with nothing to enforce it would be a promise the app cannot keep, so the one
    /// state worth a caption is the one where there is no passcode to ask for.
    private var quickDisableCaption: String? {
        lock.passcode == nil ? "Needs a passcode." : nil
    }

    // MARK: - The controls

    /// Whole hours read as hours. "180 min" is a number to be worked out rather than a length
    /// anybody feels; past the hour, the minutes come after it rather than instead of it.
    ///
    /// A value the stepper's own span does not cover still reads correctly, because this is
    /// arithmetic on the number rather than a lookup in a list — which is what a hand-edited
    /// `config.json` needs. `StepperControl` is what lets the user walk it back.
    private static func label(forMinutes minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    private var timerOn: Binding<Bool> {
        Binding(
            get: { lock.timerMinutes != nil },
            set: { isOn in
                edit { $0.timerMinutes = isOn ? SettingsLock.defaultTimerMinutes : nil }
            }
        )
    }

    private var timerMinutes: Binding<Int> {
        Binding(
            get: { lock.timerMinutes ?? SettingsLock.defaultTimerMinutes },
            set: { minutes in edit { $0.timerMinutes = minutes } }
        )
    }

    /// Switching it **on** opens the sheet rather than saving anything: there is no passcode to
    /// save until one has been typed twice. Switching it off is an ordinary edit, and therefore
    /// one the passcode itself guards — which is the point.
    private var passcodeOn: Binding<Bool> {
        Binding(
            get: { lock.passcode != nil },
            set: { isOn in
                guard !isOn else {
                    sheet = .set
                    return
                }
                edit {
                    $0.passcode = nil
                    $0.forgotStartedAt = nil
                }
            }
        )
    }

    private var coversQuickDisable: Binding<Bool> {
        Binding(
            get: { lock.coversQuickDisable },
            set: { isOn in edit { $0.coversQuickDisable = isOn } }
        )
    }

    private var allowForgot: Binding<Bool> {
        Binding(
            get: { lock.allowForgot },
            set: { isOn in
                edit {
                    $0.allowForgot = isOn
                    // Switching recovery off calls off a wait that is already running, rather
                    // than leaving a timestamp behind that would resume if it were switched
                    // back on.
                    if !isOn { $0.forgotStartedAt = nil }
                }
            }
        )
    }

    private func edit(_ change: (inout SettingsLock) -> Void) {
        var config = appState.config
        change(&config.settingsLock)
        problem = appState.applyConfigEdit(config)
    }

    // MARK: - What the sheet does

    /// `nil` means the sheet closes.
    ///
    /// `unlockSettings` is what checks the current passcode, and asking it here is now a check and
    /// nothing more: with a passcode set, this card is only reachable through `SettingsDoorView`,
    /// so the visit it would unlock is already unlocked by the time anybody can press "Change…".
    private func submit(_ mode: PasscodeSheet.Mode) -> (String, String) -> String? {
        { current, new in
            if mode.asksForCurrent, !appState.unlockSettings(passcode: current) {
                return "That passcode doesn't match."
            }
            guard let hash = PasscodeHash.make(new) else {
                return "A passcode needs at least \(PasscodeHash.minimumLength) characters."
            }
            var config = appState.config
            config.settingsLock.passcode = hash
            config.settingsLock.forgotStartedAt = nil
            return appState.applyConfigEdit(config)
        }
    }
}
