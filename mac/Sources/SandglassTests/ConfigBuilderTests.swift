import SandglassAppCore
import SandglassCore
import Foundation

/// The rules that turn what somebody picked into a `Config`, and back.
///
/// None of this is cosmetic. A duplicate target is a document `Store` refuses to save; a
/// missed grouping hands the user two budgets where they asked for one; a preset marker that
/// stops matching its own values makes the settings screen describe settings that are not
/// running. All of it is arithmetic on values, so all of it is checked here rather than by
/// clicking through a window.
func runConfigBuilderTests() {
    testDomainInputAcceptsWhatPeopleActuallyType()
    testDomainInputRefusesWhatCannotBeAHost()
    testDomainDisplayNamesReadLikeNames()
    testGroupsAreListedInConfigurationOrder()
    testPresetIsReadFromTheValuesNotTheLabel()
    testPickingAPresetLeavesTheGroupsWeekAlone()
    testAPresetThatCarriesNoWindowsClearsTheGroups()
    testAPresetThatCarriesAWeekReplacesTheGroups()
    testTheWeekAPresetClaimsIsPartOfBeingOnIt()
    testApplyingAPresetLeavesTheGroupOnIt()
    testDrawingAWindowDoesNotMakeAGroupCustom()
    testEditingAKnobDetachesTheGroupFromItsPreset()
    testAPresetOfTheUsersOwnIsJustAnotherEntry()
    testDeletingAPresetLeavesItsGroupsSettingsIntact()
    testAddingLandsInTheGroupBeingEditedAndRemovingCleansUp()
    testGroupsCanBeCreatedNamedAndFilled()
    testNamingAndSwitchingOffDoNotChangeThePreset()
    testUntickingACategoryTakesItsExceptionsWithIt()
    testACarriedCategoryCountsTowardsWhatTheGroupHoldsInIt()
    testTickingACategoryDoesNotMakeAGroupCustom()
    testAPresetCannotHandTheEmergencyPassBackIntoAGroup()
    testAPresetNeitherCarriesADatedBlockNorEndsOne()
}

// MARK: - Categories

private func messaging() -> DistractionCategory {
    guard let found = DistractionCategory.builtIns.first(where: { $0.id == "messaging" }) else {
        failTest("no messaging category")
        return DistractionCategory(id: "messaging", name: "Messaging", domains: [], bundleIDs: [])
    }
    return found
}

/// Re-ticking has to give the whole list back. Exceptions that outlived their category would be
/// invisible holes: sites the chip obviously carries, quietly not blocked, with nothing on
/// screen to explain it.
private func testUntickingACategoryTakesItsExceptionsWithIt() {
    let discord = Target.id(ofKind: .app, value: "com.hnc.Discord")
    let linkedin = Target.id(ofKind: .domain, value: "linkedin.com")
    var settings = GroupSettings.standard
    ConfigBuilder.toggle(messaging(), on: true, in: &settings)
    settings.categories.insert("social")
    settings.categoryExceptions = [discord, linkedin]

    ConfigBuilder.toggle(messaging(), on: false, in: &settings)

    expectEqual(settings.categories, ["social"], "the category is gone")
    expectEqual(
        settings.categoryExceptions, [linkedin],
        "with its own exception, and nobody else's — Social keeps the site it struck off"
    )

    ConfigBuilder.toggle(messaging(), on: true, in: &settings)
    expectEqual(settings.categories, ["messaging", "social"], "and ticking it again brings it back")
    expectEqual(
        settings.categoryExceptions, [linkedin], "carrying the whole list rather than yesterday's holes"
    )
}

/// The sidebar counts what the group blocks, not what it happens to hold as targets.
private func testACarriedCategoryCountsTowardsWhatTheGroupHoldsInIt() {
    var settings = GroupSettings.standard
    settings.name = "Messaging"
    settings.categories = ["messaging"]
    settings.categoryExceptions = [Target.id(ofKind: .domain, value: "zoom.us")]
    let config = Config(
        version: 1,
        targets: [],
        groupSettings: ["grp:chips": settings]
    )
    guard let group = ConfigBuilder.groups(in: config).first else {
        failTest("a group of nothing but a chip is listed at all")
        return
    }

    expectEqual(group.name, "Messaging", "and is listed under the name the chip gave it")
    expectEqual(
        group.siteCount, messaging().domains.count - 1,
        "a group of nothing but a chip counts the sites it carries, minus what was struck off"
    )
    expectEqual(
        group.appCount, 0,
        "and claims none of its apps, which only exist if this Mac happens to have them"
    )
}

