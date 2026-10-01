import SandglassAppCore
import SandglassCore
import Foundation

/// Blocking a website by reading the browser: everything about it that is arithmetic.
///
/// What is deliberately not here is the half that talks to macOS — an Apple event into Safari, a
/// walk through Firefox's accessibility tree — because neither can be exercised on a machine with
/// no browser in front and no permissions granted, and a test that mocked them would only be
/// checking that the mock was written the way the code was. What *is* here is every decision
/// those calls hang off: which browser is which, what counts as a page, what an error means for
/// the route that produced it, how long a refused route rests, and what the user ends up looking
/// at when a blocked address is in front.
func runBrowserWatchTests() {
    testTheSixBrowsersAreKnownAndNothingElseIs()
    testFirefoxHasOnlyTheAccessibilityRoute()
    testTheScriptNamesTheBrowserByIdAndBoundsItsOwnWait()
    testTheScriptBringsBackTheTabTheAddressCameFrom()
    testAnAnswerIsSplitBackIntoTheTabAndTheAddress()

    testAPageIsNormalizedExactlyAsARuleIs()
    testWhatIsNotAPageIsNotReadAsOne()
    testAnErrorIsOnlyRestedWhenItMeansTheRouteIsShut()

    testTheRouteThatAnsweredIsTriedFirstNextTime()
    testARefusedRouteRestsAndComesBack()
    testConsecutiveRefusalsRestLongerAndStopGrowing()
    testSuccessForgivesTheBackoffEntirely()
    testFirefoxWithNoAccessibilityHasNothingLeftToTry()

    testAClearedPageStaysClearedUntilTheUserLeavesIt()
    testAnOpenClearedInOneBrowserSaysNothingAboutAnother()
    testTheMemoryOutlivesTheGapAnOpenItselfLeaves()

    testWhatTheSettingsPageSaysAboutPermissions()

    MainActor.assumeIsolated {
        testABlockedAddressBecomesTheSamePauseScreenAnAppWould()
        testTheMenuBarOnlyAsksForPermissionWhenItWouldUseIt()
        testWhatASecondScreenOverTheSamePageCosts()
    }
}

/// The two sentences the Protection card shows. They are the app's claim about what it can
/// actually see, which is the one claim it must never overstate — and one of them changes with a
/// count, which is arithmetic and belongs in a test rather than in a window.
///
/// Both are the live state under one row, so both are short: what the permission *is* went into
/// the row's info button, where prose belongs.
private func testWhatTheSettingsPageSaysAboutPermissions() {
    expectEqual(
        BrowserAccess(accessibility: .granted).accessibilityLine,
        "Granted. Sandglass can hide blocked apps and read the address bar.",
        "granted names the state and then both halves of what it buys"
    )
    // The app half is not decoration. Without the grant a blocked app in fullscreen answers
    // `hide()` with `true` and stays exactly where it is, which is the most invisible way a
    // block can fail — so the row has to say so rather than talk only about browsers.
    expectEqual(
        BrowserAccess(accessibility: .denied).accessibilityLine,
        "Not granted. Fullscreen apps stay put and the address bar can't be read.",
        "and denied does the same, without naming a browser it happens to be worst for"
    )
    expect(
        !BrowserAccess(accessibility: .denied).accessibilityLine.contains("Firefox"),
        "no browser is named on this row: it is about a permission, not about a browser list"
    )
    expectEqual(
        BrowserAccess(accessibility: .unknown).accessibilityLine,
        BrowserAccess(accessibility: .granted).accessibilityLine,
        "nobody having looked yet is not a permission problem to warn about"
    )

    expectNil(
        BrowserAccess(accessibility: .granted).automationLine,
        "with nothing refused there is no line at all — a row explaining nothing is noise"
    )
    expectEqual(
        BrowserAccess(accessibility: .granted, automationRefused: ["Chrome"]).automationLine,
        "Chrome refused direct reading. Blocking still works.",
        "one refusal names the browser and says blocking survives it, in one line"
    )
    expectEqual(
        BrowserAccess(accessibility: .granted, automationRefused: ["Arc", "Chrome", "Safari"])
            .automationLine,
        "Arc, Chrome and Safari refused direct reading. Blocking still works.",
        "and several are read as a sentence rather than as a comma-separated list"
    )

    expectEqual(BrowserAccess.naming([]), "", "no names is no sentence")
    expectEqual(BrowserAccess.naming(["Chrome"]), "Chrome", "one name is the name")
    expectEqual(BrowserAccess.naming(["Chrome", "Safari"]), "Chrome and Safari", "two are joined")
}

