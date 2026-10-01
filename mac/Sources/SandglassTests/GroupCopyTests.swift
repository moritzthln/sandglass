import SandglassAppCore
import SandglassCore
import Foundation

/// Duplicating a group: what a copy carries, what it may never carry, and the two locks it is
/// asked in front of.
///
/// The rule is one function — `ConfigBuilder.duplicatingGroup` — and most of it is about what
/// does *not* come across. A target that travelled would make a document `Store` refuses outright;
/// an id that travelled would make two rows the editor cannot tell apart, and nothing downstream
/// would catch it — `Store` compares window ids within one group and never between two.
func runGroupCopyTests() {
    testACopyCarriesEverythingExceptWhatIsInIt()
    testACopyCarriesNoLockOfItsOwn()
    testACopyMintsEveryIdItCarries()
    testACopyKeepsThePresetItWasOn()
    testACopySitsDirectlyBehindItsSource()
    testASecondCopyCollidesWithNothing()
    testACopyIsNamedAfterWhatTheGroupIsCalled()
    testAGroupWithNoSettingsHasNothingToCopy()
    testACopyNeverJoinsTheAllAtOnceList()
    testACopySurvivesTheDisk()
    // Every `AppState` is MainActor-isolated, and this executable's main thread is that actor's
    // executor — the same assertion `runSettingsLockTests` makes, for the same reason.
    MainActor.assumeIsolated {
        testTheSettingsLockLetsACopyThrough()
        testAStrictWindowOnTheSourceDoesNotStopACopy()
    }
}

// MARK: - Fixtures

/// One group carrying something of every kind: knobs off Strict with a budget of its own, two
/// windows, two rules, a ticked category with a member struck off it — and two targets, which are
/// the one thing a copy may not take.
///
/// The windows are the shared fixtures on purpose: they have **fixed ids**, so a copy that failed
/// to mint its own is visible rather than merely improbable.
private func richConfig() -> Config {
    var settings = GroupSettings.strict
    settings.name = "Social"
    settings.timeWindows = [officeHours, bedtime]
    // Fixed rule ids, for the reason the windows have them: `Rule.init` mints a `UUID` otherwise,
    // and a fixture whose ids differ between two calls cannot be compared with itself.
    settings.rules = [
        Rule(
            id: "rule-shorts", pattern: "shorts", matchType: .websiteOrText, action: .block,
            highPriority: true
        ),
        Rule(
            id: "rule-hn", pattern: "news.ycombinator.com", matchType: .specificPage, action: .allow
        ),
    ]
    settings.categories = ["messaging"]
    settings.categoryExceptions = [Target.id(ofKind: .domain, value: "linkedin.com")]
    settings.dailyMinutes = 45
    settings.ignoresAppWideUnblocks = true
    let youtube = Target(
        kind: .domain, value: "youtube.com", displayName: "YouTube", groupID: "grp:social"
    )
    let notes = Target(
        kind: .app, value: "com.apple.Notes", displayName: "Notes", groupID: "grp:social"
    )
    return Config(version: 1, targets: [youtube, notes], groupSettings: ["grp:social": settings])
}

private func namedGroup(_ name: String) -> GroupSettings {
    var settings = GroupSettings.standard
    settings.name = name
    return settings
}

/// The rich group copied, or a failed check and `nil` — the guard four cases would otherwise
/// spell out identically.
private func copyOfRichConfig(
    _ config: Config = richConfig(), from groupID: String = "grp:social"
) -> (source: GroupSettings, copy: GroupSettings, config: Config, groupID: String)? {
    guard let made = ConfigBuilder.duplicatingGroup(groupID, in: config) else {
        failTest("a group with settings behind it can be copied")
        return nil
    }
    guard let source = made.config.groupSettings[groupID],
          let copied = made.config.groupSettings[made.groupID] else {
        failTest("the copy and the group it came from both have settings")
        return nil
    }
    return (source, copied, made.config, made.groupID)
}

// MARK: - What comes across

