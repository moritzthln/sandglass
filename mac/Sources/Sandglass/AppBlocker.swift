import SandglassAppCore
import SandglassCore
import AppKit

/// The half of the app that watches macOS and puts the pause screen in front of things.
///
/// It knows two facts and no rules: what is in front, and what `AppState` says about it. Every
/// question goes through `AppState`'s inbound API — `blockDecision`, `consumeOpen`,
/// `recordDismissal`, `displayInfo` — which is also what writes the event log and keeps the menu
/// bar in step. `RulesEngine` and `Store` are never touched from here.
///
/// "What is in front" is two things, and they arrive by different routes. An **application**
/// announces itself: macOS posts an activation and this class decides on the spot. A **page**
/// announces nothing — a tab switch is not an activation — so the address is asked for on the
/// app's own 1 Hz clock. That is the seam this file is cut at: the page half is `PageBlocker`,
/// which owns the browser watcher, the navigator and the four pieces of bookkeeping only a page
/// needs, and this class holds one of them and forwards to it.
///
/// From the overlay's side the two are the same subject with the same two buttons, which is the
/// point: a blocked site meets exactly the screen a blocked app does, and "Back to work" sends the
/// browser away as it sends an app away. So the overlay stays here and `PageBlocker` reaches it
/// through `PageBlockerHost` — a page raises the pause screen only where it cannot be navigated
/// instead, which is Firefox and a browser that refused.
@MainActor
final class AppBlocker: BlockerControlling {

    /// Weak, and every use guarded. `AppState` holds the blocker for the life of the app, so
    /// this is the back edge of that cycle; a blocker that outlived its state would have
    /// nothing to ask and does nothing at all.
    private weak var appState: AppState?

    private let overlay = OverlaySet()

    /// The web half: what page is in front, and what happens to a tab that is blocked. Built here
    /// because it is this class's collaborator and nobody else's — see `PageBlocker`.
    ///
    /// Implicitly unwrapped because it takes `self` and so cannot be built before `init` has one.
    /// Set on the first line of `init` and never `nil` afterwards; there is no path into this
    /// class that does not run that line first.
    private var pages: PageBlocker!

    /// What the overlay is currently standing in front of, or `nil` when no overlay is up. Held
    /// so a re-render knows what to re-ask about, and so "Open" can give the keyboard back to
    /// whatever the user just paid for.
    private var subject: BlockSubject?

    /// The workspace subscription, kept only so `start` can tell it has already run.
    private var observer: NSObjectProtocol?

    /// The activation this class caused by opening an app for the user, and the apps it has
    /// just hidden. Both are documented in `ActivationGuards.swift`.
    private var grace = ActivationGrace()
    private var recentlyHidden = RecentlyHidden(window: staleFrontmostSeconds)

    /// What each blocked application has done to the hides sent at it, and what to try next on
    /// the ones that claimed to go and did not. Fed by every hide this class performs, whoever
    /// asked for it, and judged once a second by the sweep. See `FullscreenEscalation`.
    private var escalation = FullscreenEscalation()

    /// The store arrives here rather than being made here, so the app has one of them. It is
    /// passed straight on: what is built from it writes into the same directory as the settings
    /// and the history, and that is the page half's tab navigator.
    init(store: Store) {
        pages = PageBlocker(host: self, store: store)
    }

    /// How long an open's own activation stays forgiven, and how long macOS may go on naming
    /// a hidden application as frontmost. Both are about the operating system's latency, not
    /// about any rule — which is why the blocker reads the wall clock directly here instead of
    /// borrowing the injected clock `AppState` runs the rules on.
    private static let graceSeconds: TimeInterval = 2
    private static let staleFrontmostSeconds: TimeInterval = 2

    // MARK: - Startup

