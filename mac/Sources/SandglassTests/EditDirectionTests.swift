import SandglassAppCore
import SandglassCore
import Foundation

/// The direction table, walked field by field and in both directions.
///
/// The lock rule is one sentence — making things stricter must always work, only making them
/// looser is held — and a table with one row read the wrong way round is a lock with a hole in it or a
/// lock that argues with the person who set it. So every field is asked twice here: the move that
/// blocks harder must pass, and its reverse must be held.
///
/// What a held edit then costs is `GroupLockTests` and `SettingsLockTests`; that the gates are
/// actually asked is `GroupLockEditTests` and `SettingsLockEditTests`. Nothing here reads a clock.
func runEditDirectionTests() {
    testTheNumbersMoveOneWay()
    testTheSwitchesHaveASide()
    testScopeMayGrowAndNotShrink()
    testRulesSplitByWhatTheyDo()
    testBlocksGrowAndBreaksShrink()
    testADateMayBePushedOutAndNeverPulledIn()
    testALockMayBeTightenedAndNeverLoosened()
    testTheGroupItselfMayNotGoAway()
    testWhatIsNotComparedAtAll()
    testAGroupIsOnlyItsOwnBusiness()
    testAPresetIsAsStrictAsTheKnobsItWrites()
    testTheAppsOwnSettings()
    testTheWholeConfigurationIsTheGroupsPlusTheGlobals()
}

// MARK: - The fixture

/// The day every question below is asked on.
///
/// The table reads one clock-dependent field — a dated block, which stops being one when its day
/// arrives — and it is handed in rather than read, so this suite still reads no clock. A fixed day
/// well before the fixture's dates keeps every other row's answer exactly what it always was.
private let directionDay = "2026-08-20"

/// One group with every knob somewhere it can be moved from in both directions, a week, a rule of
/// each kind and a category it carries.
private func directionBase() -> Config {
    var config = categoryConfig()
    var settings = config.groupSettings[youtubeGroup] ?? .standard
    settings.pauseSeconds = 10
    settings.escalationSeconds = 5
    settings.cooldownMinutes = 10
    settings.opensPerDay = 5
    settings.sessionMinutes = 5
    settings.dailyMinutes = 60
    settings.earnBackEnabled = true
    settings.lockMinutes = 10
    settings.timeWindows = [officeHours, window(.break, weekdays: [7], from: 600, to: 720)]
    settings.rules = [
        Rule(pattern: "shorts", matchType: .websiteOrText, action: .block),
        Rule(pattern: "music.youtube.com", matchType: .websiteOrText, action: .allow),
    ]
    config.groupSettings[youtubeGroup] = settings
    config.breakWaitSeconds = 30
    config.settingsLock = SettingsLock(timerMinutes: 10)
    return config
}

/// What the table says about one edit to the fixture's group.
private func loosensGroup(_ change: (inout Config) -> Void) -> Bool {
    let base = directionBase()
    var edited = base
    change(&edited)
    return EditDirection.loosens(group: youtubeGroup, from: base, to: edited, onDay: directionDay)
}

/// The same, one field at a time on the group's settings.
private func loosensSettings(_ change: (inout GroupSettings) -> Void) -> Bool {
    loosensGroup { config in
        guard var settings = config.groupSettings[youtubeGroup] else { return }
        change(&settings)
        config.groupSettings[youtubeGroup] = settings
    }
}

/// Both directions of one field, in one call: the tightening move passes and its reverse is held.
private func expectDirection(
    _ field: String,
    tightening: @escaping (inout GroupSettings) -> Void,
    loosening: @escaping (inout GroupSettings) -> Void
) {
    expect(!loosensSettings(tightening), "\(field): the tightening move goes through")
    expect(loosensSettings(loosening), "\(field): the loosening move is held")
}

// MARK: - The table

