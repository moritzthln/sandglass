import SandglassAppCore
import SandglassCore
import Foundation

/// One control that switches every group off, and back on again.
///
/// Nearly every case here is about the same promise: **the way back must not switch on a group
/// that was already off**. Everything else — a group deleted, a group added, a group switched on
/// by hand while the rest are off — is that promise asked under a world that moved, and the
/// answers all fall out of recording what the switch *changed* rather than what happens to be off.
///
/// The strict-window half is checked twice over. Here it is the arithmetic, with the held groups
/// handed in; `runAppStateTests` drives the same case through a real engine with a window actually
/// standing, which is the only thing that proves the plan and the lock agree.
func runAllGroupsSwitchTests() {
    testSwitchingOffTakesEveryGroupThatIsOn()
    testAGroupThatWasAlreadyOffIsNeitherTouchedNorRemembered()
    testTheWayBackPutsBackExactlyWhatWentOff()
    testAGroupDeletedWhileEverythingIsOffIsWalkedPast()
    testDeletingAGroupAlsoTakesItOutOfTheList()
    testAGroupAddedWhileEverythingIsOffIsLeftAlone()
    testAGroupSwitchedOnByHandIsNotSwitchedOffOnTheWayBack()
    testTheWayBackEmptiesTheListEvenWithNothingLeftToDo()
    testALockLeavesTheGroupsItHolds()
    testALockOnEveryGroupThatIsOnLeavesNothingToDo()
    testThereIsNothingToDoWithNoGroupsAtAll()
    testThereIsNothingToDoWhenEveryGroupIsAlreadyOff()
    testTheListIsSortedSoTwoRunsWriteTheSameBytes()
    testTheListSurvivesASaveAndALoad()
    testTheButtonSaysHowMuchItWillMove()
    testAPartialPressNeverReadsAsDone()
    testTheWayBackNamesWhatItLeavesAlone()

    // Every `AppState` is MainActor-isolated, and this executable's main thread is that actor's
    // executor — the same assertion `runQuickDisableLockTests` makes, for the same reason.
    MainActor.assumeIsolated {
        testAStandingLockHoldsItsOwnGroupAndLetsTheRestGo()
        testTheWayBackIsAllowedWithTheLockStillStanding()
    testTheWayBackSweepsUpAGroupLockedWhileItWasOff()
        testAFocusSessionRefusesNothingAndGoesOnBlocking()
        testTheWayBackSurvivesARelaunch()
    }
}

// MARK: - Fixtures

/// Four groups, all switched on, and nothing off from the switch: where most of these start.
private func fourGroups() -> Config {
    Config(
        version: 1,
        targets: [],
        groupSettings: ["grp:a": .standard, "grp:b": .standard, "grp:c": .standard, "grp:d": .standard]
    )
}

private func switchingOff(_ config: Config, locked: Set<String> = []) -> Config {
    guard let edited = AllGroupsSwitch.edit(for: config, locked: locked).config else {
        failTest("there was nothing to switch off")
        return config
    }
    return edited
}

private func isOn(_ config: Config, _ groupID: String) -> Bool? {
    config.groupSettings[groupID]?.enabled
}

private func plan(_ config: Config, locked: Set<String> = []) -> AllGroupsSwitch.Plan {
    AllGroupsSwitch.plan(for: config, locked: locked)
}

// MARK: - Off, and back

private func testSwitchingOffTakesEveryGroupThatIsOn() {
    let off = switchingOff(fourGroups())

    expect(
        off.groupSettings.values.allSatisfy { !$0.enabled }, "every group is switched off"
    )
    expectEqual(
        off.switchedOffTogether, ["grp:a", "grp:b", "grp:c", "grp:d"],
        "and every one of them is written down as this switch's doing"
    )
    expectEqual(AllGroupsSwitch.direction(in: off), .on, "so the next press is the way back")
}

