import Foundation

/// The full user-editable configuration; persisted as one JSON document.
public struct Config: Codable, Equatable, Sendable {
    public var version: Int
    public var targets: [Target]
    public var groupSettings: [String: GroupSettings]

    /// The order the sidebar lists the groups in, as ids — the user's own, and the only thing
    /// that decides it.
    ///
    /// There was no order at all before this. The list was derived from `targets`, so a group sat
    /// wherever the first thing in it happened to sit, and adding or removing one target
    /// reshuffled the sidebar. An order nobody chose and everybody's edits move is not an order.
    ///
    /// A sequence rather than an index per group, because that is the shape of the thing: an
    /// index has to be renumbered across every group on every move, and two groups claiming the
    /// same one is a state with no meaning. Here, a move is a removal and an insertion.
    ///
    /// **Nothing keeps this in step with `groupSettings`, and nothing needs to.** A hand-edited
    /// `config.json`, a group made by a build that did not write this key, a list half-written by
    /// an interrupted save — all of them leave ids in here that name nothing, or groups out there
    /// that are named nowhere. So it is read as a preference rather than as the truth: see
    /// `ConfigBuilder.groupOrder(in:)`, which walks past what does not exist and puts what is
    /// missing at the end. An absent key and an empty list therefore mean the same thing — no
    /// order recorded — and it is written either way, like everything else in this document.
    ///
    /// `ConfigBuilder.removingGroup` takes a deleted id out all the same, exactly as it does from
    /// `switchedOffTogether` below and for the same reason: the walking past is what makes a
    /// hand-edited file safe, and not letting the file fill up with the names of things that no
    /// longer exist is what makes it readable.
    public var groupOrder: [String]

    /// The groups the all-at-once switch turned off, as ids — empty whenever nothing is off from
    /// there.
    ///
    /// The whole feature is this one list. Switching every group off is easy; switching them back
    /// on **without** switching on the ones the user deliberately switched off last week is not,
    /// and a control that cannot tell those two apart destroys that distinction the first time it
    /// is used. So what is recorded is what the switch actually *changed*, never what happens to
    /// be off: a group that was already off is not in here, and the way back does not touch it.
    ///
    /// On disk rather than in memory because the way back has to survive a relaunch — being
    /// unable to get back to where you were because the app restarted is the worst version of
    /// this. An absent key and an empty list mean the same thing, which is what every file written
    /// before this existed says, and it is written either way like everything else here.
    ///
    /// **Read as a preference rather than as the truth**, exactly like `groupOrder` above and for
    /// the same reason: nothing keeps it in step with `groupSettings`. An id naming a group that
    /// is gone is walked past, and a group made since is simply not in here — so neither can make
    /// the way back wrong or make it fail. `ConfigBuilder.removingGroup` takes the id out too, so
    /// the list does not fill up with the names of things that no longer exist; the walking past
    /// is what a hand-edited file is safe by.
    ///
    /// Sorted, so two runs that switch the same groups off write the same bytes.
    ///
    /// Held by no lock of its own, and it does not need to be: it blocks nothing. The group
    /// switches it names are what a group's own lock refuses, and they are refused one by one
    /// where every other edit is — see `GroupLocks`. What writes this is `AllGroupsSwitch`.
    public var switchedOffTogether: [String]

    /// The bundles of settings the user can make a group from, in the order they are offered.
    ///
    /// Seeded with Gentle, Standard and Strict and then entirely theirs: renameable, editable,
    /// deletable, and extendable. An empty list is a legitimate state — every group would then be
    /// Custom, which is what every group already is until somebody picks a preset for it.
    ///
    /// Part of the configuration rather than of the state for the reason `settingsLock` is: these
    /// are decisions the user made, not something today produced.
    public var presets: [NamedPreset]

