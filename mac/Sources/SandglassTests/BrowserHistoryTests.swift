import SandglassAppCore
import Foundation

/// What setup offers as "sites you actually visit", worked out without a browser in sight.
///
/// The whole point of `BrowserHistory` being a value type with the file access injected: a list
/// built from somebody's real history cannot be checked by looking at it, because it is different
/// on every Mac. What can be checked is every rule that turns rows into that list — which host a
/// URL counts as, what is thrown away, what order the rest come in, and what is said when a
/// browser will not answer.
func runBrowserHistoryTests() {
    testTheMostVisitedComeFirst()
    testOneSitePerDomainWhateverTheSubdomain()
    testWhatIsNotASite()
    testWhatIsAlreadyPickedIsNotOffered()
    testAnUnreadableBrowserSaysSoInOneLine()
    testEachBrowsersHistoryIsWhereItActuallyLives()
    testOneBrowsersFilesFoldIntoOneAnswer()
}

// MARK: - Fixtures

private func visits(_ rows: [(String, Int)]) -> BrowserHistory.Reading {
    .visits(rows.map { BrowserHistory.Visit(url: $0.0, count: $0.1) })
}

private func answer(_ browser: String, _ rows: [(String, Int)]) -> BrowserHistory.Answer {
    BrowserHistory.Answer(browser: browser, reading: visits(rows))
}

// MARK: - Ranking

/// The order is the whole feature: a list of the sites somebody visits, in the order they visit
/// them, is a different offer from seven names chosen by whoever wrote the defaults.
private func testTheMostVisitedComeFirst() {
    let ranking = BrowserHistory.rank([
        answer("Chrome", [("https://youtube.com/feed", 40), ("https://news.ycombinator.com", 12)]),
        answer("Arc", [("https://reddit.com/r/swift", 90), ("https://youtube.com", 30)]),
    ])
    // `ycombinator.com` rather than `news.ycombinator.com` on purpose: a domain target covers
    // everything under it (`WebResolver.domainTarget`), so the shorter row blocks the page the
    // user actually visits and every sibling of it.
    expectEqual(ranking.sites.map(\.host), ["reddit.com", "youtube.com", "ycombinator.com"], "most visited first")
    expectEqual(
        ranking.sites.first { $0.host == "youtube.com" }?.visits, 70,
        "and a site open in two browsers is one row with both counts in it"
    )
    expectNil(ranking.line, "nothing was refused, so nothing is said")

    // A tie is broken by name rather than by whichever browser was read first, so the list does
    // not reshuffle itself between two openings of setup.
    let tied = BrowserHistory.rank([answer("Chrome", [("b.com", 3), ("a.com", 3), ("c.com", 3)])])
    expectEqual(tied.sites.map(\.host), ["a.com", "b.com", "c.com"], "an even week is listed alphabetically")

    let long = (1...40).map { ("https://site\(String(format: "%02d", $0)).com", 100 - $0) }
    expectEqual(
        BrowserHistory.rank([answer("Chrome", long)], limit: 5).sites.map(\.host),
        ["site01.com", "site02.com", "site03.com", "site04.com", "site05.com"],
        "and the picker asks for as many rows as it can show"
    )
}

/// Every visit to a site is a visit to the site: three rows in a picker for `youtube.com`,
/// `www.youtube.com` and `m.youtube.com` would be three checkboxes doing one job.
private func testOneSitePerDomainWhateverTheSubdomain() {
    let ranking = BrowserHistory.rank([
        answer("Chrome", [
            ("https://www.youtube.com/watch?v=abc", 10),
            ("https://m.youtube.com", 5),
            ("http://youtube.com/", 2),
        ]),
    ])
    expectEqual(ranking.sites.count, 1, "one row")
    expectEqual(ranking.sites.first?.host, "youtube.com", "under the name a rule would be written against")
    expectEqual(ranking.sites.first?.visits, 17, "carrying every visit under it")

    expectEqual(
        BrowserHistory.registrableDomain(of: "news.bbc.co.uk"), "bbc.co.uk",
        "a two-label suffix keeps three labels, or the row would offer to block the whole of .co.uk"
    )
    expectEqual(BrowserHistory.registrableDomain(of: "tagesschau.de"), "tagesschau.de", "two labels are left alone")
    expectEqual(
        BrowserHistory.registrableDomain(of: "mail.google.com"), "google.com",
        "and an ordinary subdomain is folded in"
    )
}

