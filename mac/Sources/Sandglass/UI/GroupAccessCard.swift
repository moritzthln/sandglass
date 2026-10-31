import SandglassAppCore
import SandglassCore
import SwiftUI

/// Whether this group opens only with a password, and which password.
///
/// A card of its own rather than a row in the Lock card, because the two guard different things:
/// the Lock card holds this group's **settings**, this holds what the group **blocks** — and,
/// once set, the settings too: the password becomes the group's door (`GroupLockGate.hasDoor`),
/// so this card is only ever reached by somebody who has typed it.
///
/// Setting a password is an edit like every other on the page and goes through `applyConfigEdit`.
/// It shuts the group further, so it goes on whatever lock is standing; turning it off, switching
/// its source or changing it is the way back out, so a running lock holds all three — see
/// `EditDirection.lockHolds`.
@MainActor
struct GroupAccessCard: View {
    @Binding var settings: GroupSettings
    /// Where a refused write is reported: the page's own slot, as for every other edit.
    @Binding var problem: String?
    /// Whether the app has a settings passcode to open with. Without one that choice is offered
    /// but cannot be picked.
    let hasSettingsPasscode: Bool
    var tighteningOnly = false

    @State private var sheet: PasscodeSheet.Mode?

    private enum Source: Hashable { case settingsPasscode, custom }

    var body: some View {
        SettingsCard("Access") {
            SettingsRow(
                "Open only with a password",
                help: "Everything in this group stays blocked until the password is typed; then"
                    + " it opens for the group's open length (30 minutes if it has none) and locks"
                    + " again. The same password guards this group's settings, “Unblock"
                    + " everything” and the emergency pass do not open it, and turning off “Start"
                    + " at login and keep running” asks for it.",
                caption: caption
            ) {
                SettingsToggle(isOn: passwordOn, label: "Open only with a password")
                    .disabled(tighteningOnly && settings.accessPassword != nil)
            }
            if settings.accessPassword != nil {
                Divider().overlay(Palette.hairline).padding(.vertical, 6)
                SettingsRow(
                    "Password",
                    help: "The settings passcode is the one Settings opens with; changing it there"
                        + " changes it here. A password you set belongs to this group alone.",
                    caption: hasSettingsPasscode ? nil : Self.noPasscodeHint
                ) {
                    sourcePicker.disabled(tighteningOnly)
                }
            }
            if case .custom = settings.accessPassword {
                Divider().overlay(Palette.hairline).padding(.vertical, 6)
                SettingsRow(
                    "Change the password",
                    help: "Asks for the current password, then for the new one twice."
                ) {
                    SecondaryPillButton(title: "Change…") { sheet = .change }
                        .disabled(tighteningOnly)
                }
            }
        }
        .sheet(item: $sheet) { mode in
            PasscodeSheet(mode: mode, submit: submit(mode), dismiss: { sheet = nil }, noun: "password")
        }
    }

    static let noPasscodeHint = "To use the settings passcode, set one in Settings → Settings lock."

    private var caption: String? {
        guard settings.accessPassword != nil else { return nil }
        return "Opens for \(settings.accessMinutes) min after the password."
    }

    private var sourcePicker: some View {
        Picker("", selection: source) {
            Text("The settings passcode").tag(Source.settingsPasscode)
                .disabled(!hasSettingsPasscode)
            Text("A password you set").tag(Source.custom)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    /// Picking the settings passcode saves at once; picking a password of the group's own opens
    /// the sheet and saves nothing until one has been typed twice.
    private var source: Binding<Source> {
        Binding(
            get: { settings.accessPassword == .settingsPasscode ? .settingsPasscode : .custom },
            set: { picked in
                switch picked {
                case .settingsPasscode:
                    guard hasSettingsPasscode else {
                        problem = Self.noPasscodeHint
                        return
                    }
                    settings.accessPassword = .settingsPasscode
                case .custom:
                    if settings.accessPassword == .settingsPasscode { sheet = .set }
                }
            }
        )
    }

    /// On uses the settings passcode where there is one — the default — and otherwise opens the
    /// sheet for a password of the group's own. Off is an ordinary edit, and therefore one a
    /// standing lock holds.
    private var passwordOn: Binding<Bool> {
        Binding(
            get: { settings.accessPassword != nil },
            set: { isOn in
                guard isOn else {
                    settings.accessPassword = nil
                    return
                }
                if hasSettingsPasscode {
                    settings.accessPassword = .settingsPasscode
                } else {
                    sheet = .set
                }
            }
        )
    }

    /// `nil` means the sheet closes. The current password is checked against this group's own
    /// hash; the minimum length is `PasscodeHash.make`'s, so no second rule can drift from it.
    private func submit(_ mode: PasscodeSheet.Mode) -> (String, String) -> String? {
        { current, new in
            if mode.asksForCurrent, settings.accessPassword?.matches(current, settingsPasscode: nil) != true {
                return "That password doesn't match."
            }
            guard let hash = PasscodeHash.make(new) else {
                return "A password needs at least \(PasscodeHash.minimumLength) characters."
            }
            settings.accessPassword = .custom(hash)
            return problem
        }
    }
}
