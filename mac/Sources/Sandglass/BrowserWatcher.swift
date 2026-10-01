import SandglassAppCore
import AppKit
import ApplicationServices

/// Reads the address of the page in the browser the user is looking at.
///
/// The only way this app knows what is on the web. It covers Safari, Chrome, Arc, Brave, Edge and
/// Firefox with no install step at all, by asking macOS the same question a screen reader would —
/// which is why the browser extension it replaced could be deleted whole: that one covered
/// Chromium, only after a "Load unpacked" ritual, and ran beside this one.
///
/// **Two ways of asking, and the order matters.** AppleScript into the browser's own dictionary
/// is exact and cheap, and every browser but Firefox has one. The accessibility tree is the
/// fallback, the only route into Firefox, and the one permission that covers all six at once —
/// Firefox's `MOXWebAreaAccessible` implements `moxURL`, which is how `AXURL` reaches the web
/// area, so the same walk works there as in Safari.
///
/// **A browser has to be woken before it will answer.** None of them keeps an accessibility tree
/// standing for nobody, so the tree is built on being asked for. Firefox's trigger is reading the
/// role off its application element, which `readAccessibility` does first and throws away.
/// Chromium's is older and less reachable — it wants an assistive technology to announce itself by
/// *writing* `AXEnhancedUserInterface`, which has side effects on other people's windows and is
/// not something this app is going to do. That is why AppleScript leads for the five browsers that
/// have a dictionary: for them the tree is the fallback's fallback, and if it turns out empty in a
/// Chromium browser whose Automation was refused, the honest state is the yellow menu bar.
///
/// **Nothing here prompts.** `AXIsProcessTrusted()` is the non-prompting question, and it is the
/// gate on every accessibility call below: a background app polling at 1 Hz must never be the
/// thing that puts a system dialog on screen. AppleScript is the exception the system owns — the
/// first Apple event to a browser raises macOS's own Automation prompt, once, and a refusal is
/// remembered by the system rather than re-asked. The settings row is where both are explained.
///
/// **Everything that decides anything is somewhere else.** Which browsers exist, what counts as
/// a page, what an error number means and how long a refused route rests are all in
/// `Browsers.swift` and `BrowserWatch.swift`, where they are values with tests. What is left
/// here is the calls into macOS, which cannot be tested on a machine with no browser open and no
/// permissions granted.
@MainActor
final class BrowserWatcher {

    /// A page in front, as the blocker needs it: what is showing, and the browser showing it.
    ///
    /// The browser is carried twice over, and both are used. `known` is what says whether its tab
    /// can be navigated at all — Firefox's cannot — and carries the line of AppleScript that does
    /// it. `running` is the process, which "Open" has to give the keyboard back to.
    struct Page {
        let sighting: BrowserSighting
        /// What the browser actually said, before anything normalized it.
        ///
        /// The sighting is the page's *name* — `youtube.com/watch`, which is the spelling every
        /// rule and every comparison uses, and which by design has lost the video id along with
        /// the rest of the query string. This is the address, and it is kept for the one job that
        /// needs the whole of it: the block page's button has to open the video somebody was
        /// watching, not the bare path. See `BlockPage.opening(from:target:)`.
        let address: String
        /// What the browser calls the tab this came from, or `nil` when it has no way of saying —
        /// Safari and Firefox, and any reading that came off the accessibility tree.
        let tabID: String?
        let known: KnownBrowser
        let running: NSRunningApplication

        var bundleID: String { known.bundleID }

        /// The tab, as everything that keys by one wants it. A wait belongs to the tab that served
        /// it rather than to an address, so this is what the ledger and the settle window are
        /// keyed by — and with no identity it is one key per browser, which is what they were
        /// keyed by before. See `BrowserTab`.
        var tab: BrowserTab { BrowserTab(browserID: known.bundleID, tabID: tabID) }
    }

