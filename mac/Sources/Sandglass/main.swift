import SandglassAppCore
import SandglassCore
import AppKit

/// Builds the app and hands it the two long-lived objects it has.
///
/// The order matters: `AppState` derives its first picture during `init`, the status item is
/// built so it can show that picture immediately, the 1 Hz loop starts, and only then does
/// the blocker begin watching — its first act is to look at whatever is already frontmost,
/// which is a question nothing else in the app asks.
/// `@MainActor` on the class: every delegate callback below arrives on the main thread, and so
/// does the signal handler, which is delivered on `DispatchQueue.main` for exactly that reason.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusItemController: StatusItemController?
    private var blocker: AppBlocker?
    /// Held for as long as the app runs: a cancelled dispatch source stops delivering.
    private var terminationSignal: DispatchSourceSignal?

    /// One Sandglass, and it is the newest one — which since the keep-alive changed shape means it
    /// is launchd's.
    ///
    /// **Why there can be two.** launchd owns the process now: bootstrapping the agent starts the
    /// executable there and then. So every moment the app installs its own agent while running —
    /// a first launch, the settings toggle, and above all the launch that upgrades an agent
    /// written by an older build — ends with launchd starting a second copy beside the one that
    /// asked for it. LaunchServices deduplicates `open`; it has nothing to say about a binary
    /// launchd exec'd directly.
    ///
    /// **Why the newest wins.** In every one of those cases the fresh process is launchd's and
    /// the older one was started by hand or by `install.sh` — so retiring the older leaves the
    /// copy that will come back after a quit, which is the copy that has to be there. It also
    /// terminates: nothing restarts what is retired here, because launchd was never running it.
    ///
    /// `SIGTERM` rather than `NSRunningApplication.terminate()`, which sends a quit Apple event
    /// and would land in `applicationShouldTerminate` — that is the user asking, and it would put
    /// the keep-alive dialogue on screen behind the user's back. The signal is what
    /// `installTerminationSignalHandler` is for, and it shuts down without consulting the policy.
    ///
    /// Under `swift run` there is no bundle identifier and nothing matches, so a dev build never
    /// retires the installed copy and the installed copy never retires it.
    private static func retireOlderInstances() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let ours = NSRunningApplication.current.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        where other.processIdentifier != ours {
            kill(other.processIdentifier, SIGTERM)
        }
    }

    /// The one-time move from the app's previous name — see `LegacyMigration`.
    ///
    /// The old agent first, because booting it out is what stops the old app (launchd owns it);
    /// then any copy of the old app started by hand; then the data, once nothing is writing it;
    /// and last Sandglass's own agent, if the old one was there — installing it has launchd start
    /// a fresh copy that retires this one, so nothing may be left half-done when it does. A run
    /// redirected by `SANDGLASS_SUPPORT_DIR` has no legacy directory and moves nothing, and one
    /// redirected by `SANDGLASS_LAUNCH_AGENT_DIR` never talks to launchd — the seams hold here too.
    private static func migrateFromAppBlock(keepAlive: LaunchAgentManager) {
        let agent = keepAlive.retireLegacyAgent()
        if case .failed(let problem) = agent { NSLog("Sandglass: migration — \(problem)") }
        if keepAlive.talksToLaunchd {
            for old in NSRunningApplication.runningApplications(
                withBundleIdentifier: LegacyMigration.legacyBundleID
            ) { kill(old.processIdentifier, SIGTERM) }
        }
        if let legacy = AppPaths.legacySupportDirectory {
            switch LegacyMigration.migrateData(from: legacy, to: AppPaths.supportDirectory) {
            case .nothingToDo: break
            case .moved(let names): NSLog("Sandglass: migration — moved \(names) from \(legacy.path)")
            case .failed(let message): NSLog("Sandglass: migration — \(message)")
            }
        }
        if let problem = keepAlive.carryOverKeepAlive(from: agent) {
            NSLog("Sandglass: migration — \(problem)")
        }
    }

    /// The invisible menu that makes the standard editing shortcuts work.
    ///
    /// Every item targets the first responder (`target: nil`), which is how the system's own
    /// Edit menu behaves: whatever field holds the keyboard gets the verb.
    private static func hiddenMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        return main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, before anything reads a file or draws an icon: this may be the second Sandglass
        // on the Mac, and two of them would be two menu bar icons writing the same config.json.
        Self.retireOlderInstances()
        // A menu bar app: no Dock icon, no menu bar of its own, never the active app until
        // it puts a window in front of someone.
        NSApp.setActivationPolicy(.accessory)
        // No menu bar is ever drawn for an accessory app — but the key equivalents still route
        // through `NSApp.mainMenu`, and without an Edit menu there, ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z reach
        // no text field in the app. It shows up the ordinary way: paste refuses to paste.
        // The menu is invisible; the shortcuts are the whole point of it.
        NSApp.mainMenu = Self.hiddenMainMenu()

        // Before the store reads anything and before the agent is reconciled: the old app's agent
        // would otherwise start it beside this one, and its data is what this store should open.
        let keepAlive = LaunchAgentManager()
        Self.migrateFromAppBlock(keepAlive: keepAlive)
        let store = Store(directory: AppPaths.supportDirectory)
        // The blocker exists before the state that owns it, because `AppState.init` takes it.
        // It answers nothing until `start(appState:)` gives it something to ask. The store comes
        // first now because it takes one: the block page's ledger of outstanding opens is a
        // document in the same directory as the settings and the history, and so is the line it
        // writes when a browser refuses to move a tab.
        let blocker = AppBlocker(store: store)
        // Before `AppState` reads the toggle, and before anything else can act on it: the agent
        // names this bundle by absolute path, and the bundle moves — built in the checkout, then
        // copied to /Applications. It also carries a shape that changes, and this is the launch
        // on which an agent written by an older build is replaced. See `reconcileInstalledAgent`.
        logKeepAlive(keepAlive.reconcileInstalledAgent())
        let state = AppState(
            store: store,
            blocker: blocker,
            notifications: UserNotificationPresenter(),
            keepAlive: keepAlive
        )
        // And a first run switches that agent on, once and silently — see `AppState
        // .seedKeepAlive`. After the reconcile above and never before it: a reconcile that fails
        // takes the plist off disk, and an app left with no agent and the round still owed should
        // write one rather than record a round against nothing. The other order is safe by
        // construction — what the seed installs already names this bundle, so there would be
        // nothing for a reconcile to correct even if one still had to run.
        logKeepAlive(state.seedKeepAlive())
        installTerminationSignalHandler()

        // Manual test harness for the overlay. The seeded configuration lives in memory only —
        // see `DemoSeed`. `gentle` seeds the preset that grants opens without a session, which
        // is what exercises the activation grace, and `domain` seeds a website.
        switch ProcessInfo.processInfo.environment["SANDGLASS_SEED_DEMO"] {
        case "1": DemoSeed.app(state)
        case "gentle": DemoSeed.app(state, settings: .gentle)
        case "domain": DemoSeed.domain(state)
        default: break
        }

        statusItemController = StatusItemController(appState: state)
        state.start()
        blocker.start(appState: state)
        appState = state
        self.blocker = blocker

        // The main window opens itself on a launch that has nothing to protect — a first launch,
        // or one whose groups have all been emptied. There is no wizard behind it any more: the
        // window shows an empty group list, one sentence saying what a group is, and the `+` that
        // makes one, which is the whole of what setup was for.
        //
        // Here rather than in `StatusItemController`, which is the other place that could do it:
        // this is the only object that knows what "launch" means — the controller's `refresh()`
        // runs once a second and would need a flag to keep from reopening the window all day.
        //
        // Last, so nothing above waits on a window: a launch with nothing to protect has no
        // targets, so the blocker's opening sweep has nothing to find and the two cannot collide.
        if state.hasNothingToProtect {
            WindowPresenter.showSettings(appState: state)
        }

        applyManualSeams(to: state)
    }

    /// The rest of the manual test harness, gathered.
    ///
    /// Everything a verification script has to reach is behind a menu bar item, and a menu bar
    /// item cannot be clicked from a script: `SANDGLASS_OPEN` opens a window directly so the run
    /// can look for it in the window list, and `SANDGLASS_KEEPALIVE` is the settings toggle that
    /// installs the LaunchAgent. Where that agent lands is the manager's own seam,
    /// `SANDGLASS_LAUNCH_AGENT_DIR` — `test-keepalive.sh` sets it for the half of its run that
    /// checks the plist, and leaves it unset for the half that has to prove launchd accepts it.
    ///
    /// `SANDGLASS_SEED_DEMO` is the third and runs earlier, above: what it seeds has to be in
    /// the configuration before the blocker takes its opening sweep of the screen.
    private func applyManualSeams(to state: AppState) {
        switch ProcessInfo.processInfo.environment["SANDGLASS_OPEN"] {
        case "settings": WindowPresenter.showSettings(appState: state)
        case "group":
            // The group editor, which is otherwise only reachable by clicking a sidebar card.
            let first = ConfigBuilder.groups(in: state.config).first
            WindowPresenter.showSettings(
                appState: state, selecting: first.map { .group($0.id) } ?? .settings
            )
        case "presets": WindowPresenter.showSettings(appState: state, selecting: .presets)
        case "stats": WindowPresenter.showSettings(appState: state, selecting: .stats)
        default: break
        }
        // No window is open at launch, so the seam asks for the scope that does not want one —
        // the same one the quit dialogue uses. A passcode-locked run refuses it and logs why.
        switch ProcessInfo.processInfo.environment["SANDGLASS_KEEPALIVE"] {
        case "on": logKeepAlive(state.setKeepAlive(true, requiring: .deliberateAction))
        case "off": logKeepAlive(state.setKeepAlive(false, requiring: .deliberateAction))
        default: break
        }
    }

    private func logKeepAlive(_ problem: String?) {
        guard let problem else { return }
        NSLog("Sandglass: keep-alive — \(problem)")
    }

    // MARK: - Going away

    /// Whether the app may be quit — and it always may. What is left here is telling a user's
    /// quit from the system's, and putting one dialogue on screen for the first of them.
    ///
    /// The route in is the settings footer's Quit button. It used to be the popover's row, which
    /// made this the one place strict mode had to hold; it no longer holds anything, because a
    /// refusal that a round-the-clock block turned into "never" was a trap rather than a
    /// commitment device. `QuitPolicy` is the argument, and `AppState` still owns the decision.
    ///
    /// The dialogues below are run modally, which would be a hazard during a shutdown sequence —
    /// macOS gives an app seconds to answer, and a modal window does not answer. That hazard is
    /// retired rather than accepted: a logout, restart or shutdown never reaches them, because
    /// `isSystemInitiatedQuit()` short-circuits above.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        switch appState.quitDecision(systemInitiated: Self.isSystemInitiatedQuit()) {
        case .allowed:
            return .terminateNow
        case .confirmKeepAlive:
            return answerKeepAliveConfirmation(appState)
        }
    }

    /// Whether this quit request is a logout, a restart or a shutdown rather than a user's Quit.
    ///
    /// macOS asks every running app to quit during those sequences, and it asks with the same
    /// `quit` Apple event the Dock sends. The reason code riding on that event is the only thing
    /// that tells them apart — see `AppState.quitDecision(systemInitiated:)` for why the
    /// difference has to be honoured.
    ///
    /// The reason is read from both the parameter and the attribute list. `AERegistry.h` calls
    /// `kAEQuitReason` a parameter, most shipping code reaches for it as an attribute, and this
    /// is a path that cannot be exercised without actually logging the user out — so it looks in
    /// both places rather than betting the user's shutdown on which one is right. Anything not
    /// recognised is treated as a user's quit, which is the safe way round: the worst case is one
    /// keep-alive dialogue too many, not a Mac that will not restart. It used to be a great deal
    /// worse — a lock honoured mid-shutdown — and the refusal going took that hazard with it.
    private static func isSystemInitiatedQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication)
        else { return false }
        let keyword = AEKeyword(kAEQuitReason)
        let reason = event.paramDescriptor(forKeyword: keyword)
            ?? event.attributeDescriptor(forKeyword: keyword)
        guard let code = reason.map(Self.fourCharCode) else { return false }
        return systemQuitReasons.contains(code)
    }

    /// A reason arrives as `typeEnumerated` in practice, but `typeType` is legal too and the two
    /// are read by different accessors. Whichever is non-zero is the answer.
    private static func fourCharCode(_ descriptor: NSAppleEventDescriptor) -> OSType {
        descriptor.enumCodeValue != 0 ? descriptor.enumCodeValue : descriptor.typeCodeValue
    }

    /// Every reason that means "the machine is going down or the user is leaving". `kAEQuitAll`
    /// is deliberately absent: that is Dock's "Quit All", which is a user asking.
    private static let systemQuitReasons: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut),
        OSType(kAEShowRestartDialog), OSType(kAERestart),
        OSType(kAEShowShutdownDialog), OSType(kAEShutDown),
    ]

    /// Quitting an app that is back seconds later is worth one question, or the user watches it
    /// reappear believing the quit did not work. The middle button is the honest answer to what
    /// they probably meant.
    ///
    /// "Turn off and quit" is two promises, and the quit is cancelled when the first one cannot
    /// be kept. Quitting anyway would leave the user watching the app come back from an agent
    /// they were just told had been switched off — the exact confusion this dialog exists to
    /// prevent. They are shown what launchd said and left with the app running, which is the
    /// state they can still do something about.
    private func answerKeepAliveConfirmation(_ appState: AppState) -> NSApplication.TerminateReply {
        switch show(NSAlert.keepAliveConfirmation()) {
        case .alertFirstButtonReturn:
            return .terminateNow
        case .alertSecondButtonReturn:
            return turnOffAndQuit(appState)
        default:
            return .terminateCancel
        }
    }

    /// The middle button, and the settings passcode standing in front of it.
    ///
    /// Turning the agent off is the largest undo of the commitment there is — nothing is blocked
    /// once the app stops coming back — so the passcode applies here exactly as it applies on the
    /// settings page. The wait does not: it is measured from a settings window that is not open,
    /// and a friction nobody can satisfy is a dead button rather than a friction. Which is
    /// `.deliberateAction`, and the reasoning is written down at `SettingsLockScope`.
    ///
    /// Every way out that is not a quit says so. A passcode refused or never entered leaves the
    /// app running *and* still keeping itself alive, and quitting quietly with the agent still
    /// loaded would be the exact confusion this dialog exists to prevent.
    private func turnOffAndQuit(_ appState: AppState) -> NSApplication.TerminateReply {
        // The passcode is asked for first and then handed to the enforcement, so an agent is
        // never switched off on the way to finding out that the passcode was wrong.
        guard let typed = askForPasscode(appState) else {
            show(NSAlert.keepAliveStillOn("It needs the settings passcode, and it was not entered."))
            return .terminateCancel
        }
        let refusal = appState.setKeepAlive(
            false, requiring: .deliberateAction, passcode: typed
        )
        guard let refusal else { return .terminateNow }
        show(NSAlert.keepAliveStillOn(refusal))
        return .terminateCancel
    }

    /// The passcode for this one quit, or `nil` when the dialogue was dismissed. An empty string
    /// means nothing is being asked — no passcode set, or an emergency pass is lifting everything.
    ///
    /// Not the enforcement, which is `AppState.setKeepAlive(_:requiring:passcode:)` and stays
    /// there. This is only the way to satisfy it, put where the friction is felt — and it hands
    /// the answer over rather than unlocking with it, so the next quit asks again.
    private func askForPasscode(_ appState: AppState) -> String? {
        guard appState.standaloneActionNeedsPasscode else { return "" }
        let (alert, field) = NSAlert.passcodeForKeepAlive()
        guard show(alert) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// An accessory app is never the active one, and an inactive alert can end up behind
    /// whatever the user was looking at — the same reason every window here activates first.
    @discardableResult
    private func show(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// SIGTERM arrives from `launchctl bootout`, from `pkill`, and from a logout that ran out
    /// of patience. Its default disposition kills the process outright: `applicationWillTerminate`
    /// never runs, so the seconds the usage coalescing is holding back are lost. A dispatch
    /// source takes the signal instead and shuts down the way a quit does.
    ///
    /// The quit policy is deliberately **not** consulted here. `applicationShouldTerminate` is
    /// about the user asking; a signal is the system asking, and an app that ignores SIGTERM
    /// during a shutdown is a bug rather than strict mode. What holds strict mode together is
    /// the LaunchAgent starting the app again seconds later, not a process that refuses to die.
    private func installTerminationSignalHandler() {
        // Ignored at the POSIX level first, or the default disposition kills the process before
        // the source is ever delivered to.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            // The source's queue is `.main`, so this runs on the main thread.
            MainActor.assumeIsolated {
                self?.shutDown()
                // Not `NSApp.terminate`: that asks `applicationShouldTerminate`, which is
                // allowed to say no, and nothing may say no to this.
                exit(0)
            }
        }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Runs for a quit the policy above allowed, and for a logout that asked politely.
        // A kill does not come through here — that is what the signal handler is for.
        shutDown()
    }

    /// Everything that has to happen before the process goes away, whichever way it is going.
    private func shutDown() {
        appState?.stop()
    }
}

// SwiftPM treats a file called `main.swift` as top-level code, which is what an AppKit entry
// point wants anyway: build the application, give it its delegate, run it. `delegate` is a
// global, which is what keeps it alive — `NSApplication.delegate` is a weak reference.
//
// Deliberately not a SwiftUI `App`. This app opens every window it shows by hand — the
// popover, the overlay, the settings window — and a scene tree adds one it never asked for:
// SwiftUI answers an activation that finds no windows on screen by opening its only scene,
// which put an empty "Sandglass Settings" window behind the overlay whenever a blocked app was
// already frontmost at launch. SwiftUI views are unaffected; they live in `NSHostingView` and
// `NSHostingController` exactly as before.
let application = NSApplication.shared
// Top-level code is not MainActor-isolated under swift-tools-version 5.10, and `AppDelegate` is.
// The assumption is trivially true: this line *is* the main thread starting.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
