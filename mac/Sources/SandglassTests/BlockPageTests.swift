import SandglassAppCore
import SandglassCore
import Foundation

// The address a blocked tab is sent to, and what comes back off one. Every rule here is arithmetic
// on strings, and every one of them is load-bearing: the query string is the only copy of the
// address the user was interrupted on, so a round trip that loses a character is a tab that can
// never go home.

func runBlockPageTests() {
    theShapeOfTheAddress()
    theWholeAddressOfARealBlock()
    aBrowserThatDecodesSomeOfItIsStillUnderstood()
    aTargetThatIsItselfAnAddress()
    readingOneBack()
    whereTheButtonGoes()
    theCountdownNeverEndsEarly()
    aCountdownThatIsNotANumber()
    refusingAnythingElse()
    theTwoStates()
    tellingABrowserToGo()
    whatTheBrowserIsShowing()
    theSettleWindow()
}

private let page = URL(fileURLWithPath: "/Applications/Sandglass.app/Contents/Resources/block.html")
private let info = TargetDisplayInfo(targetID: "domain:instagram.com", name: "Instagram")

// MARK: - The address

/// A file URL into the bundle with the query riding along — and no local HTTP server to serve
/// it. Focus runs one on ports 8919–8925 for exactly this job and does not need to.
private func theShapeOfTheAddress() {
    let query = BlockPage.Query(
        target: "https://www.instagram.com/", name: "Instagram", mode: .blocked,
        untilText: "Blocked until 17:00"
    )
    let address = BlockPage.address(page: page, query: query)
    expect(
        address.hasPrefix(
            "file:///Applications/Sandglass.app/Contents/Resources/block.html?"
        ),
        "the page is a file in the bundle, opened as one"
    )
    expect(
        address.contains("target=https%3A%2F%2Fwww.instagram.com%2F"),
        "and the address it interrupted rides in the query, escaped whole"
    )
    expect(address.contains("mode=blocked"), "the app decides which state the page draws")
    expect(
        address.contains("until=Blocked%20until%2017%3A00"),
        "a space is escaped rather than left to a browser's idea of one"
    )
}

/// The whole thing, character for character, for the one block a person is most likely to meet.
///
/// Every other check here is about one field. This is the address a tab is actually sent to, and it
/// is pinned whole for the reason `StoreFormatTests` pins a document: it is read by something this
/// suite cannot run — a browser, and the page's own script — and a field quietly renamed or dropped
/// would be a block page that draws the wrong thing or a button that goes nowhere, with every test
/// still green.
private func theWholeAddressOfARealBlock() {
    let query = BlockPage.Query(
        target: "instagram.com",
        name: "Instagram",
        mode: .wait,
        budgetLine: "2 of 5 opens left today",
        endsAt: Date(timeIntervalSince1970: 1_760_000_300),
        opens: "https://www.instagram.com/"
    )
    expectEqualText(
        BlockPage.address(page: page, query: query),
        "file:///Applications/Sandglass.app/Contents/Resources/block.html"
            + "?mode=wait"
            + "&target=instagram.com"
            + "&opens=https%3A%2F%2Fwww.instagram.com%2F"
            + "&name=Instagram"
            + "&budget=2%20of%205%20opens%20left%20today"
            + "&ends=1760000300",
        "the address a blocked tab is sent to, whole"
    )
}

