import SandglassCore
import Foundation
import Observation

// This module deliberately imports no UI framework. AppKit, SwiftUI and UserNotifications
// all stay in the `Sandglass` executable, which is what lets the whole of `AppState` —
// the loop, the persistence rules, the pause friction — run under the test suite.
//
// The protocols and published values this class talks through are in `AppStateContracts`;
// the pause button's own state machine is in `PauseFriction`; every wait and passcode in front
// of loosening the rules is in `SettingsVisit`; what the menu bar says and what it had no room
// for is in `StatusReadout`; the disk and its refusals are in `StatePersistence`; every question
// of the engine that publishes nothing is in `AppStateProjection` (about the app as a whole) and
// `TargetQuestions` (about one thing on screen); the surface the blocker and the browser watcher
// are written against is in `AppStateInbound`, and the surface one settings visit is asked
// through in `AppStateSettingsVisit`; the two-step write an edit ends in — the engine, then the
// disk — is in `ConfigWriter`. What is left here is the loop, the mutations and when to save.

/// The app's single piece of mutable truth, and the MainActor boundary for the two core
/// objects that demand one.
///
/// `RulesEngine` and `Store` are both documented as "not thread-safe; confine to one thread
/// or actor". Nothing in the compiler enforces that — this class does, by being the only
/// owner of both and by being `@MainActor` itself. Every path in or out goes through here.
///
/// The shape of the loop: a 1 Hz timer asks the engine what time has made true, turns the
/// effects into notifications and hide calls, re-derives everything the UI shows, and saves
/// the state if it actually changed. Nothing else drives the app.
@Observable
@MainActor
public final class AppState {

    // MARK: - Published UI state

    public private(set) var statusKind: StatusKind = .active(targetCount: 0)
    /// Degraded lines not already shown as the status line — never silently dropped.
    public private(set) var warningLines: [String] = []
    public private(set) var budgetsByGroup: [BudgetRow] = []
    public private(set) var activeSession: SessionRow?
    public private(set) var focusSessionLine: String?
    /// What a pass is holding off. See `AppStateProjection.heldFocusSessionLine`.
    public private(set) var heldFocusSessionLine: String?
    public private(set) var streakLine = ""
    /// The running break: when blocking actually comes back, and whether an emergency pass is
    /// what is holding it open. `nil` when no break is running.
    ///
    /// Published rather than read out of `statusKind`, because the two disagree: a pass outranks
    /// a break in the status line, so a break underneath one vanishes from it — and it still has
    /// to be endable, and it still has to name the later of the two ends. Both ends in one value
    /// for the reason `SettingsLockState` is one: they are read together, always. See `BreakEnd`.
    public private(set) var breakEnd: BreakEnd?
    /// Where this week's emergency pass stands, for the settings section that spends it.
    public private(set) var emergencyPassLine = ""
    /// Whether the pass can be spent right now — what the button is enabled by.
    public private(set) var emergencyPassAvailable = true
    /// Where the settings lock stands this second: both countdowns, and whether the passcode is
    /// still owed. Re-derived on every tick, because two of the three move.
    public private(set) var settingsLockState = SettingsLockState()
    /// Where every group's own lock stands this second, keyed by group id.
    ///
    /// Published for the reason `settingsLockState` is: the timers move every second, so one
    /// assignment per tick is what counts a group's door down and what opens its page when the
    /// wait is over. One dictionary rather than a value per group, because the editor reads one
    /// entry and the sidebar reads none — and a dozen published fields would wake a dozen
    /// observers where one page redraws. See `GroupLockState`.
    public private(set) var groupLockStates: [String: GroupLockState] = [:]
    /// What the all-at-once group switch would do if it were pressed this second: which way it
    /// goes, how much it would move, and what it would leave alone.
    ///
    /// Published rather than computed on the row, for the reason `settingsLockState` is: half of
    /// it depends on which group locks are standing, so it changes on the stroke of a clock with
    /// nobody touching anything — and asking the engine from inside a SwiftUI body would mean the
    /// engine's own catch-up running during a view update. See `AllGroupsSwitch`.
    ///
    /// Assigned in `init` as well as on every pass, so a launch that comes up with groups already
    /// off from here offers the way back before the first tick rather than after it.
    public private(set) var allGroupsSwitch = AllGroupsSwitch.Plan.noGroups
    /// Whether the configuration names nothing at all — no targets, and no group that blocks
    /// something without one.
    ///
    /// What a launch reads to decide whether to put the main window in front of somebody. It used
    /// to open a setup wizard; the wizard is gone, and what is left is the window the app is,
    /// showing an empty group list and the `+` that ends it. An unreadable settings file is
    /// deliberately **not** one of these — see `StatePersistence.loadConfig`.
    public private(set) var hasNothingToProtect = false
    /// Whether the app is set to start at login and come back after a kill.
    ///
    /// Mirrored here rather than asked of the manager on every redraw: the manager answers by
    /// looking at the disk, and a SwiftUI toggle reads its binding far more often than the
    /// answer can change. Re-read after every change, never assumed from what was asked for.
    public private(set) var keepAliveEnabled = false
    /// What macOS is letting the app read of the browsers, for the settings row that explains it.
    /// Mirrored out of `StatusReadout` for the reason `keepAliveEnabled` is mirrored out of its
    /// manager: the watch it keeps is `@ObservationIgnored` — it is written once a second, and
    /// observing that would wake the settings window on every tick.
    public private(set) var browserAccess = BrowserAccess.unknown
    /// Today's numbers, re-read on every recompute. The stats screen shows these and nothing
    /// it worked out for itself.
    public private(set) var stats = StatsSnapshot(
        opensUsedToday: [:], opensAvoidedToday: 0, streakDays: 0, freezesLeft: 0
    )