/// The six numbers. Each of them has a direction, and nought is a value like any other — except
/// on the pause, where it is the loosest one on the dial.
private func testTheNumbersMoveOneWay() {
    expect(!loosensSettings { _ in }, "an edit that changes nothing takes nothing away")
    expectDirection(
        "pause countdown",
        tightening: { $0.pauseSeconds = 30 },
        loosening: { $0.pauseSeconds = 3 }
    )
    expect(
        loosensSettings { $0.pauseSeconds = 0 },
        "a pause of nought is no screen at all, so it is the loosening the dial's bottom looks like"
    )
    expectDirection(
        "escalation",
        tightening: { $0.escalationSeconds = 15 },
        loosening: { $0.escalationSeconds = 0 }
    )
    expectDirection(
        "cooldown",
        tightening: { $0.cooldownMinutes = 30 },
        loosening: { $0.cooldownMinutes = 0 }
    )
    expectDirection(
        "daily opens",
        tightening: { $0.opensPerDay = 2 },
        loosening: { $0.opensPerDay = 20 }
    )
    expect(
        loosensSettings { $0.opensPerDay = nil },
        "unlimited opens is looser than any number somebody could type"
    )
    expectDirection(
        "open length",
        tightening: { $0.sessionMinutes = 2 },
        loosening: { $0.sessionMinutes = 60 }
    )
    expect(
        loosensSettings { $0.sessionMinutes = nil },
        "an open that never relocks is looser than the longest one on the dial"
    )
    expectDirection(
        "daily time limit",
        tightening: { $0.dailyMinutes = 30 },
        loosening: { $0.dailyMinutes = 600 }
    )
    expect(loosensSettings { $0.dailyMinutes = nil }, "and no limit at all is looser still")
}

/// The three switches, and which side of each is the strict one.
///
/// The last of them is the one to watch across a rename: `ignoresAppWideUnblocks` covers two ways
/// out now rather than one, and widening what a switch shuts out must not flip which side of it is
/// the tightening. Both directions are checked, so a rename that inverted the comparison would be
/// caught here rather than by a lock quietly letting an escape back in.
private func testTheSwitchesHaveASide() {
    expect(loosensSettings { $0.enabled = false }, "switching the group off hands everything back")
    let base = directionBase()
    var off = base
    off.groupSettings[youtubeGroup]?.enabled = false
    var on = off
    on.groupSettings[youtubeGroup]?.enabled = true
    expect(
        !EditDirection.loosens(group: youtubeGroup, from: off, to: on, onDay: directionDay),
        "and switching it back on is the tightening move, which goes through"
    )
    expect(
        !loosensSettings { $0.earnBackEnabled = false },
        "giving up earn-back is the user taking their own escape hatch away"
    )
    var given = base
    given.groupSettings[youtubeGroup]?.earnBackEnabled = false
    var asked = given
    asked.groupSettings[youtubeGroup]?.earnBackEnabled = true
    expect(
        EditDirection.loosens(group: youtubeGroup, from: given, to: asked, onDay: directionDay),
        "and asking for it back is budget returning, which is held"
    )
    expect(
        !loosensSettings { $0.ignoresAppWideUnblocks = true },
        "putting this group out of reach of the pass and the break takes both ways out away"
    )
    var immune = base
    immune.groupSettings[youtubeGroup]?.ignoresAppWideUnblocks = true
    var reachable = immune
    reachable.groupSettings[youtubeGroup]?.ignoresAppWideUnblocks = false
    expect(
        EditDirection.loosens(group: youtubeGroup, from: immune, to: reachable, onDay: directionDay),
        "and handing both of them back is the loosening, which a running lock holds"
    )
}