/// Every field of `GroupSettings`, asked one at a time. A copy that silently dropped the earn-back
/// switch or the day's minutes would be a group behaving unlike the one it was taken from, and
/// nothing on screen would say which field had gone.
private func testACopyCarriesEverythingExceptWhatIsInIt() {
    guard let made = copyOfRichConfig() else { return }
    expectEqual(made.copy.pauseSeconds, made.source.pauseSeconds, "the pause comes across")
    expectEqual(made.copy.opensPerDay, made.source.opensPerDay, "and the day's opens")
    expectEqual(made.copy.sessionMinutes, made.source.sessionMinutes, "and how long one lasts")
    expectEqual(made.copy.cooldownMinutes, made.source.cooldownMinutes, "and the wait between them")
    expectEqual(made.copy.escalationSeconds, made.source.escalationSeconds, "and the escalation")
    expectEqual(made.copy.earnBackEnabled, made.source.earnBackEnabled, "and the earn-back switch")
    expectEqual(made.copy.dailyMinutes, made.source.dailyMinutes, "and the day's minutes")
    expectEqual(made.copy.enabled, made.source.enabled, "and whether the group is on at all")
    expectEqual(
        TimeWindow.shapes(of: made.copy.timeWindows),
        TimeWindow.shapes(of: made.source.timeWindows),
        "the week comes across window for window"
    )
    expectEqual(
        made.copy.rules.map(\.pattern), made.source.rules.map(\.pattern),
        "the rules come across in the order they were written in, which is the last tie-break"
    )
    expectEqual(
        made.copy.rules.map(\.action), made.source.rules.map(\.action),
        "a block rule copies as a block rule, claiming its pattern from the copy too"
    )
    expectEqual(
        made.copy.rules.map(\.matchType), made.source.rules.map(\.matchType),
        "and each keeps the way it is matched"
    )
    expectEqual(
        made.copy.rules.map(\.highPriority), made.source.rules.map(\.highPriority),
        "and whether it is read before the rest"
    )
    expectEqual(
        made.copy.ignoresAppWideUnblocks, made.source.ignoresAppWideUnblocks,
        "and whether the emergency pass reaches it, which is a setting rather than a lock"
    )
    expectEqual(made.copy.categories, made.source.categories, "the category ticks come across")
    expectEqual(
        made.copy.categoryExceptions, made.source.categoryExceptions,
        "and the members struck off them, without which the copy would block more than the tick meant"
    )
    expectEqual(
        made.config.targets.filter { $0.groupID == made.groupID }, [],
        "and nothing that is in the group: a target belongs to exactly one, and the store enforces it"
    )
    expectEqual(
        made.config.targets, richConfig().targets,
        "so the group it was taken from keeps every one of them"
    )
}

/// **Neither half of a lock crosses**, and the hour running against a forgotten code does not
/// either.
///
/// The one exception to "a copy carries the knobs", and the reason for it is that a lock is
/// configured per group on purpose, deliberately and by hand. Read the other way round, a copy
/// would arrive behind a code somebody would have to remember belongs to two groups, and behind a
/// wait they never chose to sit out; the copy is a new group with nothing in it yet, and deciding a
/// commitment on its behalf is not the app's to do.
///
/// `passcodeForgotStartedAt` goes with them because it is meaningless without the code it clears: a
/// timestamp carried onto a group with no passcode is an hour waiting to clear the *next* one
/// somebody sets.
///
/// **The dated block is on the same list**, for the same reason one step further on: it is a
/// one-shot promise made once, for a reason, about one group. A copy arriving already shut until
/// Monday — and, with a lock somewhere, shut until Monday for good — would be the app making a
/// commitment nobody asked for.
private func testACopyCarriesNoLockOfItsOwn() {
    guard let hash = PasscodeHash.make("2468") else {
        failTest("a four-character passcode hashes")
        return
    }
    var config = richConfig()
    config.groupSettings["grp:social"]?.lockMinutes = 30
    config.groupSettings["grp:social"]?.passcode = hash
    config.groupSettings["grp:social"]?.passcodeForgotStartedAt = ClockReading(
        wall: Date(timeIntervalSince1970: 1_000), uptime: 1_000
    )
    config.groupSettings["grp:social"]?.blockedUntilDay = "2026-08-24"
    guard let made = copyOfRichConfig(config) else { return }
    expectEqual(made.copy.lockMinutes, 0, "the copy carries no wait of its own")
    expectNil(made.copy.passcode, "and no passcode")
    expectNil(made.copy.passcodeForgotStartedAt, "and no hour running against a code it has not got")
    expect(!made.copy.hasOwnLock, "so it reads as a group with no lock on it at all")
    expectNil(made.copy.blockedUntilDay, "nor a day somebody else set aside")
    expectEqual(made.source.lockMinutes, 30, "the group it was taken from keeps its wait")
    expectEqual(made.source.passcode, hash, "and its code")
    expectEqual(made.source.blockedUntilDay, "2026-08-24", "and its date")
}

