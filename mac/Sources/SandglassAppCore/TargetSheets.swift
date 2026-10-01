import SandglassCore
import Foundation

/// What the two add sheets offer, and what they refuse to offer twice.
///
/// Websites and apps are picked in two different sheets because they are two different questions.
/// The set of apps is **closed** — what is installed on this Mac — so that sheet is a list to tick.
/// The set of websites is **open** — every address there is — so that sheet is a field to type in,
/// with the browsers' own history underneath as help. One picker serving both had to guess, at
/// every keystroke, which of the two somebody meant.
///
/// Everything here is arithmetic on values. Asking macOS what is running and reading four history
/// databases are the app's half; deciding what the two lists then say is this one, and it is
/// checked without a Mac anywhere near it.

// MARK: - What "already there" is measured against

/// What a sheet judges "already there" against: the whole configuration, or one list of the
/// caller's own.
///
/// It replaces an optional set whose `nil` meant "ask the configuration", which is a rule that had
/// to be remembered at every call site. It also carries the **word**, because the two cases do not
/// mean the same thing to a reader: in the group editor a row nobody can tick is blocked
/// somewhere, possibly by another group; in the category editor it is simply already on the list
/// being filled, and calling that "blocked" would be the sheet claiming something no group has
/// said.
public enum AlreadyThere: Equatable, Sendable {
    /// The group editor's: a target that exists anywhere in the configuration cannot be added
    /// again, because `Store` refuses a document with two targets of one id.
    case configuration
    /// The category editor's: the entries of the list this sheet is filling, as target ids.
    case list(Set<String>)

    /// What a row nobody can tick says at its right-hand end.
    public var label: String {
        switch self {
        case .configuration: return "Already blocked"
        case .list: return "Already there"
        }
    }

    /// The same fact inside a sentence.
    public var word: String {
        switch self {
        case .configuration: return "already blocked"
        case .list: return "already there"
        }
    }

    public func holds(_ targetID: String, in config: Config) -> Bool {
        switch self {
        case .configuration: return config.targets.contains { $0.id == targetID }
        case .list(let ids): return ids.contains(targetID)
        }
    }

    /// The websites this already holds, as hosts — what the suggestions leave out.
    ///
    /// A row somebody cannot use is one more thing to read past, and a list of suggestions is
    /// meant to be short.
    public func hosts(in config: Config) -> Set<String> {
        switch self {
        case .configuration:
            return Set(config.targets.filter { $0.kind == .domain }.map(\.value))
        case .list(let ids):
            let prefix = "\(TargetKind.domain.rawValue):"
            return Set(ids.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        }
    }
}

// MARK: - What an add comes to

/// What handing a whole selection to one group comes to: the configuration to write, what
/// reached it, and the one line about what did not.
///
/// Out of the card and into a value for one reason: both sheets read the answer as a **verdict**.
/// `nil` means it landed, and the sheet closes on it; anything else keeps the sheet open over its
/// selection. A selection that resolves to nothing is the case that got that wrong — see
/// `adding(_:toGroup:in:)`.
public struct TargetAdd: Equatable, Sendable {
    /// The configuration to write — the one handed in, when nothing was taken.
    public let config: Config
    /// What reached it, in the order the sheet offered it.
    public let added: [Target]
    /// Why not all of it landed, or `nil` when all of it did. **Never `nil` while `added` is
    /// empty**: that pair is what a caller reads as success.
    public let problem: String?

    public init(config: Config, added: [Target], problem: String?) {
        self.config = config
        self.added = added
        self.problem = problem
    }

    /// Everything one selection can do to one group.
    ///
    /// **An empty selection is a refusal, not a quiet success.** `TargetPicker.targets` resolves
    /// ticks against the list as it stands now and drops whatever has become already blocked
    /// since, so a sheet can hand over an empty list with its ticks still on screen. Answering
    /// `nil` to that closed the sheet on ten ticks, wrote nothing, and said nothing.
    ///
    /// One edit for the whole selection rather than one per target: every write goes through the
    /// settings lock and the engine's own, and ten of them would be ten chances to be refused
    /// half way through a list the user ticked as one decision.
    public static func adding(
        _ targets: [Target], toGroup groupID: String, in config: Config
    ) -> TargetAdd {
        guard !targets.isEmpty else {
            return TargetAdd(config: config, added: [], problem: RuleCopy.nothingToAdd)
        }
        var updated = config
        var added: [Target] = []
        var refused: [(name: String, group: String?)] = []
        for target in targets {
            let before = updated.targets.count
            updated = ConfigBuilder.adding(target, toGroup: groupID, in: updated)
            if updated.targets.count == before {
                refused.append((target.displayName, holder(of: target, in: config)))
            } else {
                added.append(target)
            }
        }
        return TargetAdd(config: updated, added: added, problem: RuleCopy.alreadyBlocked(refused))
    }