/// The case the whole feature turns on. A group the user disabled last week is not one this
/// switched off a minute ago, and recording what is *off* rather than what *changed* would lose
/// the difference on the very first press.
private func testAGroupThatWasAlreadyOffIsNeitherTouchedNorRemembered() {
    var config = fourGroups()
    config.groupSettings["grp:b"]?.enabled = false

    let before = plan(config)
    expectEqual(before.moving, 3, "three groups are on, and those are the three that move")
    expectEqual(before.untouched, 1, "the fourth is off already and is nobody's business here")

    let off = switchingOff(config)
    expectEqual(
        off.switchedOffTogether, ["grp:a", "grp:c", "grp:d"],
        "so only the three that were changed are written down"
    )
}

private func testTheWayBackPutsBackExactlyWhatWentOff() {
    var config = fourGroups()
    config.groupSettings["grp:b"]?.enabled = false
    let off = switchingOff(config)

    guard let back = AllGroupsSwitch.edit(for: off, locked: []).config else {
        failTest("there was nothing to switch back on")
        return
    }
    expectEqual(isOn(back, "grp:a"), true, "the groups this switched off come back on")
    expectEqual(isOn(back, "grp:c"), true, "all of them")
    expectEqual(isOn(back, "grp:d"), true, "every one")
    expectEqual(
        isOn(back, "grp:b"), false,
        "and the one the user had switched off themselves is still off"
    )
    expect(back.switchedOffTogether.isEmpty, "with nothing left off from here")
    expectEqual(AllGroupsSwitch.direction(in: back), .off, "so the next press switches off again")
}

// MARK: - The world moving while everything is off

/// An id that names nothing must not make the way back wrong, and must not make it fail. This is
/// what a hand-edited `config.json` is safe by, and it is checked without the delete path so that
/// it stands on its own.
private func testAGroupDeletedWhileEverythingIsOffIsWalkedPast() {
    var off = switchingOff(fourGroups())
    off.groupSettings["grp:c"] = nil       // gone, and its id still in the list

    let before = plan(off)
    expectEqual(before.moving, 3, "the three that are still there are the three that move")

    guard let back = AllGroupsSwitch.edit(for: off, locked: []).config else {
        failTest("a list naming a group that is gone stopped the way back")
        return
    }
    expectEqual(isOn(back, "grp:a"), true, "the groups that are still there come back on")
    expectEqual(isOn(back, "grp:b"), true, "all of them")
    expectEqual(isOn(back, "grp:d"), true, "every one")
    expectNil(back.groupSettings["grp:c"], "the deleted one is not conjured back")
    expect(back.switchedOffTogether.isEmpty, "and the list is emptied either way")
}

/// The tidying half: the walking past above is what keeps this honest, and this is what keeps
/// `config.json` from filling up with the names of things that no longer exist.
private func testDeletingAGroupAlsoTakesItOutOfTheList() {
    let off = switchingOff(fourGroups())
    let deleted = ConfigBuilder.removingGroup("grp:c", from: off)

    expectEqual(
        deleted.switchedOffTogether, ["grp:a", "grp:b", "grp:d"],
        "the deleted group stops being one of the groups to put back"
    )
}

/// A group made while the rest are off was made switched on, and nothing here may switch it off:
/// it is not in the list, so the way back does not touch it.
private func testAGroupAddedWhileEverythingIsOffIsLeftAlone() {
    var off = switchingOff(fourGroups())
    let (added, newGroup) = ConfigBuilder.addingGroup(named: "Later", to: off, settings: .standard)
    off = added

    expectEqual(isOn(off, newGroup), true, "the new group is on, as every new group is")
    expectEqual(plan(off).untouched, 0, "and it is not one of the groups that are off")

    guard let back = AllGroupsSwitch.edit(for: off, locked: []).config else {
        failTest("there was nothing to switch back on")
        return
    }
    expectEqual(isOn(back, newGroup), true, "the way back leaves it exactly as it was")
    expectEqual(plan(back).moving, 5, "and it joins the next press like any other group")
}