/// **A browser is free to report our own address partially decoded**, and this app has no way of
/// asking which ones do. So the reader is defensive rather than targeted: every case below is the
/// exact same address with one class of escape turned back into the character it stood for.
///
/// It used to be read through `URL(string:)`, which re-encodes what it is handed — so one decoded
/// space made every `%` that had survived into `%25`, and `target` came back as
/// `reddit.com%2Fr%2Fall`: a page nothing manages, which sent the tab "home" to an address that is
/// not one. A decoded `#` was worse still and cost the whole query, so the tab became invisible to
/// this app for good.
private func aBrowserThatDecodesSomeOfItIsStillUnderstood() {
    let sent = BlockPage.Query(
        target: "reddit.com/r/all", name: "Reddit", mode: .wait,
        budgetLine: "5 of 5 opens left today",
        endsAt: Date(timeIntervalSince1970: 1_760_000_060),
        opens: "https://www.reddit.com/r/all?sort=new&t=day#top"
    )
    let address = BlockPage.address(page: page, query: sent)
    for (escape, character) in [("%20", " "), ("%23", "#"), ("%3F", "?"), ("%3D", "=")] {
        let reported = address.replacingOccurrences(of: escape, with: character)
        guard let back = BlockPage.query(of: reported, page: page) else {
            failTest("\(escape) reported as \(character) is still our own page")
            continue
        }
        expectEqual(back.target, sent.target, "\(escape) as \(character): the target is the page")
        expectEqual(back.mode, sent.mode, "\(escape) as \(character): the mode is the app's")
        expectEqual(back.name, sent.name, "\(escape) as \(character): the name is whole")
        expectEqual(back.opens, sent.opens, "\(escape) as \(character): the way home is whole")
        expectEqual(back.endsAt, sent.endsAt, "\(escape) as \(character): the wait is whole")
    }

    // The one that cannot be undone: a decoded `&` is the separator it was escaped to avoid being.
    // What is asked of it is that the damage stops at the field it is in — `mode` and `target` are
    // written in front of everything carrying a browser's or a user's text for exactly this — and
    // that the button falls back to the page the target names rather than to a truncation of one.
    let ampersand = address.replacingOccurrences(of: "%26", with: "&")
    guard let back = BlockPage.query(of: ampersand, page: page) else {
        failTest("a decoded ampersand still leaves our own page recognisable")
        return
    }
    expectEqual(back.target, sent.target, "the target is in front of it and survives it")
    expectEqual(back.mode, sent.mode, "and so is the mode")
    expectEqual(
        RuleMatcher.normalize(url: back.opens), sent.target,
        "and the button still opens the page the tab was interrupted on, whole or truncated"
    )

    // Nothing later may name a field that has already been read: the fields are first-wins, so a
    // value that damaged itself cannot become an `opens` pointing somewhere else.
    expectEqual(
        BlockPage.query(
            of: "\(page.absoluteString)?mode=wait&target=instagram.com"
                + "&opens=https%3A%2F%2Finstagram.com&opens=https%3A%2F%2Fevil.example",
            page: page
        )?.opens,
        "https://instagram.com",
        "a second copy of a field is not the one that counts"
    )

    // The three spellings of a local file. This app writes one of them and reads whichever the
    // browser hands back.
    for spelling in ["file:///", "file://localhost/", "file:/"] {
        let path = page.path.dropFirst()
        expectEqual(
            BlockPage.query(of: "\(spelling)\(path)?mode=wait&target=x.com", page: page)?.target,
            "x.com",
            "\(spelling) names the same file"
        )
    }
}

/// The case the whole encoding exists for. A target carries `?`, `#`, `&` and `=` of its own, and
/// every one of them would end the value early or invent a field of its own.
private func aTargetThatIsItselfAnAddress() {
    let target = "https://www.youtube.com/watch?v=abc&t=90#comments"
    let address = BlockPage.address(
        page: page,
        query: BlockPage.Query(target: target, name: "YouTube", mode: .blocked)
    )
    expect(
        address.contains(
            "target=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc%26t%3D90%23comments"
        ),
        "a query string and a fragment inside the target are escaped, not passed through"
    )
    expectEqual(
        BlockPage.query(of: address, page: page)?.target,
        target,
        "and come back exactly as they went in"
    )
    // A `+` in an address is a plus, not a space. This app escapes a real one as %2B, so reading
    // one as a space could only ever corrupt something a person typed.
    let plus = "https://example.com/a+b"
    expectEqual(
        BlockPage.query(
            of: BlockPage.address(
                page: page, query: BlockPage.Query(target: plus, name: "x", mode: .blocked)
            ),
            page: page
        )?.target,
        plus,
        "a plus survives the round trip as a plus"
    )
}

