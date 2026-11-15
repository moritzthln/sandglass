import SandglassAppCore
import Foundation

// The bookkeeping of the page pipeline that used to be one slot wide, and the guard on the one
// navigation that could move the wrong tab.
//
// Each of these was a single value standing in for something there can be several of at once:
// browsers parked on a block page, tabs with a navigation in flight, presses on the password
// button. The cases here are the "several" ones.

func runPagePipelineTests() {
    twoBrowsersParkedAreBothAskedAbout()
    twoTabsSentAtOnceBothSettle()
    theNavigationChecksTheTabItWasReadOn()
    aBrowserWithoutTabNamesChecksTheAddressAlone()
    aPressFromBeforeARelaunchIsNotAQuestion()
    theSameRefusalIsWrittenOncePerMinute()
}

private let chrome = "com.google.Chrome"
private let safari = "com.apple.Safari"

/// A block page in Chrome and then one in Safari: an edit that unblocks the site is about both,
/// and the second sighting used to overwrite the first.
private func twoBrowsersParkedAreBothAskedAbout() {
    var parked = LastBlockPage()
    parked.record(browserID: chrome)
    parked.record(browserID: safari)
    expectEqual(parked.browserIDs, [chrome, safari], "both browsers are remembered, oldest first")
    expectEqual(parked.browserID, safari, "and the newest is still the newest")
    parked.record(browserID: chrome)
    expectEqual(parked.browserIDs, [safari, chrome], "a second sighting moves a browser to the end, once")
    parked.forget(browserID: chrome)
    expectEqual(parked.browserIDs, [safari], "a browser that moved on takes only itself out")
}

/// Two windows sent away within the same three seconds each have a navigation in flight. With one
/// slot the second send wiped the first, and the first tab's stale reading was sent again.
private func twoTabsSentAtOnceBothSettle() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let first = BrowserTab(browserID: chrome, tabID: "1")
    let second = BrowserTab(browserID: safari, tabID: nil)
    var sent = SentToBlockPage()
    sent.record(tab: first, from: "https://youtube.com/a", now: start)
    sent.record(tab: second, from: "https://reddit.com/", now: start.addingTimeInterval(1))
    let later = start.addingTimeInterval(2)
    let youtube = "https://youtube.com/a", reddit = "https://reddit.com/"
    expect(sent.isSettling(tab: first, address: youtube, now: later), "the first send is still waited for")
    expect(sent.isSettling(tab: second, address: reddit, now: later), "and so is the second")
    sent.forget(tab: first)
    expect(!sent.isSettling(tab: first, address: youtube, now: later), "the arrival clears its own tab")
    expect(sent.isSettling(tab: second, address: reddit, now: later), "and only its own")
}

/// The read and the navigation are two Apple events a poll apart. The guarded script takes the tab
/// once and moves it only while it still shows what was read — and, in Chrome, is still the same tab.
private func theNavigationChecksTheTabItWasReadOn() {
    guard let chromeBrowser = Browsers.browser(forBundleID: chrome),
          let source = chromeBrowser.navigationScriptSource(
              to: "file:///x/block.html?target=y", ifShowing: "https://youtube.com/watch?v=1",
              tabID: "42"
          )
    else {
        failTest("Chrome has a guarded navigation")
        return
    }
    let moved = KnownBrowser.movedOnAnswer
    expectEqualText(
        source,
        """
        with timeout of 1 second
        tell application id "com.google.Chrome"
            set theTab to active tab of front window
            if ((URL of theTab) as text) is not "https://youtube.com/watch?v=1" then return "\(moved)"
            if ((id of theTab) as text) is not "42" then return "\(moved)"
            set URL of theTab to "file:///x/block.html?target=y"
        end tell
        end timeout
        """,
        "the tab is checked by its address and its identity before it is moved"
    )
    expectNil(
        Browsers.browser(forBundleID: "org.mozilla.firefox")?
            .navigationScriptSource(to: "x", ifShowing: "y"),
        "and Firefox, which cannot be told where to go, has no such script either"
    )
}

private func aBrowserWithoutTabNamesChecksTheAddressAlone() {
    let source = Browsers.browser(forBundleID: safari)?.navigationScriptSource(
        to: "https://a.example/", ifShowing: "https://b.example/", tabID: "ignored"
    ) ?? ""
    expect(source.contains("set theTab to current tab of front window"), "Safari's tab is its own")
    expect(source.contains("is not \"https://b.example/\""), "checked by the address it was read on")
    expect(!source.contains("ignored"), "and by no identity, which Safari's dictionary has no word for")
}

/// The answered presses are kept in memory, and the keep-alive agent relaunches within seconds of
/// a quit. A press still standing in a tab's address from before that is not a new question.
private func aPressFromBeforeARelaunchIsNotAQuestion() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let millis = Int64(now.timeIntervalSince1970 * 1000)
    var asks = AnsweredAsks()
    expect(asks.isNew("\(millis - 5_000).ab12", now: now), "a press five seconds old raises the prompt")
    expect(
        !asks.isNew("\(millis - 10 * 60_000).cd34", now: now),
        "one made ten minutes ago, before the relaunch, does not"
    )
    expect(asks.isNew("ef56", now: now), "and a nonce with no moment in it is judged as before")
}

/// A browser that refuses to be told where to go, behind a window that is not active, is asked
/// again on every poll. One line a minute says everything sixty would.
private func theSameRefusalIsWrittenOncePerMinute() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var log = NavigationFailures()
    let line = "couldn't show the block page — Chrome: error -1743"
    expect(log.shouldRecord(line, now: start), "the first refusal is written")
    expect(!log.shouldRecord(line, now: start.addingTimeInterval(1)), "the same one a second later is not")
    expect(
        log.shouldRecord(
            "couldn't go back to the page — Chrome: error -1712", now: start.addingTimeInterval(2)
        ),
        "a different failure is written at once"
    )
    expect(
        log.shouldRecord(line, now: start.addingTimeInterval(NavigationFailures.quietSeconds + 1)),
        "and the first is written again once a minute has passed"
    )
}
