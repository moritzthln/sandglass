import SandglassCore
import Foundation

/// One group as the settings and stats screens show it: what it is called, what is in it, and
/// how it behaves. `settings` is optional because a group can exist in the targets and be
/// missing from `groupSettings` — the engine calls that `notManaged`, and a screen that
/// invented a preset for it would claim protection that is not there.
public struct ConfigGroup: Identifiable, Equatable {
    public let id: String            // groupID
    public let name: String
    public let targets: [Target]
    public let settings: GroupSettings?
    /// The categories this group is a live member of, resolved against the configuration's own
    /// list and in the order that list offers them.
    ///
    /// Resolved here rather than by every screen that needs it, because the lists are the user's
    /// now: a screen holding an id and no way back to the document would have nothing to look it
    /// up in. Ids naming a category that has been deleted are simply absent — see
    /// `Config.category(id:)`.
    public let categories: [DistractionCategory]

    public init(
        id: String, name: String, targets: [Target], settings: GroupSettings?,
        categories: [DistractionCategory] = []
    ) {
        self.id = id
        self.name = name
        self.targets = targets
        self.settings = settings
        self.categories = categories
    }

    /// Whether the engine acts on this group at all: it needs settings, and they have to be
    /// switched on. Sugar over the two conditions, because every screen asks both.
    public var isActive: Bool { settings?.enabled == true }

    public var appTargets: [Target] { targets.filter { $0.kind == .app } }
    public var siteTargets: [Target] { targets.filter { $0.kind == .domain } }

    /// Websites the group blocks: the ones its targets name, plus the ones its live categories
    /// carry. A group made of categories has no targets at all, and a card counting only those
    /// would report it empty while it was blocking twenty sites.
    public var siteCount: Int {
        guard let settings else { return siteTargets.count }
        let carried = categories
            .flatMap { CategoryMembership.members(of: $0, in: settings).domains }
        return siteTargets.count + carried.count
    }

    /// Apps the group blocks, as far as that can be known without asking this Mac what is
    /// installed — so, the ones its targets name. A category's apps are left out on purpose;
    /// see `CategoryMembership.carriedDomains` for why undercounting is the safe direction.
    public var appCount: Int { appTargets.count }
}

/// Every rule for turning what somebody picked into a `Config`, and back.
///
/// It lives here rather than in the views for one reason: a configuration built wrong is not
/// a cosmetic bug. Two targets that should share a budget and do not give the user twice the
/// budget they chose; a duplicate target is a document `Store` refuses to save at all; a
/// preset marker that stops matching its own values makes the settings screen lie about what
/// is running. All of that is arithmetic on values, and all of it is checked in the suite.
public enum ConfigBuilder {

    // MARK: - Building

    /// Adds one target to a named group, whatever it is called.
    ///
    /// The only way to add one. There used to be a second — "put it wherever a target of the same
    /// display name already is" — which existed for a setup wizard that guessed at groups from
    /// names, and a rule that guesses is the wrong thing to reach for from the editor: that screen
    /// is about *one* group, so a site added there belongs there and nowhere else. A target that
    /// already exists anywhere in the configuration changes nothing, because `Store` refuses a
    /// document with two targets of one id.
    public static func adding(
        _ target: Target, toGroup groupID: String, in config: Config
    ) -> Config {
        guard !config.targets.contains(where: { $0.id == target.id }) else { return config }
        var added = target
        added.groupID = groupID
        var updated = config
        updated.targets.append(added)
        // A group that only ever existed as a row of settings now has something in it; one with
        // no settings is left alone, because inventing a preset would claim protection.
        return updated
    }