private let chrome = "com.google.Chrome"
private let safari = "com.apple.Safari"

private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func browser(_ bundleID: String) -> KnownBrowser {
    guard let found = Browsers.browser(forBundleID: bundleID) else {
        failTest("no browser is registered for \(bundleID)")
        return KnownBrowser(bundleID: bundleID, name: bundleID, tabTerm: nil)
    }
    return found
}

// MARK: - Which browser is which

/// The list is the one place a browser bundle id is written down — `AppScanner` leaves the same
/// six out of the app picker — so a browser missing from it is a browser the picker would offer
/// as a blockable app *and* the watcher would ignore, which is wrong in both directions at once.
private func testTheSixBrowsersAreKnownAndNothingElseIs() {
    let expected = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
    ]
    expectEqual(Browsers.bundleIDs, Set(expected), "the six browsers the app knows")
    expectEqual(Browsers.all.count, expected.count, "and no duplicate entries behind them")
    expectNil(
        Browsers.browser(forBundleID: "com.apple.Notes"),
        "an application that is not a browser is not one"
    )
}

/// Firefox ships no scripting dictionary for its tabs, so the accessibility tree is the only
/// thing it will tell anybody. Everything else is asked in its own words first — an Apple event
/// answers with the address, where accessibility answers with what a web area is reporting.
private func testFirefoxHasOnlyTheAccessibilityRoute() {
    expectEqual(
        browser("org.mozilla.firefox").strategies, [.accessibility],
        "Firefox has one route and it is not AppleScript"
    )
    expectNil(browser("org.mozilla.firefox").appleScriptSource, "so there is no script to run")
    for bundleID in Browsers.bundleIDs where bundleID != "org.mozilla.firefox" {
        expectEqual(
            browser(bundleID).strategies, [.appleScript, .accessibility],
            "\(bundleID) is asked in its own words first, and read off the tree if that fails"
        )
    }
}