    /// What the engine is running on, for the screens that show and edit it.
    ///
    /// A stored copy rather than a pass-through to the engine: the engine is
    /// `@ObservationIgnored` (it is a class, and observing it would mean observing every
    /// mutation of the loop), so a computed property reading it would never tell SwiftUI that
    /// the settings window has to be redrawn. It is only ever assigned when it differs — see
    /// `recompute` — because assigning an equal value still wakes every observer, once a
    /// second, forever.
    ///
    /// Read-only on purpose: the way to change it is `applyConfigEdit`, which is also the
    /// only way a change reaches the engine, the disk and the blocker.
    public private(set) var config: Config

    /// The break: the engine call that grants one, and the two sentences the card reads it
    /// through. Stored rather than `@ObservationIgnored` so the projections below are observed
    /// like any other published value — which is what puts a refusal on screen without the card
    /// having to ask for it.
    private var pauseBreak: ProtectionBreak

    /// One visit to the settings window, and both of the waits measured from it. What it
    /// publishes is `settingsLockState` and `breakWaitSecondsLeft`, so it needs no observers of
    /// its own.
    @ObservationIgnored var visit = SettingsVisit()

    /// Seconds until the Unblock card can be operated at all, or `nil` when it can be.
    ///
    /// Published rather than computed for the reason `settingsLockState` is: it moves every
    /// second, and one assignment per tick is what redraws the countdown. The card reads this
    /// single value for **both** of the things the wait stands in front of — choosing a length,
    /// and changing the wait itself — so the two can never come alive at different moments.
    public private(set) var breakWaitSecondsLeft: Int?
    /// Why protection cannot be paused right now, or `nil` when it can. Derived from what is
    /// true this second and nothing else, so it can never outlive its cause.
    public var pauseBlockedReason: String? { pauseBreak.blockedReason }

    // `undoLockText` was published here: what was holding the three app-wide undos — resetting
    // today's counters, the start of the day, the clock guard's off switch. Nothing holds them,
    // so there is nothing to publish. A running "Block everything" blocks apps and websites and
    // freezes no setting; see `RulesEngine.updateConfig`.
    /// Why the last pause attempt ended without a pause. A short-lived note, not a state.
    public var pauseStoppedReason: String? { pauseBreak.stoppedReason }

    /// Called after every recompute. The status item refreshes from this rather than by
    /// observing, so the icon is never a frame behind what the popover shows.
    @ObservationIgnored public var onStateChanged: (@MainActor () -> Void)?

    // MARK: - Collaborators

    @ObservationIgnored private let persistence: StatePersistence
    @ObservationIgnored private let engine: RulesEngine
    /// The two-step write every configuration edit ends in — the engine, then the disk, and the
    /// rollback when only the first of them takes it. See `ConfigWriter`.
    @ObservationIgnored private let writer: ConfigWriter
    /// The same engine, asked only questions that publish nothing. Held rather than rebuilt
    /// per call because it is asked several times a second.
    @ObservationIgnored let readout: EngineReadout
    /// The same again, asked about one thing on screen rather than about the app as a whole.
    /// Reachable from `AppStateInbound`, which is where the blocker's questions are answered.
    @ObservationIgnored let questions: TargetQuestions
    /// What the menu bar says, and everything true it had no room for. `@ObservationIgnored`
    /// because it is asked on every tick and holds the permission watch: observing it would wake
    /// the settings window once a second.
    @ObservationIgnored private var statusReadout: StatusReadout
    /// Spending an open, refusing one, counting a second — and the trail each has to leave.
    /// Reachable from `AppStateInbound`, for the reason `questions` is.
    @ObservationIgnored let ledger: OpenLedger
    /// What the end of a session does outside the engine: the log line, and the apps sent away.
    @ObservationIgnored private let effects: SessionEffects
    @ObservationIgnored private let blocker: BlockerControlling
    @ObservationIgnored private let notifications: NotificationPresenting?
    @ObservationIgnored private let keepAlive: KeepAliveManaging?
    @ObservationIgnored let clock: Clock
    /// `internal` rather than `private` for the reason `clock` is: `AppStateSettingsVisit` reads
    /// both to work out which day this moment is in. See `AppState.today`.
    @ObservationIgnored let calendar: Calendar

