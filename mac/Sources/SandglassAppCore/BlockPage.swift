import SandglassCore
import Foundation

/// The local page a blocked tab is navigated to, and the query that tells it what to say.
///
/// **Navigating away rather than covering up.** An overlay over a browser leaves the video playing
/// and the audio running behind it, and the only way out of it — "Back to work" — hid the whole
/// browser, every innocent tab with it. Sending the one tab somewhere else stops the media, leaves
/// every other tab alone, and needs nothing remembered anywhere: the address it interrupted rides
/// in the query string and comes back out of it.
///
/// **No local HTTP server.** The page is a file in the app bundle and is opened as one. Focus runs
/// a server on ports 8919–8925 for exactly this job and does not need to; a file URL in the
/// bundle does it with nothing listening:
///
/// ```
/// file:///Applications/Sandglass.app/Contents/Resources/block.html?target=https%3A%2F%2Fwww.instagram.com%2F&…
/// ```
///
/// **And the button is an ordinary link.** It carries no token, tells this app nothing and asks the
/// browser for nothing unusual: it is an `<a href>` at the site, and pressing it is the browser
/// doing what browsers do. What the app does is get out of the way — on the next poll it sees the
/// target, finds that the wait it imposed has been served, and does not block it. See `EarnedOpens`.
///
/// Two mechanisms came before it and both failed in the same place, which is the handoff. An
/// `sandglass://` link put the browser's own "open Sandglass?" confirmation in front of the one
/// control that exists to be the way through, and in practice the press did nothing at all. The
/// page rewriting its own address so the poll could read a token off it got as far as saying
/// "Opening…" and no further. Neither is a thing a link can fail at: there is no message, no
/// second reader, and no second navigation to get the order of wrong.
///
/// Everything here is arithmetic on strings, which is why it lives beside no UI framework at all:
/// a target that itself carries a query string and a fragment has to survive the round trip
/// exactly, and that deserves a test rather than a look.
public enum BlockPage {

    /// The file in `Contents/Resources`. `scripts/build-app.sh` copies it there.
    public static let fileName = "block.html"

    /// Which of the page's two states to draw. It is the app that decides, never the page.
    public enum Mode: String, Equatable, Sendable {
        /// A way through: what is blocked, the countdown, and the button once it reaches zero.
        case wait
        /// No way through: what is blocked and until when. No button, because there is nothing
        /// to press.
        case blocked

        /// The screen's own shape, as the page's. One conversion rather than one per caller: the
        /// watcher compares the page a tab is on against what the engine says *now*, and two
        /// spellings of "does this still have a button on it" is how those two would drift.
        public init(_ mode: PauseScreenModel.Mode) {
            switch mode {
            case .countdown: self = .wait
            case .blocked: self = .blocked
            }
        }
    }

    /// Everything the page is told, and everything that can be read back off a tab sitting on it.
    public struct Query: Equatable, Sendable {
        /// The page this is about, in the one spelling everything compares — `host/path`, no
        /// scheme, no query. It is what the engine is asked about, what a cleared page is
        /// remembered by and what an earned open is claimed against.
        public var target: String
        /// The address the button opens, and the one the tab comes home to: absolute, and whole
        /// where `target` is not.
        ///
        /// **Two fields, because they are two jobs.** `target` is a name and has to be the same
        /// name every second, which is why it is normalized down to `youtube.com/watch` — a video
        /// id would make every second of the same video a different page. An address to *navigate*
        /// to has the opposite requirement: `youtube.com/watch` with the id stripped off it is not
        /// the video anybody was watching, and on a page loaded from `file://` it is not even a
        /// web address — a relative `href` would resolve against the app bundle.
        ///
        /// Derived rather than free-form: see `opening(from:target:)`, which is what keeps an
        /// edited query from naming somewhere the target does not.
        public var opens: String
        /// What to call it — the group or target name the pause screen would use.
        public var name: String
        public var mode: Mode
        /// The day's budget in the engine's words. `wait` only; a hard block states itself.
        public var budgetLine: String?
        /// The engine's own sentence about when it ends. `blocked` only.
        public var untilText: String?
        /// When the wait reaches zero. **Absolute rather than a duration**, so reloading the page
        /// does not hand the user a fresh countdown — and so the countdown survives the reload at
        /// all. `wait` only.
        public var endsAt: Date?