    /// The group that already holds a target, under the name the sidebar calls it.
    private static func holder(of target: Target, in config: Config) -> String? {
        guard let existing = config.targets.first(where: { $0.id == target.id }) else {
            return nil
        }
        return config.groupDisplayName(forGroup: existing.groupID)
    }
}

// MARK: - Add a website

/// The address field, which is the main way into the website sheet — and the history underneath
/// it, which is help rather than the menu.
///
/// The normaliser is `DomainInput`'s and stays exactly what it was: people paste
/// `https://www.youtube.com/feed/subscriptions` and mean `youtube.com`, and a field that stored
/// what was typed would produce four targets that block nothing. What is added here is saying so
/// out loud — the "adds youtube.com instead" line — rather than quietly storing something else.
public enum SiteField {

    /// What is in the field right now, and therefore whether `Add` can be pressed.
    public enum State: Equatable, Sendable {
        case empty
        /// Typed, and not an address any amount of normalising can rescue.
        case unusable
        case alreadyThere(String)
        case ready(String)

        /// The host this would add, for the two cases that name one.
        public var host: String? {
            switch self {
            case .ready(let host), .alreadyThere(let host): return host
            case .empty, .unusable: return nil
            }
        }

        public var canAdd: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    public static func state(
        of text: String, alreadyThere: AlreadyThere, config: Config
    ) -> State {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let host = DomainInput.normalize(trimmed) else { return .unusable }
        let id = Target.id(ofKind: .domain, value: host)
        return alreadyThere.holds(id, in: config) ? .alreadyThere(host) : .ready(host)
    }

    /// The one line under the field, or `nil` when the field has nothing to say.
    ///
    /// Said rather than left as a button that will not press: a disabled `Add` with no reason
    /// beside it reads as a broken sheet, which is the same argument the rule sheet's pattern
    /// field already makes.
    public static func note(
        for text: String, alreadyThere: AlreadyThere, config: Config
    ) -> String? {
        switch state(of: text, alreadyThere: alreadyThere, config: config) {
        case .empty:
            return nil
        case .unusable:
            return "That is not a website address. One looks like youtube.com."
        case .alreadyThere(let host):
            return "\(host) is \(alreadyThere.word)."
        case .ready(let host):
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard host != typed else { return nil }
            return "Adds “\(host)” instead — a website is blocked whole, "
                + "every page under it included."
        }
    }

    /// The target a host becomes, whichever way it arrived.
    ///
    /// Typed and picked from the suggestions go through here together, which is what keeps them
    /// one target: two that differ only in their display name are two group keys, and that shows
    /// up months later as a second budget for one site rather than as a wrong name on a row.
    public static func target(forHost host: String) -> Target {
        TargetCandidate(kind: .domain, value: host, label: host, alreadyBlocked: false).target
    }

    /// The suggestions a half-typed address leaves standing.
    ///
    /// The history is filtered rather than replaced by what is typed: it is the same list, getting
    /// shorter, which is why picking one is still one click at any point.
    ///
    /// Matched the way `TargetPicker.matching` matches the app list. It used to be `contains`
    /// against a lowercased needle, which is the same answer only for as long as every host in the
    /// list arrives lowercased — one feature spelling "search" two ways and relying on a
    /// normalisation three files upstream to hide the difference.
    public static func matching(
        _ query: String, in sites: [BrowserHistory.Site]
    ) -> [BrowserHistory.Site] {
        let needle = searchTerm(in: query)
        guard !needle.isEmpty else { return sites }
        return sites.filter { $0.host.localizedCaseInsensitiveContains(needle) }
    }

    /// What a half-typed address is matched on: the part of it that could be a host.
    ///
    /// A scheme, a `www.` and a path are dropped, so pasting a full address filters the list to
    /// the site it names instead of emptying it. What is left is matched as typed — `you` is a
    /// prefix of nothing in particular and still has to find `youtube.com`.
    ///
    /// A query that is **only** a path — someone typing `/` first, or pasting a fragment — has no
    /// host part at all, and the honest answer to that is the whole list rather than none of it.
    /// It used to refuse to cut at position zero, which left the slash in the needle and emptied
    /// the section under a field that had not yet been given an address to work with.
    private static func searchTerm(in query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeEnd = text.range(of: "://") { text = String(text[schemeEnd.upperBound...]) }
        if let cut = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text
    }
}

// MARK: - Add apps

/// The two lists of the app sheet: what is running right now, and everything installed.
///
/// **Running goes on top** because you usually block the thing that just distracted you, and it is
/// the one app somebody can name without thinking. It is a shortcut into the same list rather than
/// a list of its own: a running app stays in `All apps` as well, because a list where Slack
/// vanishes from A-l-l because it happens to be open is a list that lies.
public enum AppChoices {