private func readingOneBack() {
    let sent = BlockPage.Query(
        target: "https://reddit.com/r/all", name: "Reddit", mode: .wait,
        budgetLine: "2 of 5 opens left today",
        endsAt: Date(timeIntervalSince1970: 1_760_000_030)
    )
    let back = BlockPage.query(of: BlockPage.address(page: page, query: sent), page: page)
    expectEqual(back, sent, "everything the page is told comes back off it")
    // Absolute rather than a duration: the countdown has to survive the user reloading, and a
    // duration would hand them a fresh wait every time they pressed ⌘R.
    expectEqual(
        back?.endsAt,
        Date(timeIntervalSince1970: 1_760_000_030),
        "the end of the wait is a moment, not a length"
    )
}

// MARK: - Where the button goes

/// The button is a plain link, so the address behind it is the whole of the mechanism: get it
/// wrong and the press lands somewhere that is not the site, which is every way this has failed so
/// far. Whether a browser follows an `href` cannot be checked here and does not need to be. What
/// can be checked is the address the app puts on it.
private func whereTheButtonGoes() {
    // The page is loaded from `file://`, so a bare host would resolve against the app bundle and
    // land on a "file not found" of the browser's own. `target` never carries a scheme — the
    // engine's normalizer takes it off — so one is always put back.
    expectEqual(
        BlockPage.opening(from: nil, target: "instagram.com"),
        "https://instagram.com",
        "the name the rules know a page by is not an address a browser can follow"
    )

    // What the browser reported is used whole, and this is the reason: `target` lost the video id
    // to the normalizer on the way in, and a button that lands on `youtube.com/watch` has not
    // taken anybody to the video they were watching.
    expectEqual(
        BlockPage.opening(
            from: "https://www.youtube.com/watch?v=abc&t=90", target: "youtube.com/watch"
        ),
        "https://www.youtube.com/watch?v=abc&t=90",
        "the address the browser reported still has the video on it, and is used whole"
    )

    // By the time a redraw reads that field back, the whole query has been sitting in an address
    // bar somebody can edit. An address that names somewhere else is thrown away rather than
    // followed: this app navigates tabs, and it will not navigate one to an address it was handed.
    expectEqual(
        BlockPage.opening(from: "https://evil.example/", target: "instagram.com"),
        "https://instagram.com",
        "an edited field that names another site is not where the tab goes"
    )
    expectEqual(
        BlockPage.opening(from: "javascript:alert(1)", target: "instagram.com"),
        "https://instagram.com",
        "and no scheme but the web's ever reaches an href on our own page"
    )
    expectEqual(
        BlockPage.opening(from: "file:///etc/passwd", target: "instagram.com"),
        "https://instagram.com",
        "including the one this page is itself loaded from"
    )

    // Credentials come out, and they are the one thing that does. The block page's address ends up
    // in the address bar and in the browser's own history, so a password left in this field is
    // written down twice in places the user cannot easily clear.
    expectEqual(
        BlockPage.opening(
            from: "https://joe:hunter2@intranet.example.com/p/1?a=b",
            target: "intranet.example.com/p/1"
        ),
        "https://intranet.example.com/p/1?a=b",
        "a password in the address a browser reported never reaches the query string"
    )
    expectEqual(
        BlockPage.opening(from: "https://joe@example.com/x", target: "example.com/x"),
        "https://example.com/x",
        "and neither does a bare user name"
    )
    // An `@` after the authority is part of the path and is nothing to do with credentials.
    expectEqual(
        BlockPage.opening(from: "https://example.com/@someone", target: "example.com/@someone"),
        "https://example.com/@someone",
        "an at sign in the path is a character in the path"
    )

    // `http` is a web address too. Downgrading somebody's own address to https would be this app
    // deciding something about their connection that it knows nothing about.
    expectEqual(
        BlockPage.opening(from: "http://neverssl.com/", target: "neverssl.com"),
        "http://neverssl.com/",
        "a plain-http page comes back as the plain-http page it was"
    )

    // The whole thing rides in the query and comes back out of it, exactly, or the button lands
    // on a truncated address.
    let query = BlockPage.Query(
        target: "youtube.com/watch", name: "YouTube", mode: .wait,
        opens: "https://www.youtube.com/watch?v=abc&t=90#top"
    )
    let address = BlockPage.address(page: page, query: query)
    expect(
        address.contains("opens=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc%26t%3D90%23top"),
        "the address the button opens is escaped whole, like the target beside it"
    )
    expectEqual(
        BlockPage.query(of: address, page: page)?.opens,
        "https://www.youtube.com/watch?v=abc&t=90#top",
        "and comes back exactly as it went in"
    )

    // A page built before this field existed, or one somebody deleted it from, still has a button
    // that works: it falls back to the target, which is the one thing every block page carries.
    expectEqual(
        BlockPage.query(of: "\(page.absoluteString)?target=instagram.com&mode=wait", page: page)?
            .opens,
        "https://instagram.com",
        "a query with no address to open falls back to the one the target names"
    )
}