    // MARK: - Bookkeeping

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastBlockedGroups: Set<String> = []
    /// The groups a strict window or a dated block is holding shut, out of the last pass. Read by
    /// `refreshStatus` alone; see `AppStateProjection.hardBlockedGroups`.
    @ObservationIgnored private var hardBlockedGroups: Set<String> = []
    /// What a missing permission is currently being enforced with, worked out on every refresh.
    ///
    /// `@ObservationIgnored` because it is rewritten once a second and nothing draws it directly —
    /// what the screens read is the degraded line it produced. `private(set)` so the blocker's own
    /// question can reach it from `AppStateInbound` without a second copy existing anywhere.
    ///
    /// It is therefore at most one tick old when an activation asks. That is the same freshness
    /// every other answer in this app has, and it errs the harmless way round: a block that ended
    /// in the last second costs one hide, and the activation right after it goes through.
    @ObservationIgnored private(set) var bluntBlock = BluntBlock.none

    /// The break length the card offers first, and what an unspecified request means. Owned by
    /// `ProtectionBreak` and re-exported here because it is what the menu is written against.
    ///
    /// `nonisolated` for the reason the one it forwards to is: `startBreak` reads it as
    /// a default argument, and those are evaluated at the call site rather than inside the callee.
    public nonisolated static let defaultPauseMinutes = ProtectionBreak.defaultMinutes

    // MARK: - Startup

    /// `notifications` and `keepAlive` are optional because not every caller has somewhere to
    /// send one: the test suite passes recorders, and a headless run passes nothing at all.
    public init(
        store: Store,
        blocker: BlockerControlling,
        notifications: NotificationPresenting? = nil,
        keepAlive: KeepAliveManaging? = nil,
        clock: Clock = SystemClock(),
        calendar: Calendar = .current
    ) {
        self.blocker = blocker
        self.notifications = notifications
        self.keepAlive = keepAlive
        keepAliveEnabled = keepAlive?.isInstalled ?? false
        self.clock = clock
        self.calendar = calendar

        // A local until every stored property is assigned: a class initialiser may not touch
        // `self` before then, and the disk has to be read before the engine can be built. Both
        // halves in one call, because the order they are read in is a rule — see
        // `StatePersistence.load`.
        let persistence = StatePersistence(store: store)
        let loaded = persistence.load(now: clock.now, calendar: calendar)
        self.persistence = persistence
        let engine = RulesEngine(
            config: loaded.config.config, state: loaded.state, clock: clock, calendar: calendar
        )
        self.engine = engine
        let readout = EngineReadout(engine: engine, calendar: calendar)
        self.readout = readout
        writer = ConfigWriter(engine: engine, persistence: persistence)
        statusReadout = StatusReadout(persistence: persistence, readout: readout)
        pauseBreak = ProtectionBreak(engine: engine, readout: readout, clock: clock)
        let questions = TargetQuestions(engine: engine)
        self.questions = questions
        let ledger = OpenLedger(
            engine: engine, persistence: persistence, questions: questions, clock: clock
        )
        self.ledger = ledger
        effects = SessionEffects(
            engine: engine, blocker: blocker, notifications: notifications,
            readout: readout, ledger: ledger
        )
        config = loaded.config.config
        hasNothingToProtect = loaded.config.hasNothingToProtect
        // Primed here for the reason the status line below is: a launch that comes up with
        // groups already off from this switch has to offer the way back straight away, not from
        // whenever the first tick happens to run.
        allGroupsSwitch = AllGroupsSwitch.plan(for: config, locked: heldGroups(in: config))
        // A freshly built AppState must never be observably inconsistent: a damaged settings
        // file is degraded from this moment, not from whenever the first tick happens to run.
        refreshStatus()
    }

