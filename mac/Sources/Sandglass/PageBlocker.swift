import SandglassAppCore
import SandglassCore
import AppKit

/// What `AppBlocker` needs of the overlay, and the only thing the web half cannot own.
///
/// One pause screen serves both subjects — a blocked site meets exactly the screen a blocked app
/// does — so the screen itself, and the memory of what it is standing in front of, stay with
/// `AppBlocker`. Everything else about a page is on the other side of this protocol.
///
/// `wasRecentlyHidden` is here for the same reason and points the other way: "Back to work" hides
/// a browser, macOS goes on naming it as frontmost for about a second, and the page poll must not
/// believe that reading. The hide is the app half's, so the memory of it is too.
@MainActor
protocol PageBlockerHost: AnyObject {
    /// What the overlay is standing in front of, or `nil` when none is up.
    var standingSubject: BlockSubject? { get }
    func raise(_ model: PauseScreenModel, for subject: BlockSubject)
    func clearOverlay()
    func refreshOverlay()
    func wasRecentlyHidden(_ bundleID: String) -> Bool
}

/// The web half of the blocker: what page is in front, and what happens to a tab that is blocked.
///
/// Split out of `AppBlocker` at the seam that file always described in its own opening comment —
/// an **application** announces itself and is decided on the spot, a **page** announces nothing
/// and has to be asked for on a clock. Everything on the asking side is here, together with the
/// four pieces of bookkeeping only it has any use for: the address an open was spent on
/// (`ClearedPage`), the tab already asked to leave (`SentToBlockPage`), the waits imposed and the
/// one navigation each buys (`EarnedOpens`), and which browser to ask about a parked tab
/// (`LastBlockPage`).
///
/// A collaborator rather than an extension on the same class. The point of the cut is that this
/// state belongs to nobody else: an extension would leave all six pieces sitting in `AppBlocker`,
/// reachable from every method in it, which is exactly the arrangement that let one file grow
/// past 800 lines.
///
/// **The tab is navigated, not covered**, which is what makes this a different shape from the app
/// half rather than the same shape applied to a browser. Navigating away stops the video and the
/// sound and leaves every other tab alone. The overlay is the fallback — Firefox, which cannot be
/// told where to go, and a browser that refused — and it is the host's, above.
///
/// `AppState` arrives as an argument rather than being held. Every method here already took it
/// that way; the two entry points do now as well, so this class holds no reference to the state
/// at all and cannot outlive one.
@MainActor
final class PageBlocker {

    private unowned let host: PageBlockerHost

    /// Reads the address of the page in the frontmost browser. Everything it decides is a value
    /// with a test; everything it *does* is a call into macOS. See `BrowserWatcher`.
    private let watcher = BrowserWatcher()

    /// Sends a blocked tab to the block page, and brings it home again — and writes down every
    /// browser that refuses to go. The writing half of the watcher above; see `TabNavigator`.
    private let navigator: TabNavigator

    /// The page an open was just spent on, per browser. The web counterpart of the app half's
    /// activation grace, and it is keyed by browser and address rather than by time — see
    /// `ClearedPage`.
    private var cleared = ClearedPage()

    /// The tab just sent to the block page, covering the gap before the browser says it went.
    /// See `SentToBlockPage`.
    private var sentAway = SentToBlockPage()

    /// The waits this class has imposed, and the one navigation each buys once it is over.
    ///
    /// The whole of what the block page's button is: the button is a link to the site, the browser
    /// walks there by itself, and this is what the poll consults a second later instead of blocking
    /// it again. See `EarnedOpens`.
    private var earned = EarnedOpens()

    /// The browser the poll last saw sitting on our own block page. Which browser to ask about a
    /// parked tab, at the moment there is none in front to ask. See `LastBlockPage`.
    private var lastBlockPage = LastBlockPage()

