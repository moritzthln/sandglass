import Foundation
import SandglassCore

/// The rule layer as arithmetic on values: what a URL normalizes to, which rule a group's list
/// answers with, and which group ends up claiming a page.
///
/// Every check here is pure — no clock, no engine, no disk — which is the point of splitting
/// `RuleMatcher` and `WebResolver` out in the first place. The engine's own behaviour once a
/// group has claimed a page is `RulesEngineRuleTests`.
func runRuleMatcherTests() {
    testURLNormalization()
    testPatternNormalization()
    testAPatternIsActionableOnlyIfItSurvivesNormalization()
    testWebsiteOrTextMatchesAnywhere()
    testSpecificPageMatchesOnePage()
    testAnAllowRuleNamesAPlaceRatherThanAString()
    testAnAllowRulesPathIsMatchedInWholeSegments()
    testAnAllowedStringInThePathCannotFreeTheGroup()
    testHighPriorityIsReadFirst()
    testSpecificityBeatsBreadth()
    testAllowBeatsBlockAtEqualFooting()
    testDeclarationOrderIsTheLastTieBreak()
    testTheAdultListIsAnOrdinaryCategory()
    testAdultListShape()
    testResolverPrefersAnExplicitBlock()
    testResolverLetsAnAllowCarveOutItsOwnTarget()
    testAGroupThatWroteNothingClaimsNothing()
    testResolverIgnoresSwitchedOffGroups()
}

// MARK: - Normalizing

private func testURLNormalization() {
    let cases: [(String, String)] = [
        ("https://www.YouTube.com/watch?v=abc#t=10", "youtube.com/watch"),
        ("http://youtube.com/", "youtube.com"),
        ("youtube.com", "youtube.com"),
        ("www.youtube.com.", "youtube.com"),
        ("https://user:pw@youtube.com:8443/feed", "youtube.com/feed"),
        ("HTTPS://M.Youtube.COM/Shorts/xyz", "m.youtube.com/shorts/xyz"),
        ("  https://youtube.com/a/b/  ", "youtube.com/a/b"),
        ("youtube.com?v=1", "youtube.com"),
        ("", ""),
    ]
    for (raw, expected) in cases {
        expectEqual(RuleMatcher.normalize(url: raw), expected, "normalize \(raw.isEmpty ? "«empty»" : raw)")
    }
    expectEqual(RuleMatcher.host(of: "youtube.com/watch"), "youtube.com", "host of a normalized URL")
    expectEqual(RuleMatcher.host(of: "youtube.com"), "youtube.com", "host of a bare host")
}

private func testPatternNormalization() {
    expectEqual(
        Rule(pattern: "  HTTPS://www.YouTube.com/Shorts/  ", matchType: .websiteOrText, action: .block).pattern,
        "youtube.com/shorts",
        "a website-or-text pattern loses scheme, www, case and the trailing slash"
    )
    expectEqual(
        Rule(pattern: "https://youtube.com/watch?v=abc", matchType: .specificPage, action: .allow).pattern,
        "youtube.com/watch",
        "a specific-page pattern loses its query, because the URL it is compared with has none"
    )
    expectEqual(
        Rule(pattern: "watch?v=", matchType: .websiteOrText, action: .block).pattern,
        "watch?v=",
        "a website-or-text pattern keeps its question mark — it is text, not an address"
    )
}

/// The bug: the rule sheet enabled Save for anything that was not empty or whitespace, and
/// `Rule.init` normalized afterwards. `www.` and `https://` are neither, and both come out of
/// normalization as nothing at all — so the sheet saved a rule with a blank title, closed as
/// though it had worked, and left a row in the list that `matches` can never act on.
private func testAPatternIsActionableOnlyIfItSurvivesNormalization() {
    for typed in ["www.", "https://", "HTTPS://WWW.", "  ", "", "https://www."] {
        expect(
            !RuleMatcher.isActionable(pattern: typed, matchType: .websiteOrText),
            "“\(typed)” normalizes to nothing, so it is not a rule"
        )
        // The thing that made it dangerous: the old check passed, the stored pattern was empty.
        expect(
            Rule(pattern: typed, matchType: .websiteOrText, action: .block).pattern.isEmpty,
            "and that is exactly what would have been stored"
        )
    }
    // A lone slash is left alone by `dropTrailingSlash`, which only trims a string longer than
    // one character — so it is a text match on "/", broad but real, and not this rule's business.
    for typed in ["youtube.com", "  shorts  ", "https://www.youtube.com/watch", "?", "/"] {
        expect(
            RuleMatcher.isActionable(pattern: typed, matchType: .websiteOrText),
            "“\(typed)” keeps something to match on"
        )
    }
    // The two match types disagree about the query, so the predicate has to be asked with one.
    expect(
        RuleMatcher.isActionable(pattern: "?ref=x", matchType: .websiteOrText),
        "a text pattern keeps its query and is a rule"
    )
    expect(
        !RuleMatcher.isActionable(pattern: "?ref=x", matchType: .specificPage),
        "the same pattern as a page loses the query and is left with nothing"
    )
}