        public init(
            target: String,
            name: String,
            mode: Mode,
            budgetLine: String? = nil,
            untilText: String? = nil,
            endsAt: Date? = nil,
            opens: String? = nil
        ) {
            self.target = target
            self.opens = opens ?? BlockPage.opening(from: nil, target: target)
            self.name = name
            self.mode = mode
            self.budgetLine = budgetLine
            self.untilText = untilText
            self.endsAt = endsAt
        }

        /// The screen the overlay would have shown, as the page's query.
        ///
        /// Built from `PauseScreenModel` rather than from a `Decision` of its own, so a blocked
        /// page and a blocked app say the same words about the same block — which is the whole
        /// reason the model is a value in this module.
        ///
        /// `address` is what the browser reported the tab was on, and is the only string that
        /// still has the video id on it. It is offered rather than trusted — see
        /// `opening(from:target:)`.
        public init(model: PauseScreenModel, target: String, now: Date, address: String?) {
            self.init(
                target: target,
                name: model.targetName,
                mode: Mode(model.mode),
                opens: BlockPage.opening(from: address, target: target)
            )
            switch model.mode {
            case .countdown(let total):
                budgetLine = model.budgetLine
                endsAt = now.addingTimeInterval(TimeInterval(max(0, total)))
            case .blocked(let untilText):
                self.untilText = untilText
            }
        }
    }

    // MARK: - Where the button goes

    /// The address the button opens and the tab comes home to, from what the browser reported and
    /// the name the rules know the page by.
    ///
    /// **The reported address is used whole when it names the same page, and thrown away when it
    /// does not.** Whole, because it is the only copy that still carries the video id, the search
    /// term and the thread — `target` lost all of that to `RuleMatcher.normalize` on the way in,
    /// and a button that lands somebody on `youtube.com/watch` has not taken them to the video
    /// they were watching. Thrown away when it disagrees, because by the time a redraw reads it
    /// back the whole query is in an address bar somebody can edit, and a field that could name
    /// anywhere would be this app navigating a tab to an address it was handed rather than to the
    /// one it interrupted.
    ///
    /// **The fallback is `https://` and the target**, and it has to be an absolute address: the
    /// page is loaded from `file://`, where `href="instagram.com"` resolves against the app bundle
    /// and lands on a "file not found" of the browser's own. It is also what refuses every scheme
    /// but the web's — a `javascript:` address surviving into an `href` on our own page is not a
    /// thing worth being clever about, and no address a browser reports for a page anybody blocks
    /// looks like one.
    /// **And it never carries credentials.** `https://joe:hunter2@intranet.example.com/p/1` is an
    /// address a browser will report and this app will otherwise write into a query string — which
    /// puts the password in the address bar of the block page and in the browser's own history,
    /// twice over. `target` loses them to `RuleMatcher.normalize` on the way in; this is the one
    /// field that keeps the address whole, so it is the one place they have to be taken out.
    public static func opening(from address: String?, target: String) -> String {
        if let address, isWebAddress(address),
           RuleMatcher.normalize(url: address) == RuleMatcher.normalize(url: target) {
            return withoutCredentials(address)
        }
        return isWebAddress(target) ? target : "https://" + target
    }