    /// Begins watching, and looks at what is already in front.
    ///
    /// Two steps rather than an initialiser taking `AppState`, because `AppState.init` needs
    /// the blocker: one of the two has to exist first, and it is this one.
    ///
    /// The sweep at the end is not belt and braces. `AppState.prime()` deliberately fires no
    /// recheck, and `didActivateApplicationNotification` never fires for an application that
    /// is already frontmost — so without this, a Mac that launches Sandglass while a blocked
    /// app is on screen would not show a pause screen until the user switched away and back.
    func start(appState: AppState) {
        // Called once, from the app delegate. Guarded rather than trusted: a second call
        // would install a second observer, and every activation would be handled twice.
        guard observer == nil else { return }
        self.appState = appState
        // Before anything else can look at the status line. `BrowserAccess.unknown` warns about a
        // permission nobody has been asked for yet, and this is the first moment the real answer
        // is available — still inside `applicationDidFinishLaunching`, so no yellow icon is ever
        // painted on the way past.
        appState.setBrowserAccess(pages.browserAccess)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // `.main` is what makes the isolation assumption safe: the block is delivered on
            // the main queue whatever thread the workspace posted from.
            MainActor.assumeIsolated {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let app else { return }
                self?.handle(activationOf: app)
            }
        }
        recheckFrontmost()
    }

    // MARK: - BlockerControlling

    /// Sends an application away so its next activation walks into the overlay. Idempotent:
    /// hiding an already-hidden app is a no-op, and there may be several instances.
    ///
    /// **What "away" takes is `AppHider`**, which comes out of fullscreen before it hides —
    /// `hide()` succeeds on an app that owns a fullscreen Space and leaves the Space standing, so
    /// the user watches the block do nothing. It also refuses to touch Finder, System Settings and
    /// Sandglass itself, in every mode; see `HideExemptions`.
    ///
    /// **Only a hide that actually happened is written down.** `RecentlyHidden` exists to make the
    /// recheck ignore a *stale* frontmost reading; an app that never went away is not stale, it is
    /// still there, and suppressing the recheck over it would swallow the pause screen a relock
    /// just earned. `HideLadder.wentAway` is what tells the two apart.
    ///
    /// The `Bool` does not cross `BlockerControlling` — nothing on the other side has any use
    /// for it — so this decision cannot be reached from the test target, which does not link
    /// this executable. `RecentlyHidden`'s side of the contract is pinned in
    /// `ActivationGuardTests` and the ladder's in `HideLadderTests`; what is left is checked by
    /// hand: put a blocked app in fullscreen and let its session expire without leaving the
    /// Space.
    func hideApp(bundleID: String) { hideApp(bundleID, escalating: []) }

    /// The same hide, with whatever the escalation had to add to it — which is nothing at all
    /// unless the sweep has watched this app claim to go away and stay where it was.
    private func hideApp(_ bundleID: String, escalating rungs: [HideRung]) {
        let outcome = AppHider.hide(bundleID: bundleID, escalating: rungs)
        // Every hide is an attempt, whoever asked for it — an activation, a session running out,
        // "Back to work", or the sweep. The next sweep tick judges them all the same way: an app
        // that is still on screen after one of them claimed success is stuck in a fullscreen Space.
        escalation.record(
            bundleID, wentAway: outcome.wentAway, fullscreenRead: outcome.fullscreenRead
        )
        if outcome.wentAway { recentlyHidden.record(bundleID, at: Date()) }
        // The overlay may be standing in front of exactly this app, showing a screen the hide
        // has just invalidated — a session that ran out is a cooldown from this second on.
        // This path is not affected by the line above, and must not be: the user is looking
        // at that screen, so it has to tell the truth.
        if subject?.bundleID == bundleID { refreshOverlay() }
    }

    /// A rule changed under whatever is in front; decide the screen again.
    ///
    /// While the overlay is up, Sandglass *is* the frontmost application — it took activation
    /// to get the keyboard — so the app the overlay is standing in front of is the only
    /// meaningful subject, and asking about it again is what lets a blocked screen re-render
    /// when the block behind it changes shape.
    func recheckFrontmost() {
        // A tab parked on the block page is re-decided **first**, and deliberately before anything
        // about what is in front: the case this closes is that nothing is. Every configuration
        // edit comes through here, and every one of them is made in a window of ours — so at the
        // moment a website is taken out of a group, the frontmost application is Sandglass and the
        // 1 Hz poll can see no browser to ask about. See `resolveParkedBlockPage`.
        if let appState { pages.resolveParkedBlockPage(with: appState) }
        if let subject {
            evaluate(subject)
            return
        }
        // A quick action runs while Sandglass itself is frontmost, so a recheck from the
        // popover finds our own application and decides nothing. Accepted: the user's next
        // switch arrives as an activation and is evaluated in full.
        // An application with no bundle id is nothing this app can decide about; `handle`
        // would turn straight back around, so the recheck stops here instead.
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else { return }
        // A session ending hides its apps and then changes the blocked set, which lands here
        // while macOS is still naming the app it was just told to hide. Taking that at face
        // value would raise a blocked screen over an app the user is no longer looking at.
        // Nothing is lost by waiting: going back to it arrives as a real activation.
        if recentlyHidden.isRecent(bundleID, now: Date()) { return }
        // Peeked at, never spent. The grace belongs to the activation an "Open" is about to
        // cause; a recheck that consumed it would leave that activation unprotected, and for
        // a gentle group the pause screen would come straight back with nothing to show for
        // the open. The trade-off is accepted: a rule that becomes true inside those two
        // seconds waits for the next real activation instead of interrupting on the spot —
        // and no caller can reach it, since a forced recheck comes only from a focus session,
        // a configuration change or the demo seed, none of which can run while the user is
        // pressing "Open" behind the overlay.
        if grace.isPending(bundleID: bundleID, now: Date()) { return }
        handle(activationOf: app)
    }

    /// Who the next second of usage belongs to, or `nil` when it belongs to nobody.
    ///
    /// Three cases answer `nil`, and each one is a second that would otherwise be charged to an
    /// app the user is not using:
    ///
    /// - **The screen is locked.** macOS goes on naming a frontmost application while nobody is
    ///   there, so a locked Mac left on YouTube would spend its daily limit overnight. Folded in
    ///   here rather than asked separately, because "who is in front" and "is anyone there" are
    ///   one question from the caller's side. See `ScreenLock`, which the page half asks the
    ///   same question of.
    /// - **Sandglass is in front.** Which it is whenever a pause screen is up — so the app behind
    ///   the overlay would be charged for the time spent deciding not to open it.
    /// - **No bundle id**, which is nothing this app can name a group for anyway.
    func frontmostBundleID() -> String? {
        guard !ScreenLock.isOn else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication, !Self.isOurself(app) else {
            return nil
        }
        return app.bundleIdentifier
    }

    // MARK: - Deciding what is on screen

    /// Every activation decides the overlay's fate, because the app that just activated is by
    /// definition the one in front: if it is not blocked, there is nothing left to block.
    private func handle(activationOf app: NSRunningApplication) {
        // Our own overlay activates us. Reacting to that would tear it down the instant it
        // appeared. An application without a bundle id — a transient helper, usually — is
        // left alone for the opposite reason: it can never be a target, and letting one
        // dismiss a pause screen would be a way through the block.
        guard !Self.isOurself(app), let bundleID = app.bundleIdentifier else { return }
        // The user chose this app, so nothing the last hide left behind applies to it any more.
        recentlyHidden.forget(bundleID)
        // **Above everything below it**, because it is the one case where the engine has nothing
        // to say and something still has to happen: a hard block is standing, the permission it
        // needs has been revoked, and this is an application the dead block covers — a browser
        // that can no longer be read, or an app of the group itself. It goes away whole, with no
        // screen and no way through, and it stops the moment the grant is back. See `BluntBlock`.
        //
        // Ahead of the grace deliberately, though the two cannot meet: a hard-blocked group grants
        // no open, so there is no forgiven activation for it to swallow. Where they ever did meet,
        // the response is the answer — a forgiveness issued under a block that has no way through
        // would be a bug, not a permission.
        if appState?.hidesWhole(bundleID: bundleID) == true {
            sendAway(.app(bundleID: bundleID, running: app))
            return
        }
        // Unless this is the activation an "Open" just performed — see `ActivationGrace`.
        // Without this, a gentle group would meet its own pause screen again the instant it
        // cleared one, because a gentle open starts no session for the decision to see.
        if grace.consume(bundleID: bundleID, now: Date()) { return }
        evaluate(.app(bundleID: bundleID, running: app))
    }

    private func evaluate(_ subject: BlockSubject) {
        guard let appState else { return }
        switch subject {
        case .app(let bundleID, _):
            present(
                appState.blockDecision(forBundleID: bundleID),
                info: appState.displayInfo(forBundleID: bundleID),
                for: subject
            )
        case .page(let url, _, _):
            present(
                appState.blockDecision(forURL: url),
                info: appState.webDisplayInfo(forURL: url),
                for: subject
            )
        }
    }

    /// The single path from a decision to what the user meets. The rule is `BlockPresentation`:
    /// a screen appears when there is a button on it, and otherwise the thing goes away.
    ///
    /// Answers whether anything is still standing in the way, which is the question the "Open"
    /// button asks. Deliberately not "is a screen showing": a refusal that hides the app shows no
    /// screen and must not be read as the block having lifted, or the button would spend nothing
    /// and let the user through anyway.
    @discardableResult
    private func present(
        _ decision: Decision, info: TargetDisplayInfo?, for subject: BlockSubject
    ) -> Bool {
        let presentation = BlockPresentation.for(decision: decision, info: info)
        switch presentation {
        case .nothing:
            clearOverlay()
        case .opensByItself:
            spendOnArrival(at: subject)
        case .sendAway where subject.isApplication:
            sendAway(subject)
        // A page reaches this line only while its overlay is already standing — Firefox, which
        // cannot be told to navigate, or a browser that refused the navigation. Every other tab is
        // sent to the block page in `decide` and never becomes a subject here at all. Both are
        // permanent: the fallback exists because the only other thing this class knows how to do
        // to a page is hide the whole browser, every innocent tab with it.
        case .screen(let model), .sendAway(let model):
            raise(model, for: subject)
        }
        return presentation.blocks
    }

    func raise(_ model: PauseScreenModel, for subject: BlockSubject) {
        self.subject = subject
        overlay.show(
            model: model,
            onOpen: { [weak self] in self?.openPressed() },
            onDismiss: { [weak self] in self?.dismissPressed() }
        )
    }

    /// No way through, so no screen: the application is hidden and the menu bar carries why.
    ///
    /// The overlay is cleared **first**, and it has to be: `hideApp` re-renders whatever screen is
    /// standing in front of the app it is hiding, which would arrive straight back here and hide
    /// it again, once per render, forever.
    private func sendAway(_ subject: BlockSubject) {
        clearOverlay()
        hideApp(bundleID: subject.bundleID)
    }

    /// A group set to no pause: the open is spent where the decision was read, and what the user
    /// reached for stays exactly where it is. Nothing is ever drawn.
    ///
    /// **The guard is written down before the open is spent, not after.** Spending re-derives the
    /// blocked set, which can call straight back into `recheckFrontmost` — and a group with no
    /// session length starts none for that pass to see, so it would meet the same decision, spend
    /// again, and go round until the budget was gone. The two guards are the two this class
    /// already keeps for an open it granted itself: the activation grace for an app, the cleared
    /// address for a page. The overlay goes first for the same reason: while one stands, a recheck
    /// evaluates its subject rather than consulting either guard.
    ///
    /// A refusal here is the world moving between reading the decision and spending it — a strict
    /// window opening on that very second. It is shown the way any other block is, which for an
    /// app is a hide and for a page is the block page.
    private func spendOnArrival(at subject: BlockSubject) {
        guard let appState else { return }
        clearOverlay()
        switch subject {
        case .app(let bundleID, _):
            guard let info = appState.displayInfo(forBundleID: bundleID) else { return }
            grace.grant(bundleID: bundleID, until: Date().addingTimeInterval(Self.graceSeconds))
            guard case .denied(let decision) = appState.consumeOpen(targetID: info.targetID)
            else { return }
            present(decision, info: info, for: subject)
        case .page(let url, let browserID, _):
            pages.rememberOpen(of: url, in: browserID)
            guard case .denied(let decision) = appState.consumeOpen(forURL: url) else { return }
            pages.forgetOpens(in: browserID)
            present(decision, info: appState.webDisplayInfo(forURL: url), for: subject)
        }
    }

    func refreshOverlay() {
        guard let subject else { return }
        evaluate(subject)
    }

    func clearOverlay() {
        subject = nil
        overlay.hide()
    }

    // MARK: - The two buttons

    /// Only reachable from a countdown that has run out — but the world may have moved during
    /// it, so the engine still has the last word.
    private func openPressed() {
        guard let appState, let subject else { return }
        switch subject {
        case .app(let bundleID, _): openApp(bundleID, subject: subject, appState: appState)
        case .page(let url, _, _): openPage(url, subject: subject, appState: appState)
        }
    }

    /// **Every ending that is not a refusal is the way through**, and that is the whole shape of
    /// this method.
    ///
    /// Three things can happen when the button is pressed, and only one of them used to be
    /// handled properly. The open is granted; or the world moved during the countdown and the
    /// refusal is shown on the same screen; or the world moved the *other* way and there is no
    /// screen left to show — a break window opening at 12:00 under a standing pause screen, or a
    /// target that stopped existing. Both of those last cases used to end in a black screen
    /// disappearing with the keyboard still held by Sandglass, which from where the user is sitting
    /// is a button that did nothing.
    private func openApp(_ bundleID: String, subject: BlockSubject, appState: AppState) {
        guard let targetID = appState.displayInfo(forBundleID: bundleID)?.targetID else {
            // Nothing claims this application any more, so there is no open to spend and nothing
            // left standing in the way either.
            letThrough(to: subject, granting: bundleID)
            return
        }
        switch appState.consumeOpen(targetID: targetID) {
        case .granted:
            letThrough(to: subject, granting: bundleID)
        case .denied(let decision):
            // The budget can have emptied while the countdown ran. The refusal reaches the user
            // the way any other block does rather than by closing the screen silently: a longer
            // wait is another screen, and a refusal with no way through hides the app.
            let stillBlocked = present(
                decision, info: appState.displayInfo(forBundleID: bundleID), for: subject
            )
            if !stillBlocked { letThrough(to: subject, granting: bundleID) }
        }
    }

    /// The same three for a page. `ClearedPage` does the grace's job here — a browser coming back
    /// to the front is an activation of an app nobody blocks — and it is written before the
    /// overlay goes, so the very next poll already sees it.
    private func openPage(_ url: String, subject: BlockSubject, appState: AppState) {
        switch appState.consumeOpen(forURL: url) {
        case .granted:
            letThrough(to: subject, clearing: url)
        case .denied(let decision):
            let stillBlocked = present(
                decision, info: appState.webDisplayInfo(forURL: url), for: subject
            )
            if !stillBlocked { letThrough(to: subject, clearing: url) }
        }
    }

    /// The overlay goes and the application gets the keyboard back.
    ///
    /// The overlay took activation to get the keyboard in the first place; without handing it
    /// over, "Open" would spend an open and leave the user looking at the desktop. The grace is
    /// granted first, because the activation is this class's doing and must not be read as the
    /// user walking back into a blocked app.
    private func letThrough(to subject: BlockSubject, granting bundleID: String) {
        let app = subject.running
        clearOverlay()
        grace.grant(bundleID: bundleID, until: Date().addingTimeInterval(Self.graceSeconds))
        app.activate()
    }

    /// The page half: no grace, and the address remembered instead.
    private func letThrough(to subject: BlockSubject, clearing url: String) {
        let browser = subject.running
        pages.rememberOpen(of: url, in: subject.bundleID)
        clearOverlay()
        browser.activate()
    }

    private func dismissPressed() {
        guard let subject else { return }
        switch subject {
        case .app(let bundleID, _):
            if let targetID = appState?.displayInfo(forBundleID: bundleID)?.targetID {
                appState?.recordDismissal(targetID: targetID)
            }
        case .page(let url, let browserID, _):
            appState?.recordDismissal(forURL: url)
            pages.forgetOpens(in: browserID)
        }
        // Cleared first, so the `hideApp` below finds no subject and does not re-render the
        // screen it is in the middle of dismissing.
        clearOverlay()
        // Through `hideApp` rather than `NSRunningApplication.hide()` directly: every hide
        // this class performs has to be remembered, or the recheck that follows would believe
        // macOS's stale answer about what is frontmost. For a page that hides the whole browser,
        // which is the honest reading of "back to work" — there is nothing smaller to send away.
        hideApp(bundleID: subject.bundleID)
    }

    /// By process id rather than bundle id, which a raw (unbundled) build does not have.
    private static func isOurself(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == NSRunningApplication.current.processIdentifier
    }

    // MARK: - Deciding what page is on screen

    /// One beat of the app's clock, handed straight to the half that owns it.
    func pollFrontmostPage() {
        guard let appState else { return }
        pages.poll(with: appState)
    }

    // MARK: - The sweep

    /// The same beat, spent on every application that is blocked with no way through and still
    /// on screen. **This is what makes the block relentless.**
    ///
    /// Activation was never enough on its own, and both halves of that turned up in one night of
    /// real use with the Accessibility grant in place: a hide that does not land — an app in its own
    /// fullscreen Space — was retried by nothing until the next activation, and a strict window
    /// opening at 00:30 over an app that is *already* frontmost produces no activation to retry
    /// on. So the visible applications are walked once a second and the ones with no way through
    /// are sent away again, with whatever `FullscreenEscalation` has earned against each of them.
    ///
    /// Which applications is `HideSweep`, which is a rule with tests; what is here is the walk
    /// over `NSWorkspace` and the two facts only AppKit can answer.
    func sweepBlockedApps() {
        guard let appState else { return }
        let standing = HideSweep.appsToSendAway(
            among: NSWorkspace.shared.runningApplications.map(Self.candidate),
            runningBundleID: Bundle.main.bundleIdentifier,
            // Peeked at, never spent — the grace belongs to the activation an "Open" is about to
            // cause, and a sweep that consumed it would leave that activation unprotected.
            graced: grace.pendingBundleID(now: Date())
        ) { verdict(of: $0, from: appState) }
        // Everything the sweep no longer names has gone away or stopped being blocked, and
        // neither is something to go on pressing.
        escalation.forgetAll(except: Set(standing))
        let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let trusted = AppHider.isAccessibilityTrusted
        for bundleID in standing {
            hideApp(bundleID, escalating: escalation.rungs(
                forStillStanding: bundleID,
                // A key event goes to whoever holds the keyboard, so the escalation is told who
                // that is and refuses the shortcuts for everyone else.
                isFrontmost: bundleID == frontmostID,
                accessibilityTrusted: trusted
            ))
        }
    }

    private static func candidate(_ app: NSRunningApplication) -> SweepCandidate {
        SweepCandidate(
            bundleID: app.bundleIdentifier,
            isHidden: app.isHidden,
            isRegularApp: app.activationPolicy == .regular
        )
    }

    /// What the sweep's rule asks about one application: the same fork `handle(activationOf:)`
    /// walks, in the same order, as a value.
    ///
    /// It has to stay the same fork. A second notion of "is there a way through" living in the
    /// sweep is how the two would eventually disagree, and the shape of that disagreement is an
    /// app being hidden out from under a countdown the user is in the middle of.
    private func verdict(of bundleID: String, from appState: AppState) -> SweepVerdict {
        if appState.hidesWhole(bundleID: bundleID) { return .hiddenWhole }
        let presentation = BlockPresentation.for(
            decision: appState.blockDecision(forBundleID: bundleID),
            info: appState.displayInfo(forBundleID: bundleID)
        )
        if case .sendAway = presentation { return .noWayThrough }
        return .leaveAlone
    }
}

// MARK: - PageBlockerHost

/// The overlay, lent to the page half. Three of the four are the methods this class already had;
/// what the protocol adds is only that `PageBlocker` may call them.
extension AppBlocker: PageBlockerHost {

    var standingSubject: BlockSubject? { subject }

    /// A browser hidden by "Back to work" goes on being named as frontmost for about a second, and
    /// the page poll must not believe that reading — see `RecentlyHidden`.
    func wasRecentlyHidden(_ bundleID: String) -> Bool {
        recentlyHidden.isRecent(bundleID, now: Date())
    }
}
