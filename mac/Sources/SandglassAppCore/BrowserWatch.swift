import Foundation

// The bookkeeping the browser watcher runs on: which way of asking worked last and which ones
// are being rested, which page the user has already been let through to, and what macOS is
// currently letting the app see. All three are values with no clock of their own, so the whole
// of each rule is a function of its arguments and can be checked as arithmetic.

/// Which tab a reading came from: the browser, and the browser's own name for the tab when it has
/// one.
///
/// **The unit a wait belongs to.** A wait used to be keyed by the browser and the page, because a
/// browser reports the address of the tab in front and — it was assumed — never says which tab that
/// is. Four of the six do say: Chromium's `tab` class carries an `id` and so does Arc's, and it
/// comes back in the same script that already fetches the address. Two do not, and for them this is
/// a browser with a `nil` beside it, which keys exactly as everything did before.
///
/// So the same type covers both, and a fallback is a value rather than a branch: `BrowserTab(chrome,
/// nil)` is one key for the whole of Chrome, and `BrowserTab(chrome, "42")` is one key for one tab.
///
/// **What it deliberately does not carry is the window.** A Chromium tab id is unique across the
/// browser, not within its window, so pairing the window's id with it would buy nothing — and it
/// would cost a real thing: a tab dragged out into a window of its own mid-countdown would look
/// like a tab nobody had promised anything, and the wait the user was serving would restart. That
/// the id really is unique across windows is confirmed by hand in a browser rather than asserted
/// here.
public struct BrowserTab: Hashable, Sendable {
    public let browserID: String
    /// What the browser calls this tab, or `nil` when it has no way of saying.
    public let tabID: String?

    public init(browserID: String, tabID: String?) {
        self.browserID = browserID
        self.tabID = tabID
    }
}

/// Which way of asking each browser worked, and which ones are resting after a refusal.
///
/// Two jobs, and they are the same job from two sides. **Preference**: the strategy that answered
/// last is tried first next time, so a Mac where Automation was granted for Chrome does not walk
/// through the accessibility tree once a second for no reason. **Back-off**: a strategy that was
/// refused is not asked again immediately, because the poll runs at 1 Hz and a permission that
/// has not been granted will not have been granted a second later either.
///
/// The rest grows with each consecutive refusal and is reset by the first success. It is capped,
/// deliberately: a strategy that rested forever would be an app that quietly stopped protecting
/// websites and never tried again, which is exactly the failure this app is supposed not to have.
public struct BrowserStrategyMemory: Equatable, Sendable {

    /// How long a strategy rests after its first, second, third and any later refusal. Five
    /// seconds is long enough that a refusal costs one attempt rather than sixty; five minutes is
    /// short enough that granting the permission is noticed while the user is still in Settings.
    public static let backoffSeconds: [TimeInterval] = [5, 15, 60, 300]

    private struct Key: Hashable {
        let bundleID: String
        let strategy: KnownBrowser.Strategy
    }

    private struct Rest: Equatable {
        var until: Date
        /// How many refusals in a row, which is the index into `backoffSeconds`.
        var strikes: Int
    }

    private var rests: [Key: Rest] = [:]
    /// The strategy that last answered, per browser.
    private var preferred: [String: KnownBrowser.Strategy] = [:]

    public init() {}

    /// The strategies to try for this browser right now, best first, resting ones left out.
    ///
    /// Empty is a real answer and means "everything this browser could be asked has just been
    /// refused" — the caller reports no page rather than guessing at one.
    public func plan(for browser: KnownBrowser, now: Date) -> [KnownBrowser.Strategy] {
        var order = browser.strategies
        if let first = preferred[browser.bundleID], let at = order.firstIndex(of: first) {
            order.remove(at: at)
            order.insert(first, at: 0)
        }
        return order.filter { !isResting($0, for: browser.bundleID, now: now) }
    }

