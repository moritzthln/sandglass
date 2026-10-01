import Foundation

/// What kind of thing a `Target` points at.
public enum TargetKind: String, Codable, Sendable { case app, domain }

/// A single blockable thing: a macOS app (bundle id) or a website (eTLD+1).
public struct Target: Codable, Hashable, Identifiable, Sendable {
    public var id: String        // "app:com.google.Chrome" | "domain:youtube.com"
    public var kind: TargetKind
    public var value: String     // bundle id (app) or eTLD+1 lowercase (domain)
    public var displayName: String
    public var groupID: String   // targets sharing groupID share budget/settings

    public init(kind: TargetKind, value: String, displayName: String, groupID: String? = nil) {
        let normalized = Target.normalize(value, kind: kind)
        self.kind = kind
        self.value = normalized
        self.displayName = displayName
        self.id = Target.makeID(kind: kind, value: normalized)
        self.groupID = groupID ?? self.id
    }

    /// `id` is never trusted from disk: a hand-edited config could name a target
    /// `youtube.com` while leaving a stale `domain:reddit.com` id behind, and every
    /// lookup in the engine goes through `id`. Re-deriving keeps the two in sync.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(TargetKind.self, forKey: .kind)
        let value = Target.normalize(try container.decode(String.self, forKey: .value), kind: kind)
        self.kind = kind
        self.value = value
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.id = Target.makeID(kind: kind, value: value)
        self.groupID = try container.decode(String.self, forKey: .groupID)
    }

    /// Hosts are case-insensitive; bundle ids are not.
    private static func normalize(_ value: String, kind: TargetKind) -> String {
        kind == .domain ? value.lowercased() : value
    }

    /// The id a target of this kind and value has, whether or not one exists.
    ///
    /// Public because two things that are not targets have to speak the same vocabulary: a
    /// bundle id read off the frontmost application, and a category's member list. A second
    /// spelling of `"app:" + bundleID` anywhere is how a lookup starts silently missing.
    public static func id(ofKind kind: TargetKind, value: String) -> String {
        makeID(kind: kind, value: normalize(value, kind: kind))
    }

    private static func makeID(kind: TargetKind, value: String) -> String {
        "\(kind.rawValue):\(value)"
    }
}

/// One advanced rule: a pattern, how it is matched, what it does, and whether it outranks the
/// rules that are not marked.
///
/// Three independent properties, deliberately. Priority is not a match type and it is not an
/// action — conflating them is what makes a rule list unreadable the moment there are four of
/// them. Rules sit *beside* the plain domain targets rather than replacing them: a target is
/// still the simple path, and is exactly `block · websiteOrText` on its own host.
///
/// See `RuleMatcher` for what each match type means and the order the rules are read in.
public struct Rule: Codable, Equatable, Sendable, Identifiable {

    public enum MatchType: String, Codable, Sendable {
        /// The pattern anywhere in the normalized URL. `shorts` catches every Shorts URL on
        /// every host; `youtube.com` catches the whole site.
        case websiteOrText
        /// The pattern *is* the page: host and path, and nothing under it.
        case specificPage
    }

    public enum Action: String, Codable, Sendable { case allow, block }

    public var id: String
    /// Stored normalized, by `RuleMatcher.normalize(pattern:matchType:)`. On the way in rather
    /// than at every comparison, so the stored value, what the rule list shows and what the
    /// matcher compares are one string — and a hand-edited `config.json` is normalized on load
    /// for the same reason `Target` re-derives its id there.
    public var pattern: String
    public var matchType: MatchType
    public var action: Action
    /// Whether this rule is read before every rule that is not marked.
    public var highPriority: Bool

