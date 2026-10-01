import SandglassCore
import Foundation

/// What a hard block does when the permission it needs has been taken away.
///
/// The obvious bypass is the user's own: open the Accessibility pane, switch the grant off, and
/// the blocks they set stop working. That was a free exit — the menu bar went yellow, the app said
/// so honestly, and nothing else happened. It is the most expensive exit now.
///
/// **While a group is hard-blocked and a permission that block needs is missing, every
/// application the dead block covers is hidden whole, on every activation.** No pause screen, no
/// budget, no countdown: `HideRung.hide`, which needs no permission at all and is the one rung
/// that still works on a Mac where the grant has gone. Out of "one tab is blocked", revoking the
/// grant makes "the whole browser is gone".
///
/// **It ends with its cause, instantly.** The grant is read live once a second — see
/// `PermissionWatch` — so the moment it is back this value is empty again and ordinary blocking
/// resumes. Nothing is remembered, nothing is persisted, and there is no penalty period: this is
/// friction, not punishment, and the line between the two is the whole product: the blockers that
/// cross it into punishment are the ones people uninstall.
///
/// ### What it covers, and nothing else
///
/// - **A hard-blocked group that reaches the web**, whose browser cannot be read or steered:
///   that browser. Reading and steering are the same Automation grant per browser, with the
///   accessibility tree as the fallback for all of them at once — so a browser is out of reach
///   only when *no* route to it is left. Automation revoked for Chrome while Accessibility still
///   stands leaves Chrome perfectly readable, and Chrome is not touched.
/// - **A hard-blocked group's applications**, the ones its targets name and the ones its live
///   categories carry. `hide()` needs no grant, so these are already sent away by the ordinary
///   path; naming them here is what makes this value a complete answer to "what does this
///   response cover" rather than a browser special case.
///
/// **The one thing it cannot reach is an app already in fullscreen.** Every way out of a
/// fullscreen Space — the attribute write and both keystrokes — is gated on the very grant that
/// is missing, and `hide()` answers `true` for such an app while leaving its Space standing. So a
/// blocked app sitting in its own Space stays there: it is hidden the moment it leaves fullscreen,
/// and while it is in fullscreen it is honestly out of reach. Nothing in user space does better;
/// see `HideLadder.fullscreenRungs`, which is where that gate is written down.
///
/// ### What it deliberately does not cover
///
/// - **A group that is not hard-blocked.** A spent budget, a cooldown, a daily limit — all of
///   them have a way through, and a permission missing under one of them stays what it is today:
///   degraded, yellow, honest, harmless.
/// - **Anything on the never-hidden list.** Finder, System Settings, Activity Monitor and
///   Sandglass itself are filtered out here as well as in `AppHider`, and System Settings staying
///   reachable is the whole way back — this feature dies without it. See `HideExemptions`.
/// - **A group the emergency pass has lifted.** The pass makes the engine answer `.notManaged`,
///   so the group is not hard-blocked and nothing here fires. The pass is an escape and stays
///   one. A group that opted out of the pass keeps its block, and therefore keeps this.
///
/// A value with no clock of its own, like `PermissionWatch` beside it: every rule is a function
/// of its arguments, and `AppState` is left with when to ask.
public struct BluntBlock: Equatable, Sendable {

    /// Every application hidden whole on every activation while this stands.
    public let bundleIDs: Set<String>

    /// The browsers among them, by the name the settings screen uses. Sorted, so the line does
    /// not reshuffle itself between ticks.
    public let hiddenBrowsers: [String]

    /// Nothing is being enforced bluntly. What every ordinary second looks like.
    public static let none = BluntBlock(bundleIDs: [], hiddenBrowsers: [])

    public init(bundleIDs: Set<String>, hiddenBrowsers: [String]) {
        self.bundleIDs = bundleIDs
        self.hiddenBrowsers = hiddenBrowsers
    }

    /// Whether this application walks straight into the hide ladder on its next activation.
    public func covers(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }

    /// Whether anything at all is being enforced bluntly this second.
    public var stands: Bool { !bundleIDs.isEmpty }

    /// The two blocks this responds to: a strict window standing, and a dated block running.
    ///
    /// Both are "shut until a moment you named", which is what makes revoking a grant under one
    /// of them an exit rather than an inconvenience. The other five reasons are not on the list
    /// on purpose — a cooldown ends in minutes, a budget comes back tomorrow, a focus session is
    /// something the user started this hour, and the clock guard is already refusing everything.
    public static let hardReasons: Set<BlockReason> = [.schedule, .datedBlock]