    /// The lists a group can be a live member of, in the order they are offered.
    ///
    /// Seeded with the six the app ships and then entirely the user's: renameable, editable,
    /// deletable, and extendable. They used to be a `static let` in the code, which meant ticking
    /// "Social" was a leap of faith — nothing anywhere said what was in it, let alone let anybody
    /// change it. An empty list is a legitimate state; a group is then made of targets and rules.
    ///
    /// Part of the configuration rather than of the state for the reason `presets` is: these are
    /// decisions the user made, not something today produced.
    public var categories: [DistractionCategory]

    /// How many rounds of seeded categories this file has already been offered.
    ///
    /// The first round is the six the app started with, and an absent `categories` key still
    /// means "none of them yet" — that path is untouched. This exists for the **second** round.
    /// Adult arrived after every `config.json` already had a `categories` key, so there was no
    /// absent key left to trigger on, and the obvious alternative — seed any id that is missing —
    /// would put the category back on the next launch after somebody deleted it.
    ///
    /// So what is recorded is how many rounds have been *offered*, never what is present. Once it
    /// says two, nothing seeds again: the category can be renamed, emptied or deleted and it
    /// stays that way, which is the whole promise the seeded six already make.
    ///
    /// Always written, empty list or not, for the same reason `categories` is.
    public var categorySeed: Int

    /// The round every file is brought up to on load. Bump it when a round is added to
    /// `DistractionCategory.seedRounds`, which is the only thing it counts.
    public static let currentCategorySeed = DistractionCategory.seedRounds.count

    /// When a day — and a week — starts, as minutes from local midnight.
    ///
    /// 03:00 rather than midnight, because 02:00 belongs to the night that came before it and
    /// late-night scrolling must not tap a fresh budget. Configurable because "my day starts at
    /// 05:00" is a fact about the user, not about the app; see `EngineState.dayKey`.
    public var dayStartMinutes: Int

    /// Midnight to six in the morning. The span a control may offer, rather than a rule the file is
    /// held to: a hand-edited value outside it is shown and stays reachable, like every other
    /// number on these screens — see `ControlRules.reachableRange`.
    ///
    /// Six because past it the setting stops being "when my day starts" and starts being a way to
    /// give an afternoon its own budget, which is what the time windows are for.
    public static let dayStartRange = 0...(6 * 60)

    /// Whether the menu bar counts the running session down next to the icon.
    public var showsMenuBarCountdown: Bool

    /// How long before a session relocks the heads-up arrives, or `nil` for no warning at all.
    ///
    /// One minute was hard-coded in V1. It is a setting because the right number is a fact
    /// about the user — long enough to finish the video, short enough not to be a second
    /// countdown — and because "no warning" is a legitimate answer.
    public var expiryWarningSeconds: Int?

    /// The warning V1 gave, and the one a file that predates the setting keeps giving.
    public static let defaultExpiryWarningSeconds = 60

    /// Nought to five minutes, and **nought is the off state**: this is the daily time limit's
    /// shape, where the absence of a budget is a bound rather than a row of its own. The stepper's
    /// bottom is `nil` on the way to disk — see the binding in `SettingsPageView` — so the file
    /// still spells "no warning" as no number, which is what it has always meant.
    ///
    /// Five minutes at the top because past that the heads-up stops being a heads-up and becomes a
    /// second countdown running beside the first.
    public static let expiryWarningRange = 0...300

    /// Where one press of the warning stepper lands, from `seconds`, in the direction asked for:
    /// the next half-minute.
    ///
    /// A destination rather than a step size, for the reason `ControlRules.clockMinutes` is one: a
    /// value on no grid line — typed, or left by an older build's menu — steps *onto* the nearest
    /// one rather than carrying its offset up and down the span forever, and a press and its undo
    /// are each other.
    ///
    /// Flat, where the settings lock's wait bands. Half a minute is as fair a step at four minutes
    /// as it is at one, because the whole span is five: ten presses from off to the top is a
    /// stepper, not a chore, and the field takes anything finer.
    public static func expiryWarningSeconds(after seconds: Int, goingUp: Bool) -> Int {
        let step = 30
        return goingUp ? ((seconds / step) + 1) * step : ((seconds - 1) / step) * step
    }

