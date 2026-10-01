import Foundation

/// Which of a group's rules a URL runs into, and the normalization both sides go through first.
///
/// Pure and static: no clock, no configuration, no state. That is what lets the whole of the
/// ordering below be checked as arithmetic on values.
///
/// **The reading order**, and the reason for each step:
///
/// 1. **High priority first.** The one knob that exists for the case where a later, broader rule
///    would otherwise win. Without it the only way to fix a collision is to reorder the list,
///    which is not a thing a user should have to think about.
/// 2. **Then specificity** — `specificPage` before `websiteOrText`. A rule naming one page is a
///    statement about that page; a rule naming a string is a statement about a habit. The
///    narrower statement is the more deliberate one.
/// 3. **Then `allow` before `block`.** An exception exists to carve something out of a block, so
///    at equal footing the exception is the newer intent. `youtube.com` blocked and
///    `music.youtube.com` allowed is the whole reason this layer exists.
/// 4. **Then the order they were written in.** The last tie-break, and the only one that is not
///    a judgement.
///
/// The first rule that matches in that order wins outright — no combining, no scoring. There is
/// nothing after it: a group that wrote no rule about a URL says nothing about it.
///
/// It used to have two more steps. The adult list was read below every rule, and a whitelist
/// group fell back to blocking below that. The list is an ordinary category now — see
/// `DistractionCategory.adult` — and "everything except" is a time window that permits, so both
/// extra layers of precedence are gone along with the switches that turned them on.
public enum RuleMatcher {

    /// The rule this URL runs into, or `nil` when the group has nothing to say about it.
    ///
    /// A plain `Rule?` since the adult list stopped being a second source of rules. It used to
    /// answer a `Match` carrying a `Source`, so that `WebResolver` could tell a rule the user
    /// wrote from one the list supplied — with one source left, the wrapper said nothing.
    public static func match(url: String, rules: [Rule]) -> Rule? {
        let target = normalize(url: url)
        guard !target.isEmpty else { return nil }
        return firstMatch(in: ordered(rules), against: target)
    }

    // MARK: - The order

    private static func ordered(_ rules: [Rule]) -> [Rule] {
        rules.enumerated().sorted { rank(of: $0) < rank(of: $1) }.map(\.element)
    }

    /// Lower sorts earlier. Written as one tuple so the four steps of the doc comment above are
    /// four lines here and cannot drift apart.
    private static func rank(of entry: (offset: Int, element: Rule)) -> (Int, Int, Int, Int) {
        (
            entry.element.highPriority ? 0 : 1,
            entry.element.matchType == .specificPage ? 0 : 1,
            entry.element.action == .allow ? 0 : 1,
            entry.offset
        )
    }

    private static func firstMatch(in rules: [Rule], against target: String) -> Rule? {
        rules.first { matches($0, target) }
    }

    /// Both sides are already normalized — the rule's pattern when it was made or decoded, the
    /// URL by the caller above — so this is the whole of the comparison.
    ///
    /// **A `websiteOrText` rule reads differently depending on which way it points**, and the two
    /// are not symmetrical. A block matches its pattern anywhere in `host/path`, which is what
    /// makes `shorts` and `reddit.com/r/` rules at all: they are habits rather than addresses, and
    /// a block that reaches too far costs a page somebody has to un-block by hand. An allow is
    /// anchored to the host, because it reaches the other way — see `covers(place:_:)`.
    private static func matches(_ rule: Rule, _ target: String) -> Bool {
        guard !rule.pattern.isEmpty else { return false }
        switch rule.matchType {
        case .websiteOrText:
            return rule.action == .allow
                ? covers(place: rule.pattern, target)
                : target.contains(rule.pattern)
        case .specificPage: return target == rule.pattern
        }
    }