    /// The store arrives here rather than being made here, so the app has one of them. What is
    /// built from it writes into the same directory as the settings and the history: the
    /// navigator's record of a browser that would not move.
    init(host: PageBlockerHost, store: Store) {
        self.host = host
        navigator = TabNavigator(store: store)
    }

    /// Whether a browser can be read at all, published so the menu bar can go yellow. Asked at
    /// launch as well as on every poll — the first answer is what keeps a yellow icon from being
    /// painted on the way past.
    var browserAccess: BrowserAccess { watcher.access }

    // MARK: - What the overlay's buttons leave behind

    /// An open was spent on this address in this browser. Written from the overlay's "Open",
    /// which is the host's button, and read by the poll a second later.
    func rememberOpen(of url: String, in browserID: String) {
        cleared.clear(url, in: browserID)
    }

    /// Turned away from rather than paid for, so there is nothing to keep quiet about: coming back
    /// to this page later is a fresh visit and gets a fresh screen.
    func forgetOpens(in browserID: String) {
        cleared.forget(in: browserID)
    }

    /// One beat of the app's clock: is the frontmost browser showing something blocked?
    ///
    /// This used to open by reading `browserWatchEnabled` and, with it off, take down a page's
    /// screen and stop. There is no such switch any more: website blocking is on, and what decides
    /// whether a page can be read is a system permission. The permission is asked about here —
    /// `watcher.access`, published so the menu bar can go yellow — and *acted on* one level down,
    /// in `frontmostPage()`, which answers nothing when every way of asking a browser has been
    /// refused. That is the right granularity: Accessibility being denied does not stop a browser
    /// that granted Automation from being read, and an early return here would have thrown away
    /// exactly those browsers. Nothing is left standing either way — a page's screen is re-derived
    /// from the engine every second, so it comes down the moment the decision does.
    ///
    /// **And it is why this half cannot fight the blunt response.** When a hard block is standing
    /// over a browser nothing can read, `AppBlocker` hides that browser whole on its next
    /// activation (see `BluntBlock`) — and a browser nothing can read is a browser this poll gets
    /// no page out of, so there is no tab here for it to want navigated. The two never reach for
    /// the same browser at the same moment: exactly the browsers the response covers are the ones
    /// `frontmostPage()` answers nothing about. A browser it does *not* cover still has a working
    /// route, and goes on being navigated tab by tab as it always was. `wasRecentlyHidden` below
    /// covers the second after a hide, when macOS is still naming the hidden browser as frontmost.
    func poll(with appState: AppState) {
        appState.setBrowserAccess(watcher.access)
        // While a page screen is up, Sandglass *is* the frontmost application — it took activation
        // to get the keyboard — so asking who is in front would answer "us" and take the screen
        // down. The page it is standing in front of is the only meaningful subject, which is the
        // rule `recheckFrontmost` follows for an application.
        //
        // Only Firefox reaches this now. Every other browser's tab is navigated to the block page
        // instead of being covered by one — see `decide`.
        if case .page(_, let browserID, let browser) = host.standingSubject {
            // Unless the browser quit behind it, which nothing else here would notice: the
            // overlay would stand over an empty desktop holding the keyboard until the user
            // pressed one of two buttons about a page that is no longer anywhere.
            guard !browser.isTerminated else {
                host.clearOverlay()
                cleared.forget(in: browserID)
                return
            }
            host.refreshOverlay()
            return
        }
        // An application's pause screen is up. A page must not become the subject behind it.
        guard case .none = host.standingSubject else { return }
        guard let page = watcher.frontmostPage() else {
            // Nothing in front is a browser, or it is showing nothing anybody blocks. The memory
            // of the last open outlives a short gap and not a long one, because the browser
            // coming back after an "Open" *is* a short gap — see `ClearedPage.settleSeconds`.
            cleared.noPageInFront(now: Date())
            return
        }
        // macOS goes on naming a hidden application as frontmost for about a second, and "Back to
        // work" has just hidden this one. Believing the stale reading would put the pause screen
        // straight back over the browser the user was let out of — see `RecentlyHidden`.
        guard !host.wasRecentlyHidden(page.bundleID) else { return }
        switch page.sighting {
        case .page(let url):
            // Whatever this browser had parked on the block page, it is not showing it now.
            lastBlockPage.forget(browserID: page.bundleID)
            chargeSecond(to: url, with: appState)
            decide(url, on: page, with: appState)
        case .blockPage(let query):
            // Written down *before* the page is watched, because what needs it happens while
            // there is no browser in front at all: a configuration edit, made in a window of
            // ours. See `LastBlockPage`.
            lastBlockPage.record(browserID: page.bundleID)
            watchBlockPage(query, on: page, with: appState)
        }
    }