    /// Sandglass's own block page, in the bundle — or `nil` when there is not one to navigate to.
    ///
    /// **Checked for on disk, not assumed.** A raw SwiftPM build has no resources directory worth
    /// the name, and a bundle whose build forgot to copy the page has one that is empty; both
    /// would otherwise send every blocked tab to a "file not found" of the browser's own, which is
    /// a worse block than the overlay and looks like a broken app rather than a missing file. With
    /// `nil` the blocker falls back to the overlay, which is the same thing it does for Firefox.
    ///
    /// Read once: the bundle does not move under a running process, and this is consulted on every
    /// address the poll reads. Shared with the blocker, which navigates tabs *to* it — one value,
    /// so recognising the page and building it cannot end up disagreeing about where it is.
    static let blockPage: URL? = {
        guard let page = BlockPage.pageURL(resources: Bundle.main.resourceURL),
              FileManager.default.fileExists(atPath: page.path)
        else { return nil }
        return page
    }()

    /// Which route worked last, and which ones are resting. See `BrowserStrategyMemory`.
    private var memory = BrowserStrategyMemory()
    /// Browsers whose AppleScript has been refused this run. Cleared per browser the moment one
    /// answers again, so granting Automation mid-run takes the line off the settings screen.
    private var automationRefused: Set<String> = []
    /// Compiled once and kept: `NSAppleScript` compiles on its first run, and recompiling four
    /// lines of AppleScript once a second is a cost with nothing to show for it.
    private var scripts: [String: NSAppleScript] = [:]

    /// How long any one accessibility question may take. Every call below is an IPC round trip
    /// into a browser that may be busy rendering, made from the main thread once a second — the
    /// system default of six seconds would freeze the app behind a wedged tab.
    private static let axTimeout: Float = 0.25
    /// How much of the accessibility tree the search may look at before giving up.
    ///
    /// The web area sits a handful of levels under the window and the whole of the DOM sits
    /// under the web area, which is why the search is breadth-first: depth-first would descend
    /// into the page and never come back. The budget is what makes that guarantee independent of
    /// how any one browser happens to be built.
    private static let maxNodes = 400
    private static let maxDepth = 12

    /// What macOS is currently letting the app see. Asked once a tick and published to
    /// `AppState`, which turns the menu bar yellow while nothing can be seen at all.
    var access: BrowserAccess {
        BrowserAccess(
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            automationRefused: automationRefused.sorted()
        )
    }