/// A category says *what* is in the group, the way targets and rules do. A preset is the
/// settings whatever is in it is blocked with.
private func testTickingACategoryDoesNotMakeAGroupCustom() {
    var settings = GroupSettings.standard
    ConfigBuilder.toggle(messaging(), on: true, in: &settings)
    settings.categoryExceptions.insert(Target.id(ofKind: .domain, value: "zoom.us"))
    expectEqual(
        ConfigBuilder.presetID(matching: settings, in: NamedPreset.builtIns),
        NamedPreset.standardID,
        "ticking a chip and dropping one site from it leaves the preset alone"
    )
    expectEqual(
        ConfigBuilder.settings(forPreset: builtIn(NamedPreset.gentleID), current: settings)
            .categories,
        ["messaging"],
        "and switching preset carries the membership across rather than dropping it"
    )
}

/// The opt-out from the emergency pass is the group's, exactly like its lock — and it is the
/// sharper case of the two, because **no preset can ever have it on**: the preset editor shows the
/// cards a group and a preset share, and the Lock card is not one of them. Read off the preset,
/// every preset in the app would be a one-click way of handing the pass back into a group that had
/// deliberately shut it out.
///
/// Both halves, because they are one rule seen twice: applying a preset must not switch it off, and
/// having it on must not make the group read as Custom for good.
private func testAPresetCannotHandTheEmergencyPassBackIntoAGroup() {
    var immune = GroupSettings.standard
    immune.ignoresAppWideUnblocks = true
    expect(
        ConfigBuilder.settings(forPreset: builtIn(NamedPreset.gentleID), current: immune)
            .ignoresAppWideUnblocks,
        "switching to a preset leaves the group out of the pass's reach"
    )
    expectEqual(
        ConfigBuilder.presetID(matching: immune, in: NamedPreset.builtIns),
        NamedPreset.standardID,
        "and the group still reads as the preset its knobs are, rather than as Custom"
    )
}

/// The same rule for the dated block, which is the same shape of fact: a preset is a template, a
/// dated block is a one-shot commitment, and no preset carries one — the row is not on the cards
/// the preset editor shows.
///
/// Read off the preset, picking any of them would silently end a block somebody had bought, through
/// the one edit a lock exists to refuse. And read into the Custom comparison, a group would show as
/// Custom for as long as its date stood, which is a label about the calendar rather than the knobs.
private func testAPresetNeitherCarriesADatedBlockNorEndsOne() {
    var dated = GroupSettings.standard
    dated.blockedUntilDay = "2026-08-24"
    expectEqual(
        ConfigBuilder.settings(forPreset: builtIn(NamedPreset.gentleID), current: dated)
            .blockedUntilDay,
        "2026-08-24",
        "switching to a preset leaves the day the group is blocked until exactly where it was"
    )
    expectEqual(
        ConfigBuilder.presetID(matching: dated, in: NamedPreset.builtIns),
        NamedPreset.standardID,
        "and the group still reads as the preset its knobs are, rather than as Custom"
    )
    expect(
        NamedPreset.builtIns.allSatisfy { $0.settings.blockedUntilDay == nil },
        "no seeded preset carries a date of its own, because no preset can"
    )
}

// MARK: - Preset fixtures

/// A second window beside the shared `bedtime` and `officeHours`, so a week can be more than one
/// thing and the tests below can tell a replaced week from an added one.
private let lunchBreak = window(.break, weekdays: TimeWindow.workWeek, from: 12 * 60, to: 13 * 60)