    /// The second the user just spent on this page, charged to whatever group claims it.
    ///
    /// The web half of `frontmostBundleID`, and it exists for a reason that had nothing to do
    /// with the app half: a daily time limit did nothing on a website, because the only thing
    /// that ever reported web seconds was the browser extension — which covered Chromium and
    /// nothing else. Safari and Firefox could be blocked and never counted.
    ///
    /// The two conditions are the two this can get wrong. The **screen has to be unlocked**, or
    /// a Mac left on YouTube overnight spends its whole limit while nobody is there — macOS goes
    /// on naming a frontmost application through a lock. And a **pause screen must not be up**,
    /// which is already true where this is called from: while one is showing, Sandglass is the
    /// frontmost application and the page is the standing subject, so the poll turned back well
    /// above this line and the time spent deciding not to open a page is charged to nobody.
    private func chargeSecond(to url: String, with appState: AppState) {
        guard !ScreenLock.isOn else { return }
        appState.recordPageSecond(forURL: url)
    }

    /// A page the engine has an opinion about. **The tab is navigated, not covered.**
    ///
    /// Navigating away stops the video and the audio, which covering the window never did, and it
    /// leaves every other tab alone — where the overlay's own way out, "Back to work", hid the
    /// whole browser and every innocent tab with it.
    ///
    /// **And it is where a served wait is spent**, which is the one ordering in this class that
    /// had to be got right. The block page's button is a link: the browser walks to the site on its
    /// own and tells nobody, so the first this app hears of it is the poll reading the address —
    /// the same reading that would otherwise block it. Claiming here, in the branch that blocks,
    /// means there is no tick in between the two for the page to be taken away in.
    private func decide(_ url: String, on page: BrowserWatcher.Page, with appState: AppState) {
        let presentation = BlockPresentation.for(
            decision: appState.blockDecision(forURL: url),
            info: appState.webDisplayInfo(forURL: url)
        )
        // A group set to no pause. **The block page is never involved**: there is no navigation
        // out and back, no promise to ripen, and no page whose countdown could be raced. The open
        // is spent on the address the poll has just read, and the tab stays on it.
        //
        // The clearance is what makes that one open rather than one a second, and it is asked
        // about first for exactly that reason: a group with no session length starts none for the
        // next tick to see. Leaving the page and coming back is a fresh arrival and spends again,
        // which is what a group set to no pause is.
        if case .opensByItself = presentation {
            guard !cleared.isCleared(url, in: page.bundleID) else { return }
            earned.forget(target: url, tab: page.tab)
            arrived(at: url, on: page, with: appState)
            return
        }
        guard let model = presentation.model else {
            // A session the user paid for, or nothing to block at all. Either way the reason
            // nothing is on screen belongs to the engine rather than to this class — so the open
            // that was spent is forgotten, and the session running out is free to block the very
            // same page again. The wait goes with it: a clearance that outlived the block it was
            // earned against would be a page permanently exempt from its own group.
            cleared.forget(in: page.bundleID)
            sentAway.forget()
            earned.forget(target: url, tab: page.tab)
            return
        }
        // The open the user already spent on exactly this address. Without this a gentle group —
        // which starts no session for the decision to see — would meet the block it just cleared,
        // once a second, until it navigated away.
        guard !cleared.isCleared(url, in: page.bundleID) else { return }
        if earned.claim(target: url, tab: page.tab, now: Date()) {
            arrived(at: url, on: page, with: appState)
            return
        }
        // This browser has been asked to leave this *address* and has not reported having done it.
        // Asking twice would put a second countdown over the one already running. A different
        // address on the same page is a different tab, and it is decided on rather than walked
        // past — see `SentToBlockPage`.
        guard !sentAway.isSettling(tab: page.tab, address: page.address, now: Date())
        else { return }
        sendAway(from: url, opening: page.address, on: page, showing: model)
    }