    /// What is being enforced bluntly right now.
    ///
    /// `hardBlockedGroups` is the engine's own answer this second, filtered to `hardReasons` —
    /// see `AppStateProjection.hardBlockedGroups`, which is where that walk already happens.
    ///
    /// **Accessibility being denied is the necessary condition for all of it**, which is why it
    /// is the first line: a browser with the accessibility route open is readable whatever
    /// Automation says, and an application with the grant in place can be taken out of fullscreen.
    /// `.unknown` is nobody having looked yet and is read as the good case — hiding a browser on
    /// the strength of not having checked is the one mistake this must never make.
    public static func standing(
        hardBlockedGroups: Set<String>, config: Config, access: BrowserAccess
    ) -> BluntBlock {
        guard access.accessibility == .denied, !hardBlockedGroups.isEmpty else { return .none }
        var apps: Set<String> = []
        var reachesWeb = false
        for groupID in hardBlockedGroups.sorted() {
            guard let settings = config.activeSettings(forGroup: groupID) else { continue }
            apps.formUnion(appBundleIDs(ofGroup: groupID, settings: settings, in: config))
            if !reachesWeb { reachesWeb = reachesTheWeb(settings, groupID: groupID, in: config) }
        }
        let browsers = reachesWeb ? unreachableBrowsers(access) : []
        let covered = apps
            .union(browsers.map(\.bundleID))
            .subtracting(HideExemptions.essentialBundleIDs)
        return BluntBlock(
            bundleIDs: covered,
            hiddenBrowsers: browsers.filter { covered.contains($0.bundleID) }.map(\.name).sorted()
        )
    }

    /// What the menu bar and the Protection card say while this stands, or `nil` when there is
    /// nothing new to say.
    ///
    /// It names the browsers and only the browsers, and that is deliberate. An application under
    /// a hard block is sent away with or without the grant, so saying "Notes is hidden whole"
    /// would announce the ordinary behaviour as though it were news — `PermissionWatch` already
    /// carries the general warning for that case. A browser disappearing is the surprising part,
    /// and somebody who does not know why would reach for the uninstaller.
    ///
    /// Three things in one line, because a status line gets one: what is happening, which
    /// permission is missing, and the way back. The way back is real — System Settings is on the
    /// never-hidden list precisely so this sentence cannot be a lie.
    public var line: String? {
        guard !hiddenBrowsers.isEmpty else { return nil }
        let verb = hiddenBrowsers.count == 1 ? "is" : "are"
        return "\(BrowserAccess.naming(hiddenBrowsers)) \(verb) hidden whole: a block is standing"
            + " and the Accessibility permission is missing. Grant it in System Settings."
    }

    // MARK: - The two halves of "what does this group cover"

    /// The browsers no route is left to.
    ///
    /// Two routes, and they are not the same consent: one line of AppleScript per browser under
    /// Automation, and the accessibility tree for all of them at once. A browser is out of reach
    /// only when both are shut — which for Firefox, whose tabs no dictionary can name, means the
    /// accessibility grant alone. See `KnownBrowser.Strategy`.
    ///
    /// `automationRefused` is what a browser has actually said no to this run rather than a guess
    /// at what TCC holds, which is the only honest reading available — see `BrowserAccess`.
    public static func unreachableBrowsers(_ access: BrowserAccess) -> [KnownBrowser] {
        guard access.accessibility == .denied else { return [] }
        let refused = Set(access.automationRefused)
        return Browsers.all.filter { browser in
            guard browser.strategies.contains(.appleScript) else { return true }
            return refused.contains(browser.name)
        }
    }

    /// Whether this group holds anything back on the web at all.
    ///
    /// The per-group half of `Config.protectsAnyWebsite`, and the same three ways in: a domain
    /// target, an advanced rule, and a live category carrying websites. A group made of nothing
    /// but applications reaches no browser, so revoking a browser permission takes nothing away
    /// from it and no browser is hidden over it.
    private static func reachesTheWeb(
        _ settings: GroupSettings, groupID: String, in config: Config
    ) -> Bool {
        if !settings.rules.isEmpty { return true }
        if config.targets.contains(where: { $0.groupID == groupID && $0.kind == .domain }) {
            return true
        }
        return !CategoryMembership.carriedDomains(settings, in: config).isEmpty
    }

    /// Every application in the group: the ones a target names, and the ones a live category
    /// carries. The same two halves `SessionEffects.hideApps` walks, for the same reason —
    /// missing the second kind would leave an app the group blocks sitting in front of the user.
    private static func appBundleIDs(
        ofGroup groupID: String, settings: GroupSettings, in config: Config
    ) -> [String] {
        config.targets.filter { $0.groupID == groupID && $0.kind == .app }.map(\.value)
            + CategoryMembership.carriedBundleIDs(settings, in: config)
    }
}