    /// Whether a system clock that was changed blocks everything until it is put back.
    ///
    /// On by default. Every *duration* in this app is already measured against the uptime counter
    /// and cannot be shortened by the clock (see `ClockReading`), and the day boundary and the
    /// weekday windows are read against the extrapolated time either way — so this setting is not
    /// what makes tampering pointless. What it adds is the refusal to carry on as if nothing
    /// happened: while the two clocks disagree, every managed group is blocked rather than judged
    /// against a time the app knows is wrong.
    ///
    /// Off is a legitimate answer for anybody who genuinely changes their Mac's clock — testing
    /// software, or a machine whose time is set by hand — and then only the extrapolation applies.
    public var preventTimeChange: Bool

    /// How long the Unblock card waits, from the moment the window opens, before a break can be
    /// asked for at all.
    ///
    /// The wait used to be a hard-coded thirty seconds that started on a button press, which put
    /// the choice of length in front of the wait — the impulse doing the choosing, and then
    /// sitting out a gap it had already crossed. It counts from the window now, and the length is
    /// chosen at the end of it; see `BreakWaitGate`.
    ///
    /// **Zero is allowed and means no wait.** This is the soft door: somebody who sets it to zero
    /// has decided, and the app does not argue. Commitment is enforced by the strict windows and
    /// by the settings lock, which is also what keeps shortening this from being free — the row
    /// that sets it is behind the wait like everything else on the card.
    public var breakWaitSeconds: Int

    /// The thirty seconds V1 spent, and what a file written before the setting existed keeps
    /// spending — so nothing changes for anybody who never touches it.
    public static let defaultBreakWaitSeconds = 30
    /// Nought to ten minutes. The top is where a wait stops being friction and starts being a
    /// broken card; the bottom is the user's right to no friction at all.
    public static let breakWaitRange = 0...600

    /// How many rounds of switching the keep-alive on this file has already been offered.
    ///
    /// Zero for a fresh install, and zero for every file written before this key existed. What
    /// is counted is the **offer**, never what is installed — the shape `categorySeed` above
    /// has, for the same reason: an agent the user switched off must stay off. When the round is
    /// offered, and what a failed one does, is `KeepAliveSeed`. Always written.
    public var keepAliveSeed: Int

    /// The round a launch brings a file up to once the agent is on. Bumping it would offer the
    /// switch again to a file that has already had it, so the bar is deliberately high.
    public static let currentKeepAliveSeed = 1

    /// What stands between an impulse and a change to everything above. Both halves off by
    /// default; see `SettingsLock`.
    ///
    /// Part of the configuration rather than of the state because it is a decision the user
    /// made, not something today produced — and because the screen that edits it is the screen
    /// it guards.
    public var settingsLock: SettingsLock

    public init(
        version: Int,
        targets: [Target],
        groupSettings: [String: GroupSettings],
        groupOrder: [String] = [],
        switchedOffTogether: [String] = [],
        presets: [NamedPreset] = NamedPreset.builtIns,
        categories: [DistractionCategory] = DistractionCategory.builtIns,
        categorySeed: Int = Config.currentCategorySeed,
        dayStartMinutes: Int = EngineState.defaultDayStartMinutes,
        showsMenuBarCountdown: Bool = true,
        expiryWarningSeconds: Int? = Config.defaultExpiryWarningSeconds,
        preventTimeChange: Bool = true,
        breakWaitSeconds: Int = Config.defaultBreakWaitSeconds,
        keepAliveSeed: Int = 0,
        settingsLock: SettingsLock = SettingsLock()
    ) {
        self.version = version
        self.targets = targets
        self.groupSettings = groupSettings
        self.groupOrder = groupOrder
        self.switchedOffTogether = switchedOffTogether
        self.presets = presets
        self.categories = categories
        self.categorySeed = categorySeed
        self.dayStartMinutes = dayStartMinutes
        self.showsMenuBarCountdown = showsMenuBarCountdown
        self.expiryWarningSeconds = expiryWarningSeconds
        self.preventTimeChange = preventTimeChange
        self.breakWaitSeconds = breakWaitSeconds
        self.keepAliveSeed = keepAliveSeed
        self.settingsLock = settingsLock
    }

