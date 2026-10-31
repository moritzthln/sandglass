import SandglassAppCore
import AppKit
import SwiftUI

/// The field a group that opens only with its password is opened with.
///
/// One view for both places it is typed: the pause screen in front of a blocked app, and the
/// small window a block page's "Enter password" raises. `submit` answers the line to show under
/// the field, or `nil` when there is nothing to say — usually because the group just opened and
/// whoever owns this view is about to take it away.
@MainActor
struct AccessPasswordField: View {
    let submit: (String) -> String?

    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            SecureField("Password", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($focused)
                .onSubmit(attempt)
            Button("Unlock", action: attempt)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(text.isEmpty)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { focused = true }
    }

    /// The field is emptied after every try, right or wrong: the typed password is not kept a
    /// moment longer than the one check it was typed for.
    private func attempt() {
        guard !text.isEmpty else { return }
        let typed = text
        text = ""
        problem = submit(typed)
    }
}

/// The small window a block page's "Enter password" button raises.
///
/// A window of the app's own rather than a field on the page, because whatever is typed into a
/// web page can end up in an address and the history. Small and ordinary rather than the full
/// pause screen: somebody asked for it by pressing a button, so it is a question, not a block.
/// One at a time — a second press replaces what the first one asked about.
@MainActor
final class AccessPasswordPanel {
    private var panel: NSPanel?

    func show(name: String, submit: @escaping (String) -> String?, cancel: @escaping () -> Void) {
        let content = AccessPasswordPrompt(name: name, submit: submit, cancel: cancel)
        let window = panel ?? makePanel()
        window.contentView = NSHostingView(rootView: content)
        panel = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Sandglass"
        // Above the browser it was asked from, which is the window somebody is looking at.
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        return window
    }
}

/// What the panel shows: whose password it is, the field, and a way to leave.
@MainActor
private struct AccessPasswordPrompt: View {
    let name: String
    let submit: (String) -> String?
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(name).font(.headline)
                Text("Opens only with its password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            AccessPasswordField(submit: submit)
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(width: 340)
    }
}
