import SandglassCore
import SwiftUI

/// The small sheet that **chooses** a passcode: setting one, or replacing one.
///
/// One sheet for both because they differ by a single field, and because two near-identical
/// dialogues is how a settings screen starts drifting.
///
/// It had a third mode, `.unlock`, and that is now a screen rather than a sheet: with a passcode
/// set, `SettingsDoorView` is the whole window until the code is entered, so nothing behind it
/// ever needs to ask again. See `SettingsLockSection.liveLines` for what went with it.
///
/// No shame copy anywhere on it. A wrong passcode is a typing mistake nine times out of ten, and
/// a lock that scolds is one people switch off — which is the only way this feature really fails.
@MainActor
struct PasscodeSheet: View {

    enum Mode: Identifiable {
        /// There is no passcode; one is being chosen. Typed twice, because it is about to guard
        /// the screen that could otherwise clear it.
        case set
        /// There is one, and it is being replaced. The current one is asked for first.
        case change

        var id: String { title }

        var title: String {
            switch self {
            case .set: return "Set a passcode"
            case .change: return "Change your passcode"
            }
        }

        var asksForCurrent: Bool { self == .change }
    }

    let mode: Mode
    /// What to do with what was typed. `nil` means it went through and the sheet closes;
    /// anything else is shown under the fields. `current` is empty in `.set`.
    let submit: (_ current: String, _ new: String) -> String?
    let dismiss: () -> Void

    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title).font(.headline)
            if mode.asksForCurrent {
                SecureField("Current passcode", text: $current)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(attempt)
            }
            SecureField("New passcode", text: $new)
                .textFieldStyle(.roundedBorder)
            SecureField("Repeat new passcode", text: $repeated)
                .textFieldStyle(.roundedBorder)
                .onSubmit(attempt)
            // The rule the field enforces, and nothing else. It used to add "there is no way
            // to read it back", which is a fact about the passcode rather than about this
            // field — it lives on the "Require a passcode" row's info button.
            Text("At least \(PasscodeHash.minimumLength) characters.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: attempt)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 320)
    }

    /// The two rules about the new passcode are checked here; everything the app has to be asked
    /// about — whether the current one is right, whether the edit is allowed — comes back from
    /// `submit` as a line to show.
    private func attempt() {
        guard new.count >= PasscodeHash.minimumLength else {
            problem = "A passcode needs at least \(PasscodeHash.minimumLength) characters."
            return
        }
        guard new == repeated else {
            problem = "The two passcodes are not the same."
            return
        }
        guard let refusal = submit(current, new) else {
            dismiss()
            return
        }
        problem = refusal
    }
}