/// A history file is full of things that are not websites, and each of them is in there in
/// quantity — enough to fill a list of two dozen rows on its own.
private func testWhatIsNotASite() {
    let ranking = BrowserHistory.rank([
        answer("Chrome", [
            ("chrome://newtab", 900),
            ("about:blank", 400),
            ("file:///Users/someone/notes.html", 120),
            ("http://localhost:3000/dashboard", 300),
            ("http://127.0.0.1:8080", 80),
            ("http://192.168.1.1", 40),
            ("http://nas.local/files", 25),
            ("https://youtube.com", 3),
        ]),
    ])
    expectEqual(ranking.sites.map(\.host), ["youtube.com"], "only the one that is a site anybody blocks")

    expectNil(BrowserHistory.site(of: "chrome://newtab"), "a browser page is not a site")
    expectNil(BrowserHistory.site(of: "http://localhost:3000"), "and neither is this Mac")
    expectNil(BrowserHistory.site(of: "https://10.0.0.4/admin"), "an address is not a name")
    expectEqual(BrowserHistory.site(of: "https://WWW.Reddit.com/r/x"), "reddit.com", "and case is not a difference")
}

/// Setup can be opened again over a configuration that already blocks things. Offering a site
/// that is already blocked is a checkbox that does nothing, in a list where every row costs a
/// glance.
private func testWhatIsAlreadyPickedIsNotOffered() {
    let ranking = BrowserHistory.rank(
        [answer("Chrome", [("https://youtube.com", 50), ("https://reddit.com", 10)])],
        excluding: ["www.youtube.com"]
    )
    expectEqual(
        ranking.sites.map(\.host), ["reddit.com"],
        "what is already blocked is left out, spelt however the configuration spells it"
    )
}

/// The case this whole three-way `Reading` exists for. Safari's history is behind Full Disk
/// Access, and a Safari user shown a list with no Safari in it would conclude the feature is
/// broken — when the fix is one checkbox in System Settings.
private func testAnUnreadableBrowserSaysSoInOneLine() {
    let safariRefused = BrowserHistory.Answer(
        browser: "Safari", reading: .denied(needsFullDiskAccess: true)
    )
    let withOthers = BrowserHistory.rank([safariRefused, answer("Chrome", [("youtube.com", 4)])])
    expectEqual(
        withOthers.line, "Safari's history needs Full Disk Access — the others are listed.",
        "the refusal is named, and so is what is still on offer"
    )
    expect(!withOthers.isEmpty, "and the list itself is what Chrome had")

    let alone = BrowserHistory.rank([safariRefused])
    expectEqual(
        alone.line, "Safari's history needs Full Disk Access and nothing else had a history to read.",
        "with nothing to fall back on, the line says that instead of promising a list"
    )
    expect(alone.isEmpty, "which is what sends setup back to the preset sites")

    let broken = BrowserHistory.rank([
        BrowserHistory.Answer(browser: "Brave", reading: .denied(needsFullDiskAccess: false)),
        answer("Chrome", [("youtube.com", 4)]),
    ])
    expectEqual(
        broken.line, "Brave's history couldn't be read — the others are listed.",
        "a refusal that is not about Full Disk Access does not claim to be"
    )

    // The two kinds are kept apart even together: folding them into one "couldn't be read" would
    // drop the only half of the sentence the user can do anything about.
    let both = BrowserHistory.rank([
        safariRefused,
        BrowserHistory.Answer(browser: "Brave", reading: .denied(needsFullDiskAccess: false)),
        answer("Chrome", [("youtube.com", 4)]),
    ])
    expectEqual(
        both.line,
        "Safari's history needs Full Disk Access, Brave's history couldn't be read — the others are listed.",
        "two kinds of refusal are one line, and each says what is true of it"
    )

    let nothing = BrowserHistory.rank([
        BrowserHistory.Answer(browser: "Arc", reading: .absent),
        BrowserHistory.Answer(browser: "Firefox", reading: .absent),
    ])
    expect(nothing.isEmpty, "a browser nobody has installed contributes nothing")
    expectNil(nothing.line, "and is not something to tell the user about")
    expect(BrowserHistory.rank([]).isEmpty, "and neither is a Mac with no browsers at all")
}