/// One of the three a fresh install is seeded with.
private func builtIn(_ id: String) -> NamedPreset {
    guard let found = NamedPreset.builtIns.first(where: { $0.id == id }) else {
        failTest("no built-in preset called \(id)")
        return NamedPreset(id: id, name: id, settings: .standard)
    }
    return found
}

// MARK: - Domain input

private func testDomainInputAcceptsWhatPeopleActuallyType() {
    expectEqual(
        DomainInput.normalize("https://www.YouTube.com/feed/subscriptions"), "youtube.com",
        "a pasted URL is reduced to its host"
    )
    expectEqual(DomainInput.normalize("  reddit.com  "), "reddit.com", "surrounding space is trimmed")
    expectEqual(DomainInput.normalize("YouTube.com."), "youtube.com", "the fully qualified form is the same site")
    expectEqual(DomainInput.normalize("youtube.com:8443"), "youtube.com", "a port is not part of the name")
    expectEqual(DomainInput.normalize("http://user@x.com/p?q=1#f"), "x.com", "credentials, path, query and fragment all go")
    expectEqual(
        DomainInput.normalize("youtube.com/watch?v=a@b"), "youtube.com",
        "and an address inside a query string is not credentials in front of a host"
    )
    expectEqual(
        DomainInput.normalize("m.youtube.com"), "m.youtube.com",
        "and a subdomain is left alone: reducing it would need the public suffix list"
    )
}

private func testDomainInputRefusesWhatCannotBeAHost() {
    expectNil(DomainInput.normalize(""), "an empty field is not a domain")
    expectNil(DomainInput.normalize("   "), "nor is a field of spaces")
    expectNil(DomainInput.normalize("youtube"), "a single label is not a host")
    expectNil(DomainInput.normalize("you tube.com"), "a host has no spaces in it")
    expectNil(DomainInput.normalize("-bad.com"), "a label may not start with a hyphen")
    expectNil(DomainInput.normalize("a..com"), "nor may a label be empty")
    expectNil(DomainInput.normalize("https://"), "a scheme on its own leaves nothing behind")
}

private func testDomainDisplayNamesReadLikeNames() {
    expectEqual(DomainInput.displayName(for: "youtube.com"), "Youtube", "the label before the suffix names it")
    expectEqual(DomainInput.displayName(for: "twitch.tv"), "Twitch", "whatever the suffix is")
    expectEqual(
        DomainInput.displayName(for: "news.ycombinator.com"), "Ycombinator",
        "and a subdomain is not the name of the site"
    )
}

// MARK: - Building

private func appPick(_ bundleID: String, _ name: String, group: String? = nil) -> Target {
    Target(kind: .app, value: bundleID, displayName: name, groupID: group)
}

private func sitePick(_ host: String, _ name: String, group: String? = nil) -> Target {
    Target(kind: .domain, value: host, displayName: name, groupID: group)
}

private func testGroupsAreListedInConfigurationOrder() {
    var config = Config(
        version: 1,
        targets: [
            appPick("com.google.YouTube", "YouTube", group: "grp:videos"),
            sitePick("youtube.com", "YouTube", group: "grp:videos"),
            sitePick("reddit.com", "Reddit", group: "grp:reddit"),
        ],
        groupSettings: ["grp:videos": .standard, "grp:reddit": .standard]
    )
    config.groupSettings["grp:reddit"] = nil               // a group the engine will not manage

    let groups = ConfigBuilder.groups(in: config)
    expectEqual(groups.map(\.id), ["grp:videos", "grp:reddit"], "one entry per group, in order")
    expectEqual(groups.first?.name, "YouTube", "named after the target picked first")
    expectEqual(groups.first?.targets.count, 2, "carrying everything in the group")
    expectEqual(groups.first?.settings, .standard, "and the settings it runs on")
    expectNil(
        groups.last?.settings,
        "a group without settings says so rather than borrowing a preset it does not have"
    )
}

// MARK: - Presets