/// Three details of the script, each of which is load-bearing: the browser is named by bundle id
/// so a renamed or localised copy still answers and a missing one cannot open a chooser, the wait
/// is bounded because this runs on the main thread once a second, and Safari's dictionary calls
/// the tab in front something different from Chromium's.
private func testTheScriptNamesTheBrowserByIdAndBoundsItsOwnWait() {
    let safari = browser("com.apple.Safari").appleScriptSource ?? ""
    expect(safari.contains(#"application id "com.apple.Safari""#), "named by id, not by name")
    expect(safari.contains("current tab of front window"), "Safari's own word for the tab in front")
    expect(safari.contains("with timeout of 1 second"), "and a wait a wedged browser cannot extend")

    let chrome = browser("com.google.Chrome").appleScriptSource ?? ""
    expect(chrome.contains("active tab of front window"), "Chromium's word for the same thing")
    expect(!chrome.contains("activate"), "nothing here brings a browser forward or opens a window")
}

/// **Which browsers can say which tab they are talking about**, which is the one fact the whole
/// tab-keyed path rests on and therefore the one worth stating rather than assuming.
///
/// Read off the dictionaries installed on this Mac: Chromium's `tab` class declares `id` — "Unique
/// ID of the tab" — and Arc's declares the same. Safari's declares `source`, `URL`, `index`,
/// `text`, `visible` and `name`, and not one of those is an identity. `index` is the near miss and
/// taking it would be worse than nothing: it is a position, so the tab that slides into it inherits
/// a wait it never served — the exact fault the keying exists to close, with a new trigger.
private func testTheScriptBringsBackTheTabTheAddressCameFrom() {
    for name in ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
                 "com.microsoft.edgemac"] {
        let source = browser(name).appleScriptSource ?? ""
        expectEqual(browser(name).tabIDTerm, "id", "\(name) has a word for the tab's own identity")
        expect(source.contains("id of active tab of front window"), "and the script asks for it")
        // The insurance on an inference. Brave and Edge were not read here — no copy to read — so
        // they are Chromium by argument, and a wrong argument must cost the narrower keying rather
        // than the browser: a script that errored would take the address down with the identity
        // and stop the browser being watched at all.
        expect(source.contains("try"), "a browser that turns out not to have one still answers")
        expect(source.contains("with timeout of 1 second"), "inside the same bounded wait")
    }

    let safari = browser("com.apple.Safari")
    expectNil(safari.tabIDTerm, "Safari's tabs have no identity, only a position")
    expect(
        !(safari.appleScriptSource ?? "").contains("id of current tab"),
        "so its script is the one line it always was, and asks for nothing that would error"
    )
    expectNil(browser("org.mozilla.firefox").tabIDTerm, "and Firefox has no dictionary at all")
}

/// The answer comes back as one string and is two things. Everything below the first newline is the
/// address, kept whole; above it is what the browser calls the tab, or nothing.
private func testAnAnswerIsSplitBackIntoTheTabAndTheAddress() {
    let chrome = browser("com.google.Chrome")
    expectEqual(
        chrome.reading(fromScriptResult: "1723\nhttps://youtube.com/watch?v=A"),
        .address("https://youtube.com/watch?v=A", tabID: "1723"),
        "the tab that served the address rides back with it"
    )
    // The `try` swallowed a property this browser does not have. An empty line is no identity,
    // which keys by browser — not an identity that happens to be the empty string, which would be
    // one shared key that looks like a real one.
    expectEqual(
        chrome.reading(fromScriptResult: "\nhttps://youtube.com"),
        .address("https://youtube.com", tabID: nil),
        "an empty identity is no identity"
    )
    // Nothing writes an address with a newline in it, and a browser that did must not be read as
    // having named a tab. The address keeps everything after the first one.
    expectEqual(
        chrome.reading(fromScriptResult: "9\nhttps://a.test/x\ny"),
        .address("https://a.test/x\ny", tabID: "9"),
        "only the first newline separates, so the address survives whole"
    )
    expectEqual(
        chrome.reading(fromScriptResult: "https://youtube.com"),
        .address("https://youtube.com", tabID: nil),
        "and an answer in the old shape is an address, not an identity"
    )

    // Safari was sent the one-line script, so its answer is the address and nothing else — even
    // one that happens to contain a newline, which must not be read as a tab's name.
    expectEqual(
        browser("com.apple.Safari").reading(fromScriptResult: "1723\nhttps://youtube.com"),
        .address("1723\nhttps://youtube.com", tabID: nil),
        "a browser that was never asked for an identity did not answer with one"
    )
}

// MARK: - What counts as a page

/// The whole point of going through `RuleMatcher`: the address this side reads and the address a
/// rule is written against have to be one string, or a rule could match what the user typed and
/// miss what the browser said. Every case below is stated against the normalizer itself rather
/// than against a literal.
private func testAPageIsNormalizedExactlyAsARuleIs() {
    let addresses = [
        "https://www.youtube.com/watch?v=abc#t=10",
        "HTTP://YouTube.com:443/Shorts/",
        "https://user:pw@m.youtube.com/feed",
        "youtube.com",
        "https://youtube.com./watch",
    ]
    for address in addresses {
        expectEqual(
            BrowserAddress.page(from: address), RuleMatcher.normalize(url: address),
            "\(address) reads exactly as a rule about it is written"
        )
    }
    expectEqual(
        BrowserAddress.page(from: "https://www.youtube.com/watch?v=abc#t=10"),
        "youtube.com/watch",
        "which is host and path, with the scheme, the www and the query gone"
    )
}

/// A browser is asked once a second and answers with whatever it happens to be showing, including
/// its own internal pages and — through the address-bar fallback — whatever is half-typed into it.
/// The last case is the one that matters most: rules match anywhere in the address, so "youtube"
/// on its way to being a search would otherwise raise the pause screen for the YouTube group.
private func testWhatIsNotAPageIsNotReadAsOne() {
    let rejected = [
        "": "an empty answer",
        "   ": "a blank one",
        "about:blank": "a browser's own blank page",
        "chrome://newtab": "and its new tab page",
        "moz-extension://abc/page.html": "an extension's page",
        "file:///Users/someone/notes.html": "a local file, which normalizes down to no host",
        "youtube": "a domain somebody is still typing",
        ".com": "or one being typed from the wrong end",
        "localhost:3000": "a bare name nobody blocks",
        "how to tie a tie": "a search phrase in the address bar",
        "youtube.com is down": "and one that starts with a real host",
    ]
    for (text, name) in rejected {
        expectNil(BrowserAddress.page(from: text), name)
    }
}

/// Getting these the wrong way round fails in both directions. A browser sitting with no windows
/// answers -1728 every second, and resting over it would leave the app blind for minutes after a
/// window came back. A refused consent answers -1743 every second, and not resting over that is
/// an app asking the system for something it has been told it may not have, once a second.
private func testAnErrorIsOnlyRestedWhenItMeansTheRouteIsShut() {
    expectEqual(
        BrowserAddress.reading(forAppleScriptError: -1728), .unavailable,
        "no front window is the browser answering, not refusing"
    )
    expectEqual(
        BrowserAddress.reading(forAppleScriptError: -1743), .refused,
        "Automation that has not been granted shuts the route"
    )
    expectEqual(
        BrowserAddress.reading(forAppleScriptError: -1712), .refused,
        "so does a browser that did not answer inside the script's own second"
    )
    expectEqual(
        BrowserAddress.reading(forAppleScriptError: -600), .refused,
        "and one that is not running any more"
    )
    expectEqual(
        BrowserAddress.reading(forAppleScriptError: 0), .refused,
        "an error nobody recognises is treated as the closed door, which is the safe way round"
    )
}

// MARK: - Which route to try, and when to stop trying it

private func testTheRouteThatAnsweredIsTriedFirstNextTime() {
    var memory = BrowserStrategyMemory()
    let chrome = browser("com.google.Chrome")
    expectEqual(
        memory.plan(for: chrome, now: t0), [.appleScript, .accessibility],
        "with nothing learned yet, the browser's own order stands"
    )

    memory.succeeded(.accessibility, for: chrome.bundleID)
    expectEqual(
        memory.plan(for: chrome, now: t0), [.accessibility, .appleScript],
        "the route that answered is promoted rather than walked past every second"
    )
}

private func testARefusedRouteRestsAndComesBack() {
    var memory = BrowserStrategyMemory()
    let chrome = browser("com.google.Chrome")
    memory.failed(.appleScript, for: chrome.bundleID, now: t0)

    expectEqual(
        memory.plan(for: chrome, now: at(1)), [.accessibility],
        "a refused route is left out rather than asked again on the next tick"
    )
    expect(
        memory.isResting(.appleScript, for: chrome.bundleID, now: at(4.9)),
        "for as long as the first rest lasts"
    )
    expectEqual(
        memory.plan(for: chrome, now: at(5)), [.appleScript, .accessibility],
        "and then it is tried again — a permission may have been granted meanwhile"
    )
    expect(
        !memory.isResting(.appleScript, for: "com.apple.Safari", now: at(1)),
        "and one browser's refusal says nothing about another's"
    )
}

private func testConsecutiveRefusalsRestLongerAndStopGrowing() {
    var memory = BrowserStrategyMemory()
    let safari = browser("com.apple.Safari")
    var refusedAt = t0
    for rest in BrowserStrategyMemory.backoffSeconds {
        memory.failed(.appleScript, for: safari.bundleID, now: refusedAt)
        expect(
            memory.isResting(.appleScript, for: safari.bundleID, now: refusedAt + rest - 0.1),
            "the rest after this refusal is \(Int(rest)) seconds"
        )
        expect(
            !memory.isResting(.appleScript, for: safari.bundleID, now: refusedAt + rest),
            "and no longer"
        )
        refusedAt = refusedAt + rest
    }
    // One more, past the end of the list. A route that rested for ever would be an app that
    // quietly stopped protecting websites and never looked again.
    memory.failed(.appleScript, for: safari.bundleID, now: refusedAt)
    let longest = BrowserStrategyMemory.backoffSeconds.last ?? 0
    expect(
        !memory.isResting(.appleScript, for: safari.bundleID, now: refusedAt + longest),
        "the rest stops growing at the longest one on the list"
    )
}

private func testSuccessForgivesTheBackoffEntirely() {
    var memory = BrowserStrategyMemory()
    let safari = browser("com.apple.Safari")
    memory.failed(.appleScript, for: safari.bundleID, now: t0)
    memory.failed(.appleScript, for: safari.bundleID, now: at(5))
    expect(memory.isResting(.appleScript, for: safari.bundleID, now: at(10)), "two strikes in")

    memory.succeeded(.appleScript, for: safari.bundleID)
    expect(
        !memory.isResting(.appleScript, for: safari.bundleID, now: at(10)),
        "a permission that has just been granted does not serve out the rest its refusals earned"
    )
    memory.failed(.appleScript, for: safari.bundleID, now: at(10))
    expect(
        !memory.isResting(.appleScript, for: safari.bundleID, now: at(15)),
        "and the count starts again from the first, shortest rest"
    )
}

/// A refusal also costs the route its preference, so the next tick tries the other one first
/// rather than after it. For Firefox there is no other one, and an empty plan is the honest
/// answer: the caller reports no page instead of guessing at one.
private func testFirefoxWithNoAccessibilityHasNothingLeftToTry() {
    var memory = BrowserStrategyMemory()
    let firefox = browser("org.mozilla.firefox")
    memory.succeeded(.accessibility, for: firefox.bundleID)
    memory.failed(.accessibility, for: firefox.bundleID, now: t0)

    expect(
        memory.plan(for: firefox, now: at(1)).isEmpty,
        "nothing is left to ask Firefox while its one route rests"
    )
    expectEqual(
        memory.plan(for: firefox, now: at(5)), [.accessibility],
        "and the rest is what brings it back, not a second route"
    )
}

// MARK: - The page an open was spent on

/// The loop that this exists to break: a gentle group starts no session, so one second after an
/// open the engine says `pause` about the very page the user just paid for.
private func testAClearedPageStaysClearedUntilTheUserLeavesIt() {
    var cleared = ClearedPage()
    expect(!cleared.isCleared("youtube.com/watch", in: chrome), "nothing is cleared by default")

    cleared.clear("youtube.com/watch", in: chrome)
    expect(
        cleared.isCleared("youtube.com/watch", in: chrome),
        "the page an open was spent on stays quiet"
    )
    expect(
        cleared.isCleared("youtube.com/watch", in: chrome), "and asking twice does not use it up"
    )

    expect(!cleared.isCleared("reddit.com", in: chrome), "somewhere else is a new decision")
    expect(
        !cleared.isCleared("youtube.com/watch", in: chrome),
        "and coming back afterwards is a fresh visit, not the one that was paid for"
    )

    cleared.clear("youtube.com/watch", in: chrome)
    cleared.forget(in: chrome)
    expect(
        !cleared.isCleared("youtube.com/watch", in: chrome),
        "a session starting takes the memory with it, so the session's end can raise the screen"
    )
}

/// **An open is one browser's.** It was a single slot keyed by neither browser nor tab, so an open
/// spent on a page in Chrome answered "already paid for" about the same address in Safari — never
/// blocked, never waited, and quiet until the poll happened to read a different page. It bites the
/// gentle groups, which start no session for the engine to see and lean on this entirely.
///
/// The tab it cannot key by, and does not pretend to: a browser reports the one in front and
/// nothing else, so a second tab on the address just cleared is indistinguishable from the tab
/// that paid for it.
private func testAnOpenClearedInOneBrowserSaysNothingAboutAnother() {
    var cleared = ClearedPage()
    cleared.clear("instagram.com/p/1", in: chrome)
    expect(
        !cleared.isCleared("instagram.com/p/1", in: safari),
        "the same address in another browser is a block that browser has not paid for"
    )
    expect(
        cleared.isCleared("instagram.com/p/1", in: chrome),
        "and asking about it left the one that was paid for alone"
    )

    // Each browser's own last page, and one going somewhere else forgets only its own.
    cleared.clear("reddit.com", in: safari)
    expect(!cleared.isCleared("tiktok.com", in: safari), "Safari moved on")
    expect(
        cleared.isCleared("instagram.com/p/1", in: chrome),
        "which is nothing to do with what Chrome was let through to"
    )

    cleared.forget(in: safari)
    expect(
        cleared.isCleared("instagram.com/p/1", in: chrome),
        "and a session ending in one browser does not raise the screen in the other"
    )

    // Asked without being answered for, which is what a tab parked on the block page needs: the
    // page it is about may already have been paid for in another tab, and a countdown drawn over
    // one of those is theatre — `AppBlocker.decide` would let the next reading of that address
    // straight through. Asking must leave the memory exactly as it was, since the tab being asked
    // about is not the tab the open was spent in.
    expect(cleared.holds("instagram.com/p/1", in: chrome), "the page an open was spent on")
    expect(!cleared.holds("instagram.com/p/2", in: chrome), "and no other page")
    expect(!cleared.holds("instagram.com/p/1", in: safari), "and no other browser")
    expect(
        cleared.isCleared("instagram.com/p/1", in: chrome),
        "asking about another page this way did not forget the one that was paid for"
    )
}

/// The gap between granting an open and macOS actually bringing the browser back. A poll landing
/// inside it sees no page at all, and forgetting there would raise the screen the open had just
/// cleared — the gentle loop, back again with no visible cause. A gap that goes on, though, is
/// the user having left: a tab reopened later is a new visit and gets a new screen.
private func testTheMemoryOutlivesTheGapAnOpenItselfLeaves() {
    var cleared = ClearedPage()
    cleared.clear("youtube.com/watch", in: chrome)

    cleared.noPageInFront(now: t0)
    cleared.noPageInFront(now: at(1))
    expect(
        cleared.isCleared("youtube.com/watch", in: chrome),
        "the browser arriving a second late still finds the page cleared"
    )

    cleared.noPageInFront(now: at(10))
    cleared.noPageInFront(now: at(10 + ClearedPage.settleSeconds))
    expect(
        !cleared.isCleared("youtube.com/watch", in: chrome),
        "but a gap the user spent somewhere else ends the visit the open belonged to"
    )

    // Nothing in front is nothing in front for every browser, so a long gap ends all of them.
    cleared.clear("youtube.com/watch", in: chrome)
    cleared.clear("reddit.com", in: safari)
    cleared.noPageInFront(now: at(20))
    cleared.noPageInFront(now: at(20 + ClearedPage.settleSeconds))
    expect(!cleared.isCleared("reddit.com", in: safari), "the other browser's visit ended too")

    // Two polls, because the first is what starts the clock. Nothing is timed from a moment the
    // memory never saw.
    cleared.clear("reddit.com", in: chrome)
    cleared.noPageInFront(now: at(100 + ClearedPage.settleSeconds * 2))
    expect(cleared.isCleared("reddit.com", in: chrome), "the first empty poll only notes the time")
}

// MARK: - What the user ends up looking at

/// The whole chain `AppBlocker` runs for a page, in one test: the engine's decision about an
/// address, the app's name for it, and the screen the two become. It matters that this is the
/// same `PauseScreenModel` an application produces — a blocked site meets the screen a blocked
/// app meets, with the group's own question on it and the same two buttons.
@MainActor
private func testABlockedAddressBecomesTheSamePauseScreenAnAppWould() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        let url = BrowserAddress.page(from: "https://www.youtube.com/watch?v=abc") ?? ""
        guard let info = state.webDisplayInfo(forURL: url) else {
            failTest("the address the watcher read is not one the app can name")
            return
        }
        expectEqual(
            PauseScreenModel.for(decision: state.blockDecision(forURL: url), info: info),
            PauseScreenModel(
                targetName: "YouTube",
                budgetLine: "5 of 5 opens left today",
                mode: .countdown(total: 10)
            ),
            "a blocked page is the pause screen a blocked app is"
        )

        // Into the cooldown, which is the other half of the mapping: a hard block offers no way
        // through, so the screen carries no button and no budget line under it.
        _ = state.consumeOpen(forURL: url)
        state.endActiveSessionEarly()
        expectEqual(
            PauseScreenModel.for(decision: state.blockDecision(forURL: url), info: info),
            PauseScreenModel(
                targetName: "YouTube",
                budgetLine: nil,
                mode: .blocked(untilText: "Next open in 10 min")
            ),
            "and a page inside a cooldown is the block screen, in the engine's own words"
        )

        expectNil(
            PauseScreenModel.for(
                decision: state.blockDecision(forURL: "example.com"),
                info: TargetDisplayInfo(targetID: "x", name: "x")
            ),
            "an address nobody asked to block puts nothing on screen at all"
        )
    }
}