    public init(
        id: String = UUID().uuidString,
        pattern: String,
        matchType: MatchType,
        action: Action,
        highPriority: Bool = false
    ) {
        self.id = id
        self.pattern = RuleMatcher.normalize(pattern: pattern, matchType: matchType)
        self.matchType = matchType
        self.action = action
        self.highPriority = highPriority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let matchType = try container.decode(MatchType.self, forKey: .matchType)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            pattern: try container.decode(String.self, forKey: .pattern),
            matchType: matchType,
            action: try container.decode(Action.self, forKey: .action),
            highPriority: try container.decodeIfPresent(Bool.self, forKey: .highPriority) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey { case id, pattern, matchType, action, highPriority }
}

/// Everything that governs how one group behaves.
public struct GroupSettings: Codable, Equatable, Sendable {
    /// Which of the user's presets this group was made from, or `nil` for values that came from
    /// nowhere in particular — which is what the screens call Custom.
    ///
    /// A **label, not the truth**: the values are. Every edit re-derives it, so a knob moved by
    /// hand detaches the group and a knob moved back attaches it again, and a preset that has
    /// since been deleted or edited leaves the group's own settings exactly as they were. See
    /// `ConfigBuilder.presetID(matching:in:)`, which is what every screen actually reads.
    public var presetID: String?
    public var pauseSeconds: Int
    public var opensPerDay: Int?          // nil = unlimited
    public var sessionMinutes: Int?       // nil = no relock (gentle)
    public var cooldownMinutes: Int
    public var escalationSeconds: Int     // 0 = off
    public var earnBackEnabled: Bool
    /// Recurring stretches of the week in which this group behaves differently: hard-blocked,
    /// deliberately free, or plainly budgeted. Empty is the common case and means the group
    /// behaves the same way all week.
    ///
    /// Replaces V1's single `schedule` and its separate always-block switch; both are migrated
    /// on load, in `init(from:)` below. See `TimeWindow` for what a window is and
    /// `RulesEngine` for what happens where two of them overlap.
    public var timeWindows: [TimeWindow]

    /// Minutes the group may be used for in one day; `nil` = no time limit.
    ///
    /// The day's other budget, beside `opensPerDay`, and the two may both be on: they count
    /// different things — opens how often you go in, minutes how long you stay — and neither
    /// sentence can be said with the other's number. Whichever runs out first blocks, under its
    /// own reason, so the user is always told which one they met. See `GroupBudget.line`, which
    /// reports every budget that is on, and `RulesEngine.grantedSessionSeconds`, which is what
    /// keeps an open from being sold for longer than the day has left.
    ///
    /// None of the three seeded presets sets it; a preset the user makes may, and a group that
    /// has one when its preset does not shows as Custom like any other knob out of place.
    ///
    /// Last in the argument list, and optional, so that a `GroupSettings(…)` written against
    /// V1 still compiles and every `config.json` a V1 build wrote still decodes.
    public var dailyMinutes: Int?

    /// What the user called this group, or `nil` while it is still named after its first target.
    ///
    /// It lives on the settings rather than on the targets because renaming a target is a
    /// different act: `ConfigBuilder` groups targets by display name, so renaming one to name
    /// the group would silently change where the *next* target lands.
    ///
    /// Not part of what a preset is — see `ConfigBuilder.presetID(matching:in:)`.
    public var name: String?

    /// Whether the group does anything at all.
    ///
    /// A group that is off exists, keeps its targets and its settings, and is `.notManaged`
    /// everywhere the engine looks: no pause screen, no budget, no window, no usage counted.
    /// The one thing it is not is deleted — which is the whole point of having it separate from
    /// the trash button next to it.
    public var enabled: Bool

    /// The group's advanced rules, in the order the user wrote them — which is the last
    /// tie-break the matcher uses, so the order is data rather than presentation.
    ///
    /// Empty is the common case and means the group is exactly its targets. Not part of what a
    /// preset is: rules say *what* is in scope, the way targets do, and a preset is the settings
    /// the group blocks whatever is in scope with.
    public var rules: [Rule]

    /// Lists this group is a live member of — ids from `Config.categories`.
    ///
    /// A **membership**, not a copy. The first version of the chips expanded a category into
    /// individual targets and forgot it had ever been a category, which meant a site added to
    /// the list in a later build never reached a group that had ticked it — the user had said
    /// "everything social" and got a snapshot of what social was that afternoon. Here the group
    /// carries the id and matching reads the list every time, so the list is the only thing that
    /// has to be maintained.
    ///
    /// Not part of what a preset is, exactly like `rules` and like the targets themselves: this
    /// says *what* is in scope, a preset is the settings it is blocked with.
    public var categories: Set<String>