private func testPresetIsReadFromTheValuesNotTheLabel() {
    let seeded = NamedPreset.builtIns
    expectEqual(
        ConfigBuilder.presetID(matching: .gentle, in: seeded), NamedPreset.gentleID,
        "gentle values are Gentle"
    )
    expectEqual(
        ConfigBuilder.presetID(matching: .standard, in: seeded), NamedPreset.standardID,
        "standard values are Standard"
    )
    expectEqual(
        ConfigBuilder.presetID(matching: .strict, in: seeded), NamedPreset.strictID,
        "and strict values are Strict — which is now a set of knobs and no window at all"
    )

    var moved = GroupSettings.standard
    moved.pauseSeconds = 45
    expectNil(
        ConfigBuilder.presetID(matching: moved, in: seeded), "one knob moved makes it Custom"
    )

    var mislabelled = GroupSettings.gentle
    mislabelled.presetID = NamedPreset.strictID
    expectEqual(
        ConfigBuilder.presetID(matching: mislabelled, in: seeded), NamedPreset.gentleID,
        "and the label on a set of values is never the answer"
    )
    expectNil(
        ConfigBuilder.presetID(matching: .gentle, in: []),
        "a preset that has been deleted leaves the values it labelled as Custom"
    )

    expectEqual(
        ConfigBuilder.settings(forPreset: nil, current: moved), moved,
        "and Custom is not a set of values to switch to"
    )

}

/// The bug this exists to stop coming back, and the reason "time windows don't work" was a fair
/// description of the app: **picking a preset used to replace the group's `timeWindows`.**
///
/// Which meant a window somebody had drawn was silently gone the moment they set the group to
/// Strict — and the sidebar's dropdown makes a group *straight into* a preset, so a window drawn
/// on a fresh group was thrown away by the very next preset change.
///
/// A preset may carry a week now, but only by saying so: this is the first of the three states,
/// the one every seeded preset is in, and the one that guarantees the bug above cannot come
/// back for anybody who has not deliberately asked for it. See `NamedPreset.timeWindows`.
private func testPickingAPresetLeavesTheGroupsWeekAlone() {
    let seeded = NamedPreset.builtIns
    let bedtime = strictWindow(weekdays: TimeWindow.everyDay, from: 22 * 60, to: 8 * 60)
    let lunch = window(.break, weekdays: TimeWindow.workWeek, from: 12 * 60, to: 13 * 60)
    let drawn = standardSettings(windows: [bedtime, lunch])

    for preset in seeded {
        expectEqual(
            ConfigBuilder.settings(forPreset: preset, current: drawn).timeWindows,
            [bedtime, lunch],
            "picking \(preset.name) keeps both windows, untouched and in order"
        )
    }
    expectEqual(
        ConfigBuilder.settings(forPreset: builtIn(NamedPreset.strictID), current: drawn)
            .cooldownMinutes,
        GroupSettings.strict.cooldownMinutes,
        "while the knobs it does own are taken from it"
    )

    // A group with no windows gets none either: carrying the current list across cannot become a
    // way for a preset to smuggle one in.
    expect(
        ConfigBuilder.settings(forPreset: builtIn(NamedPreset.strictID), current: .gentle)
            .timeWindows.isEmpty,
        "and a group with no week stays that way"
    )
}

// MARK: - The three states of a preset's week

/// The middle state, and the one a plain `[TimeWindow]` cannot tell apart from the first: a
/// preset that deliberately carries none takes the group's away.
private func testAPresetThatCarriesNoWindowsClearsTheGroups() {
    let always = NamedPreset(name: "Always on", settings: .standard, timeWindows: [])
    let drawn = standardSettings(windows: [bedtime, lunchBreak])
    expect(
        ConfigBuilder.settings(forPreset: always, current: drawn).timeWindows.isEmpty,
        "an empty list is an opinion, and applying it clears the week"
    )
    expectEqual(
        ConfigBuilder.settings(forPreset: always, current: drawn).cooldownMinutes,
        GroupSettings.standard.cooldownMinutes,
        "with the knobs coming across as they always did"
    )
}