    public func isResting(
        _ strategy: KnownBrowser.Strategy, for bundleID: String, now: Date
    ) -> Bool {
        guard let rest = rests[Key(bundleID: bundleID, strategy: strategy)] else { return false }
        return now < rest.until
    }

    /// This strategy answered. It becomes the preferred one and its rest is forgotten, strikes
    /// and all — a permission that has just been granted must not still be serving out the
    /// back-off its refusals earned.
    public mutating func succeeded(_ strategy: KnownBrowser.Strategy, for bundleID: String) {
        preferred[bundleID] = strategy
        rests.removeValue(forKey: Key(bundleID: bundleID, strategy: strategy))
    }

    /// This strategy was refused. It rests, and stops being the preferred one so the other route
    /// is tried first next time rather than after it.
    public mutating func failed(
        _ strategy: KnownBrowser.Strategy, for bundleID: String, now: Date
    ) {
        if preferred[bundleID] == strategy { preferred.removeValue(forKey: bundleID) }
        let key = Key(bundleID: bundleID, strategy: strategy)
        let strikes = min((rests[key]?.strikes ?? 0) + 1, Self.backoffSeconds.count)
        rests[key] = Rest(
            until: now.addingTimeInterval(Self.backoffSeconds[strikes - 1]), strikes: strikes
        )
    }
}

/// The page the user has already been let through to.
///
/// The web counterpart of `ActivationGrace`, and it exists for the same reason: the blocker
/// causes something that would otherwise look exactly like the user walking back into a block.
/// An open granted on a gentle group starts no session, so one second later the engine says
/// `pause` about the very page the user just paid for — and the pause screen would come back,
/// and again, once a second, forever.
///
/// The unit is the address rather than a stretch of time, because that is the unit the user
/// experiences: they cleared *this page*, and going somewhere else is a new decision. That also
/// makes the whole thing one comparison, with no clock to get wrong.
///
/// **One page per browser.** It was a single slot keyed by neither browser nor tab, so an open
/// spent in Chrome answered "already paid for" about the same address in Safari: never blocked,
/// never waited, and it stayed that way until the poll happened to read a different page.
///
/// **And deliberately not one page per tab**, which is the whole difference between this and
/// `EarnedOpens` beside it. A wait is friction and belongs to the tab that sat through it: nothing
/// may open without somebody pressing the button that was served. This is the other side of that
/// press — an open the user has already spent — and an open is not a per-tab thing. It buys the
/// page, so a second tab on the page just paid for is quiet too, and a tab parked on a block page
/// for it goes home rather than counting down again for something already bought. Narrowing this
/// to the tab would charge a second wait for the same page in the same visit, which is the
/// punishing direction and not what the press bought.
///
/// What stops it from suppressing a block the user has not paid for is the caller: a decision of
/// `allowed` or `notManaged` calls `forget(in:)`, so a session that runs out raises the screen on
/// the same page the memory would otherwise have kept quiet. See `AppBlocker.pollFrontmostPage`.
public struct ClearedPage: Equatable, Sendable {

    /// How long the memory survives with no page in front of it at all.
    ///
    /// It cannot be zero, and that is the whole reason this is not a plain string. Granting an
    /// open hides the overlay and brings the browser back — an activation this app asked for and
    /// macOS performs when it gets round to it — so a poll landing in that gap sees no browser in
    /// front, and forgetting there would raise the screen the open had just cleared.
    ///
    /// And it cannot be unbounded: a tab closed and reopened an hour later is a new visit, and a
    /// memory with no way of expiring would be a page permanently exempt from its own group.
    public static let settleSeconds: TimeInterval = 3

    /// The page each browser was let through to.
    private var urls: [String: String] = [:]
    /// Since when there has been nothing in front, or `nil` while there is.
    private var emptySince: Date?

    public init() {}

    /// The user spent an open on this page in this browser. Nothing is shown over it until they
    /// leave.
    public mutating func clear(_ url: String, in browserID: String) {
        urls[browserID] = url
        emptySince = nil
    }

