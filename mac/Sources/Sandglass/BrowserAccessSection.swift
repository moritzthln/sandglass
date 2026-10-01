import SandglassAppCore
import AppKit
import SwiftUI

/// The row on the Protection card for the permission the blocking runs on.
///
/// It was about websites alone, and the grant has outgrown that: the same permission is what takes
/// a blocked app out of its fullscreen Space before hiding it. So the row is what the app can
/// actually do right now, both halves of it — and it is read from `AXIsProcessTrusted()` on every
/// tick rather than from the System Settings list, which keeps showing a grant this app lost on
/// its last reinstall.
///
/// There used to be a **Block websites** switch above it, on by default, and the row was three
/// paragraphs under it. The switch answered a question nobody asks — of course websites are
/// blocked — and it was the one click that could lift every website block in a strict window. It
/// is gone. What is left is the thing that genuinely decides whether website blocking can work:
/// whether macOS lets Sandglass read the address of the page in front.
///
/// So the row is a label, one line of live state, and the button that opens the pane macOS will
/// only grant it from. Everything else — which browsers are covered, that the address never
/// leaves this Mac, that Automation is asked for separately — is in the info button, where a
/// reader who wants it can find it and a reader who does not is not made to read it.
///
/// The honesty rule this row exists to keep: the app never claims to be protecting websites it
/// cannot see. Accessibility can be asked about without prompting, so it is reported as a fact.
/// Automation cannot be, so what is reported is which browsers have actually refused — and only
/// when some have. Both sentences are `BrowserAccess`'s own.
@MainActor
struct BrowserAccessSection: View {
    let appState: AppState

    /// The Accessibility pane of System Settings. A URL rather than an `open -a`: it lands on the
    /// list the checkbox is in, which is the difference between one click and a hunt.
    private static let accessibilityPane =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(
                "Accessibility",
                help: "One permission, and two things depend on it. Websites are blocked by reading the address of the page in the browser you are looking at — Safari, Chrome, Arc, Brave, Edge and Firefox are all covered, with nothing to install, and the address is compared on this Mac and never stored or sent anywhere. And a blocked app in fullscreen is taken out of its Space before it is hidden: without that it ignores being hidden and simply stays there. Each browser also asks once, by itself, whether Sandglass may read it directly — that one is optional and only more accurate.\n\nmacOS forgets this grant every time Sandglass is reinstalled, and goes on showing the old entry with its switch still on. That is why the line above is read from the system live rather than from the list. If it says the permission is missing while the list says otherwise, remove Sandglass there with “−” and add it again with “+”.",
                caption: appState.browserAccess.accessibilityLine
            ) {
                SecondaryPillButton(title: "Open settings") { openAccessibilitySettings() }
            }
            // Only when a browser has actually said no. See `BrowserAccess.automationLine`.
            if let refused = appState.browserAccess.automationLine {
                SettingsStateRow(text: refused, tone: .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: Self.accessibilityPane) else { return }
        NSWorkspace.shared.open(url)
    }
}