    /// Ticks or unticks one category on a group.
    ///
    /// Here rather than in the chip's binding because it is a decision rather than a gesture:
    /// **unticking drops that category's exceptions with it**, so re-ticking gives back the whole
    /// list rather than the list minus five things nobody can now see they removed. Remembering
    /// them reads as helpful right up until the user cannot work out why a site the category
    /// obviously carries is not being blocked here.
    ///
    /// Only that category's exceptions go: a group can be a member of several, and unticking
    /// Social must not hand Messaging back an app that was struck off it.
    public static func toggle(
        _ category: DistractionCategory, on: Bool, in settings: inout GroupSettings
    ) {
        guard on else {
            settings.categories.remove(category.id)
            settings.categoryExceptions.subtract(category.targetIDs)
            return
        }
        settings.categories.insert(category.id)
    }

    /// Removes one target. The group stays, even when that was its last one.
    ///
    /// It used to go with it, back when a group only existed as a property of its targets and
    /// an empty one would have been invisible. The sidebar changed that: a group is a row the
    /// user made, with a name and a trash button, and clearing its list to retype it must not
    /// delete the thing being edited. Deleting is `removingGroup(_:from:)`.
    public static func removing(targetID: String, from config: Config) -> Config {
        guard config.targets.contains(where: { $0.id == targetID }) else { return config }
        var updated = config
        updated.targets.removeAll { $0.id == targetID }
        return updated
    }

    /// Deletes a group outright: its settings and everything in it.
    ///
    /// **Both lists of group ids are pruned**, and by one policy rather than two. `Config` keeps
    /// two of them — `switchedOffTogether`, which the all-at-once switch has to put back, and
    /// `groupOrder`, which the sidebar arranges by — and both are read as a preference rather than
    /// as the truth, so both walk past an id naming nothing and neither needs this to be correct.
    /// It is tidiness, and tidiness that applies to one list applies to the other: a list that
    /// accumulated the names of deleted groups would sit in `config.json` for ever, meaning nothing
    /// to anybody who opened it. Deleting seven groups over a month should not leave seven ghosts
    /// in a file the user is invited to read.
    ///
    /// Nothing on screen moves either way. `ConfigBuilder.groupOrder(in:)` already skips an id it
    /// cannot find, and `AllGroupsSwitch` already skips one too — which is what keeps a
    /// hand-edited file safe, and what this deliberately does not replace.
    public static func removingGroup(_ groupID: String, from config: Config) -> Config {
        var updated = config
        updated.targets.removeAll { $0.groupID == groupID }
        updated.groupSettings[groupID] = nil
        updated.switchedOffTogether.removeAll { $0 == groupID }
        updated.groupOrder.removeAll { $0 == groupID }
        return updated
    }

    /// Creates an empty group with a name of its own, and answers with its id.
    ///
    /// Empty is a real state here: a group is made first and filled afterwards, which is the
    /// order the editor works in. It blocks nothing until something is put in it.
    public static func addingGroup(
        named name: String, to config: Config, settings: GroupSettings = .standard
    ) -> (config: Config, groupID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = freeGroupID(basedOn: trimmed, in: config)
        var created = settings
        created.name = trimmed.isEmpty ? nil : trimmed
        var updated = config
        updated.groupSettings[groupID] = created
        return (updated, groupID)
    }

