import SandglassCore
import Foundation

// The browsers this app knows about, and everything about reading an address out of one that is
// arithmetic on strings rather than a call into macOS. It lives here, next to no UI framework at
// all, for the reason `ActivationGuards` does: the rules that decide whether a pause screen
// appears over a web page deserve a test rather than a look.
//
// The list is the one place a browser bundle id is written down. `AppScanner` leaves the same
// six out of the app picker — blocking a browser would block the web whole — and a second copy
// of the list is how those two would eventually disagree.

/// One browser, and how to ask it what page it is showing.
public struct KnownBrowser: Equatable, Sendable {

    /// The two ways of asking. Both need the user's consent, and they are not the same consent.
    public enum Strategy: String, Equatable, Sendable, CaseIterable {
        /// One line into the browser's own scripting dictionary. Exact — it answers with the
        /// address, not with what the address bar happens to be displaying — and consented to
        /// once per browser, under Privacy → Automation.
        case appleScript
        /// The accessibility tree, read for the web area's own `AXURL`. One consent for every
        /// browser at once, under Privacy → Accessibility, and the only route into Firefox.
        case accessibility
    }

    public let bundleID: String
    /// What the settings screen calls it.
    public let name: String
    /// What this browser's dictionary calls the tab in front: `current tab` in Safari, `active
    /// tab` in everything built on Chromium. `nil` for a browser whose dictionary cannot answer
    /// the question at all — which is Firefox, and is why the accessibility route exists.
    public let tabTerm: String?
    /// What this browser's dictionary calls a tab's own identity, or `nil` for one that has no
    /// such thing.
    ///
    /// **The one fact the whole tab-keyed path rests on**, so it is written down per browser
    /// rather than assumed for all of them. Chromium's `tab` class carries `id` — "Unique ID of
    /// the tab", read-only text — and Arc's carries the same. **Safari's does not**: its `tab` has
    /// `source`, `URL`, `index`, `text`, `visible` and `name`, and not one of those is an identity.
    ///
    /// `index` is the near miss, and taking it would be worse than having nothing. It is the
    /// position of the tab, left to right, so it changes when tabs are reordered or one to the left
    /// is closed — and the tab that slides into position 2 would inherit the wait the old one
    /// served and spend it with nobody pressing anything, which is the exact fault this keying
    /// exists to close. Safari's hidden `pid` is the same trap wearing a better name: it is the
    /// WebContent process behind the tab, and Safari shares one process between tabs on the same
    /// site — so it is identical for precisely the two tabs that have to be told apart.
    ///
    /// So Safari and Firefox key by browser alone, as everything did before, and the ones that can
    /// say which tab they mean do.
    public let tabIDTerm: String?

    public init(bundleID: String, name: String, tabTerm: String?, tabIDTerm: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.tabTerm = tabTerm
        self.tabIDTerm = tabIDTerm
    }

    /// The strategies worth trying, in the order they are worth trying in. AppleScript first
    /// where there is one: it answers with the address itself, where accessibility answers with
    /// whatever the page's web area is currently reporting.
    public var strategies: [Strategy] {
        tabTerm == nil ? [.accessibility] : [.appleScript, .accessibility]
    }