    /// Whether the screen should stay down for this page in this browser. Any other page forgets
    /// that browser's last one, so coming back to a cleared page is a fresh visit and gets a fresh
    /// screen — and one browser going somewhere else says nothing about another.
    public mutating func isCleared(_ url: String, in browserID: String) -> Bool {
        emptySince = nil
        guard urls[browserID] == url else {
            urls.removeValue(forKey: browserID)
            return false
        }
        return true
    }

    /// The same question, asked without answering it for the browser.
    ///
    /// What a tab parked on the block page needs: whether the page it is about has already been
    /// paid for. Asking must not disturb what that browser is remembered as having been let
    /// through to — the tab being asked about is not the tab the open was spent in — which is the
    /// whole difference from `isCleared` above.
    public func holds(_ url: String, in browserID: String) -> Bool {
        urls[browserID] == url
    }

    /// Nothing is in front to have an opinion about. Survives a short gap and not a long one —
    /// see `settleSeconds`.
    public mutating func noPageInFront(now: Date) {
        guard !urls.isEmpty else { return }
        guard let emptySince else {
            self.emptySince = now
            return
        }
        guard now.timeIntervalSince(emptySince) >= Self.settleSeconds else { return }
        urls.removeAll()
        self.emptySince = nil
    }

    /// Whatever this browser had cleared is history: the reason nothing is showing belongs to the
    /// engine now, or the user turned away from the page rather than paying for it.
    public mutating func forget(in browserID: String) {
        urls.removeValue(forKey: browserID)
        emptySince = nil
    }
}

/// The tab this app has just sent to its own block page.
///
/// A browser does not report a navigation the instant it is asked for one, and the poll comes
/// round once a second. Without this, a reading that still names the old address would be decided
/// on again and the tab sent to a *second* block page — a fresh countdown over the one already
/// running, which from where the user is sitting is a wait that restarts itself.
///
/// **It holds the address the tab was on, not the page that address belongs to**, and the
/// difference is the whole of what this may suppress. It used to hold the normalized target, which
/// is a *page* — so for three seconds after one tab was sent away, every tab on that page in that
/// browser was walked past without being decided on at all. A second tab on `?v=B` is not the
/// navigation this app is waiting on: it is a page nobody has been shown a block for, and it gets
/// one now. The guard exists to stop the app fighting its own navigation, so it suppresses the
/// re-send and nothing else.
///
/// What was left after that was a second tab on the *same* address, and it was left because the
/// record named a browser rather than a tab: for three seconds, an identical address anywhere in
/// that browser was walked past. **It is keyed by the tab now** — see `BrowserTab` — so the guard
/// covers the one tab that was actually asked to move, and a sibling tab on the identical address
/// is decided on at once. In Safari and Firefox, whose tabs have no identity, the key is the
/// browser again and those three seconds remain.
///
/// Short, because it is only ever covering the gap between asking a browser to go somewhere and its
/// saying that it has.
public struct SentToBlockPage: Equatable, Sendable {

    /// How long a navigation is given to show up in what the browser reports. Generous against a
    /// browser busy rendering, and far shorter than any countdown it could hide.
    public static let settleSeconds: TimeInterval = 3

    private var tab: BrowserTab?
    private var address: String?
    private var at: Date?

    public init() {}

    /// `address` is what the browser reported the tab was on when it was told to leave — the whole
    /// address, which is the only thing a stale reading of that same tab will match.
    public mutating func record(tab: BrowserTab, from address: String, now: Date) {
        self.tab = tab
        self.address = address
        at = now
    }

    /// Whether this tab has just been sent away from this exact address and may not be sent again
    /// while it catches up.
    public func isSettling(tab: BrowserTab, address: String, now: Date) -> Bool {
        guard self.tab == tab, self.address == address, let at else { return false }
        return now.timeIntervalSince(at) < Self.settleSeconds
    }