    /// One application macOS says is running.
    ///
    /// Three fields rather than an `NSRunningApplication`, so what the sheet does with the answer
    /// can be checked without launching anything.
    public struct RunningApp: Equatable, Sendable {
        public let bundleID: String
        public let name: String
        /// Whether it is an ordinary app — `.regular` activation policy, meaning a Dock icon and a
        /// menu bar. Everything else running on a Mac is an agent, a helper or an extension: some
        /// eighty processes nobody thinks of as an app and nobody wants to scroll past.
        public let isOrdinary: Bool

        public init(bundleID: String, name: String, isOrdinary: Bool) {
            self.bundleID = bundleID
            self.name = name
            self.isOrdinary = isOrdinary
        }
    }

    /// This app, which no picker offers: hiding itself would hide the way out.
    public static let appBundleID = "io.github.moritzthln.sandglass"

    /// What neither list ever names. The browsers are left out for the reason `AppScanner` leaves
    /// them out of the installed scan — blocking one would block the web whole, and websites are
    /// blocked one at a time through the frontmost tab — and `Browsers` is the one place a browser
    /// bundle id is written down. A running list that offered Chrome while the installed list
    /// refused it would be two answers to one question.
    public static let excludedBundleIDs: Set<String> = Browsers.bundleIDs.union([appBundleID])

    /// The apps worth offering out of everything macOS says is running.
    ///
    /// Named the way the Finder names them, and by bundle id when macOS has no name to give —
    /// which is better than dropping the row, since an app with no name is still an app somebody
    /// can see in front of them.
    public static func running(_ apps: [RunningApp]) -> [TargetPicker.App] {
        var found: [String: TargetPicker.App] = [:]
        for app in apps where app.isOrdinary {
            let bundleID = app.bundleID.trimmingCharacters(in: .whitespaces)
            guard !bundleID.isEmpty, !excludedBundleIDs.contains(bundleID),
                  found[bundleID] == nil else { continue }
            let name = app.name.trimmingCharacters(in: .whitespaces)
            found[bundleID] = TargetPicker.App(
                bundleID: bundleID, name: name.isEmpty ? bundleID : name
            )
        }
        // Alphabetical, like the installed list: launch order is what macOS answers in, and a
        // list that reshuffles itself between two openings of the same sheet is unreadable.
        return found.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The sheet's two sections, both filtered by the same search.
    public struct Sections: Equatable, Sendable {
        public let running: [TargetCandidate]
        public let all: [TargetCandidate]

        public init(running: [TargetCandidate], all: [TargetCandidate]) {
            self.running = running
            self.all = all
        }

        public var isEmpty: Bool { running.isEmpty && all.isEmpty }
    }

    /// Both lists, as rows that know whether they can be ticked.
    ///
    /// One search over both, and both keep their heading: a search that collapsed the two into one
    /// list would take away the only thing the top section is for.
    public static func sections(
        running: [TargetPicker.App],
        installed: [TargetPicker.App],
        alreadyThere: AlreadyThere,
        config: Config,
        search: String
    ) -> Sections {
        Sections(
            running: TargetPicker.matching(
                search, in: rows(running, alreadyThere: alreadyThere, config: config)
            ),
            all: TargetPicker.matching(
                search, in: rows(installed, alreadyThere: alreadyThere, config: config)
            )
        )
    }

    /// Every app on offer, each of them once — what a selection is resolved against.
    ///
    /// Unfiltered on purpose, and separate from `sections` for that reason: a tick survives the
    /// search being changed under it, so resolving against what is currently on screen would drop
    /// half of what somebody ticked. And each row **once**, because an app that is both running
    /// and installed appears twice — two candidates of one id, which would ask the configuration
    /// to add one target twice and come back reading as "already blocked".
    public static func everything(
        running: [TargetPicker.App],
        installed: [TargetPicker.App],
        alreadyThere: AlreadyThere,
        config: Config
    ) -> [TargetCandidate] {
        var seen = Set<String>()
        return rows(running + installed, alreadyThere: alreadyThere, config: config)
            .filter { seen.insert($0.id).inserted }
    }

    private static func rows(
        _ apps: [TargetPicker.App], alreadyThere: AlreadyThere, config: Config
    ) -> [TargetCandidate] {
        apps.map { app in
            TargetCandidate(
                kind: .app,
                value: app.bundleID,
                label: app.name,
                alreadyBlocked: alreadyThere.holds(
                    Target.id(ofKind: .app, value: app.bundleID), in: config
                )
            )
        }
    }
}