    /// The tab is on an address that is about to cost an open, and the engine has the last word on
    /// it — the same shape "Open" has on the overlay, for the same reason.
    ///
    /// Two arrivals end here. The user has **walked to the address their wait paid for**: the claim
    /// is spent whichever way this goes, because it was permission for one navigation and the
    /// navigation happened. Or the group is set to **no pause**, and this is the first and only
    /// thing that happens to the page — see `decide`.
    ///
    /// A refusal is not a wait that goes unserved: it is the day's opens having run out, or a
    /// strict window having opened, while the countdown ran — and the tab is sent to a block page
    /// that says so, rather than to a second copy of the wait just served.
    private func arrived(at url: String, on page: BrowserWatcher.Page, with appState: AppState) {
        switch appState.consumeOpen(forURL: url) {
        case .granted:
            // Written down before the next tick can ask: a gentle group starts no session, so the
            // engine will still say `pause` about this page one second from now.
            cleared.clear(url, in: page.bundleID)
            sentAway.forget()
        case .denied(let decision):
            let presentation = BlockPresentation.for(
                decision: decision, info: appState.webDisplayInfo(forURL: url)
            )
            guard let model = presentation.model else {
                // Refused, and by the time it was refused there was nothing left to block. The
                // walk still ends on the site rather than on a page about a block that is over.
                cleared.forget(in: page.bundleID)
                sentAway.forget()
                return
            }
            sendAway(from: url, opening: page.address, on: page, showing: model)
        }
    }

    /// The tab goes to the block page — or, for the one browser that cannot be told to, the
    /// overlay goes up over it.
    ///
    /// `address` is where the button on that page will point: what the browser reported the tab was
    /// on when this is a fresh block, and what the page already carries when it is a redraw. It is
    /// offered rather than trusted — see `BlockPage.opening(from:target:)`.
    private func sendAway(
        from url: String,
        opening address: String?,
        on page: BrowserWatcher.Page,
        showing model: PauseScreenModel
    ) {
        let now = Date()
        let browser = page.known
        guard browser.canNavigate, let blockPage = BrowserWatcher.blockPage else {
            // **Firefox, as a case of its own.** We read it through the accessibility tree and
            // there is no sound way to write its address bar the same way, so it keeps the
            // overlay. The other way in here is a build with no resources — a raw SwiftPM binary,
            // which has no block page to navigate to.
            raiseIfLookedAt(model, from: url, on: page)
            return
        }
        var query = BlockPage.Query(model: model, target: url, now: now, address: address)
        // **The page draws the wait that is actually being served.** Everything that lands on a
        // page a countdown is already running for — a second tab on the same site, a Back out of
        // the block page, a press this app answered as early — would otherwise put a fresh
        // countdown on screen, and the wait the user had served would be gone. The ledger keeps
        // the earlier ripening (see `EarnedOpens.promise`); this is what stops the page from
        // saying something else. A moment already past draws 0:00 and offers the button at once.
        if let ripening = earned.outstanding(target: url, tab: page.tab, now: now),
           let ends = query.endsAt, ripening < ends {
            query.endsAt = ripening
        }
        guard navigator.send(
            browser, to: BlockPage.address(page: blockPage, query: query),
            doing: "show the block page"
        ) else {
            // Automation refused, or the browser would not answer. A screen is a worse block than
            // a navigation and a better one than nothing at all.
            raiseIfLookedAt(model, from: url, on: page)
            return
        }
        sentAway.record(tab: page.tab, from: page.address, now: now)
        switch model.mode {
        case .countdown(let total):
            // Written down as the page goes up rather than when its countdown runs out, because
            // the button appears the instant the page's own clock reaches zero and the poll is a
            // second wide. See `EarnedOpens`.
            earned.promise(target: url, tab: page.tab, countdownSeconds: total, now: now)
        case .blocked:
            // A wall grants nothing, and it also **takes back** whatever the wait it replaced was
            // going to grant: a strict window opening over a countdown four minutes in must not
            // leave a claim that ripens a minute later. The engine would refuse that walk anyway,
            // which is what makes this belt and braces rather than the guard — but a clearance
            // that outlived the block it was earned against has no business existing at all.
            earned.forget(target: url, tab: page.tab)
        }
    }