    /// Members struck off a live category, as target ids — `domain:x.com`, `app:com.hnc.Discord`.
    ///
    /// The price of a live membership: without a way to say "Social, but not LinkedIn" the only
    /// way out of one entry is to give up the whole category and type nineteen sites by hand.
    /// An exception rather than an edit to the list, because the list is shared — editing it in
    /// Settings → Categories changes what *every* group that ticked it blocks, and "not here" is
    /// a different sentence from "not anywhere". And because a category that grows next month
    /// must not quietly hand back something that was deliberately removed; the one exception to
    /// that is an entry no list carries any more, which is pruned — see
    /// `ConfigBuilder.pruningDanglingExceptions(in:)`.
    public var categoryExceptions: Set<String>

    /// How long after the settings window opens this group's own settings are refused, in
    /// minutes. **0 is off**, and off is what every group has until somebody says otherwise.
    ///
    /// The group's half of the commitment device — see `GroupLocks` for what it holds and
    /// `Config.settingsLock` for the app-wide one. Where both are set, the longer of the two holds
    /// this group: a strict group stays hard to loosen while the rest of the app is freely
    /// editable, which is the whole point of having one per group.
    ///
    /// A number rather than an `Int?` because the control it belongs to is a stepper whose bottom
    /// is the off state, the shape `Config.expiryWarningSeconds` already has on screen. The span a
    /// control offers is `GroupSettings.lockRange`; a hand-edited value outside it is shown and
    /// stays reachable, like every other number on these screens.
    public var lockMinutes: Int

    /// The passcode this group's editor page is opened with, or `nil` when none is set.
    ///
    /// Its own code, salted and hashed exactly like the app-wide one — see `PasscodeHash`, which
    /// is also where what this does and does not defend against is written down. It gates the
    /// **whole page**: without it the group does not open, not even to read, which is the same
    /// answer `SettingsDoor` gives for the window as a whole.
    public var passcode: PasscodeHash?

    /// When the hour that clears this group's forgotten passcode was started, or `nil` when none
    /// is running.
    ///
    /// The escape, and it is not optional equipment: a group door with no way past a forgotten
    /// code is a reinstall, which is worse than no lock at all. A reading rather than a date, for
    /// the reason `SettingsLock.forgotStartedAt` is one — an hour that could be skipped by setting
    /// the clock forward would not be an hour.
    public var passcodeForgotStartedAt: ClockReading?

    /// Whether the app's two ways of unblocking everything at once leave this group alone.
    ///
    /// **Both of them**, and the name says so because it once did not: this was
    /// `ignoresEmergencyPass`, and while it was, "Unblock everything" opened the very groups the
    /// week's pass was refused. A group immune to the rationed door and not to the free one is
    /// immune until the next afternoon somebody takes the free one — so the pass and the break are
    /// one question here, asked once.
    ///
    /// **Off for every group until somebody says otherwise**, because these are the app's safety
    /// net and a net with holes in it by default is not one. On, neither a running pass nor a
    /// running break does anything whatever to this group: its blocks stand
    /// (`RulesEngine.decision(for:)`), and under a pass its door stays shut and its own wait goes
    /// on counting (`GroupLockGate`). Everything else either of them does is untouched — every
    /// other group unblocks, both run their full length, and the app-wide settings lock lifts under
    /// a pass as it always did.
    ///
    /// Which is worth saying plainly, because it is what the toggle is worth: **this keeps the
    /// unblocks out, and the group's own lock keeps the user out.** With no lock of its own, an
    /// immune group can simply be switched off during the pass hour like any other unlocked group —
    /// this app's whole model is that every setting is always editable unless a lock or a
    /// passcode is set. The two halves compose, which is why the toggle lives in the Lock card.
    ///
    /// **It is not a trap.** A passcode on an immune group still has the hour that clears it —
    /// per group, and not switchable off, unlike `SettingsLock.allowForgot`. See `GroupDoor
    /// .Recovery`, which has no third state for exactly this reason.
    public var ignoresAppWideUnblocks: Bool