    private static func isWebAddress(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    /// The same address with any `user:password@` taken out of the authority, and everything else
    /// left exactly as it was — this is the copy that still has the video id on it.
    private static func withoutCredentials(_ address: String) -> String {
        guard let scheme = address.range(of: "://") else { return address }
        let rest = address[scheme.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard let at = authority.lastIndex(of: "@") else { return address }
        return String(address[..<scheme.upperBound]) + String(rest[rest.index(after: at)...])
    }

    // MARK: - The page, and the address of it

    /// The page inside the bundle, or `nil` for a build that has no resources — a raw SwiftPM
    /// binary, which is every headless run and every test.
    public static func pageURL(resources: URL?) -> URL? {
        resources?.appendingPathComponent(fileName)
    }

    /// The full address to send a tab to.
    ///
    /// **The order is load-bearing.** `mode` and `target` are what `query(of:page:)` recognises the
    /// page by, and they come first so that nothing carrying browser- or user-supplied text sits in
    /// front of them: a value that arrives mangled can truncate itself and invent a field after it,
    /// and never touch a field already read. `mode` used to sit fourth, behind two of them, which
    /// made recognising our own page depend on the two strings most likely to be damaged.
    public static func address(page: URL, query: Query) -> String {
        var fields = [
            ("mode", query.mode.rawValue),
            ("target", query.target),
            ("opens", query.opens),
            ("name", query.name),
        ]
        if let budgetLine = query.budgetLine { fields.append(("budget", budgetLine)) }
        if let untilText = query.untilText { fields.append(("until", untilText)) }
        if let endsAt = query.endsAt, let seconds = wholeSeconds(of: endsAt) {
            // **Rounded up, never truncated.** The page offers its button the moment its own
            // countdown reaches this second, and the ledger refuses an open until the real moment
            // the wait ends — so a second dropped here is a second in which the button is on
            // screen and buys nothing. Truncating produced exactly that: `Date()` is never a whole
            // second, so every countdown reached zero up to a second early and a quick press was
            // answered with a fresh one.
            fields.append(("ends", String(seconds)))
        }
        let joined = fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
        return "\(page.absoluteString)?\(joined)"
    }

    /// What a tab sitting on our own block page is carrying, or `nil` for any other address.
    ///
    /// Matched on the file path rather than on the whole string: a browser is free to report an
    /// address with its own idea of which characters need escaping, and the path is the part both
    /// sides agree on. Nothing but a `file:` URL at exactly our page qualifies, so no page on the
    /// web can pretend to be this one.
    ///
    /// **Read by hand rather than through `URL`,** and that is the whole of the repair. A browser
    /// that reports the address with some of it already decoded is a thing this app cannot check
    /// for and must survive — nobody has confirmed which ones do it — and `URL(string:)` turned a
    /// single decoded character into damage everywhere: it re-encodes the string it is handed, so
    /// every `%` that *had* survived became `%25` and `removingPercentEncoding` then handed back
    /// `%2F` where a `/` belonged. One decoded space was enough to make `target` come back as
    /// `reddit.com%2Fr%2Fall`, which is a page nothing manages and an address no tab can go home
    /// to. It also read a decoded `#` as the start of a fragment and threw the entire query away
    /// with it, so the tab became invisible to this app for good.
    ///
    /// Splitting at the first `?` by hand has neither failure: what is in front of it is the file,
    /// decoded once and compared to ours, and everything after it is ours to read — including a
    /// `#`, which in a query this app wrote can only ever be a character inside a value.
    ///
    /// A decoded `&` is the one that cannot be undone: it is indistinguishable from the separator
    /// it was escaped to avoid being. It costs the field it is in and everything after it in that
    /// field, and nothing else — which is why `mode` and `target` are written first and why the
    /// fields are read **first-wins**, so a value that damaged itself cannot name a field that has
    /// already been read.
    public static func query(of address: String, page: URL) -> Query? {
        guard let (path, rest) = split(address), path == page.path else { return nil }
        let fields = parse(rest)
        guard let target = fields["target"], !target.isEmpty,
              let mode = fields["mode"].flatMap(Mode.init(rawValue:))
        else { return nil }
        return Query(
            target: target,
            name: fields["name"] ?? target,
            mode: mode,
            budgetLine: fields["budget"],
            untilText: fields["until"],
            endsAt: fields["ends"].flatMap(Double.init).flatMap(moment(fromSeconds:)),
            // Put back through the same rule that built it, so a field somebody edited in the
            // address bar can only ever name the page the target already names.
            opens: opening(from: fields["opens"], target: target)
        )
    }

    // MARK: - Percent-encoding

    /// Unreserved characters, RFC 3986 §2.3, and nothing else.
    ///
    /// Deliberately stricter than any of `CharacterSet`'s `urlAllowed` sets, all of which leave
    /// some sub-delimiter unescaped. A target is a whole address — it can carry `?`, `#`, `&` and
    /// `=` of its own, and every one of those would end the value early or invent a field. Escaping
    /// everything but the unreserved set means the round trip is exact and needs no exceptions.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    // MARK: - A moment, or nothing

    /// How far from 1970 a number is still allowed to name a moment. Generous by any measure —
    /// it is the year 285 million — and far inside what an `Int` holds.
    private static let secondsLimit: Double = 9.0e15

    /// A moment from what a query string said, or `nil` when the number is not one.
    ///
    /// `ends` sits in an address bar, and `1e400` and `nan` both parse as a `Double` perfectly
    /// well. Neither is a moment: `Int(_:)` **traps** on an infinity and on a NaN, so the address
    /// built back out of a parsed query would take the app down with it. Nothing re-serializes a
    /// parsed query today, which makes this one caller away from a crash — and that is the moment
    /// to close it rather than after.
    private static func moment(fromSeconds seconds: Double) -> Date? {
        guard seconds.isFinite, abs(seconds) < secondsLimit else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The other direction, and the one that would do the trapping. `nil` leaves the field off the
    /// address entirely: a page with no `ends` draws no countdown, which is a page that says less
    /// rather than an app that stops.
    private static func wholeSeconds(of date: Date) -> Int? {
        let seconds = date.timeIntervalSince1970.rounded(.up)
        guard seconds.isFinite, abs(seconds) < secondsLimit else { return nil }
        return Int(seconds)
    }

    // MARK: - Percent-decoding, by hand

    /// An address as the two halves that matter: the file it names, decoded, and everything after
    /// the first `?`. `nil` for anything that is not a local file at all.
    ///
    /// `file:/x` as well as `file:///x` and `file://localhost/x`, because all three name the same
    /// file and this app does not get to choose which one a browser reports.
    private static func split(_ address: String) -> (path: String, rest: String)? {
        guard let body = fileBody(of: address) else { return nil }
        guard let mark = body.firstIndex(of: "?") else { return (decoded(String(body)), "") }
        return (decoded(String(body[..<mark])), String(body[body.index(after: mark)...]))
    }

    /// Everything after the scheme and the authority, or `nil` when this is not a `file:` address.
    private static func fileBody(of address: String) -> Substring? {
        guard address.prefix(5).lowercased() == "file:" else { return nil }
        let rest = address.dropFirst(5)
        guard rest.hasPrefix("//") else { return rest.hasPrefix("/") ? rest : nil }
        let authority = rest.dropFirst(2)
        guard !authority.hasPrefix("/") else { return authority }
        guard let slash = authority.firstIndex(of: "/"),
              authority[..<slash].lowercased() == "localhost"
        else { return nil }
        return authority[slash...]
    }

    /// Percent-decoded, or left exactly as it came when it will not decode — a stray `%` is a
    /// character somebody typed, not a reason to drop the field it is in.
    private static func decoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// The query string as fields, **first-wins**.
    ///
    /// First-wins because nothing here writes a field twice, so a second one can only have come
    /// from a value that damaged itself or from an address bar somebody edited — and in both cases
    /// the field that was written first is the one this app put there.
    ///
    /// `+` is left alone rather than read as a space: this app is the only thing that writes these
    /// queries and it escapes a real `+` as `%2B`, so treating one as a space could only ever
    /// corrupt an address somebody typed by hand.
    private static func parse(_ query: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in query.split(separator: "&") {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let name = decoded(String(pair[..<separator]))
            guard !name.isEmpty, fields[name] == nil else { continue }
            fields[name] = decoded(String(pair[pair.index(after: separator)...]))
        }
        return fields
    }
}
