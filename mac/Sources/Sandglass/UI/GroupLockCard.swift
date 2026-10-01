import SandglassAppCore
import SandglassCore
import SwiftUI

/// The group's own lock: a wait measured from this window opening, and a passcode of its own.
///
/// The app-wide pair (Settings → Protection) applies to everything; this one applies to this
/// group, and where both are set the longer of the two holds it. That is the point of having one
/// per group — a strict group stays hard to loosen while the rest of the app is freely editable.
///
/// **Setting a lock up is itself an edit to the group**, so it goes through `applyConfigEdit` like
/// every other row on this page and passes whatever lock is already standing. Somebody who wants
/// to change a lock they set an hour ago waits it out, or enters the code, exactly as they would
/// to change anything else here.
///
/// The rows are `SettingsLockSection`'s shape, one scope down: a stepper whose bottom is off, and
/// a switch that opens `PasscodeSheet` on the way on and saves nothing until a code has been typed
/// twice. What each of them then refuses is `GroupLockGate`; nothing here decides anything.
@MainActor
struct GroupLockCard: View {
    let appState: AppState
    let groupID: String
    @Binding var settings: GroupSettings
    /// Where the writes report a refusal. The page's own slot, so a refused lock reads beside
    /// every other refused edit rather than in a second place.
    @Binding var problem: String?
    /// Whether a lock is already standing over this group, in which case this card moves the way
    /// every other one on the page does: **the wait may be made longer and a passcode may be put
    /// on, and neither may be taken off.** See `EditDirection`, and `GroupDetailColumn` for the
    /// same narrowing over the knobs.
    var tighteningOnly = false

    @State private var sheet: PasscodeSheet.Mode?

    var body: some View {
        SettingsCard(
            "Lock",
            help: "A lock of this group's own, on top of the app-wide one in Settings. While"
                + " either of them stands, nothing about this group can be made easier — not a"
                + " knob turned down, not a window taken out, not a site removed, and not the"
                + " switch that turns it off. Making it harder always goes through. Where both"
                + " are set, the longer of the two holds this group."
        ) {
            SettingsRow(
                "Lock this group's settings for",
                help: "Counted from the moment this window opens — or, with a passcode set below,"
                    + " from the moment that passcode is entered, so the wait is not spent behind"
                    + " a door nobody has opened yet. Nought is off, and the visit that moves it"
                    + " off nought is not held by what it just set: the wait starts from the next"
                    + " time this window opens. Until it runs out it holds every change that"
                    + " would make this group easier, and lets every change that makes it harder"
                    + " through — so this wait may be lengthened while it stands, and never"
                    + " shortened."
            ) {
                StepperControl(
                    value: $settings.lockMinutes,
                    range: ControlRules.upwards(
                        GroupSettings.lockRange, from: settings.lockMinutes,
                        tighteningOnly: tighteningOnly
                    ),
                    nextValue: GroupSettings.lockMinutes(after:goingUp:),
                    format: Self.label(forMinutes:)
                )
            }
            Divider().overlay(Palette.hairline).padding(.vertical, 6)
            SettingsRow(
                "Require a passcode for this group",
                help: "Its own code, separate from the app-wide one. With one set, this page opens"
                    + " on a passcode screen and nothing about the group is readable until it is"
                    + " entered — once per visit, per group, and the wait above starts counting"
                    + " from that moment rather than from the window. Setting one is more"
                    + " friction, so it"
                    + " goes on whatever else is standing; taking it off is the way out, so a"
                    + " running lock holds that. It is stored as a hash; Sandglass cannot read it"
                    + " back to you. Forgetting it is survivable: the door offers an hour that"
                    + " clears it, and the week's emergency pass lifts it at once.",
                caption: passcodeCaption
            ) {
                // Setting one is more friction and goes through whatever is standing; taking one
                // off is the way out of the lock, and that is what the lock refuses.
                SettingsToggle(isOn: passcodeOn, label: "Require a passcode for this group")
                    .disabled(tighteningOnly && settings.passcode != nil)
            }
            // Directly under the switch that puts a code on, and above the pass row rather than
            // below it: "Change…" is a follow-on to the row before it, and a row about something
            // else standing between the two would read as belonging to whichever it sat nearer.
            if settings.passcode != nil {
                Divider().overlay(Palette.hairline).padding(.vertical, 6)
                SettingsRow(
                    "Change this group's passcode",
                    help: "Asks for the current passcode, then for the new one twice. It does not"
                        + " shorten a wait that is running: swapping a code is a removal and a"
                        + " setting in one edit, and the removal half is what a lock refuses."
                ) {
                    // Swapping a code is a removal and a setting in one edit, and the removal
                    // half is the way out — so a running lock holds it like any other loosening.
                    SecondaryPillButton(title: "Change…") { sheet = .change }
                        .disabled(tighteningOnly)
                }
            }
            Divider().overlay(Palette.hairline).padding(.vertical, 6)
            SettingsRow(
                "Unblocking everything does not apply to this group",
                help: "Both of the app's ways out, in one switch: “Unblock everything” and the"
                    + " week's emergency pass. With this on, neither of them does anything to this"
                    + " group — what it blocks stays blocked, including a date you set — while"
                    + " every other group opens as usual, for the whole length either was taken"
                    + " for. Under a pass the passcode above also goes on being asked for and the"
                    + " wait goes on counting; a pass is spent either way.\n\nThe two are one"
                    + " switch because a group immune to the rationed way out and not to the free"
                    + " one is immune until the next time you take the free one.\n\nIt is not a way"
                    + " to lock yourself out: a forgotten passcode still clears an hour after you"
                    + " ask it to, from this group's own door.\n\nOn its own it only holds the"
                    + " blocks. Give the group a wait or a passcode above as well, or the pass hour"
                    + " is time enough to switch the group off instead.",
                caption: unblockImmunityCaption
            ) {
                // Switching it on takes both of the app's ways out away from this group, which is
                // more friction and goes through whatever is standing. Switching it off hands them
                // back, and that is what a running lock refuses.
                SettingsToggle(
                    isOn: $settings.ignoresAppWideUnblocks,
                    label: "Unblocking everything does not apply to this group"
                )
                .disabled(tighteningOnly && settings.ignoresAppWideUnblocks)
            }
        }
        .sheet(item: $sheet) { mode in
            PasscodeSheet(mode: mode, submit: submit(mode), dismiss: { sheet = nil })
        }
    }