/// What is in the group: its targets, its category ticks, and what those lists carry.
private func testScopeMayGrowAndNotShrink() {
    let extra = Target(
        kind: .domain, value: "x.com", displayName: "X", groupID: youtubeGroup
    )
    expect(
        !loosensGroup { $0.targets.append(extra) },
        "one more site inside the group is one more thing blocked"
    )
    expect(
        loosensGroup { $0.targets.removeAll { $0.groupID == youtubeGroup } },
        "and taking one out is the loosening"
    )
    expect(
        loosensGroup { config in
            guard let index = config.targets.firstIndex(where: { $0.groupID == youtubeGroup })
            else { return }
            config.targets[index].groupID = redditGroup
        },
        "a target moved to another group leaves this one carrying less"
    )
    expectDirection(
        "category ticks",
        tightening: { $0.categories.insert("news") },
        loosening: { $0.categories = [] }
    )
    expect(
        !loosensGroup { $0.categories[0].domains.append("x.com") },
        "growing a list the group carries is somebody widening their own blocks"
    )
    expect(
        loosensGroup { $0.categories[0].domains = ["instagram.com"] },
        "and emptying one out from under it is the side door the table has to catch"
    )
    expect(
        loosensSettings { $0.categoryExceptions = ["domain:instagram.com"] },
        "striking a member off carries less, which is the same loosening said another way"
    )
}

/// The advanced rules, split by what each one does — the row the old table refused to have an
/// opinion about at all.
private func testRulesSplitByWhatTheyDo() {
    let block = Rule(pattern: "reels", matchType: .websiteOrText, action: .block)
    let allow = Rule(pattern: "youtube.com/feed", matchType: .specificPage, action: .allow)
    expect(!loosensSettings { $0.rules.append(block) }, "one more block rule blocks more")
    expect(loosensSettings { $0.rules.append(allow) }, "one more allow rule opens something")
    expect(
        loosensSettings { $0.rules.removeAll { $0.action == .block } },
        "taking a block rule out is the loosening"
    )
    expect(
        !loosensSettings { $0.rules.removeAll { $0.action == .allow } },
        "taking an allow rule out is the tightening"
    )
    expect(
        !loosensSettings { settings in
            settings.rules = settings.rules.map {
                Rule(pattern: $0.pattern, matchType: $0.matchType, action: $0.action,
                     highPriority: $0.highPriority)
            }
        },
        "and a list rebuilt with fresh ids is the same list, which is what applying a preset does"
    )
}

/// The week. A block that grows passes; a break that grows does not, because a break is the one
/// shape in the app that hands hours back.
private func testBlocksGrowAndBreaksShrink() {
    let sunday = window(.break, weekdays: [7], from: 600, to: 720)
    expect(
        !loosensSettings { $0.timeWindows.append(bedtime) },
        "one more strict window shuts more of the week"
    )
    expect(
        !loosensSettings { settings in
            settings.timeWindows = settings.timeWindows.map { window in
                guard window.kind == .strictBlock else { return window }
                var longer = window
                longer.endMinutes = 1_200
                return longer
            }
        },
        "and extending the one that is there shuts more of it too"
    )
    expect(
        loosensSettings { $0.timeWindows.removeAll { $0.kind == .strictBlock } },
        "deleting a strict window opens the hours it held"
    )
    expect(
        loosensSettings { settings in
            settings.timeWindows = settings.timeWindows.map { window in
                guard window.kind == .strictBlock else { return window }
                var shorter = window
                shorter.weekdays = [2]
                return shorter
            }
        },
        "and so does drawing it on fewer days"
    )
    expect(
        loosensSettings { $0.timeWindows.append(window(.break, weekdays: [1], from: 600, to: 720)) },
        "one more break window opens time"
    )
    expect(
        loosensSettings { settings in
            settings.timeWindows = settings.timeWindows.map { window in
                guard window.kind == .break else { return window }
                var longer = window
                longer.endMinutes = 1_200
                return longer
            }
        },
        "and extending a break opens more of it"
    )
    expect(
        !loosensSettings { $0.timeWindows.removeAll { $0.kind == .break } },
        "deleting a break gives the hours back to the rest of the week"
    )
    expect(
        !loosensSettings { settings in
            settings.timeWindows = settings.timeWindows.filter { $0.kind != .break }
                + [window(.break, weekdays: [7], from: 600, to: 660)]
        },
        "and shortening one does the same"
    )
    expect(
        !loosensSettings { settings in
            settings.timeWindows = settings.timeWindows.map { window in
                guard window.id == sunday.id else { return window }
                var switched = window
                switched.kind = .strictBlock
                return switched
            }
        },
        "a break switched to a block is both moves at once, and both of them tighten"
    )
    expect(
        !loosensSettings { settings in
            settings.timeWindows = settings.timeWindows.reversed()
        },
        "the order the windows are listed in is not a fact about the week"
    )
}