// MARK: - The two match types

private func testWebsiteOrTextMatchesAnywhere() {
    let shorts = Rule(pattern: "shorts", matchType: .websiteOrText, action: .block)
    expectEqual(
        matched(url: "https://www.youtube.com/shorts/abc", [shorts])?.id, shorts.id,
        "a text pattern matches inside the path"
    )
    expectEqual(
        matched(url: "HTTPS://YOUTUBE.COM/SHORTS/ABC", [shorts])?.id, shorts.id,
        "matching is case-insensitive on both sides"
    )
    expectNil(matched(url: "youtube.com/watch", [shorts]), "and not where the text is absent")

    let site = Rule(pattern: "www.youtube.com", matchType: .websiteOrText, action: .block)
    expectEqual(
        matched(url: "https://m.youtube.com/feed", [site])?.id, site.id,
        "a www pattern still matches a host that has none, because both lose it"
    )
}

private func testSpecificPageMatchesOnePage() {
    let page = Rule(pattern: "music.youtube.com", matchType: .specificPage, action: .allow)
    expectEqual(
        matched(url: "https://music.youtube.com/", [page])?.id, page.id,
        "a trailing slash is ignored"
    )
    expectEqual(
        matched(url: "https://www.music.youtube.com", [page])?.id, page.id,
        "and so is a leading www"
    )
    expectNil(
        matched(url: "https://music.youtube.com/playlist", [page]),
        "but a page under it is a different page"
    )
    expectNil(matched(url: "https://youtube.com", [page]), "and so is the parent")
}

/// The hole this closes, in the shape a real configuration had it: `example-site.com` allowed in
/// a group, as a website-or-text rule. Text matched anywhere in `host/path`, so putting the
/// allowed string in a path was a way out of the group — and a group's allow suppresses the whole
/// of that group's claim, so it freed every site the Adult category carries at once.
///
/// A block rule that is too wide fails safe; an allow rule that is too wide is a door. So an allow
/// names **a place**: the host, or the host plus a path prefix. Block rules go on matching as text,
/// which is what makes `shorts` and `reddit.com/r/` work at all.
private func testAnAllowRuleNamesAPlaceRatherThanAString() {
    let allow = Rule(pattern: "example-site.com", matchType: .websiteOrText, action: .allow)
    for escape in ["blocked-site.com/search/example-site.com", "other-site.com/example-site.com"] {
        expectNil(matched(url: escape, [allow]), "“\(escape)” is not the allowed place")
    }
    for real in ["example-site.com", "https://www.example-site.com/", "example-site.com/some/page"] {
        expectEqual(matched(url: real, [allow])?.id, allow.id, "“\(real)” is")
    }
    expectEqual(
        matched(url: "https://blog.example-site.com/post", [allow])?.id, allow.id,
        "and so is a subdomain of it, the rule every host comparison in this app follows"
    )
    expectNil(
        matched(url: "notexample-site.com/x", [allow]),
        "the dot is what stops a longer name ending in the allowed one from counting"
    )

    // The same shape in the YouTube group, which is where the exception layer earns its place.
    let music = Rule(pattern: "music.youtube.com", matchType: .websiteOrText, action: .allow)
    expectEqual(
        matched(url: "https://music.youtube.com/watch?v=abc", [music])?.id, music.id,
        "the headline case still works: block the site, allow the music"
    )
    expectNil(
        matched(url: "youtube.com/results?search_query=music.youtube.com", [music]),
        "and typing it into a search box is not a way onto the site"
    )

    // A block rule is unchanged, and it has to be: both of these are text in a path.
    let shorts = Rule(pattern: "shorts", matchType: .websiteOrText, action: .block)
    let subreddits = Rule(pattern: "reddit.com/r/", matchType: .websiteOrText, action: .block)
    expectEqual(
        matched(url: "https://www.youtube.com/shorts/abc", [shorts])?.id, shorts.id,
        "a block still matches anywhere in the address"
    )
    expectEqual(
        matched(url: "https://old.reddit.com/r/swift", [subreddits])?.id, subreddits.id,
        "including a fragment of one that no host would ever equal"
    )
}