    /// The day this group is hard-blocked until, as `DatedBlock` spells one, or `nil` for the
    /// ordinary case of no dated block at all.
    ///
    /// The third statement about when a group blocks, beside its week and its budgets, and the only
    /// one that happens **once**: everything in the group is shut until the named day begins, and
    /// then the week takes over again. A calendar day rather than an instant, because the end is
    /// defined as "when that day begins by `Config.dayStartMinutes`" — so moving the start of the
    /// day moves the end with it. See `DatedBlock`, which owns every reading of this string.
    ///
    /// **A day already past reads as absent**, everywhere: `RulesEngine.decision(for:)`, every
    /// screen, and `EditDirection`. The next save drops it, the way the retired keys are dropped.
    ///
    /// Not part of what a preset is, and not carried by a copy. A preset is a template and a
    /// duplicate is a fresh group; a one-shot commitment is neither — see
    /// `ConfigBuilder.settings(forPreset:current:)` and `duplicatingGroup`.
    ///
    /// **Normalized on the way in, at every way in**, which is why this is the one field with a
    /// store behind it: everything downstream compares these as *strings*, and "2026-8-5" sorts
    /// before "2026-08-24" while falling after it in the calendar. Doing it at the setter rather
    /// than in `init` alone is the difference between a rule and a habit — `Target` re-derives its
    /// id for the same reason, and its lookups fail the same way when one spelling gets past.
    public var blockedUntilDay: String? {
        get { storedBlockedUntilDay }
        set { storedBlockedUntilDay = DatedBlock.normalized(newValue) }
    }

    private var storedBlockedUntilDay: String?

    /// Whether this group blocks anything that `Config.targets` cannot name.
    ///
    /// Two ways in, and both reach the browser with nothing listed as a target: a live category
    /// and an advanced rule. `WebResolver` reads both off `groupSettings` and never looks at the
    /// targets to decide whether to.
    ///
    /// One property because three separate places ask this question and two of them used to ask a
    /// narrower one. `Config.blocksNothing` asked only about categories, so a group blocking
    /// `/shorts` read as a blank slate and setup — which writes `targets` and `groupSettings`
    /// whole — deleted it on the next launch; `EngineReadout.representativeGroups` asked the same
    /// narrow question, so the group had no budget row, no line in the popover, and "Nothing in it
    /// yet" on its own editor.
    ///
    /// An allow-only rule list counts too, and deliberately: it blocks nothing by itself, but
    /// over-counting here costs a row nobody minds and under-counting costs the group.
    public var claimsWithoutTargets: Bool {
        !categories.isEmpty || !rules.isEmpty
    }

    public init(
        presetID: String?,
        pauseSeconds: Int,
        opensPerDay: Int?,
        sessionMinutes: Int?,
        cooldownMinutes: Int,
        escalationSeconds: Int,
        earnBackEnabled: Bool,
        timeWindows: [TimeWindow] = [],
        dailyMinutes: Int? = nil,
        name: String? = nil,
        enabled: Bool = true,
        rules: [Rule] = [],
        categories: Set<String> = [],
        categoryExceptions: Set<String> = [],
        lockMinutes: Int = 0,
        passcode: PasscodeHash? = nil,
        passcodeForgotStartedAt: ClockReading? = nil,
        ignoresAppWideUnblocks: Bool = false,
        blockedUntilDay: String? = nil
    ) {
        self.presetID = presetID
        self.pauseSeconds = pauseSeconds
        self.opensPerDay = opensPerDay
        self.sessionMinutes = sessionMinutes
        self.cooldownMinutes = cooldownMinutes
        self.escalationSeconds = escalationSeconds
        self.earnBackEnabled = earnBackEnabled
        self.timeWindows = timeWindows
        self.dailyMinutes = dailyMinutes
        self.name = name
        self.enabled = enabled
        self.rules = rules
        self.categories = categories
        self.categoryExceptions = categoryExceptions
        self.lockMinutes = lockMinutes
        self.passcode = passcode
        self.passcodeForgotStartedAt = passcodeForgotStartedAt
        self.ignoresAppWideUnblocks = ignoresAppWideUnblocks
        self.blockedUntilDay = blockedUntilDay
    }

