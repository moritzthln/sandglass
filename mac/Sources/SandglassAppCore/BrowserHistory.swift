import SandglassCore
import Foundation

/// The sites somebody actually visits, read off the browsers they already use.
///
/// Setup used to offer seven websites picked by whoever wrote the defaults, which is a guess about a
/// stranger. A browser has the real answer and has had it all along: every one of them keeps a
/// SQLite database of what was opened and how often. So the picker is that list, ordered by how
/// much of the user's week each site actually takes.
///
/// **Everything here is arithmetic on values.** Opening a database, copying it out from under a
/// running browser and asking macOS for a directory it may refuse are the file half, and they
/// live in the app (`BrowserHistoryFiles`) behind `Answer`. What is left here — deciding what
/// counts as a site, folding `m.youtube.com` and `www.youtube.com` into one row, throwing out the
/// noise, ranking what remains and saying honestly what could not be read — is the half that
/// decides what the user sees, and it is checked without a browser anywhere near it.
public enum BrowserHistory {

    // MARK: - What a browser said

    /// One row of a history database: an address, and how often it was opened.
    public struct Visit: Equatable, Sendable {
        public let url: String
        public let count: Int

        public init(url: String, count: Int) {
            self.url = url
            self.count = count
        }
    }

    /// What came back from one browser. Three cases rather than an optional list, because
    /// "this browser has no history" and "this browser would not show us its history" are
    /// opposite facts about the same empty answer — and only the second is worth a line on
    /// screen. The same distinction `BrowserAddress.Reading` draws, for the same reason.
    public enum Reading: Equatable, Sendable {
        case visits([Visit])
        /// The file is there and macOS would not open it. `needsFullDiskAccess` is Safari's
        /// case: `~/Library/Safari` is one of the places only Full Disk Access reaches, and a
        /// user who is told that can do something about it.
        case denied(needsFullDiskAccess: Bool)
        /// No history file at all — the browser is not installed, or has never been opened.
        case absent
    }

    /// What **one database file** yielded, before it is folded with the rest of its browser's.
    ///
    /// A fourth case the browser-wide `Reading` has no use for: `missing`. A Chromium browser has
    /// one file per profile and Safari has exactly one, and a file that is not there is a browser
    /// with no history — the same fact as an absent profile directory. Without the case it was
    /// read as `unusable`, which puts "Safari's history couldn't be read" in front of everyone who
    /// has granted Full Disk Access and never opened Safari.
    public enum FileReading: Equatable, Sendable {
        case visits([Visit])
        /// macOS said no.
        case denied
        /// There is no such file.
        case missing
        /// The file is there and would not answer: a schema this build does not know, or a
        /// database somebody has corrupted.
        case unusable
    }

    /// Every file of one browser, as that browser's single answer.
    ///
    /// **Anything readable wins**: somebody with two Chrome profiles where one is locked still
    /// gets the other, and being told about a refusal that cost them nothing would be noise. A
    /// refusal outranks a broken file, because it is the one with a way out; both are said out
    /// loud, and only the first is called a permission. Files that are simply not there say
    /// nothing at all.
    public static func fold(
        _ readings: [FileReading], needsFullDiskAccess: Bool
    ) -> Reading {
        var visits: [Visit] = []
        var read = false
        var denied = false
        var unusable = false
        for reading in readings {
            switch reading {
            case .visits(let rows): visits += rows; read = true
            case .denied: denied = true
            case .unusable: unusable = true
            case .missing: continue
            }
        }
        if read { return .visits(visits) }
        if denied { return .denied(needsFullDiskAccess: needsFullDiskAccess) }
        return unusable ? .denied(needsFullDiskAccess: false) : .absent
    }

    /// One browser's answer, with the name to say out loud when it is a refusal.
    public struct Answer: Equatable, Sendable {
        public let browser: String
        public let reading: Reading

        public init(browser: String, reading: Reading) {
            self.browser = browser
            self.reading = reading
        }
    }

    // MARK: - What the picker shows

    /// One row of the picker: a site, and the visits behind its place in the order.
    public struct Site: Equatable, Identifiable, Sendable {
        public let host: String
        public let visits: Int
        public var id: String { host }

        public init(host: String, visits: Int) {
            self.host = host
            self.visits = visits
        }
    }

    /// A browser that is there and would not answer.
    public struct Unreadable: Equatable, Sendable {
        public let browser: String
        public let needsFullDiskAccess: Bool

        public init(browser: String, needsFullDiskAccess: Bool) {
            self.browser = browser
            self.needsFullDiskAccess = needsFullDiskAccess
        }
    }

    /// The ranked list, and what is missing from it.
    public struct Ranking: Equatable, Sendable {
        public let sites: [Site]
        public let unreadable: [Unreadable]

