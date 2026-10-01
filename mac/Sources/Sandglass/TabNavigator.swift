import SandglassAppCore
import SandglassCore
import AppKit

/// Sends the tab in front of a browser somewhere else, and writes down every refusal.
///
/// The writing half of what `BrowserWatcher` reads, and deliberately a separate object: reading an
/// address once a second and moving a tab on a user's decision are different jobs with different
/// failure modes, and only one of them is allowed to change anything.
///
/// **No new permission.** The grant that lets Sandglass ask a browser for `URL of active tab` is
/// the same one that lets it set that URL — one Automation consent per browser, already given.
///
/// **The tab the user opened is the tab that moves.** `set URL of <the tab in front>` navigates in
/// place. `open location`, `NSWorkspace.open` and `tell application to open` would each leave a new
/// tab behind, which is the failure a user reported of RescueTime: a tab bar that filled up because
/// every switch back opened another window. The same call brings the tab home again.
///
/// **It keeps its own record**, which is why it holds the store. A refusal here is a block page
/// that never appeared or a tab that never came home — the one failure that makes this app look
/// broken from the outside — and it used to go to `NSLog`, which for a menu-bar app nobody has a
/// console open on is the same as discarding it. The object that performs the navigation is the
/// one that knows it failed and the one that should say so, rather than every caller remembering
/// to. See `EventKind.navigationFailed`.
@MainActor
final class TabNavigator {

    private let store: Store

    init(store: Store) {
        self.store = store
    }

    /// Moves the tab. `false` means the browser could not be told, and the caller is left to find
    /// a worse block than a navigation — the overlay, or nothing.
    ///
    /// `what` is what the app was trying to do, in the words the log line carries: this is read
    /// months later by somebody who only knows that a page did not come back, and "show the block
    /// page" and "go back to the page" are opposite failures with the same error number on them.
    @discardableResult
    func send(_ browser: KnownBrowser, to address: String, doing what: String) -> Bool {
        guard let refusal = refusal(sending: browser, to: address) else { return true }
        // Best-effort, like every other append: a failed navigation is already bad enough without
        // a failed write about it becoming a second problem.
        store.appendEvent(
            Event(
                ts: Date(),
                kind: EventKind.navigationFailed,
                groupID: nil,
                detail: "couldn't \(what) — \(refusal)"
            )
        )
        return false
    }

    /// Why the browser would not go, or `nil` when it went.
    ///
    /// Compiled per address, unlike the watcher's four fixed scripts: the address is baked into the
    /// source, so there is nothing to cache. Compilation of one line costs far less than the Apple
    /// event it carries, and this runs on a user's decision rather than on a 1 Hz clock.
    private func refusal(sending browser: KnownBrowser, to address: String) -> String? {
        guard let source = browser.navigationScriptSource(to: address) else {
            return "\(browser.name) has no way to be told where to go"
        }
        guard let script = NSAppleScript(source: source) else {
            return "the script for \(browser.name) would not compile"
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        let reason = Self.reason(browser, error)
        // Kept as well as recorded. It costs nothing, and a Mac being watched with `log stream`
        // during a manual test is one more place the failure can turn up.
        NSLog("Sandglass: could not navigate \(browser.name) — \(error)")
        return reason
    }

    /// AppleScript's own two words for what went wrong, and nothing of the dictionary around them.
    ///
    /// The number is what a person searches for — `-1743` is a refused Automation consent, `-1712`
    /// the one-second timeout the script sets for itself — and the message is what makes the
    /// number readable without one. Trimmed, because a log line that runs to a paragraph is a log
    /// line nobody reads to the end of.
    private static func reason(_ browser: KnownBrowser, _ error: NSDictionary) -> String {
        let number = error[NSAppleScript.errorNumber] as? Int
        let message = (error[NSAppleScript.errorMessage] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [number.map { "error \($0)" }, message].compactMap { $0 }.filter { !$0.isEmpty }
        let text = parts.isEmpty ? "no reason given" : parts.joined(separator: ": ")
        return "\(browser.name): " + (text.count <= 120 ? text : text.prefix(119) + "…")
    }
}