    /// The navigation arrived, or the user went somewhere else entirely. Either way there is
    /// nothing left to wait for.
    public mutating func forget() {
        tab = nil
        address = nil
        at = nil
    }
}

/// What macOS is currently letting the app see of the browsers.
///
/// Published by the app layer once a second and read in two places: the menu bar, which turns
/// yellow while website blocking is switched on and cannot see anything, and the settings row
/// that offers the way to fix it.
///
/// The two permissions are not symmetrical, and the type says so. Accessibility can be asked
/// about without prompting (`AXIsProcessTrusted`), so it is a fact — with a third answer for the
/// moment before anybody has asked. Automation cannot be asked about cheaply at all, so the only
/// honest thing to report is which browsers have actually refused this run: an empty list means
/// "nothing has said no", not "everything has said yes".
public struct BrowserAccess: Equatable, Sendable {

    public enum Accessibility: Equatable, Sendable {
        /// Nobody has looked yet: a headless run, or the instant between `AppState.init` and the
        /// blocker starting. Warning here would be claiming a permission is missing on the
        /// strength of not having checked.
        case unknown
        case granted
        case denied
    }

    public var accessibility: Accessibility
    /// Browsers whose AppleScript was refused this run, by the name the settings screen uses.
    /// Sorted, so the line does not reshuffle itself between ticks.
    public var automationRefused: [String]

    public init(accessibility: Accessibility, automationRefused: [String] = []) {
        self.accessibility = accessibility
        self.automationRefused = automationRefused
    }

    /// What every `AppState` starts with. The app layer replaces it during launch, before the
    /// run loop turns and before any icon is painted.
    public static let unknown = BrowserAccess(accessibility: .unknown)
}

/// The two sentences the settings page says about browser permissions.
///
/// Here rather than in the view because they are the app being honest about what it can and
/// cannot see, which is the one claim it must never get wrong — and because a sentence that
/// changes with a count is arithmetic with words attached rather than layout.
///
/// Both are short on purpose. They are the live state under a settings row, and a row carries one
/// line of that at most; what either of them *means* is in the row's own info button.
extension BrowserAccess {

    /// Whether the blocking works at all right now. `unknown` is nobody having looked yet, and is
    /// reported as the good case: warning on the strength of not having checked is the same lie in
    /// the other direction.
    ///
    /// **Both halves of what the grant buys**, because it stopped being only about the web. It
    /// also decides whether a blocked application can be taken out of its fullscreen Space — and
    /// without that it answers `hide()` with `true` and stays exactly where it is, which is the
    /// most invisible way a block can fail.
    ///
    /// It named Firefox once, as the browser that cannot be read any other way. True, and not this
    /// row's business: a settings screen that lists which browsers fail how is a screen about
    /// browsers rather than about a permission.
    public var accessibilityLine: String {
        accessibility == .denied
            ? "Not granted. Fullscreen apps stay put and the address bar can't be read."
            : "Granted. Sandglass can hide blocked apps and read the address bar."
    }

    /// What to say about the direct, per-browser route — and only when there is something to say.
    ///
    /// `nil` is the ordinary case: nothing has refused, and a row explaining a permission that is
    /// not in the way is a row about nothing. macOS answers "is Automation granted" only by being
    /// asked to do the thing, so this reports what the app has actually been told rather than
    /// guessing, and a browser that refused is still read through Accessibility — which is why
    /// this is a note and never a warning about protection being off.
    public var automationLine: String? {
        guard !automationRefused.isEmpty else { return nil }
        return "\(Self.naming(automationRefused)) refused direct reading. Blocking still works."
    }

    /// "Chrome", "Chrome and Safari", "Chrome, Safari and Arc" — rather than the comma-separated
    /// run the line used to open with, which read as a list of browsers instead of a sentence.
    public static func naming(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return "\(names.dropLast().joined(separator: ", ")) and \(last)"
    }
}