    private enum CodingKeys: String, CodingKey {
        case presetID, pauseSeconds, opensPerDay, sessionMinutes, cooldownMinutes
        case escalationSeconds, earnBackEnabled, timeWindows, dailyMinutes, name
        case enabled, rules
        case categories, categoryExceptions
        case lockMinutes, passcode, passcodeForgotStartedAt, ignoresAppWideUnblocks
        case blockedUntilDay
        /// Keys older files carry and this build no longer writes. `schedule`, `alwaysBlock` and
        /// `preset` are read on the way in — see `init(from:)`. The rest are not read at all and
        /// are listed only so the reason they are absent is written down beside the ones that
        /// are: `promptOverride` was the per-group pause question, and `zenScreen`, `zenAction`
        /// and `breathingSeconds` were the breathing, typing and arithmetic exercises. A pause
        /// screen counts `pauseSeconds` down and that is the whole of it, so a file carrying any
        /// of these loads with the key ignored rather than being refused.
        ///
        /// `whitelistMode` inverted a group: everything blocked unless a rule allowed it. A time
        /// window that permits says the same thing in a concept the app already has, and one
        /// statement with two spellings is the kind of thing that makes a blocker hard to trust.
        ///
        /// `adultBlocked` switched a hard-coded list of hosts on, at a priority below every rule.
        /// That is a category, and it is one now — see `DistractionCategory.adult`, which every
        /// existing file is offered on load. A group that had the switch on does not become a
        /// member of it: the category is offered, and ticking it is the user's to do.
        ///
        /// Both still load, both are walked past, and the next save drops them — the same
        /// retirement `unlockButtonPlacement` and `browserWatchEnabled` had on `Config`.
        ///
        /// `ignoresEmergencyPass` is the one retired key that is still **read**, because it is a
        /// rename rather than a removal: the field it fed is `ignoresAppWideUnblocks`, which now
        /// covers the break as well as the pass. A group the user had already opted out of the
        /// pass keeps its opt-out across the upgrade — silently losing it would hand back an escape
        /// nobody asked for, on a group chosen deliberately. See `init(from:)`, and the next save
        /// writes the new spelling and drops this one.
        case schedule, alwaysBlock, preset, promptOverride
        case zenScreen, zenAction, breathingSeconds
        case whitelistMode, adultBlocked, ignoresEmergencyPass
    }

    /// Written by hand so that `timeWindows` is absent rather than `[]` on the groups that have
    /// none — which is most of them — and so the two V1 keys above are never written back.
    /// A file this build saves is in the new shape; a file it reads may be in either.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Absent rather than `null` on a Custom group, for the reason `timeWindows` is absent on
        // a group that has none: a key that says nothing is a line nobody reading the file needs.
        try container.encodeIfPresent(presetID, forKey: .presetID)
        try container.encode(pauseSeconds, forKey: .pauseSeconds)
        try container.encodeIfPresent(opensPerDay, forKey: .opensPerDay)
        try container.encodeIfPresent(sessionMinutes, forKey: .sessionMinutes)
        try container.encode(cooldownMinutes, forKey: .cooldownMinutes)
        try container.encode(escalationSeconds, forKey: .escalationSeconds)
        try container.encode(earnBackEnabled, forKey: .earnBackEnabled)
        if !timeWindows.isEmpty { try container.encode(timeWindows, forKey: .timeWindows) }
        try container.encodeIfPresent(dailyMinutes, forKey: .dailyMinutes)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        // The three rule fields, written only when they say something. Most groups have no rules and
        // neither switch on, and a config.json full of `"rules" : []` is a document that got
        // longer without saying more.
        if !rules.isEmpty { try container.encode(rules, forKey: .rules) }
        // Sorted rather than written as a set, and only when there is one. `Set` has no order of
        // its own, so encoding it directly would reshuffle these two arrays on every save — a
        // `config.json` whose diff is noise is one nobody reads.
        if !categories.isEmpty { try container.encode(categories.sorted(), forKey: .categories) }
        if !categoryExceptions.isEmpty {
            try container.encode(categoryExceptions.sorted(), forKey: .categoryExceptions)
        }
        // All three written only when they say something, like `rules` and `categories` above:
        // almost no group carries a lock, and a `config.json` with `"lockMinutes" : 0` on every
        // group and every preset is a document that got longer without saying more. A group that
        // does carry one writes its keys on the next save.
        if lockMinutes > 0 { try container.encode(lockMinutes, forKey: .lockMinutes) }
        try container.encodeIfPresent(passcode, forKey: .passcode)
        try container.encodeIfPresent(passcodeForgotStartedAt, forKey: .passcodeForgotStartedAt)
        // The same rule as the three above, and the same reason: off is what every group has, so a
        // key saying so on every one of them is a document that got longer without saying more.
        if ignoresAppWideUnblocks {
            try container.encode(true, forKey: .ignoresAppWideUnblocks)
        }
        // Written only where there is one, like everything above it. Whether the day is still ahead
        // is not asked here and cannot be: an encoder has no clock. A day already past is taken out
        // one level up, where there is one — `ConfigBuilder.droppingPastBlocks(in:onDay:)`, on the
        // way to disk — so the key that reaches this line is one worth writing.
        try container.encodeIfPresent(blockedUntilDay, forKey: .blockedUntilDay)
    }