/// The failure this whole function is written against: a copy sharing an id with its source is one
/// edit away from changing both at once.
private func testACopyMintsEveryIdItCarries() {
    guard let made = copyOfRichConfig() else { return }
    let original = richConfig().groupSettings["grp:social"]
    expect(made.groupID != "grp:social", "the copy is a group of its own")
    expectEqual(
        made.groupID, "grp:social-copy",
        "with a readable id built from what it is called, like every other group id"
    )
    expect(
        Set(made.copy.timeWindows.map(\.id))
            .isDisjoint(with: Set(made.source.timeWindows.map(\.id))),
        "no window id is shared with the source — the editor keys its rows by them"
    )
    expect(
        Set(made.copy.rules.map(\.id)).isDisjoint(with: Set(made.source.rules.map(\.id))),
        "and no rule id is either"
    )
    expectEqual(
        Set(made.copy.timeWindows.map(\.id)).count, 2,
        "and the copy's own two windows do not share one with each other"
    )
    expectEqual(made.source, original, "the group that was copied is left exactly as it was")
}

/// The preset is a label re-derived from the values, so carrying the values carries the label.
/// Both directions are worth pinning: a Standard group copies as Standard, and a group whose
/// knobs match nothing copies as the Custom it is rather than picking up a name on the way.
private func testACopyKeepsThePresetItWasOn() {
    let plain = Config(
        version: 1, targets: [], groupSettings: ["grp:social": namedGroup("Social")]
    )
    guard let made = copyOfRichConfig(plain) else { return }
    expectEqual(
        ConfigBuilder.presetID(matching: made.copy, in: made.config.presets),
        NamedPreset.standardID,
        "a copy of a Standard group reads as Standard"
    )
    expectEqual(
        made.copy.presetID, made.source.presetID,
        "and carries the stored marker across, so the file says what the screen says"
    )

    guard let rich = copyOfRichConfig() else { return }
    expectNil(
        ConfigBuilder.presetID(matching: rich.copy, in: rich.config.presets),
        "and a copy of a group whose knobs match no preset is Custom, exactly as the source is"
    )
}

// MARK: - Where it lands

/// Next to the group it came from, so the copy is the next card down rather than something to hunt
/// for at the bottom of a long sidebar.
private func testACopySitsDirectlyBehindItsSource() {
    let unarranged = Config(
        version: 1,
        targets: [],
        groupSettings: [
            "grp:alpha": namedGroup("Alpha"),
            "grp:beta": namedGroup("Beta"),
            "grp:gamma": namedGroup("Gamma"),
        ]
    )
    guard let first = ConfigBuilder.duplicatingGroup("grp:alpha", in: unarranged) else {
        failTest("the first group copies")
        return
    }
    expectEqual(
        ConfigBuilder.groupOrder(in: first.config),
        ["grp:alpha", "grp:alpha-copy", "grp:beta", "grp:gamma"],
        "with no order recorded at all, the copy still lands directly behind its source"
    )
    expectEqual(
        first.config.groupOrder,
        ["grp:alpha", "grp:alpha-copy", "grp:beta", "grp:gamma"],
        "and the whole healed order is what is written back, as one drag already does"
    )

    var arranged = unarranged
    arranged.groupOrder = ["grp:gamma", "grp:alpha", "grp:beta"]
    guard let second = ConfigBuilder.duplicatingGroup("grp:gamma", in: arranged) else {
        failTest("the arranged group copies")
        return
    }
    expectEqual(
        ConfigBuilder.groupOrder(in: second.config),
        ["grp:gamma", "grp:gamma-copy", "grp:alpha", "grp:beta"],
        "and an order the user arranged is kept, with the copy behind the row it came from"
    )
}