    /// Whether an allowed **place** covers this address: the pattern must be the host, or the host
    /// followed by a path it is the start of.
    ///
    /// An exception carves out a place, not a string, and the difference is the whole security of
    /// the layer. `WebResolver` drops a group's entire claim on any URL one of that group's allows
    /// matched, so a substring match handed anybody a way out of any group: allow
    /// `example-site.com` in a group that blocks `blocked-site.com`, and
    /// `blocked-site.com/search/example-site.com` — or any other site on the list with the string
    /// typed into a path — walked straight out of it. Blocks fail safe
    /// when they are too wide. Allows do not.
    ///
    /// The host is compared by the suffix rule the rest of the app uses for hosts (see
    /// `WebResolver.domainTarget`), so allowing `example-site.com` covers `www.` and any other
    /// subdomain of it and never `notexample-site.com`. The path is compared in whole segments, for
    /// the same reason: `reddit.com/r/rust` is that subreddit and what is under it, not the one
    /// spelled `rustlang`.
    ///
    /// What this gives up is an allow written as free text — `?ref=`, or a bare `/settings` meant
    /// across every site. Those never named a place, so an exception is no longer the way to write
    /// them; a narrower block, or none, is.
    private static func covers(place pattern: String, _ target: String) -> Bool {
        let patternHost = host(of: pattern)
        let targetHost = host(of: target)
        guard !patternHost.isEmpty,
              targetHost == patternHost || targetHost.hasSuffix("." + patternHost) else {
            return false
        }
        let patternPath = pattern.dropFirst(patternHost.count)
        guard !patternPath.isEmpty else { return true }
        let targetPath = target.dropFirst(targetHost.count)
        return targetPath == patternPath || targetPath.hasPrefix(patternPath + "/")
    }

    // MARK: - Normalizing

    /// A URL as the one string everything here compares: `host/path`, lowercased, no scheme, no
    /// credentials, no port, no `www.`, no query, no fragment, and no trailing slash.
    ///
    /// Dropping the query is what makes a rule about a page a rule about the page rather than
    /// about one visit to it — `youtube.com/watch?v=a` and `?v=b` are the same page to a person
    ///
    /// `www.` is the one prefix stripped, because it is the one that never names a different
    /// site. Nothing here computes a registrable domain: telling `co.uk` from `youtube.com`
    /// needs the public suffix list, and guessing would silently widen or narrow a block.
    public static func normalize(url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        let cut = text.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
        let host = normalizeHost(cut.map { String(text[..<$0]) } ?? text)
        guard let cut, text[cut] == "/" else { return host }
        return dropTrailingSlash(host + pathOnly(String(text[cut...])))
    }

    /// Whether a pattern is one the matcher could ever act on.
    ///
    /// The rule sheet's Save button asks this, and `matches` above asks the same question of the
    /// stored pattern — one predicate, because the two were allowed to disagree. The sheet tested
    /// what had been *typed* and the matcher tests what is *stored*, with `normalize` in between:
    /// `https://` and `www.` are neither empty nor whitespace, and both come out of it as nothing
    /// at all. That saved a rule with a blank title that could never match anything, and the sheet
    /// closed on it as though it had done what was asked.
    public static func isActionable(pattern: String, matchType: Rule.MatchType) -> Bool {
        !normalize(pattern: pattern, matchType: matchType).isEmpty
    }

    /// A pattern in the shape it is stored and compared in.
    ///
    /// The two match types part company in one place: a `specificPage` pattern loses its query,
    /// because the URL it is compared against has lost one too and a pattern that can never
    /// match is a rule the user thinks they have. A `websiteOrText` pattern is left whole —
    /// it is arbitrary text, and cutting it at a `?` would leave someone matching on `?ref=`
    /// with an empty rule.
    public static func normalize(pattern: String, matchType: Rule.MatchType) -> String {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if matchType == .specificPage, let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        return dropTrailingSlash(text)
    }

    /// The host part of an already-normalized URL — what the plain domain targets are matched
    /// against, and what the pause screen falls back to calling a page.
    public static func host(of normalizedURL: String) -> String {
        String(normalizedURL.prefix { $0 != "/" })
    }

    /// Hosts arrive from the browser, from stored targets and from hand-edited configuration,
    /// and the three do not agree on case, on ports, on credentials or on the trailing dot that
    /// makes a name fully qualified.
    static func normalizeHost(_ host: String) -> String {
        var text = host.trimmingCharacters(in: .whitespaces).lowercased()
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        text = stripPort(text)
        while text.hasSuffix(".") { text.removeLast() }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text
    }

    private static func pathOnly(_ rest: String) -> String {
        guard let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return rest }
        return String(rest[..<end])
    }

    private static func dropTrailingSlash(_ text: String) -> String {
        text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// Only digits are a port. An IPv6 literal is bracketed and full of colons, so only what
    /// follows the bracket can be one — splitting on the last colon without this would cut
    /// `[::1]` down to `[::`.
    private static func stripPort(_ host: String) -> String {
        if host.hasPrefix("["), let closing = host.firstIndex(of: "]") {
            let after = host.index(after: closing)
            return after < host.endIndex && host[after] == ":"
                ? String(host[...closing]) : host
        }
        guard let colon = host.lastIndex(of: ":") else { return host }
        let port = host[host.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return host }
        return String(host[..<colon])
    }
}