    /// The AppleScript that asks this browser what it is showing, or `nil` when there is nothing to
    /// ask. One line for a browser that can only name the address, a few more for one that can also
    /// name the tab.
    ///
    /// Four details, each of which is load-bearing:
    ///
    /// - **`application id`, not `application "Name"`.** A browser the user renamed, or one whose
    ///   name is localised, still answers to its bundle id — and a `tell application "Arc"` on a
    ///   Mac with no Arc opens a "where is Arc?" chooser, which is the last thing a background
    ///   app should be able to do.
    /// - **`with timeout of 1 second`.** An Apple event waits two minutes by default, and this is
    ///   sent from the main thread once a second: a wedged browser would take the whole app down
    ///   with it. One second is a hundred times longer than a healthy answer takes, and a timeout
    ///   is reported as a refusal, which rests the strategy — see `BrowserStrategyMemory`.
    /// - **No `activate`, no window creation.** The script reads and nothing else. `front window`
    ///   on a browser with no windows is an error, and being an error is correct: there is no
    ///   page in front to have an opinion about.
    /// - **The tab's identity travels with the address**, for the browsers that have one. It is
    ///   the same script, sent on the same tick, so keying a wait by the tab that served it costs
    ///   one line rather than a second way of asking. Two details of that line matter. It is
    ///   wrapped in `try`, so a browser whose dictionary turns out not to carry `id` after all
    ///   answers with the address and an empty identity instead of erroring — degrading to the old
    ///   keying rather than going blind, which for a Chromium fork nobody here can run is the
    ///   difference between a narrower fix and a browser that stops being watched. And the
    ///   identity is written **first**, so the address keeps every character after the first
    ///   newline: it is the value that could carry anything.
    public var appleScriptSource: String? {
        guard let tabTerm else { return nil }
        guard let tabIDTerm else {
            return """
                with timeout of 1 second
                tell application id "\(bundleID)" to get URL of \(tabTerm) of front window
                end timeout
                """
        }
        return """
            with timeout of 1 second
            tell application id "\(bundleID)"
                set tabIdentity to ""
                try
                    set tabIdentity to (\(tabIDTerm) of \(tabTerm) of front window) as text
                end try
                return tabIdentity & linefeed & ((URL of \(tabTerm) of front window) as text)
            end tell
            end timeout
            """
    }

    /// What this browser's script said, as the two things it carries.
    ///
    /// A browser with no `tabIDTerm` was sent the one-line script and answered with the address
    /// whole, newlines and all — so it is read whole. One that was asked for both answers with the
    /// identity, a newline, and then the address; an empty identity is the `try` above having
    /// swallowed a property the browser does not have, and is reported as no identity at all.
    ///
    /// **The two reads are two Apple events**, microseconds apart, and a tab switched between them
    /// pairs one tab's identity with another tab's address. The cost of that is one tick: nothing
    /// is spent on a mispairing — a wait promised under a key the next poll does not produce is
    /// never sighted and never claimed — and the tab in front is decided on again a second later.
    public func reading(fromScriptResult text: String) -> BrowserAddress.Reading {
        guard tabIDTerm != nil, let newline = text.firstIndex(of: "\n") else {
            return .address(text, tabID: nil)
        }
        let identity = String(text[..<newline])
        return .address(
            String(text[text.index(after: newline)...]), tabID: identity.isEmpty ? nil : identity
        )
    }

    /// Whether this browser's tab can be sent somewhere, as well as read.
    ///
    /// The same dictionary answers both, so the answer is the same one: five browsers can, and
    /// **Firefox cannot**. We read Firefox through the accessibility tree, and there is no sound
    /// way to *write* its address bar the same way — typing into another app's text field is not
    /// something this app is going to do. So Firefox keeps the overlay, as a case of its own
    /// rather than as something that falls through.
    public var canNavigate: Bool { tabTerm != nil }

    /// The one line that sends the tab in front somewhere else, or `nil` for a browser that has
    /// no way of being told.
    ///
    /// **The tab the user opened is the tab that moves.** `set URL of <the tab in front>` navigates
    /// in place; `open location` and `tell application to open` would leave a new tab behind every
    /// time, which is RescueTime's reported failure — a user whose tab bar filled up because every
    /// switch back opened another window. The same line brings it back afterwards.
    ///
    /// The timeout and `application id` are here for the reasons `appleScriptSource` documents:
    /// an Apple event otherwise waits two minutes, and a name would open a "where is Arc?" chooser
    /// on a Mac with no Arc.
    public func navigationScriptSource(to address: String) -> String? {
        guard let tabTerm else { return nil }
        let quoted = Self.appleScriptString(address)
        return """
            with timeout of 1 second
            tell application id "\(bundleID)" to set URL of \(tabTerm) of front window to \(quoted)
            end timeout
            """
    }

