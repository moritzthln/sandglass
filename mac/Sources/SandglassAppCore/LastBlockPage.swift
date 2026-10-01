import Foundation

/// The browser this app last saw sitting on its own block page.
///
/// One fact, and it exists because of one blind spot: **the poll only ever reads the frontmost
/// browser.** That is right for the poll — a tab nobody is looking at is not urgent — but one
/// thing happens at a moment when there is deliberately no browser in front, and it is about a tab
/// that is parked on our page.
///
/// - **A configuration edit.** Taking a website out of a group, moving a target, redrawing a
///   window, switching a group off: every one of them can leave a tab standing on a block page
///   that is now about nothing. While the user is in Settings the frontmost application is
///   Sandglass, so nobody asks, and the page sits there until they switch back to it. Which is
///   exactly backwards — the moment they finish unblocking something is the moment they expect
///   to be able to look at it.
///
/// It used to have a second caller: a press on the block page's button, which arrived on an
/// `sandglass://` URL and activated Sandglass to arrive at all, so the poll could see nothing at the
/// one moment it mattered. That scheme is gone. The button changes the page's own address now and
/// the press is read by the ordinary poll, with the browser in front and its page in hand.
///
/// **It holds a browser and not a page**, which is the whole reason it needs no clock. An earlier
/// version recorded the page's query with a five-second life on it, because it was standing in
/// for a live reading at the moment of a press. That window was wrong for the caller that is
/// left: somebody can sit in Settings for a quarter of an hour before the edit that matters. And
/// a longer window would have been worse, not better — a remembered address is a guess about a tab
/// that may have moved on, and acting on it means navigating a tab away from wherever the user
/// actually took it.
///
/// So the caller asks the browser what it is showing *now*, through
/// `BrowserWatcher.page(ofBrowserWith:)`, which reads a named browser whether or not anybody is
/// looking at it. This says which one to ask and nothing more. A record that has gone stale
/// costs one Apple event and is then corrected; it can never cause a wrong navigation.
///
/// **Forgotten per browser.** The poll clears it when *that* browser is seen showing something
/// else — the tab was closed, or navigated away from. A second browser being used normally does
/// not clear it, because a page parked in Chrome is still parked in Chrome while somebody reads
/// the news in Safari.
public struct LastBlockPage: Equatable, Sendable {

    private var seenIn: String?

    public init() {}

    /// The browser to ask, or `nil` when no block page has been seen anywhere.
    public var browserID: String? { seenIn }

    /// The poll found this browser sitting on our block page.
    public mutating func record(browserID: String) {
        seenIn = browserID
    }

    /// This browser is showing something else, so whatever was parked in it is not any more.
    ///
    /// Keyed, so that reading an ordinary page in one browser does not forget a block page
    /// standing in another. Deliberately **not** called when a browser cannot be read at all —
    /// no window, no permission, or Sandglass itself in front — since "nobody answered" is not
    /// "it moved on", and that is the exact moment both callers arrive.
    public mutating func forget(browserID: String) {
        guard seenIn == browserID else { return }
        seenIn = nil
    }
}