/// The wait the page draws and the wait the ledger enforces have to agree, and only one direction
/// of disagreement is harmless.
///
/// `Date()` is never a whole second, so truncating the end of the wait into the query put the
/// page's zero up to a second before the app's: the button appeared, the walk it caused was
/// refused as early, and the honest repair for that is a fresh countdown. A user pressing the
/// moment the button appeared could serve the wait twice for no reason at all. Rounded up, the
/// page is the one that is late, and a late button is a button that works.
private func theCountdownNeverEndsEarly() {
    let minted = Date(timeIntervalSince1970: 1_760_000_000.4)
    let address = BlockPage.address(
        page: page,
        query: BlockPage.Query(
            target: "instagram.com", name: "Instagram", mode: .wait,
            endsAt: minted.addingTimeInterval(30)
        )
    )
    guard let endsAt = BlockPage.query(of: address, page: page)?.endsAt else {
        failTest("the end of the wait rides in the query")
        return
    }
    expect(
        endsAt >= minted.addingTimeInterval(30),
        "the page's countdown never reaches zero before the wait it draws is claimable"
    )
    expect(
        endsAt < minted.addingTimeInterval(31),
        "and is never more than the one second of rounding late"
    )
}

/// `ends` is a field in an address bar, and a `Double` will happily parse things that are not
/// moments. `Int(_:)` **traps** on an infinity and on a NaN, so a query read back off a tab and
/// written out again would take the app down with it — one caller away, since nothing re-serializes
/// a parsed query today. A page with no countdown is the honest answer: it draws one less line.
private func aCountdownThatIsNotANumber() {
    for text in ["1e400", "-1e400", "nan", "inf", "99999999999999999999999"] {
        let query = BlockPage.query(
            of: "\(page.absoluteString)?mode=wait&target=x.com&ends=\(text)", page: page
        )
        guard let query else {
            failTest("ends=\(text) leaves a page that is still our own")
            continue
        }
        expectNil(query.endsAt, "ends=\(text) names no moment, so the page counts nothing down")
        expect(
            !BlockPage.address(page: page, query: query).contains("ends="),
            "and the address built back out of it carries no countdown either"
        )
    }
    expectEqual(
        BlockPage.query(
            of: "\(page.absoluteString)?mode=wait&target=x.com&ends=1760000060", page: page
        )?.endsAt,
        Date(timeIntervalSince1970: 1_760_000_060),
        "an ordinary one is still a moment"
    )
}

/// Nothing on the web may pretend to be this page. It is matched on being a `file:` URL at exactly
/// our own path, so a site that copied the query string is still just a site.
private func refusingAnythingElse() {
    expectNil(
        BlockPage.query(of: "https://evil.example/block.html?target=x&mode=wait", page: page),
        "a page on the web is not our block page whatever it puts in its query"
    )
    expectNil(
        BlockPage.query(
            of: "file:///Users/someone/block.html?target=x&mode=wait", page: page
        ),
        "and neither is another block.html somewhere else on the disk"
    )
    expectNil(
        BlockPage.query(of: page.absoluteString, page: page),
        "our own page with no target is carrying nothing to go back to"
    )
    expectNil(
        BlockPage.query(of: "\(page.absoluteString)?target=x", page: page),
        "and one with no mode is a page that could not be drawn"
    )
}