/// Names are display strings and ids are separate, so the collision to avoid is the one on screen:
/// two sidebar cards both reading "Social copy".
private func testASecondCopyCollidesWithNothing() {
    let config = Config(
        version: 1, targets: [], groupSettings: ["grp:social": namedGroup("Social")]
    )
    guard let first = ConfigBuilder.duplicatingGroup("grp:social", in: config),
          let second = ConfigBuilder.duplicatingGroup("grp:social", in: first.config),
          let third = ConfigBuilder.duplicatingGroup("grp:social", in: second.config) else {
        failTest("a group can be copied three times")
        return
    }
    expectEqual(
        third.config.groupSettings[first.groupID]?.name, "Social copy", "the first is “Social copy”"
    )
    expectEqual(
        third.config.groupSettings[second.groupID]?.name, "Social copy 2", "the second is numbered"
    )
    expectEqual(
        third.config.groupSettings[third.groupID]?.name, "Social copy 3", "and so is the third"
    )
    expectEqual(
        [first.groupID, second.groupID, third.groupID],
        ["grp:social-copy", "grp:social-copy-2", "grp:social-copy-3"],
        "and each answers to an id of its own"
    )
    expectEqual(
        ConfigBuilder.groupOrder(in: third.config),
        ["grp:social", third.groupID, second.groupID, first.groupID],
        "each landing directly behind the group it was taken from, so the newest is nearest to it"
    )
}

/// A group with no stored name is called after the first thing in it. The copy has nothing in it,
/// so it has to be given that name outright or it would come out called after its own raw id.
private func testACopyIsNamedAfterWhatTheGroupIsCalled() {
    let youtube = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let config = Config(
        version: 1, targets: [youtube], groupSettings: [youtube.groupID: .standard]
    )
    guard let made = copyOfRichConfig(config, from: youtube.groupID) else { return }
    expectNil(made.source.name, "the group it came from still has no name of its own")
    expectEqual(
        made.copy.name, "YouTube copy",
        "so the copy takes the name the source is shown under rather than the one it has stored"
    )
    expectEqual(
        ConfigBuilder.groups(in: made.config).map(\.name), ["YouTube", "YouTube copy"],
        "and the sidebar reads as two rows rather than one and a raw id"
    )
}

/// The degenerate group the sidebar calls "No settings": in the targets, missing from
/// `groupSettings`, `.notManaged` everywhere the engine looks.
///
/// There is nothing to copy. Everything a copy carries lives on `GroupSettings`, including the
/// name — such a group is called after its first target — and targets do not travel. What would
/// come out is a group with no settings, no targets and no name, which `groups(in:)` does not list
/// at all: a button press that produces nothing anybody can see. So the answer is `nil`, and the
/// editor does not offer the button there, for the reason it offers neither the pencil nor the
/// preset picker.
private func testAGroupWithNoSettingsHasNothingToCopy() {
    let orphan = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
    let config = Config(version: 1, targets: [orphan], groupSettings: [:])
    expectNil(
        ConfigBuilder.duplicatingGroup(orphan.groupID, in: config),
        "a group the engine does not manage has nothing a copy could carry"
    )
    expectNil(
        ConfigBuilder.duplicatingGroup("grp:nothing", in: config),
        "and neither has a group that is not in the document at all"
    )
}

/// `switchedOffTogether` records what the all-at-once switch turned off, so that the way back
/// leaves the groups the user switched off by hand alone. Nothing turned the copy off — it was
/// made this second — so it is not on the list, whatever state it was copied in.
private func testACopyNeverJoinsTheAllAtOnceList() {
    var config = richConfig()
    config.switchedOffTogether = ["grp:social"]
    config.groupSettings["grp:social"]?.enabled = false
    guard let made = copyOfRichConfig(config) else { return }
    expectEqual(
        made.config.switchedOffTogether, ["grp:social"],
        "the copy is not among the groups the all-at-once switch turned off"
    )
    expect(
        !(made.copy.enabled),
        "though it is switched off all the same, because that is what the group it came from is"
    )
}