/// What a second pause screen over the same page costs — the one the user meets after navigating
/// away and back, since `ClearedPage` above keeps the first visit to a single screen.
///
/// **Opens inside a session are free.** `RulesEngine.consume` answers the second request out of
/// the running session and spends nothing. **Opens with no session are not**, and cannot be: a
/// group with no relock has nothing for the second request to join. **Dismissals are counted every
/// time**, because two turnings-away genuinely are two. All three are stated here rather than left
/// to be discovered from a budget that emptied faster than it should have.
///
/// This used to be about two screens *at once* — the browser extension's and this app's, running
/// over one page and each charging for it. There is one path now, so what is left is the honest
/// arithmetic of visiting a blocked page twice.
@MainActor
private func testWhatASecondScreenOverTheSamePageCosts() {
    let url = "youtube.com/watch"
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        expectEqual(state.consumeOpen(forURL: url), .granted(sessionSeconds: 300), "one open spent")
        expectEqual(
            state.consumeOpen(forURL: url), .granted(sessionSeconds: 300),
            "and a second screen inside the session joins the one it started"
        )
        expectEqual(
            state.stats.opensUsedToday["domain:youtube.com"], 1,
            "so the second one costs nothing"
        )

        state.recordDismissal(forURL: url)
        state.recordDismissal(forURL: url)
        expectEqual(
            state.stats.opensAvoidedToday, 2,
            "turning away is counted every time — two turnings-away are two"
        )
    }
    withTempDir { dir in
        // A budget with no relock behind it: the shape the join cannot cover.
        var settings = GroupSettings.standard
        settings.sessionMinutes = nil
        try? Store(directory: dir).saveConfig(webConfig(settings: settings))
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        expectEqual(state.consumeOpen(forURL: url), .granted(sessionSeconds: nil), "an open, no session")
        expectEqual(state.consumeOpen(forURL: url), .granted(sessionSeconds: nil), "and another")
        expectEqual(
            state.stats.opensUsedToday["domain:youtube.com"], 2,
            "with no session to join, two screens really do spend two opens"
        )
    }
}