    /// Decoded by hand for the fields that are not `Optional`: a `config.json` written before
    /// they existed has no such key, and the synthesised decoder would refuse the whole
    /// document — which `Store` reads as corruption and renames to `.bad`. See the
    /// schema-evolution rule in `SandglassJSON`.
    ///
    /// This is also where V1's two blocking shapes become windows. It is done here rather than
    /// in `Store` so that *every* path that decodes a group gets it, and because this is the
    /// only place that can still see the old keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
            ?? GroupSettings.migratedPresetID(from: container)
        pauseSeconds = try container.decode(Int.self, forKey: .pauseSeconds)
        opensPerDay = try container.decodeIfPresent(Int.self, forKey: .opensPerDay)
        sessionMinutes = try container.decodeIfPresent(Int.self, forKey: .sessionMinutes)
        cooldownMinutes = try container.decode(Int.self, forKey: .cooldownMinutes)
        escalationSeconds = try container.decode(Int.self, forKey: .escalationSeconds)
        earnBackEnabled = try container.decode(Bool.self, forKey: .earnBackEnabled)
        // Through `DecodedTimeWindow`, which drops the windows whose kind this build no longer
        // has rather than taking the whole document down with them. See its own note.
        timeWindows = try container.decodeIfPresent([DecodedTimeWindow].self, forKey: .timeWindows)?
            .compactMap(\.window)
            ?? GroupSettings.migratedWindows(from: container)
        dailyMinutes = try container.decodeIfPresent(Int.self, forKey: .dailyMinutes)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        // A group written before this field existed was, by definition, doing its job.
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        // A group written before live categories existed is in no category. That is also what
        // makes the upgrade silent for the groups the old chips expanded: their sites are plain
        // targets and stay plain targets. Nothing rewrites them — a hand-picked list and an
        // expanded one are indistinguishable on disk, and guessing wrong would edit a group the
        // user built.
        categories = try container.decodeIfPresent(Set<String>.self, forKey: .categories) ?? []
        categoryExceptions =
            try container.decodeIfPresent(Set<String>.self, forKey: .categoryExceptions) ?? []
        // A group written before it could carry a lock of its own carries none, which is also what
        // a fresh group gets: this is a decision the user makes deliberately or not at all.
        lockMinutes = try container.decodeIfPresent(Int.self, forKey: .lockMinutes) ?? 0
        passcode = try container.decodeIfPresent(PasscodeHash.self, forKey: .passcode)
        passcodeForgotStartedAt =
            try container.decodeIfPresent(ClockReading.self, forKey: .passcodeForgotStartedAt)
        // Absent means the app's ways out reach this group, which is what every file written before
        // the toggle existed meant and what a fresh group gets: the net is whole until somebody
        // cuts a hole in it deliberately.
        //
        // `ignoresEmergencyPass` is the key this was written under while it held the pass alone.
        // Read as the same answer rather than migrated: an opt-out is a deliberate choice about one
        // group, and a build that quietly handed the escape back would undo it on the first launch
        // after an upgrade. It widens on the way in — a group that shut the pass out shuts the
        // break out too — which is the correction, not a change of mind about that group.
        ignoresAppWideUnblocks =
            try container.decodeIfPresent(Bool.self, forKey: .ignoresAppWideUnblocks)
            ?? container.decodeIfPresent(Bool.self, forKey: .ignoresEmergencyPass)
            ?? false
        // Absent means no dated block, which is what every file written before the control existed
        // meant and what a fresh group gets. Anything that is not a day this build can read is the
        // same answer rather than a decode failure: a `config.json` `Store` cannot read is renamed
        // to `.bad` and costs the user every group they have, over one malformed string. The
        // setter above is what turns it down; this only has to hand it over.
        blockedUntilDay = try container.decodeIfPresent(String.self, forKey: .blockedUntilDay)
    }

    /// The old four-case `preset` enum, as an id into the presets the configuration now carries.
    ///
    /// `gentle`, `standard` and `strict` name the three seeded built-ins, which hold exactly the
    /// values those three cases meant — so a migrated group points at a preset it genuinely
    /// matches. `custom` was never a preset at all, only the name for values that matched none of
    /// them, so it becomes no id. A name this build has never heard of becomes no id either,
    /// rather than taking the whole document down.
    ///
    /// A group whose values have since drifted from the preset it names shows as Custom anyway:
    /// the label is re-derived from the values everywhere it is read. That is deliberate, and it
    /// is the one visible edge of this migration — a V1-era Strict group whose window is not
    /// Monday–Friday 09:00–17:00 keeps every setting it had and loses only the word "Strict".
    private static func migratedPresetID(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard let legacy = try container.decodeIfPresent(String.self, forKey: .preset) else {
            return nil
        }
        return NamedPreset.id(forLegacyPreset: legacy)
    }

    /// V1's `schedule` and `alwaysBlock`, as windows.
    ///
    /// A schedule was always a hard block, so it becomes one `.strictBlock` window with the
    /// same days and times. Always-block becomes a `.strictBlock` window over all seven days,
    /// 00:00–24:00 — which is the honest expression of it, and the reason `BlockReason` no
    /// longer needs a case that cannot name when it ends. A group that had both keeps both.
    private static func migratedWindows(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [TimeWindow] {
        var windows: [TimeWindow] = []
        if let legacy = try container.decodeIfPresent(LegacySchedule.self, forKey: .schedule) {
            windows.append(TimeWindow(
                kind: .strictBlock,
                weekdays: legacy.weekdays,
                startMinutes: legacy.startMinutes,
                endMinutes: legacy.endMinutes
            ))
        }
        if try container.decodeIfPresent(Bool.self, forKey: .alwaysBlock) == true {
            windows.append(TimeWindow.make(.allDay, kind: .strictBlock))
        }
        return windows
    }

    /// V1's `BlockSchedule`, kept only long enough to be read once and turned into a window.
    private struct LegacySchedule: Decodable {
        let weekdays: Set<Int>
        let startMinutes: Int
        let endMinutes: Int
    }

    // The values behind the three presets a fresh install is seeded with. They are here rather
    // than inline in `NamedPreset.builtIns` because the engine's own fixtures and half the suite
    // are written against them, and because "what Standard means" is a fact about settings.

    public static let gentle = GroupSettings(
        presetID: NamedPreset.gentleID, pauseSeconds: 10, opensPerDay: nil, sessionMinutes: nil,
        cooldownMinutes: 0, escalationSeconds: 0, earnBackEnabled: false
    )

    public static let standard = GroupSettings(
        presetID: NamedPreset.standardID, pauseSeconds: 10, opensPerDay: 5, sessionMinutes: 5,
        cooldownMinutes: 10, escalationSeconds: 5, earnBackEnabled: true
    )

    /// Strictness said in knobs, not in hours.
    ///
    /// It used to be Standard's values plus a Monday–Friday 09:00–17:00 block, which made the
    /// week part of what a preset was — and therefore something picking a preset overwrote. A
    /// group's windows are its own (see `ConfigBuilder.settings(forPreset:current:)`), so Strict
    /// has to be *strict* on its own terms: a wait three times as long, two opens instead of
    /// five, an hour between them, escalation that bites, and no earning any of it back.
    public static let strict = GroupSettings(
        presetID: NamedPreset.strictID, pauseSeconds: 30, opensPerDay: 2, sessionMinutes: 5,
        cooldownMinutes: 60, escalationSeconds: 15, earnBackEnabled: false
    )

}