    /// The overlay, but only over a browser somebody is actually looking at.
    ///
    /// Both fallbacks above are for a page that could not be navigated, and a screen in front of
    /// it is the honest answer while the user is sitting there. It is the wrong answer when they
    /// are not: a configuration edit resolves a tab parked in a browser behind the settings
    /// window, and a full-screen pause screen thrown over the window they are typing in is this
    /// app interrupting somebody about a tab they are not looking at.
    ///
    /// Nothing is lost by leaving it. The page is still a block page, and the poll decides it
    /// again the second they go back to it.
    private func raiseIfLookedAt(
        _ model: PauseScreenModel, from url: String, on page: BrowserWatcher.Page
    ) {
        guard page.running.isActive else { return }
        host.raise(model, for: .page(url: url, browserID: page.bundleID, running: page.running))
    }

    /// A tab is sitting on our own block page. Three things can have changed underneath it.
    ///
    /// - **The block lifted on its own** — the window ended, the day rolled over. The address it
    ///   interrupted is read out of the query and the tab goes back to it. Nothing for the user
    ///   to do, and nothing had to be remembered anywhere: the query is the only copy of it.
    /// - **The block changed shape** — a cooldown ran out, so what was a wall is now a wait with a
    ///   button at the end of it. The page is drawn entirely from its query, so a new shape means
    ///   a new query. Only a change of *shape* re-navigates: re-sending the same one every second
    ///   would restart the countdown forever.
    /// - **The wait behind it is gone** — this app was relaunched during the countdown, or the page
    ///   has been sitting there long enough for the claim it earned to expire. The page still draws
    ///   a button, and the button is a link that would land on the site and be blocked a second
    ///   later; so it is redrawn with a countdown this app is actually holding. One tick, then the
    ///   claim exists and this stops firing.
    /// - **The page was already paid for** — an open was spent on this address in this browser, in
    ///   another tab. The engine still says `pause`, because a gentle group starts no session for
    ///   it to see, so this used to redraw the countdown and ask the user to sit through it again.
    ///   It was theatre: `decide` consults `cleared` and would let the very next reading of that
    ///   address straight through, so the wait bought nothing and cost a minute. The tab goes home
    ///   instead, and the clearance stays — it is the reason, not a leftover.
    ///
    /// The button being pressed is not on the list, and that is the point of it being a link: the
    /// browser walks to the site and this class hears about it from the poll, on the tab's new
    /// address, in `decide`. There is nothing to redeem and nothing to acknowledge.
    private func watchBlockPage(
        _ query: BlockPage.Query, on page: BrowserWatcher.Page, with appState: AppState
    ) {
        // The navigation this class asked for has arrived.
        sentAway.forget()
        // And the page is on screen, which is what makes the wait behind it spendable. A claim is
        // spent by *arriving* at the target, and until this line has run a reading of the target is
        // a tab that never left it — see `EarnedOpens.sighted`.
        earned.sighted(target: query.target, tab: page.tab, now: Date())
        let presentation = BlockPresentation.for(
            decision: appState.blockDecision(forURL: query.target),
            info: appState.webDisplayInfo(forURL: query.target)
        )
        guard let model = presentation.model else {
            // The engine is the reason nothing stands in the way, so nothing here has to keep
            // quiet about this address either.
            if navigateBack(to: query, in: page.known) { cleared.forget(in: page.bundleID) }
            earned.forget(target: query.target, tab: page.tab)
            return
        }
        // Here the clearance *is* the reason, so it stays: forgetting it would send the tab home
        // and block it again on the next tick.
        guard !cleared.holds(query.target, in: page.bundleID) else {
            navigateBack(to: query, in: page.known)
            return
        }
        let shapeChanged = BlockPage.Mode(model.mode) != query.mode
        let waitIsOrphaned = query.mode == .wait
            && !earned.holds(target: query.target, tab: page.tab, now: Date())
        guard shapeChanged || waitIsOrphaned else { return }
        sendAway(from: query.target, opening: query.opens, on: page, showing: model)
    }