        public init(sites: [Site], unreadable: [Unreadable]) {
            self.sites = sites
            self.unreadable = unreadable
        }

        /// Whether there is anything to suggest. A Mac whose browsers have no history to read is
        /// a picker with no Most-visited section rather than an empty heading over nothing.
        public var isEmpty: Bool { sites.isEmpty }

        /// The one line about what could not be read, or `nil` when everything could.
        ///
        /// Said rather than quietly shown less: a Safari user looking at a list with no Safari
        /// in it would otherwise conclude the feature does not work, and the fix — one checkbox
        /// in System Settings — is a sentence away.
        ///
        /// Which is why the two kinds of refusal are kept apart even when both happen at once.
        /// Folding them into one "couldn't be read" would drop the only part of the sentence the
        /// user can act on, because a second browser failing for an unrelated reason is not a
        /// reason to stop mentioning Full Disk Access.
        public var line: String? {
            guard !unreadable.isEmpty else { return nil }
            let locked = unreadable.filter(\.needsFullDiskAccess).map(\.browser)
            let broken = unreadable.filter { !$0.needsFullDiskAccess }.map(\.browser)
            var clauses: [String] = []
            if !locked.isEmpty {
                clauses.append("\(Self.list(locked))'s history needs Full Disk Access")
            }
            if !broken.isEmpty {
                clauses.append("\(Self.list(broken))'s history couldn't be read")
            }
            let rest = sites.isEmpty
                ? " and nothing else had a history to read"
                : " — the others are listed"
            return clauses.joined(separator: ", ") + rest + "."
        }

        /// `Safari`, `Safari and Chrome`, `Safari, Chrome and Arc`.
        private static func list(_ names: [String]) -> String {
            guard let last = names.last else { return "" }
            guard names.count > 1 else { return last }
            return names.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    // MARK: - Ranking

    /// Every browser's answer, folded into one ordered list.
    ///
    /// Counts are **added across browsers**, because the question is what this person visits and
    /// not what they visit in Chrome. Order is visits first and then the host alphabetically, so
    /// a list of sites nobody has been to twice does not reshuffle itself every time setup opens.
    ///
    /// `excluding` is what the configuration already blocks: offering somebody a site they have
    /// picked is a row they cannot use and one more thing to read past.
    public static func rank(
        _ answers: [Answer], excluding excluded: Set<String> = [], limit: Int = 24
    ) -> Ranking {
        let skip = Set(excluded.compactMap(site(of:)))
        var visits: [String: Int] = [:]
        var unreadable: [Unreadable] = []
        for answer in answers {
            switch answer.reading {
            case .absent:
                continue
            case .denied(let needsFullDiskAccess):
                unreadable.append(
                    Unreadable(browser: answer.browser, needsFullDiskAccess: needsFullDiskAccess)
                )
            case .visits(let rows):
                for row in rows where row.count > 0 {
                    guard let site = site(of: row.url), !skip.contains(site) else { continue }
                    visits[site, default: 0] += row.count
                }
            }
        }
        let sites = visits
            .map { Site(host: $0.key, visits: $0.value) }
            .sorted { $0.visits == $1.visits ? $0.host < $1.host : $0.visits > $1.visits }
        return Ranking(sites: Array(sites.prefix(limit)), unreadable: unreadable)
    }

    // MARK: - What counts as a site

    /// The one row a URL belongs in, or `nil` when it is not a site anybody would block.
    ///
    /// The host is read through `RuleMatcher`, which is the app's one spelling of "the same
    /// page": a suggestion that normalises differently from the target it becomes would be a
    /// picker offering rows that block nothing.
    public static func site(of url: String) -> String? {
        let host = RuleMatcher.host(of: RuleMatcher.normalize(url: url))
        guard isSite(host) else { return nil }
        return registrableDomain(of: host)
    }

    /// Everything that is a URL in a history file and not a website.
    ///
    /// Each of these is in a real history database, in quantity, and each would otherwise take a
    /// place in a list of two dozen rows: `chrome://newtab` on every new tab, `localhost:3000`
    /// once per page load of whatever somebody is building, a router at `192.168.1.1`, the
    /// `.local` names Bonjour hands out.
    private static func isSite(_ host: String) -> Bool {
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last else { return false }
        // A numeric last label makes it an address rather than a name. IPv6 is bracketed and
        // has no dot in it at all, so it never reaches here.
        guard !tld.allSatisfy(\.isNumber) else { return false }
        return !privateSuffixes.contains(String(tld))
    }

    /// Names that never leave this Mac or this network.
    private static let privateSuffixes: Set<String> = [
        "local", "localhost", "internal", "lan", "home", "test", "invalid", "example",
    ]

    /// The domain a host is one name under: `m.youtube.com` and `www.youtube.com` are both
    /// `youtube.com`, and blocking that blocks both.
    ///
    /// **An approximation of the public suffix list, deliberately.** Doing this properly means
    /// shipping and updating Mozilla's list; guessing wrong here costs one row in a list of
    /// suggestions that reads slightly too broad — `x.github.io` offered as `github.io` — and the
    /// user can see the row before they tick it. That trade is only acceptable *here*. It is why
    /// `RuleMatcher` refuses to compute one: there a wrong answer silently widens or narrows what
    /// is blocked, and nobody would ever see it.
    ///
    /// The two-label suffixes are the ones a German-speaking user meets: British, Japanese and
    /// Australian sites, plus the `com.*` family.
    public static func registrableDomain(of host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let wanted = twoLabelSuffixes.contains(lastTwo) ? 3 : 2
        guard labels.count > wanted else { return host }
        return labels.suffix(wanted).joined(separator: ".")
    }

    private static let twoLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "net.nz", "org.nz",
        "com.br", "com.mx", "com.ar", "com.tr", "com.cn", "com.hk", "com.sg", "com.tw",
        "co.za", "co.in", "co.kr", "co.il", "co.id", "co.th",
        "com.pl", "com.ua", "com.es", "com.pt", "com.vn", "com.ph", "com.my",
    ]