/// The way back only ever switches things **on**, which is what makes a stale id harmless: the
/// worst it can do is set a switch that is already set.
private func testAGroupSwitchedOnByHandIsNotSwitchedOffOnTheWayBack() {
    var off = switchingOff(fourGroups())
    off.groupSettings["grp:b"]?.enabled = true      // switched on from the sidebar

    expectEqual(plan(off).moving, 3, "three are still off, and three is what the press moves")

    guard let back = AllGroupsSwitch.edit(for: off, locked: []).config else {
        failTest("there was nothing to switch back on")
        return
    }
    expect(back.groupSettings.values.allSatisfy(\.enabled), "everything ends up on")
    expect(back.switchedOffTogether.isEmpty, "and nothing is left off from here")
}

/// Every id switched on by hand, so the press moves nothing — and still has to empty the list,
/// or the button would be stuck offering a way back from a place nobody is any more.
private func testTheWayBackEmptiesTheListEvenWithNothingLeftToDo() {
    var off = switchingOff(fourGroups())
    for id in off.groupSettings.keys { off.groupSettings[id]?.enabled = true }

    let before = plan(off)
    expectEqual(before.moving, 0, "there is nothing left to switch on")
    expect(AllGroupsSwitch.isPressable(before), "and the button can still be pressed")

    guard let back = AllGroupsSwitch.edit(for: off, locked: []).config else {
        failTest("emptying the list was not offered as a change")
        return
    }
    expect(back.switchedOffTogether.isEmpty, "so the list is emptied")
    expectEqual(AllGroupsSwitch.direction(in: back), .off, "and the next press switches off")
}

// MARK: - What a group's own lock refuses

/// Switching a group off is an edit to that group, and a lock refuses those. The rest still go,
/// and the list records only the ones that actually went — so the way back puts back exactly
/// those. A strict window used to be the other holder and is not: a window blocks, and what may be
/// changed is the settings lock's question.
private func testALockLeavesTheGroupsItHolds() {
    let held: Set<String> = ["grp:b", "grp:c"]
    let config = fourGroups()

    let before = plan(config, locked: held)
    expectEqual(before.moving, 2, "two groups can go")
    expectEqual(before.locked, 2, "and two carry a lock of their own")

    let off = switchingOff(config, locked: held)
    expectEqual(isOn(off, "grp:b"), true, "a held group stays on")
    expectEqual(isOn(off, "grp:c"), true, "both of them")
    expectEqual(isOn(off, "grp:a"), false, "and the rest go off")
    expectEqual(
        off.switchedOffTogether, ["grp:a", "grp:d"],
        "with only the ones that went recorded, so the way back puts back exactly those"
    )
}

private func testALockOnEveryGroupThatIsOnLeavesNothingToDo() {
    let config = fourGroups()
    let all = Set(config.groupSettings.keys)

    let before = plan(config, locked: all)
    expectEqual(before.moving, 0, "nothing can move")
    expect(!AllGroupsSwitch.isPressable(before), "so the button cannot be pressed")
    expectNil(
        AllGroupsSwitch.edit(for: config, locked: all).config,
        "and there is nothing to submit"
    )
    expectEqual(
        AllGroupsSwitch.result(before),
        "Nothing switched off: every group that is on has a lock on it.",
        "which is what it would say"
    )
}

// MARK: - Nothing to do

private func testThereIsNothingToDoWithNoGroupsAtAll() {
    let empty = Config(version: 1, targets: [], groupSettings: [:])
    let before = plan(empty)

    expect(!AllGroupsSwitch.isPressable(before), "the button cannot be pressed")
    expectEqual(AllGroupsSwitch.caption(before), "No groups yet.", "and says so before it is")
    expectEqual(
        AllGroupsSwitch.result(before), "Nothing to switch off: there are no groups yet.",
        "and would say so after"
    )
    expectNil(AllGroupsSwitch.edit(for: empty, locked: []).config, "with nothing to submit")
}