    /// Duplicates a group: everything about how it blocks, and nothing that is in it.
    ///
    /// The knobs, the week, the advanced rules, the category ticks with their exceptions and the
    /// preset marker all come across, under the name "<name> copy". **The targets do not, and
    /// cannot.** A target belongs to exactly one group — `Store` refuses a document holding two of
    /// one id, and every lookup in the engine resolves by taking the first match — so a copy
    /// carrying them would be either a document that will not save or a second entry nothing can
    /// see. The copy lands empty, and the editor's two add buttons are the obvious next step.
    ///
    /// **Every id it carries is minted fresh**, which is the failure this is written against: a
    /// window or a rule sharing an id with the source is one edit away from changing both at once,
    /// and nothing downstream would catch it — the editor keys its rows by those ids, and `Store`
    /// compares window ids *within* one group and never between two. The values are carried
    /// untouched rather than rebuilt through `Rule.init`, which normalises the pattern a stored
    /// rule has already been through.
    ///
    /// **A block rule copies as a block rule**, claiming its pattern from the copy too, and a
    /// ticked category copies as a tick. Two groups claiming one URL through rules is already
    /// legal and resolves deterministically, and so is two groups ticking one list; the copy is
    /// expected to be re-targeted, so both are a passing state rather than something to strip out
    /// or warn about.
    ///
    /// It never joins `switchedOffTogether`: that list is what the all-at-once switch turned off,
    /// and nothing turned this off — it was made this second. A copy of a group that *is* off is
    /// off, because that is what the group it came from is.
    ///
    /// `nil` for a group with no settings behind it, which is the one the sidebar calls "No
    /// settings". There is nothing to copy: everything a copy carries lives on `GroupSettings`,
    /// including the name — such a group is called after its first target — and targets do not
    /// travel. What would come out is a group with no settings, no targets and no name, which
    /// `groups(in:)` does not list at all. The editor does not offer the button there, for the
    /// reason it offers neither the pencil nor the preset picker beside it.
    public static func duplicatingGroup(
        _ groupID: String, in config: Config
    ) -> (config: Config, groupID: String)? {
        guard let settings = config.settings(forGroup: groupID) else { return nil }
        let targets = config.targets.filter { $0.groupID == groupID }
        let copyName = freeGroupName(
            copying: name(ofGroup: groupID, targets: targets, in: config), in: config
        )
        let copyID = freeGroupID(basedOn: copyName, in: config)
        var updated = config
        updated.groupSettings[copyID] = reidentified(settings, named: copyName)
        updated.groupOrder = order(placing: copyID, after: groupID, in: config)
        return (updated, copyID)
    }

    /// One group's settings with a name of its own and a fresh id on everything that carries one.
    private static func reidentified(
        _ settings: GroupSettings, named name: String
    ) -> GroupSettings {
        var copied = settings
        copied.name = name
        // **The lock does not copy.** It is a promise about one group, made by choosing a code
        // for it; the copy is a new group with nothing in it yet, and giving it a door somebody
        // has not chosen — behind a code they would have to remember belongs to two groups —
        // would be the app deciding a commitment on their behalf. The original keeps its own.
        copied.lockMinutes = 0
        copied.passcode = nil
        copied.passcodeForgotStartedAt = nil
        // **Nor does the dated block**, and for the same reason: it is a one-shot promise about one
        // group, made once and for a reason. A copy is a new group with nothing in it yet, and
        // handing it somebody else's week off — which a lock could then hold them to — would be the
        // app making a commitment on their behalf. The original keeps its own.
        copied.blockedUntilDay = nil
        copied.timeWindows = settings.timeWindows.map {
            var window = $0
            window.id = UUID().uuidString
            return window
        }
        copied.rules = settings.rules.map {
            var rule = $0
            rule.id = UUID().uuidString
            return rule
        }
        return copied
    }