    /// An address as an AppleScript string literal.
    ///
    /// The addresses this app builds are percent-encoded and can hold neither character, so this
    /// guards a case that should not arise — which is exactly when it is worth having: the address
    /// is assembled from a page title and a URL the browser handed over, and a quote reaching the
    /// script would end the literal and leave the rest of it as code.
    public static func appleScriptString(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Every browser this app knows how to read, and the lookups over them.
public enum Browsers {

    /// The six, in the order the settings screen would list them.
    ///
    /// Chromium's four share one dictionary, which is why they share one term. Arc is in the
    /// family — it answers `active tab of front window` like the rest — and Firefox is not in
    /// any family: it ships no scripting dictionary for its tabs, so the accessibility tree is
    /// the only thing it will tell anybody.
    ///
    /// **Five can name the tab in front and four can say which tab it is**, which is what the
    /// second term is. Chrome's and Arc's dictionaries were read off the copies installed on this
    /// Mac: both declare `tab` with an `id` — "Unique ID of the tab" — and Safari's declares no
    /// such property at all. Brave and Edge are Chromium and ship Chrome's scripting dictionary,
    /// which is an inference rather than a reading, and the `try` in `appleScriptSource` is what
    /// makes a wrong inference cost the narrower keying rather than the browser.
    public static let all: [KnownBrowser] = [
        KnownBrowser(bundleID: "com.apple.Safari", name: "Safari", tabTerm: "current tab"),
        KnownBrowser(
            bundleID: "com.google.Chrome", name: "Chrome", tabTerm: "active tab", tabIDTerm: "id"
        ),
        KnownBrowser(
            bundleID: "company.thebrowser.Browser", name: "Arc", tabTerm: "active tab",
            tabIDTerm: "id"
        ),
        KnownBrowser(
            bundleID: "com.brave.Browser", name: "Brave", tabTerm: "active tab", tabIDTerm: "id"
        ),
        KnownBrowser(
            bundleID: "com.microsoft.edgemac", name: "Edge", tabTerm: "active tab", tabIDTerm: "id"
        ),
        KnownBrowser(bundleID: "org.mozilla.firefox", name: "Firefox", tabTerm: nil),
    ]

    /// The same set as bundle ids, for the callers that only need to know "is this a browser" —
    /// the app picker, which leaves all six out of the list of blockable apps.
    public static let bundleIDs: Set<String> = Set(all.map(\.bundleID))

    public static func browser(forBundleID bundleID: String) -> KnownBrowser? {
        all.first { $0.bundleID == bundleID }
    }
}

/// What the browser in front is showing, as far as this app is concerned.
///
/// Two cases, because a tab sitting on Sandglass's own block page is not a page the engine has any
/// opinion about — it is a block already in force, and what it needs is watching rather than
/// deciding. Reading it as an ordinary address would answer `nil` and lose the target with it:
/// `BrowserAddress.page(from:)` throws away every `file:` URL by design, since nothing anyone
/// blocks lives at one.
public enum BrowserSighting: Equatable, Sendable {
    /// A page the engine can decide about — normalized exactly as `RuleMatcher` compares it.
    case page(String)
    /// Our own block page, and everything it is carrying.
    case blockPage(BlockPage.Query)
}

/// Turning what a browser said into the string the engine decides on — or into nothing.
public enum BrowserAddress {

    /// What the browser in front is showing, or `nil` when it is nothing anybody could block.
    ///
    /// Our own page is looked for **first**, and it has to be: the block page is a `file:` URL and
    /// `page(from:)` drops every one of those, so asking in the other order would leave a blocked
    /// tab with no way of ever coming back.
    ///
    /// `page` is `nil` for a build with no resources — a raw SwiftPM binary — and then there is no
    /// block page to recognise, which is the honest answer for a run that cannot navigate to one.
    public static func sighting(from text: String, blockPage page: URL?) -> BrowserSighting? {
        if let page, let query = BlockPage.query(of: text, page: page) {
            return .blockPage(query)
        }
        return self.page(from: text).map(BrowserSighting.page)
    }

    /// What came back from one attempt at reading a browser.
    ///
    /// Three cases rather than an optional, because "the browser has nothing to show" and "the
    /// browser would not tell us" are opposite facts about the same absent answer. The first is
    /// a new tab page and is over in a second; the second is a permission that has not been
    /// granted, and retrying it once a second forever is how a blocker turns into a nuisance.
    public enum Reading: Equatable, Sendable {
        /// The browser answered with an address, and — where its dictionary carries one — the
        /// identity of the tab that served it. Not necessarily a page — see `page(from:)`.
        ///
        /// `tabID` is `nil` for Safari and Firefox, whose tabs have no identity to report, and for
        /// every reading that came off the accessibility tree rather than out of a dictionary.
        /// Everything downstream keys by the pair, so `nil` is one key per browser, which is
        /// exactly what the whole app did before any of them could say more.
        case address(String, tabID: String?)
        /// It answered, and the answer is that there is nothing to read: no window, a blank tab,
        /// a page that exposes no address. Nothing is wrong, so nothing is rested.
        case unavailable
        /// It would not answer: consent has not been given, the app is not scriptable, or it did
        /// not reply inside the timeout. The strategy rests — see `BrowserStrategyMemory`.
        case refused
    }

    /// The address as the engine expects it — `host/path`, lowercased, no scheme, no `www.`, no
    /// query — or `nil` when what the browser said is not a page anybody could block.
    ///
    /// **The engine's own normalizer**, which is the whole point:
    /// `RuleMatcher.normalize(url:)` is what `RulesEngine.decision(url:)` and
    /// `WebResolver.match` compare against, and a second spelling of "the same page" here would
    /// mean what a browser says and what a rule matches could drift apart.
    ///
    /// What is thrown away, and why each one has to be:
    ///
    /// - **Anything with a space in it.** The address-bar fallback below reads whatever the user
    ///   is typing, and a half-typed search is not a visit. It matters more than it looks: a
    ///   `websiteOrText` rule matches anywhere in the string, so "youtube" typed into a search
    ///   box would otherwise raise the pause screen for the YouTube group.
    /// - **A host with no dot in it.** `about:blank`, `localhost`, and the first four letters of
    ///   a domain somebody is still typing. Nothing anyone blocks lives at a bare name.
    /// - **A host that is only a suffix**, `.com`, which is what a domain being typed backwards
    ///   into a search box looks like.
    /// - **Anything with no host at all**, which is what `file://` and every internal page
    ///   normalizes down to.
    ///
    /// A trailing dot needs no guard of its own: `RuleMatcher` strips it, because a fully
    /// qualified `youtube.com.` is the same site as `youtube.com` and has to match the same rule.
    public static func page(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let normalized = RuleMatcher.normalize(url: trimmed)
        let host = RuleMatcher.host(of: normalized)
        guard host.contains("."), !host.hasPrefix(".") else { return nil }
        return normalized
    }

    /// What an AppleScript error number means for the strategy that produced it.
    ///
    /// Only two answers matter, and getting them the wrong way round is a real fault each way. A
    /// browser sitting with no windows answers `-1728` every second, and resting the strategy
    /// over it would leave the app blind for minutes after the user opened a window again. A
    /// refused consent answers `-1743` every second, and *not* resting over that is an app that
    /// asks the system for something it has been told it may not have, once a second, forever.
    ///
    /// `-1712` is the timeout the script sets for itself, and it is read as a refusal on purpose:
    /// a browser that did not answer in a second is one this app must stop sending to.
    public static func reading(forAppleScriptError number: Int) -> Reading {
        switch number {
        case -1728, -1719, -1700:
            // No front window, an empty index, a value that would not coerce. All of them mean
            // the browser answered and there was nothing there.
            return .unavailable
        default:
            // -1743 (not permitted), -600 (not running), -1712 (timed out), -2700 (script
            // failed), and anything a browser update invents. Rest, and try the other route.
            return .refused
        }
    }
}