/// The one-shot block, in both directions — and the third case the other rows do not have, where
/// the field means one thing on Sunday and nothing on Monday.
private func testADateMayBePushedOutAndNeverPulledIn() {
    expect(
        !loosensSettings { $0.blockedUntilDay = "2026-08-24" },
        "setting a date where there was none is somebody shutting their own group, so it passes"
    )
    let base = directionBase()
    var dated = base
    dated.groupSettings[youtubeGroup]?.blockedUntilDay = "2026-08-24"

    var later = dated
    later.groupSettings[youtubeGroup]?.blockedUntilDay = "2026-08-31"
    expect(
        !EditDirection.loosens(group: youtubeGroup, from: dated, to: later, onDay: directionDay),
        "and moving it further out is more of the same"
    )

    var earlier = dated
    earlier.groupSettings[youtubeGroup]?.blockedUntilDay = "2026-08-22"
    expect(
        EditDirection.loosens(group: youtubeGroup, from: dated, to: earlier, onDay: directionDay),
        "pulling it in hands days back, which is what a running lock holds"
    )

    var removed = dated
    removed.groupSettings[youtubeGroup]?.blockedUntilDay = nil
    expect(
        EditDirection.loosens(group: youtubeGroup, from: dated, to: removed, onDay: directionDay),
        "and taking it away entirely is the same move, all at once"
    )

    // The case that needs the day: on the far side of it the same removal is housekeeping, and a
    // lock that refused it would be defending a block that is already over.
    expect(
        !EditDirection.loosens(
            group: youtubeGroup, from: dated, to: removed, onDay: "2026-08-24"
        ),
        "a block whose day has arrived is no block, so dropping the dead key is not a loosening"
    )
    expect(
        !EditDirection.loosens(
            group: youtubeGroup, from: dated, to: earlier, onDay: "2026-08-24"
        ),
        "nor is replacing it with another day already gone"
    )
}

/// The lock itself is a setting like the rest of the page, and moves under the same rule.
private func testALockMayBeTightenedAndNeverLoosened() {
    expectDirection(
        "lock minutes",
        tightening: { $0.lockMinutes = 60 },
        loosening: { $0.lockMinutes = 0 }
    )
    expect(
        !loosensSettings { $0.passcode = PasscodeHash.make("1234") },
        "a passcode may be added to a group that had none — the rule's own example"
    )
    let base = directionBase()
    var coded = base
    coded.groupSettings[youtubeGroup]?.passcode = PasscodeHash.make("1234")
    var cleared = coded
    cleared.groupSettings[youtubeGroup]?.passcode = nil
    expect(
        EditDirection.loosens(group: youtubeGroup, from: coded, to: cleared, onDay: directionDay),
        "taking one away is the loosening"
    )
    var changed = coded
    changed.groupSettings[youtubeGroup]?.passcode = PasscodeHash.make("5678")
    expect(
        EditDirection.loosens(group: youtubeGroup, from: coded, to: changed, onDay: directionDay),
        "and changing one is a removal and a setting in one edit, so it is held too"
    )
}

/// A missing group is not a stricter one, and a group that was not there a moment ago has nothing
/// to hand back.
private func testTheGroupItselfMayNotGoAway() {
    expect(
        loosensGroup { $0.groupSettings[youtubeGroup] = nil },
        "deleting the group loosens it"
    )
    let base = directionBase()
    var born = base
    born.groupSettings["grp:new"] = .standard
    expect(
        !EditDirection.loosens(group: "grp:new", from: base, to: born, onDay: directionDay),
        "and a group that has just been made is nobody's loosening"
    )
    expect(
        !EditDirection.loosens(from: base, to: born, onDay: directionDay),
        "which is why adding one passes the whole-configuration question too"
    )
}