/// The paths, which are the one thing here that would be found out by a user rather than by a
/// test — a wrong directory reads exactly like a browser with no history.
private func testEachBrowsersHistoryIsWhereItActuallyLives() {
    let home = URL(fileURLWithPath: "/Users/someone")
    let chrome = BrowserHistory.location(forBundleID: "com.google.Chrome", home: home)
    expectEqual(
        chrome?.root.path, "/Users/someone/Library/Application Support/Google/Chrome",
        "Chrome keeps its profiles under Application Support"
    )
    expectEqual(chrome?.fileName, "History", "one database per profile, so two profiles are two halves of a week")
    expectEqual(chrome?.needsFullDiskAccess, false, "and nothing stands in the way of reading it")

    expectEqual(
        BrowserHistory.location(forBundleID: "company.thebrowser.Browser", home: home)?.root.path,
        "/Users/someone/Library/Application Support/Arc/User Data",
        "Arc is a Chromium browser with a directory of its own"
    )
    expectEqual(
        BrowserHistory.location(forBundleID: "org.mozilla.firefox", home: home)?.fileName,
        "places.sqlite",
        "Firefox names its database differently, and its rows live in another table"
    )

    let safari = BrowserHistory.location(forBundleID: "com.apple.Safari", home: home)
    expectEqual(safari?.root.path, "/Users/someone/Library/Safari/History.db", "Safari keeps one file")
    expectNil(safari?.fileName, "which is the file itself rather than a directory of profiles")
    expectEqual(safari?.needsFullDiskAccess, true, "and it is the one macOS stands in front of")

    expectNil(
        BrowserHistory.location(forBundleID: "com.example.notabrowser", home: home),
        "anything else has no history this app knows how to read"
    )
}

// MARK: - Folding one browser's files

/// What a browser's answer is, given what each of its database files said.
///
/// A Chromium browser has one file per profile and Safari has exactly one, so this is the rule
/// that turns "what happened to each file" into the single `Reading` the picker acts on. It is
/// here rather than in `BrowserHistoryFiles` because it is the half that decides what the user
/// is told, and the half next door is `copyItem` and `sqlite3_open`.
///
/// The case worth having a test for is `missing`. A file that is not there is a browser with no
/// history — the same fact as an absent profile directory — and reporting it as "couldn't be
/// read" put a warning about Safari in front of everyone who had granted Full Disk Access and
/// never opened Safari.
private func testOneBrowsersFilesFoldIntoOneAnswer() {
    let rows = [BrowserHistory.Visit(url: "https://youtube.com", count: 4)]

    expectEqual(
        BrowserHistory.fold([], needsFullDiskAccess: false), .absent,
        "no files at all is a browser with no history"
    )
    expectEqual(
        BrowserHistory.fold([.missing, .missing], needsFullDiskAccess: true), .absent,
        "and so is a file that is simply not there — Safari, never opened"
    )
    expectEqual(
        BrowserHistory.fold([.visits(rows), .denied], needsFullDiskAccess: false),
        .visits(rows),
        "anything readable wins: one locked profile out of two costs the user nothing"
    )
    expectEqual(
        BrowserHistory.fold([.visits(rows), .visits(rows)], needsFullDiskAccess: false),
        .visits(rows + rows),
        "two profiles are two halves of one week"
    )
    expectEqual(
        BrowserHistory.fold([.denied, .missing], needsFullDiskAccess: true),
        .denied(needsFullDiskAccess: true),
        "a refusal is named, and named as the permission it is"
    )
    expectEqual(
        BrowserHistory.fold([.unusable, .missing], needsFullDiskAccess: true),
        .denied(needsFullDiskAccess: false),
        "a file that is there and will not answer is said out loud, but not as a permission"
    )
    expectEqual(
        BrowserHistory.fold([.denied, .unusable], needsFullDiskAccess: false),
        .denied(needsFullDiskAccess: false),
        "and a refusal outranks a broken file, because it is the one with a way out"
    )
}