/// A path is matched in whole segments, for the reason a host is matched on the dot: an allowed
/// place is the thing named and what is under it, and nothing that merely starts with the letters.
private func testAnAllowRulesPathIsMatchedInWholeSegments() {
    let allow = Rule(pattern: "reddit.com/r/rust", matchType: .websiteOrText, action: .allow)
    expectEqual(matched(url: "reddit.com/r/rust", [allow])?.id, allow.id, "the page itself")
    expectEqual(
        matched(url: "https://reddit.com/r/rust/comments/1", [allow])?.id, allow.id,
        "and anything under it"
    )
    expectNil(matched(url: "reddit.com/r/rustlang", [allow]), "but not the subreddit next door")
    expectNil(matched(url: "reddit.com/r", [allow]), "and not the parent")
    expectNil(
        matched(url: "old.reddit.com/x/reddit.com/r/rust", [allow]),
        "and not the whole pattern buried in somebody else's path"
    )
}

/// The bug at the layer it did its damage: `WebResolver` drops a group's entire claim on a URL any
/// allow of that group's matched, so one string in a path freed every site the group carries.
private func testAnAllowedStringInThePathCannotFreeTheGroup() {
    var adult = GroupSettings.standard
    adult.name = "Adult"
    adult.categories = ["adult"]
    adult.rules = [
        Rule(pattern: "example-site.com", matchType: .websiteOrText, action: .block),
        Rule(pattern: "example-site.com", matchType: .websiteOrText, action: .allow),
    ]
    let config = Config(version: 1, targets: [], groupSettings: ["adult": adult])

    for escape in [
        "https://xvideos.com/search/example-site.com", "https://pornhub.com/example-site.com",
    ] {
        expectEqual(
            WebResolver.match(url: escape, in: config)?.groupID, "adult",
            "“\(escape)” is still the group's, whatever is written in its path"
        )
    }
    expectNil(
        WebResolver.match(url: "https://example-site.com/creator", in: config),
        "and the place the exception actually names is still carved out"
    )
}

// MARK: - The order

private func testHighPriorityIsReadFirst() {
    let broad = Rule(pattern: "youtube.com", matchType: .websiteOrText, action: .allow, highPriority: true)
    let exact = Rule(pattern: "youtube.com/watch", matchType: .specificPage, action: .block)
    expectEqual(
        matched(url: "youtube.com/watch", [exact, broad])?.id, broad.id,
        "a high-priority rule outranks a more specific one that is not marked"
    )
}

private func testSpecificityBeatsBreadth() {
    let broad = Rule(pattern: "youtube.com", matchType: .websiteOrText, action: .block)
    let exact = Rule(pattern: "youtube.com/feed/subscriptions", matchType: .specificPage, action: .allow)
    expectEqual(
        matched(url: "youtube.com/feed/subscriptions", [broad, exact])?.id, exact.id,
        "a specific page is read before a text match, whatever order they were written in"
    )
}

private func testAllowBeatsBlockAtEqualFooting() {
    let block = Rule(pattern: "youtube.com", matchType: .websiteOrText, action: .block)
    let allow = Rule(pattern: "music.youtube.com", matchType: .websiteOrText, action: .allow)
    expectEqual(
        matched(url: "https://music.youtube.com/watch", [block, allow])?.action, .allow,
        "an exception carved out of a block wins at equal priority and specificity"
    )
    expectEqual(
        matched(url: "https://www.youtube.com/watch", [block, allow])?.action, .block,
        "and changes nothing where it does not apply"
    )
}

private func testDeclarationOrderIsTheLastTieBreak() {
    let first = Rule(id: "a", pattern: "youtube", matchType: .websiteOrText, action: .block)
    let second = Rule(id: "b", pattern: "youtube.com", matchType: .websiteOrText, action: .block)
    expectEqual(
        matched(url: "youtube.com/watch", [first, second])?.id, "a",
        "two rules that tie on everything else are read in the order they were written"
    )
    expectEqual(
        matched(url: "youtube.com/watch", [second, first])?.id, "b",
        "which means reordering the list is what changes the answer"
    )
}

// MARK: - The adult list, which is now a category

/// The switch and its private priority level are gone: the list is `DistractionCategory.adult`,
/// read the way every other category is. What that buys is checked here — the matcher has one
/// kind of thing to read, and a group that wrote nothing about a page claims nothing.
private func testTheAdultListIsAnOrdinaryCategory() {
    let adult = "https://www.pornhub.com/view"
    expectNil(
        RuleMatcher.match(url: adult, rules: []),
        "no rule, no claim — there is no second list read underneath the rules any more"
    )
    expect(
        DistractionCategory.adult.domains.contains("pornhub.com"),
        "the curated list survived the switch it used to sit behind"
    )
    expect(
        DistractionCategory.builtIns.contains { $0.id == "adult" },
        "as an ordinary seeded category, tickable per group like the other six"
    )

    // It used to outrank nothing and be outranked by everything, which was a third precedence
    // rule to hold in your head. As a category it is scope, and a group's own allow rule carves
    // out of it exactly the way it carves out of Social.
    let allow = Rule(pattern: "pornhub.com", matchType: .websiteOrText, action: .allow)
    expectEqual(
        RuleMatcher.match(url: adult, rules: [allow])?.action, .allow,
        "and a rule the user wrote still decides"
    )
}