    /// The one state worth a line under the label: an hour is running against this group's code,
    /// which is a thing somebody started on the door and may well have forgotten about.
    private var passcodeCaption: String? {
        guard let seconds = appState.groupLockStates[groupID]?.resetSeconds else { return nil }
        return "Clearing in \(SettingsLockGate.countdownText(seconds))."
    }

    /// Said only while it is switched on, and only about the half people get wrong: this holds the
    /// blocks, and holding the *settings* is what the two rows above it are for. Without one of
    /// them the pass hour is time enough to switch the group off, which ends its blocks by another
    /// road — so the row says so on the group it is true of rather than in help nobody opens.
    private var unblockImmunityCaption: String? {
        guard settings.ignoresAppWideUnblocks, !settings.hasOwnLock else { return nil }
        return "This group has no lock of its own, so it can still be switched off during a pass."
    }

    /// Whole hours read as hours, and nought reads as its own word — `SettingsLockSection`'s
    /// arithmetic plus the off state its own stepper does not have.
    private static func label(forMinutes minutes: Int) -> String {
        guard minutes > 0 else { return "Off" }
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Switching it **on** opens the sheet rather than saving anything: there is no passcode to
    /// save until one has been typed twice. Switching it off is an ordinary edit to the group, and
    /// therefore one the passcode itself guards — which is the point.
    private var passcodeOn: Binding<Bool> {
        Binding(
            get: { settings.passcode != nil },
            set: { isOn in
                guard !isOn else {
                    sheet = .set
                    return
                }
                settings.passcode = nil
                settings.passcodeForgotStartedAt = nil
            }
        )
    }

    /// `nil` means the sheet closes.
    ///
    /// The current code is checked against this group's own hash rather than through the gate: the
    /// card is only reachable behind the door, so the visit this would unlock is already unlocked
    /// by the time anybody can press "Change…".
    private func submit(_ mode: PasscodeSheet.Mode) -> (String, String) -> String? {
        { current, new in
            if mode.asksForCurrent, settings.passcode?.matches(current) != true {
                return "That passcode doesn't match."
            }
            guard let hash = PasscodeHash.make(new) else {
                return "A passcode needs at least \(PasscodeHash.minimumLength) characters."
            }
            var edited = settings
            edited.passcode = hash
            edited.passcodeForgotStartedAt = nil
            settings = edited
            return problem
        }
    }
}
