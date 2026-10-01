import Foundation

/// The waits this app has imposed, and the one navigation each of them buys once it is over.
///
/// **The button on the block page is a link.** It carries nothing, tells this app nothing, and asks
/// the browser for nothing unusual: pressing it is the browser walking to the site the way it would
/// walk to any other. Which leaves this app one job, and it is the job it is actually good at — on
/// the next poll it sees the target, and it must not block it. That permission is what is written
/// down here.
///
/// **Recorded when the wait starts, not when it ends.** The alternative is a race that cannot be
/// won: the page offers its button the moment its own countdown reaches zero, and the poll comes
/// round once a second, so a permission written on the tick that notices the countdown ended can be
/// most of a second late — and the press that lands in that gap meets a block page rather than the
/// site, which is exactly the failure this replaced. So the moment the wait is imposed, the wait
/// itself is written down along with the moment it is over. Nothing becomes claimable early: the
/// page's countdown is drawn in JavaScript over a number in a query string, and it is `earnedAt`
/// below that decides, measured on this app's own clock.
///
/// **What bounds a claim**, and each one is a way of walking through a block that was not served:
///
/// - **One address.** The wait was served on a page, and it buys that page. Anything else is a
///   fresh decision. The address is the same normalized spelling everything else here compares, so
///   what the poll reads and what was promised cannot drift apart.
/// - **One tab.** The wait was sat through in a tab, and it is that tab's press that spends it.
///   The alternative was the hole this closes: a background tab already parked on the same page is
///   indistinguishable from the button having been pressed, so switching to it for an unrelated
///   reason spent the open and let both tabs through. The *effect* looked like what the user
///   wanted, and they had not decided it — and the deciding is the product. Where a browser cannot
///   say which tab it means, `BrowserTab` carries `nil` and the key is the browser again; Safari
///   and Firefox are the two, and for them the hole is still open.
/// - **One browser**, which the tab carries with it. A block page copied into another browser is
///   not the wait that browser served.
/// - **After the wait, not before.** A press before `earnedAt` buys nothing, and — deliberately —
///   costs nothing either: refusing without consuming means a countdown somebody edited short
///   cannot burn the wait they had genuinely served most of.
/// - **Once.** Claiming removes it. Going back to the site an hour later is a new visit.
/// - **And not for long.** Every one carries the moment it stops being worth anything, so a
///   clearance cannot outlive the moment it was earned for.
///
/// **The engine still has the last word.** A claim is permission to *ask*, and `RulesEngine` is
/// asked a moment later: the day's opens can have run out while the countdown ran, a strict window
/// can have opened, a session can have started. A claim that ends in a refusal still spends the
/// permission — it was one navigation, and it was taken — and the tab meets a block page saying
/// what changed.
///
/// **Nothing here goes to disk**, and that is a change from the ledger of tokens it replaces. That
/// one was persisted because a relaunch mid-countdown left a page whose button redeemed nothing and
/// did nothing at all — a dead control. A link cannot be dead: it is an address, and pressing it
/// always reaches the site. What a forgotten wait costs now is that the app blocks the page again a
/// second later, which is a thing the app can see coming and repair — a wait page it is not
/// holding a wait for is redrawn with a countdown it is. See `AppBlocker.watchBlockPage`.
public struct EarnedOpens: Equatable, Sendable {

    /// One wait, as the two moments that matter — and whether the page that imposed it was ever
    /// actually on screen.
    public struct Earned: Equatable, Sendable {
        /// When the wait is over. Before this it buys nothing.
        public let earnedAt: Date
        public let expiresAt: Date
        /// Whether the poll has read this browser sitting on the block page this wait was imposed
        /// with. Until it has, the wait buys nothing — see `sighted` and `claim`.
        var pageSeen: Bool = false
    }

    /// How long a claim stays good once its wait is over. Long enough that somebody who walked
    /// away mid-countdown comes back to a button that works; short enough that the tab they left
    /// open is not a standing exemption by the evening.
    public static let lifetimeSeconds: TimeInterval = 15 * 60

    /// How many may be outstanding at once. A tab per screen and then some — and a ceiling, so a
    /// browser stuck in a navigation loop cannot grow this without limit. It is a per-tab ledger
    /// now, so a heavy tab bar reaches further into it than it used to; 32 is still more countdowns
    /// than anybody is sitting through at once, and the eviction takes the one nearest worthless.
    public static let capacity = 32

    /// The pair is the key, which is what makes "one address, one tab" structural rather than a
    /// check somebody has to remember to write. It is also why a wait already being served has to
    /// be defended: the target is the **normalized** page, so one tab moving between `?v=A` and
    /// `?v=B` is one entry, and the second of them used to overwrite the first.
    private struct Key: Hashable {
        let tab: BrowserTab
        let target: String
    }

    private var waits: [Key: Earned] = [:]

    public init() {}

    /// How many are outstanding. For the tests, and for reading the cap.
    public var count: Int { waits.count }