/// The fields with no direction, and the reason each of them has none.
private func testWhatIsNotComparedAtAll() {
    expect(!loosensSettings { $0.name = "Something else" }, "a name blocks nothing")
    expect(!loosensSettings { $0.presetID = nil }, "and a preset label is re-derived after every edit")
    expect(
        !loosensSettings { $0.passcodeForgotStartedAt = ClockReading(wall: noon, uptime: 1_000) },
        "the hour that clears a forgotten code is the lock's own way out, not a setting it guards"
    )
    expect(
        !loosensGroup { $0.groupOrder = [redditGroup, youtubeGroup] },
        "and the order the cards sit in changes nothing about what is blocked"
    )
}

/// A per-group lock answers for its own group and for nothing else — neither the group next door
/// nor the app-wide settings, which a per-group lock holding them would be one group holding the
/// whole app hostage.
private func testAGroupIsOnlyItsOwnBusiness() {
    let base = directionBase()
    var neighbour = base
    neighbour.groupSettings[redditGroup]?.pauseSeconds = 3
    expect(
        !EditDirection.loosens(group: youtubeGroup, from: base, to: neighbour, onDay: directionDay),
        "a shorter pause next door is not this group's loosening"
    )
    expect(
        EditDirection.loosens(group: redditGroup, from: base, to: neighbour, onDay: directionDay),
        "while it is very much that group's"
    )
    var appWide = base
    appWide.dayStartMinutes = 300
    appWide.breakWaitSeconds = 0
    appWide.settingsLock = SettingsLock()
    expect(
        !EditDirection.loosens(group: youtubeGroup, from: base, to: appWide, onDay: directionDay),
        "and moving the start of the day loosens no group at all"
    )
    var arriving = base
    arriving.targets.append(
        Target(kind: .domain, value: "x.com", displayName: "X", groupID: redditGroup)
    )
    expect(
        !EditDirection.loosens(group: redditGroup, from: base, to: arriving, onDay: directionDay),
        "a target arriving is the tightening end of a move"
    )
}

/// A preset writes every knob at once, which makes it the one edit whose direction is not obvious
/// from the control that made it.
private func testAPresetIsAsStrictAsTheKnobsItWrites() {
    let base = directionBase()
    func onPreset(_ id: String, over config: Config) -> Config {
        var edited = config
        edited.groupSettings[youtubeGroup] = ConfigBuilder.settings(
            forPreset: config.presets.first { $0.id == id },
            current: config.groupSettings[youtubeGroup] ?? .standard
        )
        return edited
    }
    var plain = base
    plain.groupSettings[youtubeGroup]?.dailyMinutes = nil
    expect(
        !EditDirection.loosens(
            group: youtubeGroup, from: plain,
            to: onPreset(NamedPreset.strictID, over: plain), onDay: directionDay
        ),
        "Strict over Standard's knobs blocks harder in every row, so it goes through"
    )
    let strict = onPreset(NamedPreset.strictID, over: plain)
    expect(
        EditDirection.loosens(
            group: youtubeGroup, from: strict,
            to: onPreset(NamedPreset.gentleID, over: strict), onDay: directionDay
        ),
        "and Gentle over Strict hands most of them back, so it is held"
    )
    // The case the label hides: a preset has an opinion about the daily limit, and none of the
    // three seeded ones sets it. Put on a group that has one, Strict takes it away — so the same
    // preset that tightens six knobs is a loosening because of the seventh.
    expect(
        EditDirection.loosens(
            group: youtubeGroup, from: base,
            to: onPreset(NamedPreset.strictID, over: base), onDay: directionDay
        ),
        "and Strict over a group with a daily limit clears the limit, which is held"
    )
}