// MARK: - Which state the page draws

private func theTwoStates() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let waiting = PauseScreenModel.for(
        decision: .pause(countdownSeconds: 30, budgetLine: "2 of 5 opens left today"), info: info
    )
    let query = BlockPage.Query(
        model: waiting!, target: "instagram.com", now: now,
        address: "https://www.instagram.com/"
    )
    expectEqual(query.mode, .wait, "a way through draws the countdown and the button")
    expectEqual(query.endsAt, now.addingTimeInterval(30), "the wait ends thirty seconds from now")
    expectEqual(query.budgetLine, "2 of 5 opens left today", "in the engine's own words")
    expectEqual(
        query.opens, "https://www.instagram.com/",
        "and the button opens the address the tab was actually on"
    )
    expectEqual(query.name, "Instagram", "named the way the pause screen would name it")

    let walled = PauseScreenModel.for(
        decision: .blocked(reason: .schedule, untilText: "Blocked until 17:00"), info: info
    )
    let hard = BlockPage.Query(
        model: walled!, target: "instagram.com", now: now,
        address: "https://www.instagram.com/"
    )
    expectEqual(hard.mode, .blocked, "no way through draws what is blocked and until when")
    expectEqual(hard.untilText, "Blocked until 17:00", "in the engine's own sentence")
    expectNil(hard.endsAt, "there is no wait to count")
    // The address is carried either way — the tab still has to be able to go home when the block
    // lifts on its own — but the page never draws a button on it to press. What stops a wall from
    // being walked out of is that no wait is written down for one: see `EarnedOpens`.
    expectEqual(
        hard.opens, "https://www.instagram.com/", "and the way home is still on it, unpressable"
    )
}

// MARK: - Telling a browser to go there

private func tellingABrowserToGo() {
    let chrome = Browsers.browser(forBundleID: "com.google.Chrome")!
    let source = chrome.navigationScriptSource(to: "file:///x/block.html?target=y")
    expectEqualText(
        source,
        """
        with timeout of 1 second
        tell application id "com.google.Chrome" to set URL of active tab of front window to "file:///x/block.html?target=y"
        end timeout
        """,
        "the tab in front is navigated in place — never a new tab, never a new window"
    )
    expect(chrome.canNavigate, "Chrome's dictionary answers")

    // Firefox is a case of its own rather than a fallthrough: we read it through the accessibility
    // tree, and there is no sound way to write its address bar the same way. It keeps the overlay.
    let firefox = Browsers.browser(forBundleID: "org.mozilla.firefox")!
    expect(!firefox.canNavigate, "Firefox cannot be told to go anywhere")
    expectNil(firefox.navigationScriptSource(to: "x"), "so there is no line to send it")

    for browser in Browsers.all where browser.bundleID != "org.mozilla.firefox" {
        expect(browser.canNavigate, "\(browser.name) can be navigated")
    }

    // Cannot arise from an address this app builds — they are percent-encoded — which is exactly
    // when a guard is worth having: a quote reaching the script would end the literal and leave
    // the rest of the address as code.
    expectEqual(
        KnownBrowser.appleScriptString("a\"b\\c"),
        "\"a\\\"b\\\\c\"",
        "a quote and a backslash are escaped into the literal"
    )
}

// MARK: - Which of the two the browser is showing