    /// Writes down the wait this app is imposing, and when it will be over.
    ///
    /// `countdownSeconds` is the wait the page is about to draw, recorded rather than read back
    /// off the page later: the page's copy of it is in a query string the user can edit.
    ///
    /// **A wait already being served is never replaced by a longer one**, and this is the whole of
    /// what that rule is. The target is the normalized page, so everything one tab does while its
    /// countdown runs — a Back out of the block page, a press this app answered as early, a hop
    /// between two videos on the same site — used to overwrite the moment it ripens and push it
    /// further away. From where the user sits that is a wait that restarts itself: they served
    /// sixty seconds, pressed the button the page offered them, and got sixty more.
    ///
    /// So the earlier ripening wins. It is the one the user has been watching, and it is the one
    /// the page draws — `AppBlocker.sendAway` reads `outstanding` and hands the page the same
    /// moment, so the countdown on screen and the ledger behind it cannot say different things.
    /// A *shorter* wait does replace it, because that is the page telling the truth about a block
    /// that got cheaper.
    public mutating func promise(
        target: String, tab: BrowserTab, countdownSeconds: Int, now: Date
    ) {
        prune(now: now)
        let earnedAt = now.addingTimeInterval(TimeInterval(max(0, countdownSeconds)))
        let key = Key(tab: tab, target: target)
        if let standing = waits[key], standing.earnedAt <= earnedAt { return }
        waits[key] = Earned(
            earnedAt: earnedAt, expiresAt: earnedAt.addingTimeInterval(Self.lifetimeSeconds)
        )
        // Over the ceiling: the one that dies first goes, which is the one closest to being
        // worthless anyway.
        while waits.count > Self.capacity,
              let oldest = waits.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            waits.removeValue(forKey: oldest)
        }
    }

    /// When the wait this app is already holding for this page in this browser will be over, or
    /// `nil` when it is holding none.
    ///
    /// What a block page about to be drawn asks, so that it draws the wait that is actually being
    /// served rather than a fresh one. A moment in the past is a real answer and means the wait is
    /// over: the page draws 0:00 and offers its button at once, which is exactly right — it was
    /// served, and the only thing left is to let it be spent.
    public func outstanding(target: String, tab: BrowserTab, now: Date) -> Date? {
        guard let wait = waits[Key(tab: tab, target: target)], now < wait.expiresAt
        else { return nil }
        return wait.earnedAt
    }

    /// The poll has read this browser sitting on the block page for this wait.
    ///
    /// **What tells arriving at the page from the page still being on screen.** A claim is spent by
    /// the poll reading the target, and until now *any* reading did it — including a reading of the
    /// address the tab had not left yet. A browser does not report a navigation the instant it is
    /// asked for one, and the shortest wait the stepper offers is three seconds, so a wait could
    /// ripen while the app was still being told the old address: at t=3 the stale reading claimed
    /// it, an open was spent, and no page was ever on screen at all.
    ///
    /// A `Bool` rather than a moment, because the question is not "how long ago" but "at all": the
    /// block page sits on screen for the whole of its countdown and the poll comes round once a
    /// second, so a page anybody could have pressed a button on is a page this has seen. A wait
    /// this app imposed and never once saw is one whose navigation did not land, and the honest
    /// answer to a reading of the site is to impose it again — which `decide` does, on the same
    /// ripening, so nothing is added to what the user has to sit through.
    public mutating func sighted(target: String, tab: BrowserTab, now: Date) {
        let key = Key(tab: tab, target: target)
        guard var wait = waits[key], now < wait.expiresAt else { return }
        wait.pageSeen = true
        waits[key] = wait
    }

    /// Whether this app is still holding a wait for this page in this browser, spent or not.
    ///
    /// Not a claim and not a step towards one: it answers the question a block page asks about
    /// itself, which is whether the countdown it is drawing is one anybody is still keeping. A page
    /// drawn before a relaunch is answered `false` here and redrawn, which is what stops its button
    /// from being a link to a block page.
    public func holds(target: String, tab: BrowserTab, now: Date) -> Bool {
        guard let wait = waits[Key(tab: tab, target: target)] else { return false }
        return now < wait.expiresAt
    }

    /// Spends the wait this page served, or answers `false` for every reason not to.
    ///
    /// `false` covers a wait nobody promised, one already claimed, one whose time is not up and one
    /// that has expired — deliberately one answer for all four, exactly as a block page is the one
    /// answer to all four from where the user is sitting.
    ///
    /// A wait that is not over yet is refused **without** being consumed. That is the whole
    /// difference between friction and punishment: somebody who edited the countdown short gets
    /// nothing, and the wait they were genuinely serving is still there to be served.
    ///
    /// So is one whose page was never on screen — see `sighted`. A wait is spent by *arriving* at
    /// the page, and a reading of an address a tab has not left yet is not an arrival.
    public mutating func claim(target: String, tab: BrowserTab, now: Date) -> Bool {
        prune(now: now)
        let key = Key(tab: tab, target: target)
        guard let wait = waits[key], wait.pageSeen, now >= wait.earnedAt else { return false }
        waits.removeValue(forKey: key)
        return true
    }

    /// Drops one. What the block not standing any more leaves behind: the window ended, the day
    /// rolled over, an open was granted. Nothing is owed for a wait nobody is serving.
    public mutating func forget(target: String, tab: BrowserTab) {
        waits.removeValue(forKey: Key(tab: tab, target: target))
    }

    private mutating func prune(now: Date) {
        waits = waits.filter { now < $0.value.expiresAt }
    }
}