    /// Derives everything once and begins the 1 Hz loop. Split from `init` so the status item
    /// can be built first and see a fully derived state on its very first refresh.
    public func start() {
        prime()
        startTimer()
    }

    /// Brings the published state up to date and records which groups are blocked, without
    /// disturbing the blocker.
    ///
    /// The missing call is deliberate. `recheckFrontmost()` fires only when the blocked set
    /// *changes*, and at startup there is no previous set to differ from — so priming would
    /// otherwise report a change on every launch. The consequence is that whatever is already
    /// frontmost at launch is not examined here: `AppBlocker.start(appState:)` owns that
    /// initial sweep, because `didActivateApplication` does not fire for an app that is
    /// already in front either. `AppStateTests` pins this contract.
    public func prime() {
        lastBlockedGroups = recompute()
        saveStateIfChanged()
        onStateChanged?()
    }

    /// Stops the loop and puts on disk whatever the usage coalescing was holding back.
    ///
    /// The other half of `StatePersistence`'s fifteen-second window, and what keeps a quit from
    /// throwing counted seconds away. Both ways out reach it: `applicationWillTerminate` for a
    /// quit — every one of them, now that none is refused — and the SIGTERM source for a
    /// `bootout` or a `pkill`.
    public func stop() {
        timer?.invalidate()
        timer = nil
        if persistence.flushState(engine.state, now: clock.now) { refreshStatus() }
    }

    /// Test seam: runs exactly one iteration of the loop.
    ///
    /// In production the 1 Hz timer started by `start()` is the only caller of that loop. A
    /// test drives it by hand instead, on an injected clock, so a day, a schedule window or a
    /// session expiry can be crossed without waiting for one.
    public func tickForTesting() { tick() }

    // MARK: - The loop

