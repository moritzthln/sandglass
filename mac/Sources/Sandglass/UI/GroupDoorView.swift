import SandglassAppCore
import SandglassCore
import SwiftUI

/// The whole of a group's editor page, when that group has a passcode and this visit has not
/// answered it: the group's name, a field, and the two ways past a code nobody can remember.
///
/// `SettingsDoorView`'s shape at the scope of one group, and deliberately the same restraint: one
/// field, one button, no attempt counter and no shame copy — a wrong code is a typing mistake nine
/// times out of ten, and a lock that scolds is one people switch off. What is different is that
/// this door stands *inside* an open window: the sidebar is still there, so the screen says which
/// group is asking rather than which app, and both escapes are on it rather than whichever one
/// applies. See `GroupDoor`.
@MainActor
struct GroupDoorView: View {
    let appState: AppState
    let group: ConfigGroup

    @State private var passcode = ""
    /// A wrong code, or a refusal from one of the two escapes. One line, because only one of them
    /// can be the last thing that happened.
    @State private var problem: String?
    @State private var confirmingPass = false
    @FocusState private var focused: Bool

    private var door: GroupDoor {
        GroupDoor(
            name: group.name,
            state: appState.groupLockStates[group.id] ?? GroupLockState(),
            ignoresAppWideUnblocks: group.settings?.ignoresAppWideUnblocks ?? false
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "lock")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                Text(door.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(door.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            entry
                .padding(.top, 24)
            recovery
                .padding(.top, 14)
        }
        .multilineTextAlignment(.center)
        .frame(width: Metrics.doorColumnWidth)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// The field, the button under it, and the line that answers them — stacked for the reason
    /// `SettingsDoorView.entry` is stacked: a field and a button side by side centre as a pair
    /// whose halves are different widths, which puts the one thing anybody looks at off the axis
    /// everything else sits on.
    private var entry: some View {
        VStack(spacing: 0) {
            SecureField("Passcode", text: $passcode)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .defaultFocus($focused, true)
                .onSubmit(unlock)
                // The refusal describes the code that was refused, so it goes the moment the next
                // one is being typed.
                .onChange(of: passcode) { _, _ in problem = nil }
            Button("Unlock", action: unlock)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(passcode.isEmpty)
                .padding(.top, 10)
            message
                .padding(.top, 6)
        }
    }

    /// The refusal, in a line that is there whether or not it says anything — held for the reason
    /// `SettingsDoorView.message` is held: a line appearing at the bottom lifts the field somebody
    /// is about to retype into.
    private var message: some View {
        Text(problem ?? " ")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(problem == nil ? 0 : 1)
            .accessibilityHidden(problem == nil)
    }

    // MARK: - The ways out

    /// Both of them, and the hour first: it is the one that is about *this* group, and the pass is
    /// the whole app's one net a week. A group door with no way past a forgotten code is a
    /// reinstall, which is the one way this feature could not be allowed to fail.
    ///
    /// The pass may be missing from a group that has opted out of it and the hour never is — which
    /// is the whole of why the hour is per group and not switchable off. Their order is what makes
    /// that safe to read: the escape that is always there is the one at the top.
    private var recovery: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                if let note = door.recovery.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(door.recovery.actionTitle) { start(door.recovery) }
                    .buttonStyle(.link)
                    .help(door.recovery.help)
            }
            Divider().overlay(Palette.hairline).frame(width: 120)
            passControl
        }
    }

    /// The week's pass, behind the same confirmation the settings page puts it behind: it cannot
    /// be given back, and it unblocks everything for an hour rather than only opening this page.
    ///
    /// **Not offered at all on a group that ignores it.** A pass spent here would open every other
    /// group and leave this door exactly as shut — so the button is replaced by the sentence that
    /// says so, rather than drawn as a way in that costs the week's one net and is not one. What
    /// remains for this group is the hour above, which is why that sentence points at it. See
    /// `GroupDoor.offersEmergencyPass`.
    @ViewBuilder
    private var passControl: some View {
        if door.offersEmergencyPass {
            passButton
        } else {
            Text(GroupDoor.appWideUnblocksDoNotApply)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var passButton: some View {
        VStack(spacing: 6) {
            Button("Use emergency pass") { confirmingPass = true }
                .buttonStyle(.bordered)
                .disabled(!appState.emergencyPassAvailable)
            Text(appState.emergencyPassLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .alert("Use this week's emergency pass?", isPresented: $confirmingPass) {
            Button("Cancel", role: .cancel) {}
            Button("Use it", role: .destructive) { appState.useEmergencyPass() }
        } message: {
            Text("This unblocks everything for one hour. You get one per week.")
        }
    }

    /// Starting the hour, or calling it off. Both go through `AppState.setGroupPasscodeReset`,
    /// which deliberately does not ask this group's own lock — a passcode nobody can remember must
    /// not be what guards its own way out.
    private func start(_ recovery: GroupDoor.Recovery) {
        if case .waiting = recovery {
            problem = appState.setGroupPasscodeReset(group.id, running: false)
        } else {
            problem = appState.setGroupPasscodeReset(group.id, running: true)
        }
    }

    // MARK: - The code

    /// A wrong code says so and leaves everything else alone. **The field is not cleared**, which
    /// is what lets the refusal survive long enough to be read: clearing it is a change like any
    /// other, so the `onChange` above would wipe the line that had just been put there.
    private func unlock() {
        guard !passcode.isEmpty else { return }
        guard appState.unlockGroup(group.id, passcode: passcode) else {
            problem = GroupDoor.wrongPasscode
            return
        }
        passcode = ""
    }
}