/// A document with a copy in it is one the store accepts and gives back unchanged. The two
/// invariants `Store` enforces are exactly the two a careless copy would break: no target id
/// twice, and no window id twice inside one group.
private func testACopySurvivesTheDisk() {
    withTempDir { dir in
        let store = Store(directory: dir)
        guard let made = copyOfRichConfig() else { return }
        expectNoThrow("a document holding a copy is one the store accepts") {
            try store.saveConfig(made.config)
        }
        guard let loaded = store.loadConfig() else {
            failTest("the document comes back off disk")
            return
        }
        expectEqual(loaded, made.config, "unchanged, byte for byte in every field")
        guard let copied = loaded.groupSettings[made.groupID] else {
            failTest("the copy is in the document that came back")
            return
        }
        expectEqual(copied.timeWindows.count, 2, "with both of its windows")
        expectEqual(copied.rules.count, 2, "and both of its rules")
        expectEqual(copied.name, "Social copy", "under a name of its own")
        expectEqual(
            loaded.targets.filter { $0.groupID == made.groupID }, [],
            "and nothing in it, which is what made the document savable at all"
        )
    }
}

// MARK: - Through the real engine

/// The settings lock lets a copy through, and it is right to. A copy is a **new group** rather
/// than a loosening of an old one: the original keeps every knob, every window and every target it
/// had, and the copy arrives carrying no targets and none of the original's lock. The lock's rule
/// is about the direction of an edit, not about the window it was made in — see `EditDirection`.
///
/// It used to be refused, back when a lock held every change made while it stood. That was the
/// half of the rule that was wrong at first, and this is the case where the correction reads oddest at
/// first: nothing about a copy makes anything easier, so nothing about it is the lock's business.
@MainActor
private func testTheSettingsLockLetsACopyThrough() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(lockedConfig(timerMinutes: 10)), "switching the timer on")

        state.settingsWindowOpened()
        expectEqual(state.settingsLockState.unlockSeconds, 600, "the visit starts locked")
        guard let made = ConfigBuilder.duplicatingGroup(youtubeGroup, in: state.config) else {
            failTest("the locked configuration's one group can be copied")
            return
        }
        expectNil(state.applyConfigEdit(made.config), "the copy goes through while the timer runs")
        expectEqual(state.config.groupSettings.count, 2, "and the copy is in the document")
        expectEqual(
            state.config.groupSettings[youtubeGroup], lockedConfig(timerMinutes: 10)
                .groupSettings[youtubeGroup],
            "with the group it was taken from exactly as it was"
        )

        // The other direction, from the same visit and the same lock: deleting the copy hands
        // something back, so it waits.
        expect(
            state.applyConfigEdit(
                ConfigBuilder.removingGroup(made.groupID, from: state.config)
            ) != nil,
            "while deleting it again is refused"
        )
        clock.advance(seconds: 600)
        state.tickForTesting()
        expectNil(state.settingsLockState.unlockSeconds, "ten minutes later the wait is over")
        expectNil(
            state.applyConfigEdit(
                ConfigBuilder.removingGroup(made.groupID, from: state.config)
            ),
            "and the copy can be deleted"
        )
        expectEqual(state.config.groupSettings.count, 1, "leaving the one group behind")
    }
}

/// A strict window on the *source* is not a reason to refuse a copy, and never was the only
/// reason it might have been: nothing about the source changes.
///
/// The block is checked first, so this cannot pass by the window being closed or the group being
/// unmanaged.
@MainActor
private func testAStrictWindowOnTheSourceDoesNotStopACopy() {
    withTempDir { dir in
        // Monday noon, inside the office-hours window the group is about to be given.
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
        let config = Config(
            version: 1, targets: [target],
            groupSettings: [target.groupID: standardSettings(windows: [officeHours])]
        )
        expectNil(state.applyConfigEdit(config), "the window is drawn while nothing is blocking yet")
        expectEqual(
            state.budgetsByGroup.first?.reason, .schedule,
            "and the window is genuinely standing over the group"
        )

        guard let made = ConfigBuilder.duplicatingGroup(target.groupID, in: state.config) else {
            failTest("the blocked group can be copied")
            return
        }
        expectNil(
            state.applyConfigEdit(made.config),
            "and copying it goes through — nothing about the group inside the window changes"
        )
        expectEqual(state.config.groupSettings.count, 2, "the copy is in the document")
        expectEqual(
            state.config.groupSettings[made.groupID]?.timeWindows.count, 1,
            "carrying the window, so it starts life inside a strict window of its own"
        )
        expectEqual(
            state.config.targets.count, 1, "and the copy carries no target of its own"
        )
    }
}