/// The third state. The group's own week is replaced rather than added to — a preset that
/// carries a week is describing the whole of one.
private func testAPresetThatCarriesAWeekReplacesTheGroups() {
    let office = NamedPreset(
        name: "Office hours", settings: .strict, timeWindows: [officeHours]
    )
    let drawn = standardSettings(windows: [bedtime, lunchBreak])
    expectEqual(
        ConfigBuilder.settings(forPreset: office, current: drawn).timeWindows, [officeHours],
        "the preset's week is what the group ends up with, and only that"
    )
    expectEqual(
        ConfigBuilder.settings(forPreset: office, current: .gentle).timeWindows, [officeHours],
        "a group that had no week at all gets the preset's the same way"
    )
}

/// A preset that claims a week is a preset the group has to be *keeping* to still be on it —
/// otherwise the label would go on naming a preset the group has stopped following.
///
/// And a preset that claims nothing is not knocked off by a window, which is the state every
/// preset that already exists is in.
private func testTheWeekAPresetClaimsIsPartOfBeingOnIt() {
    let office = NamedPreset(
        id: "office", name: "Office hours", settings: .strict, timeWindows: [officeHours]
    )
    var kept = GroupSettings.strict
    kept.timeWindows = [officeHours]
    expectEqual(
        ConfigBuilder.presetID(matching: kept, in: [office]), "office",
        "the knobs and the week both match, so the group is on it"
    )

    var redrawn = kept
    redrawn.timeWindows = [bedtime]
    expectNil(
        ConfigBuilder.presetID(matching: redrawn, in: [office]),
        "a week that is not the one the preset claims makes the group Custom"
    )

    var emptied = kept
    emptied.timeWindows = []
    expectNil(
        ConfigBuilder.presetID(matching: emptied, in: [office]),
        "and so does taking the claimed week off altogether"
    )

    let quiet = NamedPreset(id: "quiet", name: "Quiet", settings: .strict)
    expectEqual(
        ConfigBuilder.presetID(matching: redrawn, in: [quiet]), "quiet",
        "while a preset that claims no week is not knocked off by one"
    )
}

/// The check that would fail on ids alone, and the one that matters in the app: applying a preset
/// **copies** its windows, and every copy carries a `UUID` of its own — so a group put on a
/// window-carrying preset would read as Custom the second after it was put there.
private func testApplyingAPresetLeavesTheGroupOnIt() {
    let office = NamedPreset(
        id: "office", name: "Office hours", settings: .strict, timeWindows: [officeHours]
    )
    let applied = ConfigBuilder.settings(
        forPreset: office, current: standardSettings(windows: [bedtime])
    )
    expectEqual(
        ConfigBuilder.presetID(matching: applied, in: [office]), "office",
        "what a preset hands out is what being on that preset means"
    )

    // The same week, drawn by hand with ids of its own: shapes are what agree, not identities.
    var retyped = applied
    retyped.timeWindows = [
        TimeWindow(
            id: "typed-by-hand", kind: officeHours.kind, weekdays: officeHours.weekdays,
            startMinutes: officeHours.startMinutes, endMinutes: officeHours.endMinutes
        ),
    ]
    expectEqual(
        ConfigBuilder.presetID(matching: retyped, in: [office]), "office",
        "and a week redrawn to the same shape is the same week"
    )
}

/// The other half of the same decision. A window carries a `UUID` of its own, so while windows
/// were part of the comparison no preset could match a group that had drawn one — every such
/// group read as Custom, whatever its knobs said.
private func testDrawingAWindowDoesNotMakeAGroupCustom() {
    let seeded = NamedPreset.builtIns
    let evening = standardSettings(
        windows: [window(.break, weekdays: TimeWindow.everyDay, from: 20 * 60, to: 22 * 60)]
    )
    expectEqual(
        ConfigBuilder.presetID(matching: evening, in: seeded), NamedPreset.standardID,
        "standard knobs plus a free evening are still Standard"
    )

    var blocked = GroupSettings.strict
    blocked.timeWindows = [TimeWindow.make(.allDay, kind: .strictBlock)]
    expectEqual(
        ConfigBuilder.presetID(matching: blocked, in: seeded), NamedPreset.strictID,
        "and strict knobs plus a block around the clock are still Strict"
    )

    blocked.cooldownMinutes += 1
    expectNil(
        ConfigBuilder.presetID(matching: blocked, in: seeded),
        "it is the knobs that detach a group, and only the knobs"
    )
}