private func testThereIsNothingToDoWhenEveryGroupIsAlreadyOff() {
    var config = fourGroups()
    for id in config.groupSettings.keys { config.groupSettings[id]?.enabled = false }

    let before = plan(config)
    expectEqual(before.untouched, 4, "all four are off, and none of them by this switch")
    expect(!AllGroupsSwitch.isPressable(before), "so there is nothing to press")
    expectEqual(
        AllGroupsSwitch.caption(before), "Every group is already off.", "and it says which it is"
    )
    expectEqual(
        AllGroupsSwitch.result(before), "Nothing to switch off: every group is already off.",
        "in both tenses"
    )
}

// MARK: - On disk

/// A `Set` iterates in a per-process random order, and this list is written to `config.json` on
/// every press: unsorted, the same four groups would be written in different bytes every time.
private func testTheListIsSortedSoTwoRunsWriteTheSameBytes() {
    expectEqual(
        switchingOff(fourGroups()).switchedOffTogether,
        switchingOff(fourGroups()).switchedOffTogether,
        "two presses over the same groups write the same list"
    )
    expectEqual(
        switchingOff(fourGroups()).switchedOffTogether.sorted(),
        switchingOff(fourGroups()).switchedOffTogether,
        "and it is sorted"
    )
}

/// The way back has to survive a relaunch: being unable to get back to where you were because the
/// app restarted is the worst version of this feature. The disk half is `runAppStateTests`; this
/// is the document itself.
private func testTheListSurvivesASaveAndALoad() {
    var config = fourGroups()
    config.groupSettings["grp:b"]?.enabled = false
    let off = switchingOff(config)

    guard let bytes = try? SandglassJSON.encoder.encode(off),
          let back = try? SandglassJSON.decoder.decode(Config.self, from: bytes) else {
        failTest("a config with groups off from the switch could not be round-tripped")
        return
    }
    expectEqual(
        back.switchedOffTogether, ["grp:a", "grp:c", "grp:d"],
        "the three this switched off are still named after a save and a load"
    )
    expectEqual(back, off, "and nothing else moved")
}

// MARK: - What the row says

private func testTheButtonSaysHowMuchItWillMove() {
    var config = fourGroups()
    expectEqual(
        AllGroupsSwitch.buttonTitle(plan(config)), "Switch all off",
        "with every group on, all of them go"
    )
    expectEqual(
        AllGroupsSwitch.caption(plan(config)), "4 groups will go off.", "and it says how many"
    )

    config.groupSettings["grp:b"]?.enabled = false
    expectEqual(
        AllGroupsSwitch.buttonTitle(plan(config)), "Switch 3 off",
        "with one already off, the button counts what it will actually move"
    )
    expectEqual(
        AllGroupsSwitch.caption(plan(config)),
        "3 groups will go off. 1 group already off stays off.",
        "and the one it is leaving alone is named before the press, not after"
    )
}

/// A press that leaves three groups on must not read as "done". The count is the whole of the
/// honesty here: it says what moved, and then what did not and why.
private func testAPartialPressNeverReadsAsDone() {
    let config = fourGroups()
    let before = plan(config, locked: ["grp:b", "grp:c"])

    expectEqual(
        AllGroupsSwitch.buttonTitle(before), "Switch 2 off",
        "the button promises two rather than all"
    )
    expectEqual(
        AllGroupsSwitch.caption(before),
        "2 groups will go off. 2 groups with a lock on them are left alone.",
        "and says out loud which two will not"
    )
    expectEqual(
        AllGroupsSwitch.result(before),
        "2 groups switched off. 2 groups with a lock on them were left alone.",
        "and afterwards it reports the same two facts rather than claiming the lot"
    )
}

