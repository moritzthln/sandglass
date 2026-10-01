import SandglassCore
import Foundation

/// What the engine's effects do to the world outside the engine: a notification before a session
/// relocks, and the apps sent away when it does.
///
/// `RulesEngine.tick()` hands back facts — this session is nearly over, this one has ended — and
/// says nothing about screens or windows, because it cannot: it has no notifier and no blocker.
/// Turning each fact into the thing the user actually sees is this type's whole job.
///
/// Split out of `AppState` for the reason `OpenLedger` was: the end of a session has to do three
/// things together, and two call sites reach it. The engine's own expiry comes through `apply`;
/// the user's "I'm done" does not — `endSession(early:)` emits no effect, because the user is
/// standing in front of the result — so `AppState` calls `sessionEnded` by hand. Both have to
/// write the same log line and send away the same apps, and one of them forgetting is a
/// statistics screen that under-reports and an app left sitting in front of a locked group.
///
/// `@MainActor` and `internal` for the reason `EngineReadout` is: the engine is confined to the
/// actor that owns it, and `AppState` is that actor.
@MainActor
struct SessionEffects {
    private let engine: RulesEngine
    private let blocker: BlockerControlling
    /// Optional because not every caller has somewhere to send one: a headless run passes nothing.
    private let notifications: NotificationPresenting?
    /// Asked for one thing: what to call a group in a notification.
    private let readout: EngineReadout
    private let ledger: OpenLedger

    init(
        engine: RulesEngine,
        blocker: BlockerControlling,
        notifications: NotificationPresenting?,
        readout: EngineReadout,
        ledger: OpenLedger
    ) {
        self.engine = engine
        self.blocker = blocker
        self.notifications = notifications
        self.readout = readout
        self.ledger = ledger
    }

    /// One effect from the engine's tick.
    func apply(_ effect: EngineEffect) {
        switch effect {
        case .sessionWarning(let groupID, let secondsLeft):
            notifications?.deliverRelockWarning(
                groupName: readout.groupName(groupID), secondsLeft: max(0, secondsLeft)
            )
        case .sessionEnded(let groupID):
            sessionEnded(groupID: groupID)
        case .dayRolledOver:
            // Every counter the new day reset is re-read by the recompute that follows.
            break
        }
    }

    /// A session is over, however it ended: log it, and send the group's apps away.
    func sessionEnded(groupID: String) {
        ledger.appendEvent(EventKind.sessionEnd, groupID: groupID)
        hideApps(inGroup: groupID)
    }

    /// Sends away everything in the group that is an app: the ones a target names, and the ones a
    /// live category carries. Missing the second kind would leave an app the group blocks sitting
    /// in front of the user with the session it was opened under already over.
    private func hideApps(inGroup groupID: String) {
        for target in engine.config.targets where target.groupID == groupID && target.kind == .app {
            blocker.hideApp(bundleID: target.value)
        }
        guard let settings = engine.config.activeSettings(forGroup: groupID) else { return }
        for bundleID in CategoryMembership.carriedBundleIDs(settings, in: engine.config) {
            blocker.hideApp(bundleID: bundleID)
        }
    }
}