    // MARK: - Where the files are

    /// Where one browser keeps its history, given a home directory.
    ///
    /// Pure, and a value rather than a path: the app half only walks directories and copies
    /// files, so which directory and which query is a fact that can be read — and checked —
    /// without a browser being installed.
    public struct Location: Equatable, Sendable {
        /// The database itself when `fileName` is `nil`, and otherwise the directory whose
        /// subdirectories are profiles.
        public let root: URL
        /// The database's name inside each profile directory. Chromium keeps one per profile,
        /// and somebody with a work profile and a private one has two halves of a week.
        public let fileName: String?
        /// Whether only Full Disk Access reaches it. Safari's, and nothing else's.
        public let needsFullDiskAccess: Bool
        /// SQL answering with `(url, visits)`, most visited first.
        public let query: String

        public init(root: URL, fileName: String?, needsFullDiskAccess: Bool, query: String) {
            self.root = root
            self.fileName = fileName
            self.needsFullDiskAccess = needsFullDiskAccess
            self.query = query
        }
    }

    /// A cap on the rows read out of one database. A year of browsing is tens of thousands of
    /// rows and the picker shows two dozen; ordering in SQLite and stopping there keeps the
    /// whole of setup's reading well under a tenth of a second.
    static let rowLimit = 800

    private static let chromiumQuery =
        "SELECT url, visit_count FROM urls WHERE visit_count > 0 ORDER BY visit_count DESC LIMIT \(rowLimit)"
    private static let firefoxQuery =
        "SELECT url, visit_count FROM moz_places WHERE visit_count > 0 ORDER BY visit_count DESC LIMIT \(rowLimit)"
    private static let safariQuery =
        "SELECT url, visit_count FROM history_items WHERE visit_count > 0 ORDER BY visit_count DESC LIMIT \(rowLimit)"

    /// Where this browser's history is, or `nil` for one whose history this app cannot read.
    public static func location(forBundleID bundleID: String, home: URL) -> Location? {
        let support = home.appending("Library").appending("Application Support")
        switch bundleID {
        case "com.apple.Safari":
            return Location(
                root: home.appending("Library").appending("Safari").appending("History.db"),
                fileName: nil, needsFullDiskAccess: true, query: safariQuery
            )
        case "com.google.Chrome":
            return chromium(support.appending("Google").appending("Chrome"))
        case "com.brave.Browser":
            return chromium(support.appending("BraveSoftware").appending("Brave-Browser"))
        case "com.microsoft.edgemac":
            return chromium(support.appending("Microsoft Edge"))
        case "company.thebrowser.Browser":
            return chromium(support.appending("Arc").appending("User Data"))
        case "org.mozilla.firefox":
            return Location(
                root: support.appending("Firefox").appending("Profiles"),
                fileName: "places.sqlite", needsFullDiskAccess: false, query: firefoxQuery
            )
        default:
            return nil
        }
    }

    private static func chromium(_ root: URL) -> Location {
        Location(root: root, fileName: "History", needsFullDiskAccess: false, query: chromiumQuery)
    }
}

private extension URL {
    /// `appendingPathComponent` without the deprecation warning on one toolchain and the
    /// availability floor on the other.
    func appending(_ component: String) -> URL {
        appendingPathComponent(component)
    }
}