    /// The page in front, or `nil` when there is none — the frontmost app is not a browser, it
    /// is showing nothing a rule could be about, or every way of asking it has just been refused.
    func frontmostPage() -> Page? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              let browser = Browsers.browser(forBundleID: bundleID)
        else { return nil }
        return page(of: browser, in: app)
    }

    /// The same question put to **one named browser**, whether or not anybody is looking at it.
    ///
    /// Neither route cares who is frontmost. `tell application id … to get URL of active tab of
    /// front window` addresses the browser directly, and the accessibility walk starts from that
    /// process's own focused window — so a browser sitting behind the settings window answers
    /// exactly as it would in front.
    ///
    /// It exists because of the one thing that happens while there is deliberately no browser in
    /// front: a configuration edit, which is made in a window of ours. It needs to know what a
    /// parked tab is showing *now* rather than what it was showing when the poll last had a look.
    /// See `LastBlockPage`.
    ///
    /// Not on the 1 Hz path, deliberately: this is one extra Apple event on a user's action, and
    /// polling every running browser once a second is a different and much worse app.
    func page(ofBrowserWith bundleID: String) -> Page? {
        guard let browser = Browsers.browser(forBundleID: bundleID),
              let app = NSRunningApplication
                  .runningApplications(withBundleIdentifier: bundleID).first,
              !app.isTerminated
        else { return nil }
        return page(of: browser, in: app)
    }

    private func page(of browser: KnownBrowser, in app: NSRunningApplication) -> Page? {
        let now = Date()
        for strategy in memory.plan(for: browser, now: now) {
            switch read(strategy, of: browser, pid: app.processIdentifier) {
            case .address(let text, let tabID):
                note(success: strategy, of: browser)
                return BrowserAddress.sighting(from: text, blockPage: Self.blockPage).map {
                    Page(sighting: $0, address: text, tabID: tabID, known: browser, running: app)
                }
            case .unavailable:
                // The browser answered and there is nothing to read: no window, a blank tab. The
                // route works, so it is not rested — and the other route is not tried, because
                // it would find the same empty window.
                note(success: strategy, of: browser)
                return nil
            case .refused:
                if strategy == .appleScript { automationRefused.insert(browser.name) }
                memory.failed(strategy, for: browser.bundleID, now: now)
            }
        }
        return nil
    }

    private func note(success strategy: KnownBrowser.Strategy, of browser: KnownBrowser) {
        memory.succeeded(strategy, for: browser.bundleID)
        if strategy == .appleScript { automationRefused.remove(browser.name) }
    }

    private func read(
        _ strategy: KnownBrowser.Strategy, of browser: KnownBrowser, pid: pid_t
    ) -> BrowserAddress.Reading {
        switch strategy {
        case .appleScript: return runScript(for: browser)
        case .accessibility: return readAccessibility(pid: pid)
        }
    }

    // MARK: - AppleScript

    private func runScript(for browser: KnownBrowser) -> BrowserAddress.Reading {
        guard let script = compiledScript(for: browser) else { return .refused }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            return BrowserAddress.reading(forAppleScriptError: number)
        }
        // An event that succeeded with no string is a browser saying it has no address, not one
        // refusing to answer — a new tab in Safari does exactly this.
        guard let text = result.stringValue else { return .unavailable }
        // Split back into the address and the tab that served it, by the browser that was asked:
        // only the ones whose dictionary has an identity were asked for one. See
        // `KnownBrowser.reading(fromScriptResult:)`.
        return browser.reading(fromScriptResult: text)
    }

    private func compiledScript(for browser: KnownBrowser) -> NSAppleScript? {
        if let existing = scripts[browser.bundleID] { return existing }
        guard let source = browser.appleScriptSource,
              let script = NSAppleScript(source: source)
        else { return nil }
        scripts[browser.bundleID] = script
        return script
    }

    // MARK: - Accessibility

    private func readAccessibility(pid: pid_t) -> BrowserAddress.Reading {
        // The non-prompting variant, deliberately. `AXIsProcessTrustedWithOptions` with the
        // prompt option would put a system dialog on screen from a 1 Hz timer.
        guard AXIsProcessTrusted() else { return .refused }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        // Not a wasted call. A browser does not build an accessibility tree for nobody — it costs
        // real memory and time — so it waits to be asked. Firefox's answer to being asked is
        // reading the role off its application element (bug 1845364, which replaced the older
        // `AXEnhancedUserInterface` handshake precisely because *setting* an attribute on another
        // app's window has side effects nobody wants). So the role is read first, deliberately,
        // and the result thrown away: it is the knock on the door.
        _ = string(app, kAXRoleAttribute)
        guard let window = child(of: app, kAXFocusedWindowAttribute)
                ?? child(of: app, kAXMainWindowAttribute)
        else { return .unavailable }
        // No tab identity on this route, and there is none to be had: the tree names a web area,
        // not a tab the browser has a word for. Firefox is read this way always, and a Chromium
        // browser whose Automation was refused falls back to it — both key by browser alone.
        if let area = firstElement(under: window, role: "AXWebArea"), let url = url(of: area) {
            return .address(url, tabID: nil)
        }
        return addressField(under: window)
    }

    /// The address bar, read as text, for a window whose page exposes no web area at all.
    ///
    /// A weaker source and treated as one: what is in the bar is what the browser is *showing*,
    /// which is a search phrase while the user types and a trimmed address the rest of the time.
    /// `BrowserAddress.page(from:)` is what keeps a half-typed word from being read as a visit.
    private func addressField(under window: AXUIElement) -> BrowserAddress.Reading {
        guard let field = firstElement(under: window, role: kAXTextFieldRole),
              let text = string(field, kAXValueAttribute)
        else { return .unavailable }
        return .address(text, tabID: nil)
    }

    /// Breadth-first, budgeted. See `maxNodes`.
    private func firstElement(under root: AXUIElement, role: String) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var seen = 0
        while !queue.isEmpty, seen < Self.maxNodes {
            let next = queue.removeFirst()
            seen += 1
            if string(next.element, kAXRoleAttribute) == role { return next.element }
            guard next.depth < Self.maxDepth else { continue }
            queue.append(contentsOf: children(of: next.element).map { ($0, next.depth + 1) })
        }
        return nil
    }

    // MARK: - The accessibility API, as three readers

    private func child(of element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copyValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    /// `AXURL` as text. Safari and Firefox answer with a URL object; a browser that answers with
    /// a plain string is read too rather than dropped on a type check.
    private func url(of element: AXUIElement) -> String? {
        guard let value = copyValue(element, kAXURLAttribute) else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    private func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}