    /// `"<name> copy"`, and `"<name> copy 2"` when there is one already.
    ///
    /// Compared against what the groups are **shown** as rather than against `GroupSettings.name`,
    /// because half of them have no stored name at all and are called after the first thing in
    /// them: two sidebar cards both reading "YouTube copy" is the collision worth avoiding, and it
    /// is a collision on screen. Ids are separate and made unique on their own — see
    /// `freeGroupID(basedOn:in:)`.
    ///
    /// The same shape as `NamedPreset.freeName(basedOn:among:)` and
    /// `DistractionCategory.freeName(basedOn:among:)`, deliberately: three lists the user reads,
    /// one rule for what a second entry of the same name is called.
    private static func freeGroupName(copying name: String, in config: Config) -> String {
        let base = "\(name) copy".trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(groups(in: config).map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// The healed order with one group put directly behind another, so a copy is the next card
    /// down rather than something to hunt for at the bottom of a long sidebar.
    ///
    /// The **whole** healed order is what is written back, for the reason `movingGroup` writes it:
    /// a file that had no order recorded gets the one it was already being shown in, and nothing
    /// on screen moves but the new card. A source the order cannot find is impossible — it has
    /// settings, so `groupOrder(in:)` lists it — and the end of the list is the answer that cannot
    /// lose the copy if it ever happens.
    private static func order(
        placing copyID: String, after groupID: String, in config: Config
    ) -> [String] {
        var order = groupOrder(in: config)
        guard let index = order.firstIndex(of: groupID) else { return order + [copyID] }
        order.insert(copyID, at: order.index(after: index))
        return order
    }

    /// `grp:<slug>`, with a counter appended until nothing else answers to it. Readable in
    /// `config.json`, which a random id would not be, and stable once it exists — the id is
    /// what every counter in `state.json` is keyed by, so renaming must never change it.
    private static func freeGroupID(basedOn name: String, in config: Config) -> String {
        let slug = slugify(name)
        let taken = Set(config.groupSettings.keys).union(config.targets.map(\.groupID))
        var candidate = "grp:\(slug)"
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "grp:\(slug)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func slugify(_ name: String) -> String {
        let allowed = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let slug = String(allowed).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "group" : slug
    }

    // MARK: - Reading

    /// The configuration's groups, in the order the user arranged them, one entry each.
    public static func groups(in config: Config) -> [ConfigGroup] {
        let members = Dictionary(grouping: config.targets, by: \.groupID)
        return groupOrder(in: config).map { groupID in
            let targets = members[groupID] ?? []
            let settings = config.settings(forGroup: groupID)
            return ConfigGroup(
                id: groupID,
                name: name(ofGroup: groupID, targets: targets, in: config),
                targets: targets,
                settings: settings,
                categories: categories(of: settings, in: config)
            )
        }
    }

    /// Every group this configuration holds, once each, in the order to show them in.
    ///
    /// `Config.groupOrder` is the user's answer and it comes first — but it is a preference
    /// rather than an index, and nothing keeps it in step with the groups themselves. So it is
    /// **read against what exists** and the two disagreements are given the only answers that
    /// cannot lose a group:
    ///
    /// - an id naming a group that is not there is walked past — a group deleted, or a line typed
    ///   into `config.json` by hand;
    /// - a group the order does not name is listed at the end — one made by a build that never
    ///   wrote the key, or a save interrupted halfway through.
    ///
    /// An id listed twice is shown once, for the same reason: whatever the file says, the sidebar
    /// has to be a list of the groups, exactly.
    ///
    /// What the end is ordered by is the rule this replaced, and it is kept rather than being an
    /// arbitrary tail: a group sits where the first thing in it sits, and one holding nothing at
    /// all comes after those, by id. It is a poor order — adding a target moves a group under
    /// somebody's hand, which is why there is a stored one now — but it is stable between
    /// launches and it is what an unarranged sidebar has always looked like.
    public static func groupOrder(in config: Config) -> [String] {
        let derived = derivedGroupOrder(in: config)
        let known = Set(derived)
        var seen: Set<String> = []
        let arranged = config.groupOrder.filter { known.contains($0) && seen.insert($0).inserted }
        return arranged + derived.filter { !seen.contains($0) }
    }

    /// The order storage puts the groups in, which is what the sidebar showed before it had one
    /// of its own: each group where its first target sits, then the groups with no targets at
    /// all, by id.
    private static func derivedGroupOrder(in config: Config) -> [String] {
        var order: [String] = []
        var withTargets: Set<String> = []
        for target in config.targets where withTargets.insert(target.groupID).inserted {
            order.append(target.groupID)
        }
        return order + config.groupSettings.keys.filter { !withTargets.contains($0) }.sorted()
    }

    /// Moves one group to where another one is — a card picked up and dropped onto a row.
    ///
    /// The dropped card **takes that row's place** and the row it landed on moves out of the way,
    /// which is what makes dropping between two groups possible at all: every position in the
    /// list is some row, so there is no gap that can only be reached from an end.
    ///
    /// What is written back is the whole healed order rather than the stored one with two entries
    /// swapped, so one drag also tidies whatever the reader was walking past — a first drag on a
    /// file that had no order writes the order it was already showing, and nothing on screen
    /// moves but the card.
    ///
    /// Either id being unknown, or the two being the same, changes nothing: a drop on the card
    /// that was picked up is a drop that means nothing, and the caller is a gesture rather than a
    /// decision.
    public static func movingGroup(
        _ groupID: String, onto other: String, in config: Config
    ) -> Config {
        var order = groupOrder(in: config)
        guard let from = order.firstIndex(of: groupID),
              let to = order.firstIndex(of: other), from != to else { return config }
        order.remove(at: from)
        // `to` is where the row being landed on started, and it is the right insertion point in
        // both directions: dragging down, everything above it has already shifted up by the
        // removal, so this lands just after it; dragging up, nothing below it moved, so this
        // lands just before it. Either way the card ends up in the slot it was dropped on.
        order.insert(groupID, at: to)
        var updated = config
        updated.groupOrder = order
        return updated
    }

    /// The categories a group is a member of, in the order the configuration offers them — so a
    /// list of them does not reshuffle itself between redraws, which a `Set` would.
    public static func categories(
        of settings: GroupSettings?, in config: Config
    ) -> [DistractionCategory] {
        guard let settings else { return [] }
        return config.categories.filter { settings.categories.contains($0.id) }
    }

    /// What to call a group: the name the user gave it, else the target they picked first —
    /// the members of a group share a name anyway — and the raw id only when there is neither.
    public static func name(
        ofGroup groupID: String, targets: [Target], in config: Config
    ) -> String {
        let given = config.settings(forGroup: groupID)?.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let given, !given.isEmpty { return given }
        return targets.first?.displayName ?? groupID
    }

    /// Which of the user's presets a set of values actually is, or `nil` for Custom.
    ///
    /// The marker in `GroupSettings.presetID` is a label, not the truth — the values are. This
    /// re-reads it after every edit, so a knob moved by hand shows as "Custom" and a knob moved
    /// back shows as the preset it matches again. Without it the screen would keep saying
    /// "Standard" over settings that are nothing of the kind — and a preset the user has since
    /// edited or deleted would leave every group it touched claiming a name that means something
    /// else now, or nothing at all.
    ///
    /// The stored id is tried first so that two presets holding the same values do not swap
    /// places under the user; failing that, any preset those values match is the honest answer.
    ///
    /// Some fields are held out of the comparison because a preset does not have an opinion
    /// about them: what the group is called, whether it is switched on, its advanced rules and
    /// its live categories. Naming a group "Social" must not make it Custom, and neither must
    /// adding a rule or ticking a chip: they say *what* is in scope, the way targets do (which
    /// are not in `GroupSettings` at all), while a preset is the settings the group runs against
    /// whatever is in it. `dailyMinutes` *is* in: it is a budget, which is friction.
    ///
    /// The **week** is the one field asked about conditionally, and `weekAgrees(_:with:)` is
    /// where that is written down.
    public static func presetID(
        matching settings: GroupSettings, in presets: [NamedPreset]
    ) -> String? {
        let probe = presetProbe(settings)
        func matches(_ preset: NamedPreset) -> Bool {
            presetProbe(preset.settings) == probe && weekAgrees(settings, with: preset)
        }
        if let stored = settings.presetID,
           let named = presets.first(where: { $0.id == stored }), matches(named) {
            return stored
        }
        return presets.first(where: matches)?.id
    }

    /// Whether the group's week is the one the preset claims — and `true` whenever it claims
    /// nothing at all, which is the common case and the whole reason `NamedPreset.timeWindows`
    /// is optional.
    ///
    /// Drawing a window must not knock a group off a preset that never said anything about the
    /// week; it must knock it off one that did, or the label would go on naming a preset the
    /// group has stopped following.
    ///
    /// Shapes rather than values, because applying a preset **copies** its windows and every
    /// window carries a `UUID` of its own: the group's copies are equal in every way that blocks
    /// and equal in none that `==` can see. See `TimeWindow.Shape`.
    private static func weekAgrees(_ settings: GroupSettings, with preset: NamedPreset) -> Bool {
        guard let claimed = preset.timeWindows else { return true }
        return TimeWindow.shapes(of: claimed) == TimeWindow.shapes(of: settings.timeWindows)
    }

    /// The values behind a preset, as a group would run them. `nil` is Custom, which has no
    /// values of its own — it is the name for values that match nothing — so it answers with
    /// what the group already had.
    ///
    /// The fields no preset has an opinion about are carried across: picking one answers "how
    /// should this block", not "what is this called", "is it even on", "what is in it" or
    /// "when does it apply".
    ///
    /// **The week is the preset's only if the preset says so, and that is the whole point of
    /// this being written down.** It used to be replaced outright, on the reasoning that a preset
    /// owned its week — which made picking one silently throw away every window the user had
    /// drawn, including at group creation, where the sidebar's dropdown makes a group straight
    /// into a preset. Somebody who draws a bedtime block and then sets the group to Strict has
    /// said two things, and the second is not a retraction of the first.
    ///
    /// Then it was carried across unconditionally, which was the safe half of the answer and cost
    /// the other half: a preset could not prepare a week at all. `NamedPreset.timeWindows` has
    /// three states, and this line is where all three land — `nil` leaves the group's week alone,
    /// `[]` clears it, a list replaces it. **No confirmation stands in front of any of them**:
    /// picking a preset is already a deliberate act, and what a preset does not claim it still
    /// does not touch, so the protection is in the model rather than in a question.
    public static func settings(
        forPreset preset: NamedPreset?, current: GroupSettings
    ) -> GroupSettings {
        guard let preset else { return current }
        var chosen = preset.settings
        chosen.presetID = preset.id
        chosen.name = current.name
        chosen.enabled = current.enabled
        chosen.rules = current.rules
        chosen.categories = current.categories
        chosen.categoryExceptions = current.categoryExceptions
        chosen.timeWindows = preset.timeWindows ?? current.timeWindows
        // The group's own lock is the group's, exactly like its name and its switch. A preset is
        // how hard the group blocks, and a preset that could hand back a lock would be one click
        // that undid a commitment — through the very edit the lock is there to refuse.
        chosen.lockMinutes = current.lockMinutes
        chosen.passcode = current.passcode
        chosen.passcodeForgotStartedAt = current.passcodeForgotStartedAt
        // Carried across for the same reason and it is the sharper case: no preset can ever have
        // this switched on — the preset editor shows the shared cards and the Lock card is not one
        // of them — so taking a preset's answer would mean every preset silently handed both of
        // the app's ways out back into a group that had opted out of them.
        chosen.ignoresAppWideUnblocks = current.ignoresAppWideUnblocks
        // And the dated block, which is the sharpest case of the three: a preset is a template and
        // a dated block is a one-shot commitment, so no preset carries one — the row is not on the
        // cards the preset editor shows. Taking the preset's answer would therefore mean picking
        // any preset silently ended a block the user had bought, through the very edit a lock is
        // there to refuse.
        chosen.blockedUntilDay = current.blockedUntilDay
        return chosen
    }

    /// A copy with everything a preset has no opinion about set back to its default, so the
    /// comparison above is about behaviour and nothing else.
    private static func presetProbe(_ settings: GroupSettings) -> GroupSettings {
        var probe = settings
        // The label itself is never part of what it labels: a group that says nothing and a
        // preset that says its own name have to be able to match on their values.
        probe.presetID = nil
        probe.name = nil
        probe.enabled = true
        probe.rules = []
        // For the reason rules are cleared: a category says what is in the group, the way the
        // targets do, and a preset is the settings it is blocked with. Ticking Social
        // must no more make a group Custom than adding a website does.
        probe.categories = []
        probe.categoryExceptions = []
        // The week is compared separately or not at all — see `weekAgrees(_:with:)`. It cannot be
        // compared here in either case: a preset's own `settings.timeWindows` is always empty, so
        // leaving the group's in would make every group with a window Custom, whatever any preset
        // claims.
        probe.timeWindows = []
        // For the reason `enabled` is set back: a lock is a fact about this group rather than
        // about how it blocks, and reading it here would make every locked group Custom. The
        // emergency-pass opt-out is on that card and is the same kind of fact — and no preset can
        // carry it, so comparing it would make every group that has it read as Custom for good.
        probe.lockMinutes = 0
        probe.passcode = nil
        probe.passcodeForgotStartedAt = nil
        probe.ignoresAppWideUnblocks = false
        // The dated block joins them, and for the same two reasons at once: it is a fact about this
        // group rather than about how it blocks, and no preset can carry one — so reading it here
        // would make every group with a date on it read as Custom until the date passed.
        probe.blockedUntilDay = nil
        return probe
    }

    // MARK: - The presets themselves

    /// A new preset, ready to be edited — and deliberately **not** added to `config`.
    ///
    /// It used to write it in and answer with the id, which meant "Add preset" saved a preset
    /// before its editor had opened and Cancel left an orphan behind. The card holds this until
    /// Save instead, so the only thing that creates a preset is agreeing to one.
    ///
    /// Named uniquely against the list it is destined for, because a list whose whole job is to
    /// be picked from cannot have two rows reading "Standard" — see
    /// `NamedPreset.freeName(basedOn:among:)`.
    public static func newPreset(
        named name: String, settings: GroupSettings, in config: Config
    ) -> NamedPreset {
        var preset = NamedPreset(
            name: NamedPreset.freeName(basedOn: name, among: config.presets),
            settings: settings
        )
        // A preset made from Standard's values would otherwise carry Standard's own marker inside
        // it. Harmless to the matching, which reads the values, and confusing to anybody opening
        // `config.json` to see what a preset is.
        preset.settings.presetID = preset.id
        return preset
    }

    /// Deletes a preset. **The groups made from it keep every setting they have** — they stop
    /// being attached, which is all a preset ever was to them, and show as Custom from then on.
    ///
    /// The detaching is done here rather than left to the derivation so that what is on disk says
    /// the same thing as what is on screen: an id pointing at a preset that no longer exists is a
    /// dangling reference nobody would ever clean up.
    public static func removingPreset(_ presetID: String, from config: Config) -> Config {
        var updated = config
        updated.presets.removeAll { $0.id == presetID }
        for (groupID, settings) in updated.groupSettings where settings.presetID == presetID {
            updated.groupSettings[groupID]?.presetID = nil
        }
        return updated
    }

    /// How many groups are currently made from this preset — what the delete confirmation says
    /// out loud, so nobody has to guess what they are about to detach.
    public static func groupCount(usingPreset id: String, in config: Config) -> Int {
        config.groupSettings.values.filter {
            presetID(matching: $0, in: config.presets) == id
        }.count
    }

    // MARK: - The categories themselves

    /// A new, empty category, ready to be filled — and deliberately **not** added to `config`.
    ///
    /// Empty is the honest starting point: a category is a list the user builds, and seeding a
    /// new one with somebody else's idea of Social would be the app guessing. The card holds this
    /// until Save for the reason `newPreset(named:settings:in:)` does — a Cancel that creates the
    /// thing it was cancelling is the one behaviour a Cancel may not have.
    public static func newCategory(named name: String, in config: Config) -> DistractionCategory {
        DistractionCategory(
            name: DistractionCategory.freeName(basedOn: name, among: config.categories),
            domains: [],
            bundleIDs: []
        )
    }

    /// Deletes a category. **The groups that were members keep everything else they have** — they
    /// stop claiming what it carried, which is all a membership ever was, and their own targets,
    /// rules and switches are untouched.
    ///
    /// Their exceptions are pruned rather than dropped wholesale; see
    /// `pruningDanglingExceptions(in:)`. Striking something off is a decision that outlives one
    /// list — two categories may carry the same entry now — but an exception naming something no
    /// list carries at all is a hole waiting to open.
    public static func removingCategory(_ categoryID: String, from config: Config) -> Config {
        var updated = config
        updated.categories.removeAll { $0.id == categoryID }
        for (groupID, settings) in updated.groupSettings where settings.categories.contains(categoryID) {
            updated.groupSettings[groupID]?.categories.remove(categoryID)
        }
        return pruningDanglingExceptions(in: updated)
    }

    /// Drops every exception that names something no category carries any more.
    ///
    /// An exception is a target id struck off a list. Take that entry out of the list — which the
    /// Categories card can now do — and the exception is a hole waiting to happen: put the entry
    /// back next month and the group that struck it off goes on not blocking it, with nothing on
    /// screen to say why. The expanded row shows what the group *carries*, and what it carries has
    /// already had the exceptions taken out, so the site is simply absent.
    ///
    /// **Only the genuinely dangling ones.** An entry another category still carries is one the
    /// exception may yet apply to, and "deliberately removed stays removed" is the whole reason an
    /// exception survives an edit at all. Whether the group is a member of that other category
    /// does not come into it: memberships change, and a decision about a site should not be
    /// undone by ticking something.
    ///
    /// Run wherever the category lists themselves change. Not on every edit: a group's exceptions
    /// are otherwise its own business, and a rule that quietly rewrote them on an unrelated save
    /// would be harder to reason about than the hole it closes.
    public static func pruningDanglingExceptions(in config: Config) -> Config {
        let carried = Set(config.categories.flatMap(\.targetIDs))
        var updated = config
        for (groupID, settings) in config.groupSettings {
            let kept = settings.categoryExceptions.intersection(carried)
            guard kept != settings.categoryExceptions else { continue }
            updated.groupSettings[groupID]?.categoryExceptions = kept
        }
        return updated
    }

    /// Drops every dated block whose day has already begun.
    ///
    /// A dated block reads as absent the moment its day arrives — the engine, every screen and
    /// `EditDirection` all say so through `DatedBlock.standing`. This is the other half of that:
    /// the dead key stops being written down. Self-cleaning, like the keys this build has retired,
    /// except that no encoder can decide it — an encoder has no clock, so it is decided here, on
    /// the way to disk. See `AppState.saveEdit`, which is the one door every write goes through.
    ///
    /// **On every save rather than on the day rolling over**, and deliberately: a day passing is
    /// not a reason to write `config.json`, and a file whose only change is a key nobody reads any
    /// more is a write with nothing in it. The next real edit takes it out, and until then it says
    /// nothing to anybody.
    public static func droppingPastBlocks(in config: Config, onDay today: String) -> Config {
        var updated = config
        for (groupID, settings) in config.groupSettings {
            guard settings.blockedUntilDay != nil,
                  DatedBlock.standing(settings.blockedUntilDay, onDay: today) == nil else { continue }
            updated.groupSettings[groupID]?.blockedUntilDay = nil
        }
        return updated
    }

    /// How many groups are live members of this category — what the delete confirmation says out
    /// loud, so nobody has to guess how much of their configuration is about to stop claiming it.
    ///
    /// Switched-off groups count. A group that is off is not a group that is gone, and a number
    /// that quietly left them out would understate what the button does.
    public static func groupCount(usingCategory id: String, in config: Config) -> Int {
        config.groupSettings.values.filter { $0.categories.contains(id) }.count
    }
}