/// The app-wide half: the two the old table froze, and the frictions that have arrived since.
private func testTheAppsOwnSettings() {
    let base = directionBase()
    func loosensGlobally(_ change: (inout Config) -> Void) -> Bool {
        var edited = base
        change(&edited)
        return EditDirection.loosensGlobals(from: base, to: edited)
    }
    expect(!loosensGlobally { _ in }, "an edit that changes nothing takes nothing away")
    expect(
        loosensGlobally { $0.dayStartMinutes = 300 },
        "the start of the day hands a budget back moved later"
    )
    expect(
        loosensGlobally { $0.dayStartMinutes = 60 },
        "and moved earlier, which is why it is frozen in both directions"
    )
    expect(
        loosensGlobally { $0.preventTimeChange = false },
        "switching the clock guard off is the loosening"
    )
    expect(
        !loosensGlobally { $0.preventTimeChange = true },
        "and it is already on, so setting it changes nothing"
    )
    expect(
        !loosensGlobally { $0.breakWaitSeconds = 120 },
        "a longer wait in front of the Unblock card is more friction"
    )
    expect(loosensGlobally { $0.breakWaitSeconds = 0 }, "and cutting it is a break arriving sooner")
    expect(
        !loosensGlobally { $0.settingsLock.timerMinutes = 60 },
        "raising the app-wide wait goes through"
    )
    expect(loosensGlobally { $0.settingsLock.timerMinutes = 1 }, "lowering it is held")
    expect(loosensGlobally { $0.settingsLock.timerMinutes = nil }, "and switching it off with it")
    expect(
        !loosensGlobally { $0.settingsLock.passcode = PasscodeHash.make("1234") },
        "a passcode may be set where none was"
    )
    expect(
        !loosensGlobally { $0.settingsLock.coversQuickDisable = true },
        "asking for it in front of a break as well is more friction"
    )
    expect(
        !loosensGlobally { $0.settingsLock.allowForgot = false },
        "and giving up the hour that clears it is the user taking their own way out away"
    )
    expect(
        !loosensGlobally { $0.showsMenuBarCountdown = false },
        "what the menu bar shows loosens nothing"
    )
    expect(
        !loosensGlobally { $0.expiryWarningSeconds = nil },
        "and neither does the heads-up before a relock"
    )
    var coded = base
    coded.settingsLock = SettingsLock(
        timerMinutes: 10, passcode: PasscodeHash.make("1234"), coversQuickDisable: true
    )
    var undone = coded
    undone.settingsLock.passcode = nil
    expect(
        EditDirection.loosensGlobals(from: coded, to: undone), "taking the passcode away is held"
    )
    undone = coded
    undone.settingsLock.coversQuickDisable = false
    expect(
        EditDirection.loosensGlobals(from: coded, to: undone),
        "and so is taking the question off the break"
    )
}

/// The whole-configuration question is the globals plus every group, which is what the app-wide
/// lock is asked and what makes it the wider of the two.
private func testTheWholeConfigurationIsTheGroupsPlusTheGlobals() {
    let base = directionBase()
    var group = base
    group.groupSettings[redditGroup]?.pauseSeconds = 1
    expect(
        EditDirection.loosens(from: base, to: group, onDay: directionDay),
        "a group loosened anywhere loosens the configuration"
    )
    expect(
        !EditDirection.loosens(group: youtubeGroup, from: base, to: group, onDay: directionDay),
        "while the group next door is untouched by it"
    )
    var globals = base
    globals.dayStartMinutes = 300
    expect(EditDirection.loosens(from: base, to: globals, onDay: directionDay), "and so does an app-wide field")
    var tighter = base
    tighter.groupSettings[youtubeGroup]?.pauseSeconds = 60
    tighter.groupSettings[redditGroup]?.opensPerDay = 1
    tighter.settingsLock.timerMinutes = 240
    expect(
        !EditDirection.loosens(from: base, to: tighter, onDay: directionDay),
        "an edit that tightens everywhere at once takes nothing away"
    )
}