/// The one thing the marker has to do: come off the moment a knob moves, and go back on when the
/// knob does. It is what the group editor's dropdown reads, and it is written on every edit.
private func testEditingAKnobDetachesTheGroupFromItsPreset() {
    let seeded = NamedPreset.builtIns
    var settings = ConfigBuilder.settings(forPreset: builtIn(NamedPreset.standardID), current: .gentle)
    expectEqual(settings.presetID, NamedPreset.standardID, "picking a preset attaches the group")

    settings.cooldownMinutes = 25
    settings.presetID = ConfigBuilder.presetID(matching: settings, in: seeded)
    expectNil(settings.presetID, "moving the cooldown detaches it")

    settings.cooldownMinutes = GroupSettings.standard.cooldownMinutes
    settings.presetID = ConfigBuilder.presetID(matching: settings, in: seeded)
    expectEqual(settings.presetID, NamedPreset.standardID, "and moving it back attaches it again")
}

/// Nothing about the seeded three is special: a preset the user makes is picked, matched and
/// carried across exactly as they are. Renaming Standard is the same operation as renaming any
/// other, and a preset with the same values as a group already has claims that group's label.
private func testAPresetOfTheUsersOwnIsJustAnotherEntry() {
    var evening = GroupSettings.standard
    evening.pauseSeconds = 45
    evening.opensPerDay = 2
    var base = Config(version: 1, targets: [], groupSettings: [:])
    let made = ConfigBuilder.newPreset(named: "Evening", settings: evening, in: base)
    expectEqual(
        base.presets.count, 3,
        "making one adds nothing: the editor opens on a draft, and Cancel must leave no orphan"
    )
    expectEqual(made.settings.presetID, made.id, "it carries its own marker, not Standard's")

    base.presets.append(made)
    expectEqual(base.presets.count, 4, "saved, it is the three seeded ones plus this")
    expectEqual(
        ConfigBuilder.presetID(matching: evening, in: base.presets), made.id,
        "and values matching it are labelled with it rather than with Custom"
    )

    let renamed = ConfigBuilder.newPreset(named: "Standard", settings: .gentle, in: base)
    expectEqual(
        renamed.name, "Standard 2",
        "a second preset called Standard is numbered rather than left ambiguous"
    )
}

/// The promise the delete confirmation makes. A group holds its own copy of the values, so
/// throwing the preset away costs it a label and not one setting.
private func testDeletingAPresetLeavesItsGroupsSettingsIntact() {
    var strict = ConfigBuilder.settings(forPreset: builtIn(NamedPreset.strictID), current: .standard)
    strict.name = "Social"
    let config = Config(version: 1, targets: [], groupSettings: ["grp:social": strict])
    expectEqual(
        ConfigBuilder.groupCount(usingPreset: NamedPreset.strictID, in: config), 1,
        "the confirmation can say how many groups are on it"
    )

    let after = ConfigBuilder.removingPreset(NamedPreset.strictID, from: config)
    guard let left = after.groupSettings["grp:social"] else {
        failTest("the group went with the preset")
        return
    }
    expectEqual(left.timeWindows, strict.timeWindows, "the group keeps the window it was blocking in")
    expectEqual(left.opensPerDay, strict.opensPerDay, "and its budget")
    expectEqual(left.name, "Social", "and its name")
    expectNil(left.presetID, "and stops being attached, which is all it loses")
    expectEqual(
        ConfigBuilder.presetID(matching: left, in: after.presets), nil,
        "so it reads as Custom from here on"
    )
}

// MARK: - Editing