/// The ordering here is the whole point. The block page is a `file:` URL and `page(from:)` throws
/// every one of those away by design — nothing anybody blocks lives at one — so asking in the
/// other order would leave a blocked tab with no way of ever coming home.
private func whatTheBrowserIsShowing() {
    let address = BlockPage.address(
        page: page,
        query: BlockPage.Query(target: "instagram.com", name: "Instagram", mode: .blocked)
    )
    expectEqual(
        BrowserAddress.sighting(from: address, blockPage: page),
        .blockPage(
            BlockPage.Query(target: "instagram.com", name: "Instagram", mode: .blocked)
        ),
        "our own page is recognised before anything tries to read it as an address"
    )
    expectEqual(
        BrowserAddress.sighting(from: "https://www.instagram.com/reels", blockPage: page),
        .page("instagram.com/reels"),
        "an ordinary address is normalized exactly as the engine compares it"
    )
    expectNil(
        BrowserAddress.sighting(from: "about:blank", blockPage: page),
        "a new tab is nothing anybody blocks"
    )
    expectNil(
        BrowserAddress.sighting(from: "file:///Users/x/notes.html", blockPage: page),
        "and a local file that is not ours is still a file"
    )
    // A build with no resources — a raw SwiftPM binary, which is every headless run. There is no
    // page to navigate to, so there is none to recognise either.
    expectNil(
        BrowserAddress.sighting(from: address, blockPage: nil),
        "with no block page in the bundle, our own address is just a file"
    )
}

// MARK: - The gap before a browser says it moved

private func theSettleWindow() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let watching = "https://www.youtube.com/watch?v=A"
    let chrome = BrowserTab(browserID: "com.google.Chrome", tabID: "7")
    var sent = SentToBlockPage()
    expect(
        !sent.isSettling(tab: chrome, address: watching, now: start),
        "nothing has been sent anywhere yet"
    )
    sent.record(tab: chrome, from: watching, now: start)
    // A browser does not report a navigation the instant it is asked for one, and the poll comes
    // round once a second. Deciding again on the stale reading would put a second countdown over
    // the one already running.
    expect(
        sent.isSettling(tab: chrome, address: watching, now: start.addingTimeInterval(1)),
        "the same tab is not sent twice while the browser catches up"
    )
    expect(
        !sent.isSettling(
            tab: BrowserTab(browserID: "com.apple.Safari", tabID: "7"), address: watching,
            now: start.addingTimeInterval(1)
        ),
        "another browser on the same address is its own tab, whatever it calls it"
    )
    // **The identical address in another tab.** The last thing this guard swallowed. It named a
    // browser, so for three seconds a sibling tab on the very same address was walked past without
    // being decided on at all — not blocked, not counted down, nothing. The tab is in the key now,
    // and the only tab that gets those three seconds is the one that was asked to move.
    expect(
        !sent.isSettling(
            tab: BrowserTab(browserID: "com.google.Chrome", tabID: "8"), address: watching,
            now: start.addingTimeInterval(1)
        ),
        "a second tab on the identical address is blocked rather than waited for"
    )
    // **The address, not the page.** This held the normalized target once, and a page is a thing
    // several tabs can be on: for three seconds after one of them was sent away, every other tab
    // on that page in that browser was walked past without a decision. A second tab is not the
    // navigation this app is waiting on.
    expect(
        !sent.isSettling(
            tab: chrome, address: "https://www.youtube.com/watch?v=B",
            now: start.addingTimeInterval(1)
        ),
        "a second tab on the same page is blocked rather than waited for"
    )
    expect(
        !sent.isSettling(
            tab: chrome, address: "https://reddit.com", now: start.addingTimeInterval(1)
        ),
        "and another site is a new decision, as it always was"
    )
    expect(
        !sent.isSettling(
            tab: chrome, address: watching,
            now: start.addingTimeInterval(SentToBlockPage.settleSeconds)
        ),
        "a navigation that never arrived stops being waited for"
    )
    sent.forget()
    expect(
        !sent.isSettling(tab: chrome, address: watching, now: start),
        "and the arrival clears it outright"
    )

    // Safari and Firefox, whose tabs have no identity: one key for the whole browser, which is
    // what every browser had before. The three seconds are still open there, and stating it here
    // is what keeps that a known limit rather than a surprise.
    let blind = BrowserTab(browserID: "com.apple.Safari", tabID: nil)
    var unnamed = SentToBlockPage()
    unnamed.record(tab: blind, from: watching, now: start)
    expect(
        unnamed.isSettling(tab: blind, address: watching, now: start.addingTimeInterval(1)),
        "a browser that cannot name its tabs waits on the address, as everything used to"
    )
}