    /// Two retired keys are deliberately absent, and a document still carrying either one decodes:
    /// a key no `CodingKey` names is one `Codable` walks past, and the next save drops it.
    ///
    /// - `unlockButtonPlacement` sent the pause screen's Open button between five slots so the
    ///   hand could not learn one; the button does not move any more. See `PauseScreenView`.
    /// - `browserWatchEnabled` switched website blocking off wholesale. There is no switch: what
    ///   decides whether a website can be blocked is whether macOS lets the app read the address
    ///   bar, which is a permission rather than a preference. See `PermissionWatch`.
    private enum CodingKeys: String, CodingKey {
        case version, targets, groupSettings, groupOrder, switchedOffTogether
        case presets, categories, categorySeed
        case dayStartMinutes
        case showsMenuBarCountdown, expiryWarningSeconds, preventTimeChange, breakWaitSeconds
        case keepAliveSeed, settingsLock
    }

    /// Written by hand for one field: `expiryWarningSeconds` has to be written even when it is
    /// `nil`, because `nil` means "no warning" and an absent key means "the V1 default". The
    /// synthesised encoder omits nil optionals, which would turn the user's "None" back into a
    /// minute on the next launch.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(targets, forKey: .targets)
        try container.encode(groupSettings, forKey: .groupSettings)
        try container.encode(groupOrder, forKey: .groupOrder)
        try container.encode(switchedOffTogether, forKey: .switchedOffTogether)
        // Always written, empty list included: an absent key means "seed the three built-ins",
        // and somebody who deleted all three must not find them back on the next launch.
        try container.encode(presets, forKey: .presets)
        // Always written for the reason above, empty list included: an absent key means "seed the
        // six built-ins", and somebody who deleted all six must not find them back next launch.
        try container.encode(categories, forKey: .categories)
        try container.encode(categorySeed, forKey: .categorySeed)
        try container.encode(dayStartMinutes, forKey: .dayStartMinutes)
        try container.encode(showsMenuBarCountdown, forKey: .showsMenuBarCountdown)
        try container.encode(expiryWarningSeconds, forKey: .expiryWarningSeconds)
        try container.encode(preventTimeChange, forKey: .preventTimeChange)
        try container.encode(breakWaitSeconds, forKey: .breakWaitSeconds)
        try container.encode(keepAliveSeed, forKey: .keepAliveSeed)
        try container.encode(settingsLock, forKey: .settingsLock)
    }

    /// Hand-decoded for the same reason `GroupSettings` is: the newer fields are not `Optional`
    /// in the sense JSON means, and a `config.json` written before they existed must keep
    /// loading rather than be quarantined and replaced by an empty configuration.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        targets = try container.decode([Target].self, forKey: .targets)
        groupSettings = try container.decode([String: GroupSettings].self, forKey: .groupSettings)
        // A file written before the groups could be arranged has no order, which is the same
        // thing an emptied list says: the sidebar falls back to deriving one. Taken as written
        // rather than tidied here — what an order says about groups that have come and gone is
        // the reader's problem, and `ConfigBuilder.groupOrder(in:)` is where it is solved.
        groupOrder = try container.decodeIfPresent([String].self, forKey: .groupOrder) ?? []
        // A file written before the switch existed has nothing off from it, which is the same
        // thing an empty list says. Taken as written for the reason the order above is: what a
        // remembered id says about a group that has come or gone is the reader's problem, and
        // `AllGroupsSwitch` is where it is solved.
        switchedOffTogether =
            try container.decodeIfPresent([String].self, forKey: .switchedOffTogether) ?? []
        // A file written before presets were the user's own is seeded with the three the enum
        // used to name, which is what its groups have just been migrated onto.
        presets = Config.presetsWithoutWindows(
            try container.decodeIfPresent([NamedPreset].self, forKey: .presets)
                ?? NamedPreset.builtIns
        )
        // And a file written before the categories were the user's own is seeded with the six the
        // code used to hold. Their ids are the ids its groups already carry, so a group that ticked
        // "social" goes on blocking exactly what it blocked before — see `DistractionCategory
        // .builtIns`. Nothing about a group is rewritten by this.
        //
        // An absent `categories` key is round zero: nothing has been offered yet. A file that has
        // the key but no `categorySeed` was written by a build that knew the first round only, so
        // it is round one and the rounds after it are still owed. See `Config.categorySeed`.
        let stored = try container.decodeIfPresent([DistractionCategory].self, forKey: .categories)
        let offered = try container.decodeIfPresent(Int.self, forKey: .categorySeed)
            ?? (stored == nil ? 0 : 1)
        categories = Config.seeding(from: offered, into: stored ?? [])
        categorySeed = Config.currentCategorySeed
        dayStartMinutes = try container.decodeIfPresent(Int.self, forKey: .dayStartMinutes)
            ?? EngineState.defaultDayStartMinutes
        showsMenuBarCountdown =
            try container.decodeIfPresent(Bool.self, forKey: .showsMenuBarCountdown) ?? true
        // `null` and "no such key" are two different answers here, so the key is asked for
        // rather than the value: written null is the user's "None", absent is a V1 file.
        expiryWarningSeconds = container.contains(.expiryWarningSeconds)
            ? try container.decodeIfPresent(Int.self, forKey: .expiryWarningSeconds)
            : Config.defaultExpiryWarningSeconds
        preventTimeChange =
            try container.decodeIfPresent(Bool.self, forKey: .preventTimeChange) ?? true
        // A file written before the wait was a number waits the thirty seconds it always did.
        breakWaitSeconds = try container.decodeIfPresent(Int.self, forKey: .breakWaitSeconds)
            ?? Config.defaultBreakWaitSeconds
        // An absent key is round zero: a file older than the seed is offered the round once.
        keepAliveSeed = try container.decodeIfPresent(Int.self, forKey: .keepAliveSeed) ?? 0
        // A file written before the lock existed has neither half of it switched on, which is
        // also what a fresh install gets: this is a decision the user makes deliberately or
        // not at all.
        settingsLock =
            try container.decodeIfPresent(SettingsLock.self, forKey: .settingsLock) ?? SettingsLock()
    }

    /// The seed rounds this file has not been offered yet, appended to what it already carries.
    ///
    /// Appended rather than merged by id: what is present is the user's, and a category they
    /// renamed, emptied or deleted is not a gap to be filled. Only rounds beyond `offered` are
    /// added, and `categorySeed` is written back at the current round, so each round reaches a
    /// given file exactly once and never again.
    private static func seeding(
        from offered: Int, into existing: [DistractionCategory]
    ) -> [DistractionCategory] {
        existing + DistractionCategory.seedRounds.dropFirst(offered).flatMap { $0 }
    }

    /// Every preset with the week taken out of its `settings`, which is where a preset's week has
    /// never belonged and where an earlier build put one.
    ///
    /// A preset's opinion about the week is `NamedPreset.timeWindows`, which has three states and
    /// is the only thing `settings(forPreset:current:)` reads. `settings.timeWindows` is the
    /// group's own list, and a preset carrying one there hands out nothing and means nothing.
    /// Earlier builds disagreed: the seeded Strict carried a Monday–Friday 09:00–17:00 block, and
    /// applying a preset replaced the group's windows with it, so picking one discarded whatever
    /// the user had drawn. Both are fixed, which leaves that window sitting in the `config.json`
    /// of anybody who ran those builds — never handed out, but written back on every save and
    /// visible to anybody who opens the file.
    ///
    /// A stripped week is **not** turned into an opinion. Those presets decode with `timeWindows`
    /// absent, which is `nil`, which is "says nothing" — so an upgrade cannot start clearing or
    /// replacing a week that nobody asked it to touch.
    ///
    /// **Only the presets are touched, never a group.** A group's windows are the group's, and
    /// this migration exists precisely because they were once thrown away.
    private static func presetsWithoutWindows(_ presets: [NamedPreset]) -> [NamedPreset] {
        presets.map { preset in
            guard !preset.settings.timeWindows.isEmpty else { return preset }
            var stripped = preset
            stripped.settings.timeWindows = []
            return stripped
        }
    }

    /// Settings for one group, or `nil` when the group has none.
    ///
    /// `nil` is a real state, not an error: the engine treats a group without settings
    /// exactly like an unknown target — `Decision.notManaged`, nothing is blocked or
    /// counted. Callers must not substitute a default preset for a missing group.
    ///
    /// This is the *editor's* accessor: it answers for a switched-off group too, because the
    /// screen that edits one has to be able to read it. Everything that decides, counts or
    /// claims protection asks `activeSettings(forGroup:)` instead.
    public func settings(forGroup groupID: String) -> GroupSettings? {
        groupSettings[groupID]
    }

    /// Settings for one group, but only while the group is switched on.
    ///
    /// The engine's accessor. A group that is off is indistinguishable from a group that has no
    /// settings at all — `.notManaged` — which is exactly what "the group exists but does
    /// nothing when off" has to mean if the menu bar is not to claim protection that is off.
    public func activeSettings(forGroup groupID: String) -> GroupSettings? {
        guard let settings = groupSettings[groupID], settings.enabled else { return nil }
        return settings
    }

    /// The category with this id, or `nil` for one this configuration does not carry.
    ///
    /// Optional on purpose: `GroupSettings.categories` holds ids that came off disk, and a group
    /// naming a category the user has since deleted — or a `config.json` edited by hand — must not
    /// be able to take the configuration down. An unknown id carries nothing and is otherwise left
    /// alone, so a category put back under its old id picks its groups up again.
    public func category(id: String) -> DistractionCategory? {
        categories.first { $0.id == id }
    }

    /// Whether anything on the web is protected at all.
    ///
    /// A website target is the obvious case; a switched-on group whose advanced rules or live
    /// categories reach the browser is the other, and neither has a target to be found by.
    /// Missing them would mean a group that blocks half the web quietly losing the warning that
    /// says its browser side has gone silent.
    public var protectsAnyWebsite: Bool {
        let hasTarget = targets.contains {
            $0.kind == .domain && activeSettings(forGroup: $0.groupID) != nil
        }
        guard !hasTarget else { return true }
        return groupSettings.values.contains { settings in
            guard settings.enabled else { return false }
            if !settings.rules.isEmpty {
                return true
            }
            return !CategoryMembership.carriedDomains(settings, in: self).isEmpty
        }
    }

    /// Whether the configuration names nothing at all: no targets, and no group that blocks
    /// something without one.
    ///
    /// This is what a launch reads to decide whether to open the window by itself — see
    /// `AppState.hasNothingToProtect`. It used to be asked of a setup wizard that wrote `targets`
    /// and `groupSettings` whole, so anything it missed was something the wizard deleted; the
    /// wizard is gone and the question is only ever answered with a window now, but the reach of
    /// it is worth keeping right. It was once `targets.isEmpty`, which stopped being the same
    /// question the moment a group could hold a category and no targets; it then asked only about
    /// categories, which left out the three other ways a group reaches the web. See
    /// `GroupSettings.claimsWithoutTargets`.
    ///
    /// Switched-off groups count. A group that is off is not a group that is gone, and a window
    /// saying "no groups yet" over one would be the app forgetting what the user only paused.
    public var blocksNothing: Bool {
        targets.isEmpty && groupSettings.values.allSatisfy { !$0.claimsWithoutTargets }
    }

    /// What to call a group where no target of its own can name it: the name the user gave it,
    /// else the first thing in it, else `nil` and the caller decides.
    ///
    /// A group made of live categories has no targets at all, and a page it claims still has to
    /// arrive on the pause screen under a name. One accessor rather than one per screen, so the
    /// overlay and the browser cannot end up calling the same group two different things.
    public func groupDisplayName(forGroup groupID: String) -> String? {
        let given = groupSettings[groupID]?.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let given, !given.isEmpty { return given }
        return targets.first { $0.groupID == groupID }?.displayName
    }
}
