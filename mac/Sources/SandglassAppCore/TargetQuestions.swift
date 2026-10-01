import SandglassCore
import Foundation

/// The questions asked about **one thing on screen** — the app in front, or the page in a
/// browser — none of which change anything.
///
/// Split out of `AppState` for the reason `EngineReadout` was: neither derives a published
/// value, writes to disk or tells the blocker anything, and the loop reads better without them
/// in the way. The two are separated from each other by what they are *about*: `EngineReadout`
/// answers about the app as a whole ("what is blocked", "when does the window close"), this one
/// answers about a single target, and only ever the same three questions —
///
/// - is it blocked right now,
/// - what should its pause screen call it,
/// - which group would it spend from.
///
/// "Pure" is a claim about this module rather than about the engine: every `RulesEngine`
/// question begins by applying whatever the clock has made true, and may queue effects for the
/// next tick while doing so. That is why this is `@MainActor` and `internal` — the engine is
/// confined to the actor that owns it, and `AppState` holds the only instance.
@MainActor
struct TargetQuestions {
    private let engine: RulesEngine

    init(engine: RulesEngine) {
        self.engine = engine
    }

    // MARK: - An application

    /// The one place a bare bundle id becomes a target id, so nothing in the app can disagree
    /// about the spelling.
    static func targetID(forBundleID bundleID: String) -> String {
        "\(TargetKind.app.rawValue):\(bundleID)"
    }

    /// What should happen if this application is brought to the front right now.
    ///
    /// Cheap enough to ask on every activation: it derives nothing and saves nothing, and
    /// anything the engine's catch-up produced is handed to the next tick.
    func decision(forBundleID bundleID: String) -> Decision {
        engine.decision(targetID: Self.targetID(forBundleID: bundleID))
    }

    /// What the pause screen should call this app, and which target it should spend from.
    /// `nil` when no target in the configuration claims that bundle id.
    ///
    /// The overlay needs what a `Decision` does not carry, and this is where it gets it instead
    /// of reading `Config` itself. As pure as `decision(forBundleID:)`: nothing is derived,
    /// saved or logged, so it stays cheap enough to ask on every activation.
    ///
    /// A target that exists but whose group has no settings still answers here — naming it is
    /// harmless, and the decision is what decides whether a screen is shown at all.
    ///
    /// An app no target names may still be claimed by a group's live category, and then the
    /// screen is named after the group: there is no target to borrow a name from, and "Messaging"
    /// is what the user ticked. Without this the engine would block the app and the overlay
    /// would have nothing to draw — a blocked app that simply refuses to come to the front.
    func displayInfo(forBundleID bundleID: String) -> TargetDisplayInfo? {
        let targetID = Self.targetID(forBundleID: bundleID)
        if let target = engine.config.targets.first(where: { $0.id == targetID }) {
            return TargetDisplayInfo(targetID: targetID, name: target.displayName)
        }
        guard let claim = CategoryMembership.claim(targetID: targetID, in: engine.config) else {
            return nil
        }
        let name = engine.config.groupDisplayName(forGroup: claim.groupID)
            ?? engine.config.category(id: claim.categoryID)?.name
            ?? claim.entry
        return TargetDisplayInfo(targetID: targetID, name: name)
    }

    // MARK: - A page in a browser

    // The same questions, asked about a URL. The browser watcher reaches them through
    // `AppState`. A URL is turned into a group by the engine (`RulesEngine.webMatch(forURL:)`,
    // the same matcher its decisions use), so an open spent on a page leaves exactly the trail
    // an open spent in an app does — same budget, same event log, same saved state.
    //
    // A whole URL rather than a host: an advanced rule can be about a path, and a
    // host alone could never tell `youtube.com/shorts` from `youtube.com/watch`. A bare host is
    // still a valid argument — it is a URL with no path.

    /// What should happen if this page is opened right now. As pure as its app counterpart.
    func decision(forURL url: String) -> Decision {
        engine.decision(url: url)
    }

    /// What the web pause screen should call this page, and which group it spends from.
    /// `nil` when nothing in the configuration claims it.
    func displayInfo(forURL url: String) -> TargetDisplayInfo? {
        guard let match = engine.webMatch(forURL: url) else { return nil }
        return TargetDisplayInfo(
            targetID: match.targetID ?? match.groupID, name: match.displayName
        )
    }

    // MARK: - Which group it belongs to

    /// The group a target id belongs to, or `nil` when the configuration does not know it.
    ///
    /// Live categories count, so a second spent in an app a group carries that way is charged to
    /// that group. Time the engine blocks for but does not count is a daily limit that never
    /// arrives.
    func groupID(forTargetID targetID: String) -> String? {
        if let groupID = engine.config.targets.first(where: { $0.id == targetID })?.groupID {
            return groupID
        }
        return CategoryMembership.claim(targetID: targetID, in: engine.config)?.groupID
    }

    /// The same, for an application. What a counted second is charged to.
    func groupID(forBundleID bundleID: String) -> String? {
        groupID(forTargetID: Self.targetID(forBundleID: bundleID))
    }
}
