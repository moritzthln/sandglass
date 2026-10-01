import SandglassCore
import Foundation

// The protocols the app shell implements for `AppState`, and the small values it publishes
// back. They live in their own file rather than in `AppState.swift` because none of them is
// part of the loop: the loop is long enough to be worth reading on its own.
//
// Like the rest of this module, nothing here imports a UI framework — see `AppState`'s header.

/// Everything the app shell asks of the layer that watches and hides applications.
///
/// Implemented by `AppBlocker` in the executable, which is where AppKit lives. The protocol
/// is `MainActor`-isolated because both sides of it are.
@MainActor
public protocol BlockerControlling: AnyObject {
    /// Send the app behind a bundle id away, so its next activation walks into the overlay.
    func hideApp(bundleID: String)
    /// A rule changed under whatever is frontmost; look at the front of the screen again.
    func recheckFrontmost()
    /// One beat of the app's own clock, for the watching no notification can do.
    ///
    /// The frontmost *application* announces itself: macOS posts an activation, and the blocker
    /// decides on the spot. The frontmost *page* announces nothing — a tab switch inside Chrome
    /// is not an activation, and neither is a redirect — so the address in front has to be asked
    /// for on a clock. This is that clock, borrowed from the loop rather than a second timer of
    /// the blocker's own, so a Mac that slept polls no more than a Mac that did not.
    func pollFrontmostPage()
    /// The same beat, spent on the enforcement no activation announces.
    ///
    /// The blocker used to act only when macOS said an application had come to the front, and
    /// two things fall through that: a hide that did not land — an app in its own fullscreen
    /// Space — was retried by nothing until the next activation, and a window opening over an
    /// app that is *already* frontmost produces no activation at all. So every visible
    /// application is looked at once a second and the ones with no way through are sent away
    /// again. The rule for which ones is `HideSweep`.
    func sweepBlockedApps()
    /// The application the user is actually looking at, or `nil` when nobody is looking.
    ///
    /// Asked once a second, and the answer is charged straight to that app's group — so
    /// "nobody is looking" has to be a real answer rather than a stale bundle id. The
    /// implementation folds in every case where the Mac is unattended or Sandglass itself is in
    /// front; see `AppBlocker`.
    func frontmostBundleID() -> String?
}

/// A blocker with nothing to block onto: for a headless run, and for the tests that are
/// about the loop rather than about what reaches the screen.
@MainActor
public final class NoopBlocker: BlockerControlling {
    public init() {}
    public func hideApp(bundleID: String) {}
    public func recheckFrontmost() {}
    public func pollFrontmostPage() {}
    public func sweepBlockedApps() {}
    /// Nothing is in front of a headless run, so nothing is ever counted.
    public func frontmostBundleID() -> String? { nil }
}

/// How the user is told that a session is about to relock.
///
/// A protocol rather than a direct `UNUserNotificationCenter` call, for two reasons: it keeps
/// UserNotifications (and the app-bundle assumptions that come with it) out of this module,
/// and it lets a test read back what would have been delivered instead of inspecting the
/// system's notification centre.
@MainActor
public protocol NotificationPresenting: AnyObject {
    func deliverRelockWarning(groupName: String, secondsLeft: Int)
}

/// How the app is asked to keep itself running across a quit, a crash and a reboot.
///
/// Implemented by `LaunchAgentManager`, which is where `launchctl` and the user's
/// `~/Library/LaunchAgents` live. A protocol for the two reasons `NotificationPresenting` is one:
/// `AppState` stays free of the filesystem layout the app happens to have, and a test can watch
/// what was asked for without an agent ever reaching a real Mac.
@MainActor
public protocol KeepAliveManaging: AnyObject {
    /// Whether the agent is installed right now. Looked up rather than remembered, so an agent
    /// removed by hand is noticed the next time anything asks.
    var isInstalled: Bool { get }
    /// Install or remove it. `nil` means it went through; anything else is the reason it did
    /// not, in the words the settings screen shows.
    func setInstalled(_ installed: Bool) -> String?
}