/// The menu bar's promise: it never claims to be protecting what it cannot reach, and it never
/// asks for a permission it would not use. Both conditions are load-bearing.
///
/// **The permission it asks for grew.** It used to be about reading a browser's address bar, and
/// the warning was gated on a website being protected. The same grant now also decides whether a
/// blocked application can be taken out of its fullscreen Space — and without that it answers
/// `hide()` with `true` and stays exactly where it is. So a Mac blocking nothing but applications
/// used to be told everything was fine while the block quietly did nothing.
///
/// The reason this is not hypothetical: an ad-hoc signed app loses the Accessibility grant on
/// every reinstall, macOS goes on showing the stale entry as though it were live, and this app is
/// reinstalled constantly.
@MainActor
private func testTheMenuBarOnlyAsksForPermissionWhenItWouldUseIt() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        expectEqual(
            state.statusKind, .active(targetCount: 1),
            "before anything has looked, nothing is claimed and nothing is warned about"
        )

        state.setBrowserAccess(BrowserAccess(accessibility: .denied))
        expectDegraded(
            state.statusKind, mentioning: "permission",
            "a website to protect and no way to see the browser is worth saying out loud"
        )

        state.setBrowserAccess(BrowserAccess(accessibility: .granted, automationRefused: ["Safari"]))
        expectEqual(
            state.statusKind, .active(targetCount: 1),
            "a browser that refused the direct route is still protected through the other one"
        )

        state.setBrowserAccess(BrowserAccess(accessibility: .denied))
        expectDegraded(
            state.statusKind, mentioning: "permission",
            "and no edit to the configuration can talk the warning away — there is no switch"
        )
    }
    withTempDir { dir in
        // Applications only, and it still needs the grant: three of the four things that send a
        // blocked app away are gated on it, and a fullscreen app ignores the fourth.
        try? Store(directory: dir).saveConfig(gentleConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        state.setBrowserAccess(BrowserAccess(accessibility: .granted))
        expectEqual(
            state.statusKind, .active(targetCount: 1),
            "with the grant in place there is nothing to say"
        )
        state.setBrowserAccess(BrowserAccess(accessibility: .denied))
        expectDegraded(
            state.statusKind, mentioning: "Accessibility",
            "a setup with no websites in it still cannot hide a fullscreen app without the grant"
        )
    }
    withTempDir { dir in
        // Nothing is protected at all, so nothing is missing. The one case that must stay quiet:
        // warning about a permission on a Mac blocking nothing is asking for a grant to do nothing
        // with, which is how a user learns to ignore the warning that matters.
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        state.setBrowserAccess(BrowserAccess(accessibility: .denied))
        expectEqual(
            state.statusKind, .active(targetCount: 0),
            "an empty configuration asks for nothing"
        )
    }
}
