import SandglassAppCore
import SandglassCore
import SwiftUI

/// The whole window, when a passcode is set and this visit has not answered it: a name, a field,
/// and the one way out of a passcode nobody can remember.
///
/// It used to be a sheet on the first refusal — everything was readable, and the question came
/// when something was changed. At the door instead, which is the point: without the code nothing
/// is reachable, not how a group is configured and not the numbers screen either.
///
/// Deliberately bare, for the reason `PauseScreenView` is: a screen with one job says one thing.
/// There is no second unlock anywhere in the app, no attempt counter, and no shame copy — a wrong
/// code is a typing mistake nine times out of ten, and a lock that scolds is one people switch off.
///
/// **It refuses entry; it does not trap.** The red traffic light closes the window as it always
/// did, Escape does the same, and the recovery control at the bottom is whichever of the three
/// ways back actually applies — see `SettingsDoor.Recovery`. With "Allow resetting a forgotten
/// passcode" switched off the week's emergency pass is the only one left, and it is offered here
/// because the settings page that normally carries it is behind this screen.
@MainActor
struct SettingsDoorView: View {
    let appState: AppState
    /// Shuts the window. Escape, and nothing else on this screen — the traffic light is the
    /// window's own and needs no help from here.
    let close: () -> Void

    @State private var passcode = ""
    /// A wrong code, or a refusal from the recovery control. One line, because only one of them
    /// can be the last thing that happened. Its height is held whether or not there is one — see
    /// `message`.
    @State private var problem: String?
    @State private var confirmingPass = false
    @FocusState private var focused: Bool

    private var door: SettingsDoor {
        SettingsDoor(lock: appState.config.settingsLock, state: appState.settingsLockState)
    }

    /// Three blocks down one axis: who is asking, what it wants, and the way out.
    ///
    /// The seams are written out rather than left to one `VStack` spacing, because the blocks are
    /// not the same shape: `entry` ends in a line that is usually blank (see `message`), so an
    /// even spacing here would draw an even gap above it and half again as much below. What is
    /// meant to be even is what the eye measures — ink to ink — and that is what these numbers are
    /// tuned against.
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                brand
                Text(SettingsDoor.title)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            entry
                .padding(.top, 26)
            recovery
                .padding(.top, 14)
        }
        .multilineTextAlignment(.center)
        .frame(width: Metrics.doorColumnWidth)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
        // Two paths to one close, and both are wanted. A `.cancelAction` shortcut becomes an
        // AppKit key equivalent, and those are offered the keystroke *before* the focused field's
        // editor sees it — which is what makes Escape work while somebody is halfway through
        // typing a passcode, and is why the button exists at all rather than only the modifier
        // below. Invisible and unhittable, so the one thing it contributes is the keystroke.
        // `onExitCommand` is the responder-chain path and covers focus having left the field.
        .background {
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onExitCommand(perform: close)
    }

    /// The sidebar's own wordmark, centred. This screen stands in for the whole window, so it has
    /// to say which app is asking — a bare passcode field on an unnamed window is a phishing
    /// prompt.
    private var brand: some View {
        HStack(spacing: 9) {
            Image(systemName: "hourglass")
                .foregroundStyle(Color.accentColor)
            Text("Sandglass").font(.headline)
        }
    }

    /// The field, the button under it, and the line that answers them.
    ///
    /// Stacked rather than side by side. A field and a button in an `HStack` centre as a *pair*,
    /// and the pair's halves are not the same width — so the field, the one thing on this screen
    /// anybody looks at, sat 34 points to the left of the title while everything else sat on the
    /// axis. That is the whole of what looked crooked. The field has the column to itself now,
    /// which puts it on the axis and makes it wide enough to type a passcode into.
    ///
    /// The button keeps its own width rather than matching the field. Stretched to the column it
    /// is a second bar of the same size directly under the first, and `.borderedProminent` while
    /// `disabled` — which is how the door opens, with nothing typed — draws it in the same grey
    /// the field is drawn in. Two identical bars, one of them a field and one of them not.
    private var entry: some View {
        VStack(spacing: 0) {
            SecureField("Passcode", text: $passcode)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .defaultFocus($focused, true)
                .onSubmit(unlock)
                // The refusal describes the code that was refused, so it goes the moment the
                // next one is being typed.
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

    /// The refusal, in a line that is there whether or not it says anything.
    ///
    /// Held rather than inserted: the column is centred in the window, so a line appearing at the
    /// bottom of it used to lift everything above it by half the line's height — a measured 16.5
    /// points, at the exact moment somebody was about to retype into the field that moved. An
    /// empty line of the same font costs the space once and never moves anything again. A refusal
    /// long enough to wrap still grows, which is rare and worth less than the jump it replaces.
    private var message: some View {
        Text(problem ?? " ")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(problem == nil ? 0 : 1)
            .accessibilityHidden(problem == nil)
    }

    // MARK: - The way out

    /// Exactly one control, and which one is `SettingsDoor.Recovery`'s to decide.
    @ViewBuilder
    private var recovery: some View {
        let recovery = door.recovery
        VStack(spacing: 8) {
            if let note = recovery.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .emergencyPassOnly = recovery {
                passControl(title: recovery.actionTitle)
            } else {
                Button(recovery.actionTitle) { start(recovery) }
                    .buttonStyle(.link)
                    .help(recovery.help ?? "")
            }
        }
    }

    /// The week's pass, behind the same confirmation the settings page puts it behind: it cannot
    /// be given back, and it unblocks everything for an hour rather than only opening this screen.
    /// Where the pass stands is the app's own published line, so a spent one says when it returns
    /// rather than leaving a dead button to be worked out.
    private func passControl(title: String) -> some View {
        VStack(spacing: 6) {
            Button(title) { confirmingPass = true }
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

    /// Starting the hour, or calling it off. Both go through `AppState.setPasscodeReset`, which
    /// deliberately does not ask the settings lock — a passcode nobody can remember must not be
    /// what guards its own way out.
    private func start(_ recovery: SettingsDoor.Recovery) {
        if case .waiting = recovery {
            problem = appState.setPasscodeReset(false)
        } else {
            problem = appState.setPasscodeReset(true)
        }
    }

    // MARK: - The code

    /// A wrong code says so and leaves everything else alone. No attempt counter and no lockout:
    /// the app already has one lock here, and a second one built on top of it would be the thing
    /// that turns a forgotten passcode into a reinstall.
    ///
    /// **The field is not cleared**, and that is the whole reason the refusal survives long enough
    /// to be read: clearing it is a change like any other, so `onChange` above would wipe the line
    /// that had just been put there. Leaving it costs a select-and-retype and buys a message that
    /// stays until the next keystroke — which is exactly when it stops being true.
    private func unlock() {
        guard !passcode.isEmpty else { return }
        guard appState.unlockSettings(passcode: passcode) else {
            problem = SettingsDoor.wrongPasscode
            return
        }
        passcode = ""
    }
}