private func testTheWayBackNamesWhatItLeavesAlone() {
    var config = fourGroups()
    config.groupSettings["grp:b"]?.enabled = false
    let after = plan(switchingOff(config))

    expectEqual(
        AllGroupsSwitch.buttonTitle(after), "Switch 3 back on", "the way back counts too"
    )
    expectEqual(
        AllGroupsSwitch.caption(after),
        "3 groups switched off from here. 1 group you switched off yourself stays off.",
        "and promises the one it will not touch before it is pressed"
    )
    expectEqual(
        AllGroupsSwitch.result(after),
        "3 groups switched back on. 1 group you switched off yourself was left off.",
        "and reports it afterwards"
    )
}

// MARK: - Through the real engine

/// Two groups: YouTube with a lock of its own, Reddit with nothing. The lock is what a switch-off
/// is refused for; Reddit is what still goes.
private func oneHeldOneFree() -> Config {
    let held = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let free = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
    var locked = GroupSettings.standard
    locked.lockMinutes = 30
    return Config(
        version: 1,
        targets: [held, free],
        groupSettings: [held.groupID: locked, free.groupID: .standard]
    )
}

/// The refusal that must not become a loophole, driven end to end. Nothing here works out for
/// itself what a lock forbids: the edit goes through `applyConfigEdit`, so a plan that had it
/// wrong would be refused whole and this case would fail rather than quietly switching a locked
/// group off.
@MainActor
private func testAStandingLockHoldsItsOwnGroupAndLetsTheRestGo() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(state.applyConfigEdit(oneHeldOneFree()), "two groups, one of them locked")
        state.settingsWindowOpened()
        expectEqual(state.allGroupsSwitch.locked, 1, "the row knows one is held before the press")
        expectEqual(state.allGroupsSwitch.moving, 1, "and that only the other one can go")

        let said = state.switchAllGroups()
        expect(!said.refused, "the press is not turned away whole")
        expectEqual(
            said.text, "1 group switched off. 1 group with a lock on it was left alone.",
            "and it never reads as done while a group stayed on"
        )
        expectEqual(
            state.config.groupSettings[redditGroup]?.enabled, false,
            "the group no window is holding goes off"
        )
        expectEqual(
            state.config.groupSettings[youtubeGroup]?.enabled, true,
            "the one with a lock on it stays on, which is the refusal working"
        )
        expectEqual(
            state.config.switchedOffTogether, [redditGroup],
            "and only the group that actually went is written down"
        )
    }
}

/// The way back with the same lock still standing. That group never went off, so there is nothing
/// of it to put back, and the rest of the press is untouched.
@MainActor
private func testTheWayBackIsAllowedWithTheLockStillStanding() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(state.applyConfigEdit(oneHeldOneFree()), "two groups, one of them locked")
        state.settingsWindowOpened()
        state.switchAllGroups()

        let said = state.switchAllGroups()
        expect(!said.refused, "the way back is not refused")
        expectEqual(said.text, "1 group switched back on.", "and it says what it put back")
        expectEqual(
            state.config.groupSettings[redditGroup]?.enabled, true, "the group is on again"
        )
        expect(state.config.switchedOffTogether.isEmpty, "with nothing left off from here")
    }
}