/// What should happen when the user asks Sandglass to quit.
///
/// **Two answers, and neither is no.** There was a third — a refusal naming the hour a block ends
/// — and it is gone along with the alert that showed it; `QuitPolicy` is where the reasoning
/// lives. Nothing here consults the engine any more, which is why the case that carried its own
/// sentence has nothing left to carry.
///
/// The route in is the settings footer's Quit button. The menu bar popover used to have one too
/// and no longer does: "Turn off and quit" is the largest undo the app has, it belongs behind the
/// passcode door, and a popover has no door.
public enum QuitDecision: Equatable {
    /// Nothing would bring the app back. Quit.
    case allowed
    /// The keep-alive agent starts the app again within seconds. Worth asking about, or the user
    /// is left thinking the quit did not work.
    case confirmKeepAlive
}

/// A configuration the engine accepted and the disk would not take.
///
/// The only way an edit can fail once it has been through the settings lock, and the engine's own
/// error where there used to be two of them: `EngineError` is gone with the refusals it carried,
/// because a block is not a lock. This names a file rather than a rule. The reason is already a
/// sentence for the user, and the same one the menu bar shows, so `AppState.saveEdit` passes it
/// through untouched.
public struct ConfigWriteFailure: Error, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// What the menu bar icon says at a glance.
///
/// A pause outranks a degraded state for the icon, because "protection is off right now" is
/// the more urgent of the two facts. The degraded lines are still listed in the popover, so
/// nothing is hidden — see `AppState.warningLines`.
public enum StatusKind: Equatable {
    case active(targetCount: Int)
    case degraded(String)
    case paused(until: Date)
    /// The week's emergency pass is running: everything is lifted until this moment. Its own
    /// case rather than a second kind of pause, because the two end in different ways — a
    /// break can be ended early, an hour of pass is an hour.
    case emergencyPass(until: Date)
}

/// One group's row in the popover. A struct rather than the tuple the plan sketched: Swift
/// has no key paths into tuple elements, and `ForEach` needs one.
public struct BudgetRow: Identifiable, Equatable {
    public let id: String        // groupID
    public let name: String
    /// Where the day stands, in the engine's own words: a budget, or when the block ends.
    public let line: String
    /// Why it is blocked right now, or `nil` when it is not.
    ///
    /// The line above already says *when* it ends, which was all the popover used to show — and
    /// "Blocked until 11:00" is a fact with no cause attached. Somebody looking at it has to
    /// know whether they walked into a window they drew, a budget they spent or a session they
    /// started, because those are three different things to do about it.
    public let reason: BlockReason?

    /// Whether the engine will not act on this group **right now** — it is inside a break window,
    /// or protection is paused over the whole app.
    ///
    /// Not the same as switched off, and not the same as unblocked: the group is on, it is going
    /// to start blocking again, and at this moment nothing in it is being held back. The sidebar's
    /// shield keys off it, because an icon claiming protection over a group that is deliberately
    /// wide open is the one kind of lie this app cannot afford.
    public let isOpen: Bool

    public init(
        id: String, name: String, line: String, reason: BlockReason? = nil, isOpen: Bool = false
    ) {
        self.id = id
        self.name = name
        self.line = line
        self.reason = reason
        self.isOpen = isOpen
    }
}

/// The running session the menu bar counts down. `Equatable` so a test can state the whole
/// expected row at once, which a tuple could never be.
public struct SessionRow: Equatable {
    /// Which group's open is running. Carried so a screen about **one** group can tell whether
    /// this row is about it: the row lives in that group's editor now, and `endActiveSessionEarly`
    /// ends the session that relocks first — so a button shown next to the wrong group would end
    /// somebody else's open.
    public let groupID: String
    public let name: String
    public let secondsLeft: Int
    /// Whether ending this session early can hand half an open back — the group's own
    /// `earnBackEnabled`, which two of the three seeded presets have off.
    ///
    /// Carried because the button names the reward in its label. Over a Strict group that promised
    /// something `RulesEngine.end` refuses to give: it credits nothing unless the group asked for
    /// earn-back. A button that names a reward it will not pay is worse than one that says only
    /// what it does.
    public let earnsBack: Bool

    public init(groupID: String, name: String, secondsLeft: Int, earnsBack: Bool = false) {
        self.groupID = groupID
        self.name = name
        self.secondsLeft = secondsLeft
        self.earnsBack = earnsBack
    }
}