private func testAddingLandsInTheGroupBeingEditedAndRemovingCleansUp() {
    let base = Config(
        version: 1,
        targets: [
            sitePick("youtube.com", "YouTube", group: "grp:videos"),
            sitePick("reddit.com", "Reddit", group: "grp:reddit"),
        ],
        groupSettings: ["grp:videos": .standard, "grp:reddit": .standard]
    )

    let joined = ConfigBuilder.adding(
        appPick("com.google.YouTube", "youtube"), toGroup: "grp:videos", in: base
    )
    expectEqual(
        joined.targets.last?.groupID, "grp:videos",
        "a target added from the editor lands in the group being edited"
    )
    expectEqual(joined.groupSettings.count, 2, "and brings no group settings of its own")

    let again = ConfigBuilder.adding(
        sitePick("youtube.com", "YouTube"), toGroup: "grp:reddit", in: joined
    )
    expectEqual(
        again.targets.count, joined.targets.count,
        "a target that already exists is not moved and not added twice — the store refuses that document"
    )

    let removed = ConfigBuilder.removing(targetID: "domain:reddit.com", from: base)
    expectEqual(removed.targets.count, 1, "the target is gone")
    expectEqual(
        removed.groupSettings["grp:reddit"], .standard,
        "and the group it was in stays: emptying a list is how you retype it, not how you delete it"
    )
    expectEqual(
        ConfigBuilder.groups(in: removed).map(\.id), ["grp:videos", "grp:reddit"],
        "so the emptied group is still listed, after the ones that have targets"
    )

    let halfRemoved = ConfigBuilder.removing(targetID: "app:com.google.YouTube", from: joined)
    expectEqual(
        halfRemoved.groupSettings["grp:videos"], .standard,
        "a group that still has targets in it keeps its settings"
    )

    let deleted = ConfigBuilder.removingGroup("grp:reddit", from: base)
    expectEqual(deleted.targets.count, 1, "deleting a group takes its targets with it")
    expectNil(deleted.groupSettings["grp:reddit"], "and its settings")
}

// MARK: - Groups as things of their own

/// The sidebar makes a group something the user creates, names and deletes, rather than a
/// property of the targets in it. All four of those are arithmetic on a `Config`.
private func testGroupsCanBeCreatedNamedAndFilled() {
    let empty = Config(version: 1, targets: [], groupSettings: [:])
    let (created, groupID) = ConfigBuilder.addingGroup(named: "Time sinks", to: empty)
    expectEqual(groupID, "grp:time-sinks", "a new group is named after what it is called")
    expectEqual(created.groupSettings[groupID]?.name, "Time sinks", "which is stored on the group")
    expectEqual(
        ConfigBuilder.groups(in: created).map(\.name), ["Time sinks"],
        "and an empty group is listed, because it is a row the user just made"
    )

    let (twice, secondID) = ConfigBuilder.addingGroup(named: "Time sinks", to: created)
    expectEqual(secondID, "grp:time-sinks-2", "a second group of the same name gets its own id")

    let filled = ConfigBuilder.adding(
        Target(kind: .domain, value: "youtube.com", displayName: "Youtube"),
        toGroup: groupID, in: twice
    )
    expectEqual(
        filled.targets.first?.groupID, groupID,
        "a target added in the editor lands in the group being edited, whatever it is called"
    )
    expectEqual(
        ConfigBuilder.groups(in: filled).first?.name, "Time sinks",
        "and the group keeps the name the user gave it rather than taking the target's"
    )

    let again = ConfigBuilder.adding(
        Target(kind: .domain, value: "youtube.com", displayName: "Youtube"),
        toGroup: secondID, in: filled
    )
    expectEqual(
        again.targets.count, 1,
        "a target that already exists is not added a second time — the store would refuse the document"
    )
}

/// The two fields a preset has no opinion about. Getting this wrong would mean naming a
/// group, or switching it off, silently relabelled every preset as Custom.
private func testNamingAndSwitchingOffDoNotChangeThePreset() {
    var named = GroupSettings.standard
    named.name = "Social"
    named.enabled = false
    expectEqual(
        ConfigBuilder.presetID(matching: named, in: NamedPreset.builtIns), NamedPreset.standardID,
        "a named, switched-off group is still on the Standard preset"
    )

    let switched = ConfigBuilder.settings(forPreset: builtIn(NamedPreset.gentleID), current: named)
    expectEqual(switched.pauseSeconds, GroupSettings.gentle.pauseSeconds, "picking a preset takes its values")
    expectEqual(switched.name, "Social", "and carries the name across")
    expect(!switched.enabled, "and leaves the group switched off")
}