/// A host in any other shape matches nothing at all, so the list is checked against the
/// normalizer rather than read by eye. `CategoryTests` gives every seeded list the same guarantee;
/// this keeps the check that came with the list when it was its own type.
private func testAdultListShape() {
    for domain in DistractionCategory.adult.domains {
        expectEqual(
            RuleMatcher.normalize(url: domain), domain, "adult entry \(domain) is normalized"
        )
    }
    expectEqual(
        Set(DistractionCategory.adult.domains).count, DistractionCategory.adult.domains.count,
        "the adult list has no duplicates"
    )
}

// MARK: - Which group claims a page

private func testResolverPrefersAnExplicitBlock() {
    let target = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
    var rules = GroupSettings.standard
    rules.name = "Focus"
    rules.rules = [Rule(pattern: "shorts", matchType: .websiteOrText, action: .block)]
    let config = Config(
        version: 1,
        targets: [target],
        groupSettings: [target.groupID: .standard, "grp:focus": rules]
    )

    let byRule = WebResolver.match(url: "https://www.youtube.com/shorts/abc", in: config)
    expectEqual(byRule?.groupID, "grp:focus", "a rule claims a URL no target names")
    expectNil(byRule?.targetID, "and it carries no target, because none was involved")
    expectEqual(byRule?.displayName, "Focus", "the group's own name is what the screen says")

    let byTarget = WebResolver.match(url: "https://old.reddit.com/r/swift", in: config)
    expectEqual(byTarget?.targetID, target.id, "a plain target still claims its own subdomains")

    expectNil(WebResolver.match(url: "https://example.com", in: config), "and nothing else is claimed")
}

private func testResolverLetsAnAllowCarveOutItsOwnTarget() {
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    var settings = GroupSettings.standard
    settings.rules = [Rule(pattern: "music.youtube.com", matchType: .websiteOrText, action: .allow)]
    let other = Target(kind: .domain, value: "music.youtube.com", displayName: "Music", groupID: "grp:other")
    let config = Config(
        version: 1,
        targets: [target],
        groupSettings: [target.groupID: settings]
    )
    expectNil(
        WebResolver.match(url: "https://music.youtube.com/watch", in: config),
        "an allow in the target's own group carves the exception out of it"
    )
    expectEqual(
        WebResolver.match(url: "https://www.youtube.com/watch", in: config)?.targetID, target.id,
        "and leaves the rest of the site blocked"
    )

    // The same allow, with the exempted site a target of *another* group, must not free it:
    // stepping aside is a statement about the group that made it and nothing else.
    let split = Config(
        version: 1,
        targets: [target, other],
        groupSettings: [target.groupID: settings, "grp:other": .standard]
    )
    expectEqual(
        WebResolver.match(url: "https://music.youtube.com/watch", in: split)?.targetID, other.id,
        "one group's exception says nothing about another group's target"
    )
    expectEqual(
        WebResolver.match(url: "https://music.youtube.com/watch", in: split)?.groupID, "grp:other",
        "and the more specific of two overlapping targets is the one that claims the page"
    )
}

/// Whitelist mode is gone, and with it the third step of `WebResolver.match`. A group that
/// wrote nothing about a URL now says nothing about it — there is no longer a flag that turns
/// silence into a block, which was the one way a group could claim a page nobody had named.
private func testAGroupThatWroteNothingClaimsNothing() {
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    var quiet = GroupSettings.standard
    quiet.name = "Locked down"
    let config = Config(
        version: 1,
        targets: [target],
        groupSettings: [target.groupID: .standard, "grp:locked": quiet]
    )
    expectEqual(
        WebResolver.match(url: "https://youtube.com/watch", in: config)?.targetID, target.id,
        "a named target is still claimed by the group that names it"
    )
    expectNil(
        WebResolver.match(url: "https://example.com", in: config),
        "and a page no group named is claimed by none of them"
    )
}

private func testResolverIgnoresSwitchedOffGroups() {
    var off = GroupSettings.standard
    off.enabled = false
    off.rules = [Rule(pattern: "shorts", matchType: .websiteOrText, action: .block)]
    let config = Config(
        version: 1, targets: [], groupSettings: ["grp:off": off]
    )
    expectNil(
        WebResolver.match(url: "https://youtube.com/shorts/a", in: config),
        "a group that is switched off claims nothing, rules or no rules"
    )
}

// MARK: - Helpers

private func matched(url: String, _ rules: [Rule]) -> Rule? {
    RuleMatcher.match(url: url, rules: rules)
}