    private func startTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // The timer is scheduled on the main run loop, so it fires on the main thread.
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` keeps the countdowns running while a menu or the popover is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The second counted here is not finished here: `finishMutation()` below saves the state and
    /// re-blocks the group if this was the second that reached its daily limit.
    private func tick() {
        for effect in engine.tick() { effects.apply(effect) }
        ledger.recordSecond(inFrontmost: blocker.frontmostBundleID())
        blocker.pollFrontmostPage()
        // Beside the page poll and for the same reason: what no notification announces has to be
        // asked for on a clock. A hide that did not land is retried here and nowhere else.
        blocker.sweepBlockedApps()
        expirePasscodeResetIfDue()
        finishMutation()
    }

    /// Re-derives everything, tells the blocker only when the set of blocked groups actually
    /// changed, and persists what moved. Every mutation and every tick ends here.
    ///
    /// The blocker is not told on a schedule: a strict window opening emits no engine effect
    /// at all, so the comparison against the last tick is the only thing that notices it —
    /// and comparing is also what keeps a 1 Hz loop from hammering `NSWorkspace` forever.
    ///
    /// Internal rather than private so that `AppStateInbound` can end its mutations here too:
    /// every path that spends or refuses an open leaves the same trail, and that is only true
    /// while there is one place the trail is left.
    func finishMutation(forceRecheck: Bool = false, notify: Bool = true) {
        let blocked = recompute()
        let changed = blocked != lastBlockedGroups
        lastBlockedGroups = blocked
        if changed || forceRecheck { blocker.recheckFrontmost() }
        saveStateIfChanged()
        if notify { onStateChanged?() }
    }

    // MARK: - Deriving what the UI shows

    /// Returns the ids of the groups that are hard-blocked right now.
    ///
    /// Every derivation happens in `EngineReadout.project`, which publishes nothing; what is
    /// left here is publishing it. Each field is assigned only when it differs, because an
    /// observer woken once a second by an identical value is a settings window that redraws
    /// itself all day for nothing.
    @discardableResult
    private func recompute() -> Set<String> {
        pauseBreak.expireNote()
        let projection = readout.project(now: clock.now)
        if stats != projection.stats { stats = projection.stats }
        if config != projection.config { config = projection.config }
        if budgetsByGroup != projection.budgets { budgetsByGroup = projection.budgets }
        if activeSession != projection.activeSession { activeSession = projection.activeSession }
        if focusSessionLine != projection.focusSessionLine {
            focusSessionLine = projection.focusSessionLine
        }
        let held = projection.heldFocusSessionLine
        if heldFocusSessionLine != held { heldFocusSessionLine = held }
        if streakLine != projection.streakLine { streakLine = projection.streakLine }
        if emergencyPassLine != projection.emergencyPassLine {
            emergencyPassLine = projection.emergencyPassLine
        }
        if emergencyPassAvailable != readout.emergencyPassAvailable {
            emergencyPassAvailable = readout.emergencyPassAvailable
        }
        // The rows have just been projected, so what an unblock is failing to reach is countable
        // here without asking the engine a second time. Normally none.
        let stillBlocked = projection.budgets.filter { $0.reason != nil }.count
        let running = readout.protectionPausedUntil.map {
            BreakEnd(
                breakEndsAt: $0,
                emergencyPassEndsAt: readout.emergencyPassEndsAt,
                stillBlocked: stillBlocked
            )
        }
        if breakEnd != running { breakEnd = running }
        let groupLocks = visit.groupLockStates(
            for: projection.config, at: reading, emergencyPassRunning: emergencyPassRunning
        )
        if groupLockStates != groupLocks { groupLockStates = groupLocks }
        let switching = AllGroupsSwitch.plan(
            for: projection.config, locked: heldGroups(in: projection.config)
        )
        if allGroupsSwitch != switching { allGroupsSwitch = switching }
        let gates = visit.state(
            for: projection.config, at: reading, emergencyPassRunning: emergencyPassRunning
        )
        if settingsLockState != gates.lockState { settingsLockState = gates.lockState }
        if breakWaitSecondsLeft != gates.breakWaitSecondsLeft {
            breakWaitSecondsLeft = gates.breakWaitSecondsLeft
        }
        pauseBreak.applyBlock(projection.pauseBlock)
        // Before the status line is derived from it, and it has to be: the line that says an
        // application is being hidden whole is worked out from this set.
        hardBlockedGroups = projection.hardBlockedGroups
        refreshStatus()
        return projection.blockedGroups
    }

    /// Republishes the icon and the warnings under it, and re-derives what a missing permission is
    /// being enforced with. Which of the four things the icon says, what is left over for the
    /// popover, and the blunt response itself are all `StatusReadout`'s.
    private func refreshStatus() {
        let status = statusReadout.status(
            config: engine.config, hardBlockedGroups: hardBlockedGroups
        )
        statusKind = status.kind
        warningLines = status.warningLines
        bluntBlock = status.blunt
    }

    /// 24-hour wall-clock text, in the engine's own wording. Forwarded rather than moved: the
    /// menu bar and the overlay format a date through the app, not through a readout.
    public func clockText(for date: Date) -> String { readout.clockText(for: date) }

    // MARK: - Inbound: is macOS letting the app do its job?

    // The rule is `PermissionWatch`; what is here is when to ask it.

    /// What macOS is letting the app read of the frontmost browser — and, on the same grant,
    /// whether it can take a blocked app out of fullscreen. Told by the blocker at launch and on
    /// every tick.
    public func setBrowserAccess(_ access: BrowserAccess) {
        guard statusReadout.setAccess(access) else { return }
        browserAccess = access
        refreshStatus()
        onStateChanged?()
    }

    // MARK: - Actions

    /// The user's own "I'm done" — the only way to earn half an open back.
    ///
    /// `endSession` emits no effect (the user is standing right in front of the result), so the
    /// effects the engine's own expiry would have raised are raised by hand.
    public func endActiveSessionEarly() {
        guard let groupID = readout.nextRelockingSession(now: clock.now)?.groupID else { return }
        engine.endSession(groupID: groupID, early: true)
        effects.sessionEnded(groupID: groupID)
        finishMutation()
    }

    public func startFocusSession(minutes: Int) {
        guard minutes > 0 else { return }
        // A focus session ends a running protection pause; a pending one is moot too, and so
        // is any reason left over from an earlier attempt.
        pauseBreak.abandon()
        engine.startFocusSession(minutes: minutes)
        // Everything is blocked as of now, including whatever the user is looking at.
        finishMutation(forceRecheck: true)
    }

    /// Unblocks everything for `minutes`, on the far side of the two frictions in front of it —
    /// the Unblock card's wait, and then the settings passcode when the user asked for it. Which
    /// two, in which order, and why each is asked here rather than only drawn as a dead control,
    /// is `SettingsVisit.breakRefusal`.
    ///
    /// Every refusal — both frictions', and the engine's own — becomes the note the card already
    /// shows and comes back here; `nil` means protection is off now.
    @discardableResult
    public func startBreak(
        minutes: Int = AppState.defaultPauseMinutes, passcode: String? = nil
    ) -> String? {
        guard minutes > 0 else { return nil }
        let blocked = visit.breakRefusal(
            for: config, at: reading, emergencyPassRunning: emergencyPassRunning,
            answered: passcode
        )
        if let blocked { return refused(blocked) }
        let refusal = pauseBreak.start(minutes: minutes)
        // Nothing is blocked as of now, so whatever the overlay is standing in front of has to be
        // asked about again — and nothing is, when the engine said no.
        finishMutation(forceRecheck: refusal == nil)
        return refusal
    }

    /// The refusal on screen where the card already shows one, and back to the caller.
    private func refused(_ reason: String) -> String {
        pauseBreak.note(reason)
        onStateChanged?()
        return reason
    }

    /// Change how long the Unblock card waits before it can be operated. `nil` means it went
    /// through; anything else is the reason it did not.
    ///
    /// **Behind the wait it sets**, which is what makes it a commitment rather than a preference:
    /// a wait that could be shortened the moment it became inconvenient would be worth nothing, so
    /// making the friction smaller costs the friction one last time. The same condition the length
    /// picker is held by, asked in the same place, so the two cannot come apart.
    ///
    /// The settings lock applies on top, because this is an edit to `config.json` like any other
    /// — and it is asked second for the reason `startBreak` asks it second.
    @discardableResult
    public func setBreakWaitSeconds(_ seconds: Int) -> String? {
        if let refusal = visit.breakWaitRefusal(for: config, at: reading) { return refusal }
        var newConfig = config
        newConfig.breakWaitSeconds = seconds
        return applyConfigEdit(newConfig)
    }

    /// The user wants their blocks back before the break is over. Never refused, by the settings
    /// lock least of all: a passcode here would be a lock on the way *in* to protection.
    public func endPauseEarly() {
        pauseBreak.endEarly()
        // Everything is blocked again as of now, including whatever is on screen.
        finishMutation(forceRecheck: true)
    }

    /// Spend this week's emergency pass. `false` means it is already spent, and nothing changed.
    ///
    /// The confirmation belongs to the caller: this is the point of no return, and the settings
    /// section asks before it gets here.
    @discardableResult
    public func useEmergencyPass() -> Bool {
        // A break being waited for is moot: everything is about to be unblocked anyway.
        pauseBreak.abandon()
        guard engine.useEmergencyPass() else { return false }
        // Nothing is blocked as of now, so whatever the overlay is standing in front of has to
        // be asked about again.
        finishMutation(forceRecheck: true)
        return true
    }

    /// Replace the configuration, or throw the engine's refusal — or the disk's — straight back
    /// at the caller. The two-step write and its rollback are `ConfigWriter`'s; what is here is
    /// the bookkeeping either outcome leaves behind.
    ///
    /// Everything is re-derived afterwards, including the frontmost app: `RulesEngine` drops
    /// the sessions of groups the new configuration no longer knows, silently and by design. A
    /// rolled-back write re-derives too — whatever the edit changed on screen for a moment is put
    /// back with it, and the degraded line the failed write left is picked up by the same pass.
    ///
    /// **Not the way in from a screen.** This checks the engine's locks and not the user's own:
    /// `applyConfigEdit` is the gated path, and the only one anything in `Sandglass` calls.
    public func updateConfig(_ newConfig: Config) throws {
        do {
            try writer.write(newConfig)
        } catch let failure as ConfigWriteFailure {
            finishMutation(forceRecheck: true)
            throw failure
        }
        hasNothingToProtect = newConfig.blocksNothing
        // The schedule that explained an earlier refusal may not even exist any more.
        pauseBreak.clearNote()
        finishMutation(forceRecheck: true)
    }

    /// Turn the keep-alive agent on or off. `nil` means it went through; anything else is the
    /// reason it did not, in the words the screen shows.
    ///
    /// Locked like a configuration edit, and for the larger reason: nothing is blocked once the
    /// app stops coming back, so switching the agent off is the biggest undo there is. It writes
    /// a LaunchAgent rather than `config.json`, which is why the lock is asked here by hand, and
    /// with a `scope` — the two callers do not owe the same frictions. See `SettingsLockScope`.
    ///
    /// **Switching it on is never refused.** A lock holds loosening and only loosening — the lock
    /// rule, see `EditDirection` — and starting the agent that keeps the app alive is strictly more
    /// protection. Only the switch-off owes the lock its answer.
    ///
    /// The published flag is re-read from the manager afterwards rather than assumed from the
    /// argument, so a toggle that failed goes back to showing what is actually installed.
    ///
    /// `passcode` is the answer a `.deliberateAction` carries with it — the quit dialogue's. It
    /// is remembered nowhere, so a second quit attempt asks again.
    @discardableResult
    public func setKeepAlive(
        _ enabled: Bool, requiring scope: SettingsLockScope, passcode: String? = nil
    ) -> String? {
        if !enabled, let refusal = lockRefusal(scope, answered: passcode) { return refusal }
        guard let keepAlive else { return nil }
        let problem = keepAlive.setInstalled(enabled)
        keepAliveEnabled = keepAlive.isInstalled
        onStateChanged?()
        return problem
    }

    /// A first run switches the keep-alive on, once and silently — the one job the deleted setup
    /// wizard had that nothing took over. Why it is not a question, and why a switch-off from
    /// here holds forever, is `KeepAliveSeed`; what is here is the three things only this class
    /// can do: ask the manager, republish the toggle, and put the round on disk.
    ///
    /// The settings lock is deliberately not consulted. It stands in front of loosening what is
    /// enforced, and this only ever switches protection on.
    @discardableResult
    public func seedKeepAlive() -> String? {
        guard let keepAlive, KeepAliveSeed.isOwed(config) else { return nil }
        if !keepAlive.isInstalled {
            let problem = keepAlive.setInstalled(true)
            keepAliveEnabled = keepAlive.isInstalled
            onStateChanged?()
            // Left unrecorded when it did not take, so the next launch tries again.
            guard keepAlive.isInstalled else { return problem }
        }
        return saveEdit(KeepAliveSeed.recorded(config))
    }

    /// Whether Sandglass may be quit right now. The rule — and why nothing standing refuses it —
    /// is `QuitPolicy`; this is only where its two facts come from.
    ///
    /// It used to hand over four, two of them read off the engine. It no longer asks the engine
    /// anything: what is blocked has stopped being an argument about whether the app may go away.
    public func quitDecision(systemInitiated: Bool = false) -> QuitDecision {
        QuitPolicy.decision(
            systemInitiated: systemInitiated, keepAliveEnabled: keepAliveEnabled
        )
    }

    /// Applies an edit from one of the settings screens. `nil` means it went through; anything
    /// else is the reason it did not, in the words the screen shows.
    ///
    /// **Every** way of changing the configuration comes through here — the settings page, its
    /// presets and its categories, the group editor, its time windows and interventions, the
    /// target lists and their memberships, and the browser-permission row — which is why the
    /// lock is checked here rather than in any of them. Not the *only* place: what loosens the
    /// rules without touching `config.json` asks for itself, with a scope. See `setKeepAlive`.
    ///
    /// The engine refuses nothing: it used to freeze the configuration whole while "Block
    /// everything" ran, and a strict window used to freeze the group inside it. Neither does, so
    /// the locks asked here are the only ones there are. See `RulesEngine.updateConfig`.
    ///
    /// **Both locks are handed the edit rather than only the fact of one**, because a lock holds
    /// loosening and only loosening — see `EditDirection`. An edit that blocks harder goes
    /// through whatever is standing; one that hands something back meets the wait or the code.
    @discardableResult
    public func applyConfigEdit(_ newConfig: Config) -> String? {
        if let refusal = lockRefusal(.settingsWindow, proposing: newConfig) { return refusal }
        // Then whichever group this edit loosens carries a lock of its own. After the app-wide
        // one because that is the wider statement, and one refusal at a time means the wider one
        // first; before the engine because a lock the user set is not the engine's business.
        if let refusal = groupLockRefusal(for: newConfig) { return refusal }
        return saveEdit(newConfig)
    }

    /// The same, with the settings lock left out — the way in for the lock's own machinery.
    ///
    /// Two callers, and both would otherwise be guarded by the thing they exist to undo: the
    /// wait that clears a forgotten passcode, and the clearing itself. Both are in
    /// `AppStateSettingsVisit`, which is why this is `internal` rather than `private`.
    ///
    /// **Before the write, not after**, and that is load-bearing: writing republishes everything
    /// — see `updateConfig` — so a visit told about its own exemption afterwards would have spent
    /// that pass publishing a countdown against it, and nothing would republish for a second. A
    /// write that then fails leaves a mark that exempts nothing: the timer it was about is still
    /// off, and the only visit it could ever let off is the one that just tried to switch it on.
    @discardableResult
    func saveEdit(_ newConfig: Config) -> String? {
        guard writer.canSave else { return ConfigWriter.unsavable }
        // A dated block whose day has arrived has already stopped blocking anything; this is where
        // it stops being written down. After the locks and before the disk, so nothing about which
        // way an edit moves is decided against a key the save is about to take out — see
        // `ConfigBuilder.droppingPastBlocks(in:onDay:)`.
        let cleaned = ConfigBuilder.droppingPastBlocks(in: newConfig, onDay: today)
        visit.timersSwitchedOn(from: config, to: cleaned)
        do {
            try updateConfig(cleaned)
            return nil
        } catch {
            return writer.refusal(error)
        }
    }

    /// Switches every group off at once, or puts back exactly the ones this switched off — and
    /// answers with the one sentence the row shows afterwards.
    ///
    /// **Through `applyConfigEdit` like every other edit, and that is the whole of the safety.**
    /// Switching a group off is an edit to that group, and a group's own lock exists to refuse
    /// those; a mass switch that wrote the configuration itself would be one button that undid
    /// every commitment in the app at once. What is different here is only which groups are in the
    /// edit: `AllGroupsSwitch` leaves out the ones a lock is holding, so a press that cannot do
    /// everything still does what it can and says so, rather than being refused whole and leaving
    /// the user to switch six groups off by hand. The plan is the same answer, asked a moment
    /// before the edit that asks it again — see `SettingsVisit.heldGroups`.
    ///
    /// A refusal comes back in its own words and nothing moves: the app-wide settings lock, a
    /// running focus session and a disk that will not take the file all refuse the lot, and none
    /// of them has a partial version.
    @discardableResult
    public func switchAllGroups() -> AllGroupsSwitch.Outcome {
        let edit = AllGroupsSwitch.edit(for: config, locked: heldGroups(in: config))
        // Nothing to submit: no groups at all, every group already off, or every group that is on
        // held by its own window. Each has a sentence of its own and none of them is a refusal.
        guard let newConfig = edit.config else {
            return AllGroupsSwitch.Outcome(text: AllGroupsSwitch.result(edit.plan), refused: false)
        }
        if let refusal = applyConfigEdit(newConfig) {
            return AllGroupsSwitch.Outcome(text: refusal, refused: true)
        }
        return AllGroupsSwitch.Outcome(text: AllGroupsSwitch.result(edit.plan), refused: false)
    }

    /// Opens per group since 03:00 last Monday, and whether the log could be read at all.
    ///
    /// `complete == false` is passed through rather than smoothed over: the counts are empty
    /// then, and empty is not zero. The stats screen has to say the number is unavailable —
    /// showing "0 opens this week" to someone who spent an hour on YouTube is the one thing
    /// this app must never do. Reading the clock through the injected one keeps the week
    /// boundary on the same timeline as everything else here.
    public func weeklyOpenCounts() -> (counts: [String: Int], complete: Bool) {
        persistence.weeklyOpens(
            now: clock.now, calendar: calendar, dayStartMinutes: config.dayStartMinutes
        )
    }

    /// Puts today's opens, time and cooldowns back to zero. Neither the streak nor the record of
    /// going over budget that scores it is touched. `nil` means it went through.
    ///
    /// **The settings lock, exactly as an edit gets it**, and it is the only one: handing back a
    /// budget already spent is loosening today's rules, which is the lock's business. The engine
    /// refused this while "Block everything" ran and no longer does — a block is not a lock. See
    /// `RulesEngine.resetToday`.
    ///
    /// The confirmation belongs to the caller, like the emergency pass: the numbers cannot be put
    /// back, and a screen that wiped a day on one click would be worse than not offering it.
    public func resetTodaysCounters() -> String? {
        if let refusal = lockRefusal(.settingsWindow) { return refusal }
        engine.resetToday()
        finishMutation(forceRecheck: true)
        return nil
    }

    /// Installs a configuration **without writing it to disk**.
    ///
    /// One caller, and it is not production surface: `DemoSeed`, the manual test harness behind
    /// `SANDGLASS_SEED_DEMO`. Its whole contract is that a demo run leaves the user's own
    /// `config.json` alone — whoever runs it on their own Mac must not find Notes among their
    /// targets afterwards and their own targets gone — which is why it cannot go through
    /// `updateConfig`, the only other way in and the one that saves.
    ///
    /// `public` because `DemoSeed` is a separate type rather than an extension of this class: a
    /// file-scoped `private` does not reach across files, and widening every member of the loop
    /// to satisfy a test harness is the worse trade.
    ///
    /// The settings lock is not consulted, and does not need to be: nothing is written, and the
    /// one caller runs behind an environment variable on a throwaway support directory.
    public func seedConfigInMemory(_ newConfig: Config) {
        engine.updateConfig(newConfig)
        hasNothingToProtect = false
        finishMutation(forceRecheck: true)
    }

    // MARK: - Persistence

    // The rules about what may be written, and the lines a failure leaves behind, are in
    // `StatePersistence`. What is left here is when to ask it: after every mutation, and after
    // a save that changed the degraded lines, once more to bring the status line with it.

    private func saveStateIfChanged() {
        if persistence.saveStateIfChanged(engine.state, now: clock.now) { refreshStatus() }
    }
}