    /// The same question, asked of a tab nobody is looking at.
    ///
    /// **What this closes.** Taking a website out of a group while its block page is on screen
    /// used to leave the page standing: the poll reads the *frontmost* browser, and the user is in
    /// the settings window, so nobody re-asked until they switched back. Which is the wrong way
    /// round — finishing the edit is the moment they expect the site to be there.
    ///
    /// **Not a special case for deletion.** It re-runs `watchBlockPage`, so a target moved to
    /// another group, a window redrawn, a group switched off and a target deleted all end the same
    /// way, and they end it by the same rule: home only when *nothing* stands in the way, and a
    /// block that merely changed shape redraws instead.
    ///
    /// **The browser is asked rather than remembered.** `LastBlockPage` says which one to ask and
    /// nothing else; what that browser is showing is read now. Somebody can sit in Settings for a
    /// quarter of an hour, and a remembered address is a guess about a tab they may have taken
    /// somewhere else in the meantime — navigating on that guess would move a tab out from under
    /// them.
    func resolveParkedBlockPage(with appState: AppState) {
        guard let browserID = lastBlockPage.browserID else { return }
        // The poll owns the browser the user is actually looking at, and it runs this same second.
        // Asking twice would be a second Apple event and a second navigation for one change.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != browserID else { return }
        guard let parked = parkedBlockPage() else { return }
        watchBlockPage(parked.query, on: parked.page, with: appState)
    }

    /// The browser last seen on our block page, together with what it is showing **now** — or
    /// `nil` when there is none, it will not answer, or it has gone somewhere else since.
    ///
    /// A tab that moved on is forgotten here rather than acted on, which is what makes a record
    /// with no expiry safe to keep: the worst a stale one can cost is a single Apple event.
    private func parkedBlockPage() -> (page: BrowserWatcher.Page, query: BlockPage.Query)? {
        guard let browserID = lastBlockPage.browserID,
              let page = watcher.page(ofBrowserWith: browserID)
        else { return nil }
        guard case .blockPage(let query) = page.sighting else {
            lastBlockPage.forget(browserID: browserID)
            return nil
        }
        return (page, query)
    }

    /// Home again, to the exact address the query was carrying — the same one the button would
    /// have opened, because they are the same field.
    ///
    /// Answers whether the browser went. What the caller does with a clearance depends on *why*
    /// the tab is going home, which is the caller's question and not this one's.
    @discardableResult
    private func navigateBack(to query: BlockPage.Query, in browser: KnownBrowser) -> Bool {
        guard navigator.send(browser, to: query.opens, doing: "go back to the page") else {
            return false
        }
        sentAway.forget()
        return true
    }
}