/// **The way back is the tightening direction, so it leaves nothing behind.** A lock refuses what
/// loosens; switching a group back on puts a block back, which is the move no lock has ever
/// existed to stop — so a group locked while it was off comes back on with the rest of them, and
/// the row promises no held groups because there are none to promise.
@MainActor
private func testTheWayBackSweepsUpAGroupLockedWhileItWasOff() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        var free = oneHeldOneFree()
        free.groupSettings[youtubeGroup]?.lockMinutes = 0
        expectNil(state.applyConfigEdit(free), "two groups, neither of them locked")
        state.settingsWindowOpened()
        state.switchAllGroups()
        expectEqual(
            state.config.switchedOffTogether.sorted(), [redditGroup, youtubeGroup].sorted(),
            "both go off and both are remembered"
        )

        var locking = state.config
        locking.groupSettings[youtubeGroup]?.lockMinutes = 30
        expectNil(state.applyConfigEdit(locking), "one of them is given a lock while it is off")
        // Armed from the next visit, which is where a lock switched on this visit starts.
        state.settingsWindowClosed()
        state.settingsWindowOpened()
        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 1_800, "and the wait is running"
        )

        expectEqual(state.allGroupsSwitch.locked, 0, "the way back leaves nothing behind")
        expectEqual(
            AllGroupsSwitch.caption(state.allGroupsSwitch),
            "2 groups switched off from here.",
            "and the row says so before the press"
        )
        let said = state.switchAllGroups()
        expect(!said.refused, "the press goes through")
        expectEqual(said.text, "2 groups switched back on.", "and puts both back")
        expectEqual(
            state.config.groupSettings[youtubeGroup]?.enabled, true,
            "the locked group among them — a block going back on is nobody's loosening"
        )
        var off = state.config
        off.groupSettings[youtubeGroup]?.enabled = false
        expectEqual(
            state.applyConfigEdit(off), "Held by the lock on YouTube",
            "while switching that one off by hand is refused, which is the lock still standing"
        )
    }
}

/// A focus session used to refuse the whole press in the engine's own words. It refuses nothing:
/// it blocks apps and websites and holds no setting, so the switch does exactly what it does at
/// any other moment — everything that is not held by a lock of its own goes off, and the block
/// carries on over what is left. See `RulesEngine.updateConfig`.
@MainActor
private func testAFocusSessionRefusesNothingAndGoesOnBlocking() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(state.applyConfigEdit(oneHeldOneFree()), "two groups, one of them locked")
        state.startFocusSession(minutes: 25)

        let said = state.switchAllGroups()
        expect(!said.refused, "the press is not turned away")
        expectEqual(
            said.text, "1 group switched off. 1 group with a lock on it was left alone.",
            "and the only thing left standing is the group's own lock"
        )
        expectEqual(
            state.config.groupSettings[redditGroup]?.enabled, false, "so the free group went off"
        )
        expect(state.focusSessionLine != nil, "with everything still blocked by the session")
    }
}

/// The way back has to survive a relaunch. Being unable to get back to where you were because the
/// app restarted is the worst version of this feature, so the memory goes to disk with the rest of
/// the configuration and a second `AppState` over the same directory finds it.
@MainActor
private func testTheWayBackSurvivesARelaunch() {
    withTempDir { dir in
        var config = oneHeldOneFree()
        // No lock on either group this time: what is being tested is the disk, not the lock.
        config.groupSettings[youtubeGroup] = .standard
        config.groupSettings[youtubeGroup]?.enabled = false      // off by hand, last week

        let first = makeState(dir, clock: FakeClock(noon))
        expectNil(first.applyConfigEdit(config), "one group on, one switched off by hand")
        expectEqual(
            first.switchAllGroups().text, "1 group switched off.", "the one that was on goes off"
        )
        first.stop()

        let second = makeState(dir, clock: FakeClock(noon))
        expectEqual(
            second.config.switchedOffTogether, [redditGroup],
            "a relaunch still knows which group this switched off"
        )
        expectEqual(
            second.allGroupsSwitch.direction, .on, "so the button still offers the way back"
        )
        expectEqual(
            second.switchAllGroups().text,
            "1 group switched back on. 1 group you switched off yourself was left off.",
            "and taking it puts back exactly that one"
        )
        expectEqual(
            second.config.groupSettings[redditGroup]?.enabled, true, "the group comes back on"
        )
        expectEqual(
            second.config.groupSettings[youtubeGroup]?.enabled, false,
            "and the group switched off by hand a week ago is still off, which is the point"
        )
    }
}
