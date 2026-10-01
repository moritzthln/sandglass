import SandglassAppCore
import SandglassCore
import Foundation

/// The four ways past a group's own lock: two that must not be ways at all, and two that must.
///
/// The other half of `GroupLockEditTests`, and the half a lock is actually judged by. A lock that
/// holds every edit on the group's own page is still no lock if a switch somewhere else undoes it
/// — so the two **side doors** are here: the control that turns every group off, and the category
/// a locked group carries. Both reach into a locked group from a page that is not its own, and
/// both are the kind of thing nobody thinks to check.
///
/// The two **escapes** are the opposite: a group door with no way past a forgotten code is a
/// reinstall, and the week's emergency pass has to reach everything — unless the group has said
/// the pass does not apply to it, which is the case the last three exist for.
///
/// Fixtures — `twoGroupConfig`, `locked`, `categoryConfig` — are `GroupLockEditTests`'s, shared
/// the way they are already shared with `GroupLockTests`.
@MainActor
func runGroupLockEscapeTests() {
    testTheAllGroupsSwitchLeavesALockedGroupAloneAndSaysSo()
    testACategoryThatShrinksALockedGroupAsksForItsCode()
    testTheForgotFlowClearsThePasscodeAndCanBeCalledOff()
    testAnEmergencyPassLiftsTheDoorTheTimerAndBothSideDoors()
    testAGroupThatIgnoresThePassIsLeftAloneByIt()
    testPassImmunityGoesOnAndNotOffWhileALockStands()
}

/// Why one group is blocked this second, straight off the rows the sidebar and the popover draw —
/// so a case about blocking is asserted on the value the screens actually read.
@MainActor
private func blockReason(_ state: AppState, _ groupID: String) -> BlockReason? {
    state.budgetsByGroup.first { $0.id == groupID }?.reason
}

/// Side door one. A control that switched every group off would otherwise undo every per-group
/// lock in the app with one press.
@MainActor
private func testTheAllGroupsSwitchLeavesALockedGroupAloneAndSaysSo() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(
            state.applyConfigEdit(locked(twoGroupConfig(), group: youtubeGroup, minutes: 30)),
            "one of the two groups is locked"
        )
        state.settingsWindowOpened()

        expectEqual(
            AllGroupsSwitch.caption(state.allGroupsSwitch),
            "1 group will go off. 1 group with a lock on it is left alone.",
            "the row says what the press will leave behind, before it is pressed"
        )
        let said = state.switchAllGroups()
        expect(!said.refused, "the press is not refused whole")
        expectEqual(
            said.text, "1 group switched off. 1 group with a lock on it was left alone.",
            "and reports the same thing afterwards"
        )
        expect(
            state.config.groupSettings[youtubeGroup]?.enabled == true,
            "the locked group is still on"
        )
        expect(
            state.config.groupSettings[redditGroup]?.enabled == false, "and the other one is off"
        )
        expectEqual(
            state.config.switchedOffTogether, [redditGroup],
            "and only the one that moved is remembered"
        )

        // The way back is an edit to the group too, so a lock holds it there as well: "editable
        // unless a lock is there" is not a direction.
        var alsoLocked = state.config
        alsoLocked.switchedOffTogether = [redditGroup]
        expectNil(state.applyConfigEdit(alsoLocked), "nothing changed")
    }
}

/// Side door two. Unticking a category is an edit to the group; emptying the category is not, and
/// it is the one that would have lifted the blocks quietly.
@MainActor
private func testACategoryThatShrinksALockedGroupAsksForItsCode() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(
            state.applyConfigEdit(locked(categoryConfig(), group: youtubeGroup, passcode: "1234")),
            "the group carrying the list is locked"
        )
        state.settingsWindowOpened()

        var grown = state.config
        grown.categories[0].domains.append("x.com")
        expectNil(state.applyConfigEdit(grown), "growing the list is free")
        expectEqual(state.config.categories[0].domains.count, 3, "and it grew")

        var shrunk = state.config
        shrunk.categories[0].domains = ["instagram.com"]
        expectEqual(
            state.applyConfigEdit(shrunk), "Enter the passcode for Social to change it",
            "taking one out asks for the group's own code"
        )
        expectEqual(state.config.categories[0].domains.count, 3, "and the list is untouched")

        expect(state.unlockGroup(youtubeGroup, passcode: "1234"), "the code is entered")
        expectNil(state.applyConfigEdit(shrunk), "and then the list may shrink")
        expectEqual(state.config.categories[0].domains, ["instagram.com"], "which it does")
    }
}

/// The escape. A group door with no way past a forgotten code is a reinstall, which is worse than
/// having no lock at all.
@MainActor
private func testTheForgotFlowClearsThePasscodeAndCanBeCalledOff() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(locked(twoGroupConfig(), group: youtubeGroup, passcode: "1234")),
            "the group has a code nobody remembers"
        )
        state.settingsWindowOpened()

        expectNil(state.setGroupPasscodeReset(youtubeGroup, running: true), "the hour is started")
        expectEqual(state.groupLockStates[youtubeGroup]?.resetSeconds, 3_600, "and it counts")

        clock.advance(seconds: 1_800)
        state.tickForTesting()
        expectEqual(state.groupLockStates[youtubeGroup]?.resetSeconds, 1_800, "half an hour later, half left")
        expect(
            state.config.groupSettings[youtubeGroup]?.passcode != nil, "the code is still there"
        )

        expectNil(state.setGroupPasscodeReset(youtubeGroup, running: false), "and it can be called off")
        expectNil(state.groupLockStates[youtubeGroup]?.resetSeconds, "the countdown stops")
        clock.advance(seconds: 3_600)
        state.tickForTesting()
        expect(
            state.config.groupSettings[youtubeGroup]?.passcode != nil,
            "and an hour later the code is still there, because nothing was waiting"
        )

        expectNil(state.setGroupPasscodeReset(youtubeGroup, running: true), "started again")
        clock.advance(seconds: 3_601)
        state.tickForTesting()
        expectNil(
            state.config.groupSettings[youtubeGroup]?.passcode, "the hour clears the passcode"
        )
        expectNil(
            state.config.groupSettings[youtubeGroup]?.passcodeForgotStartedAt,
            "and the wait goes with it"
        )
        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == false,
            "and the page is open again"
        )
    }
}

/// The other escape, and the one that has to reach everything: a running pass lifts the door, the
/// timer and both side doors.
@MainActor
private func testAnEmergencyPassLiftsTheDoorTheTimerAndBothSideDoors() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        var config = locked(categoryConfig(), group: youtubeGroup, minutes: 60, passcode: "1234")
        config.groupSettings[redditGroup]?.lockMinutes = 60
        expectNil(state.applyConfigEdit(config), "both groups are locked, one of them twice over")
        state.settingsWindowOpened()

        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == true, "the door is shut"
        )
        expect(state.useEmergencyPass(), "the week's pass is spent")

        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == false,
            "the door is open"
        )
        expectNil(state.groupLockStates[youtubeGroup]?.unlockSeconds, "the timer has let go")

        var edit = state.config
        edit.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectNil(state.applyConfigEdit(edit), "an edit goes through")

        var shrunk = state.config
        shrunk.categories[0].domains = []
        expectNil(state.applyConfigEdit(shrunk), "so does emptying a list the group carries")

        expectEqual(
            AllGroupsSwitch.caption(state.allGroupsSwitch), "2 groups will go off.",
            "and the all-at-once switch stops leaving anything behind"
        )
        let said = state.switchAllGroups()
        expectEqual(said.text, "2 groups switched off.", "which it then does")
    }
}

/// The same hour over a group that has opted out of it: **the pass does nothing to it at all.**
///
/// The case the whole toggle exists for, asked of the whole app rather than of the gate: its blocks
/// stand, its door stays shut, its wait goes on counting, and the all-at-once switch goes on
/// leaving it where it is — while the group next door unblocks, opens and is swept up exactly as
/// before. And the pass is spent all the same, which is the half nobody would guess.
@MainActor
private func testAGroupThatIgnoresThePassIsLeftAloneByIt() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        let allDay = strictWindow(weekdays: TimeWindow.everyDay, from: 0, to: 24 * 60)
        var config = locked(twoGroupConfig(), group: youtubeGroup, minutes: 60, passcode: "1234")
        config.groupSettings[youtubeGroup]?.ignoresAppWideUnblocks = true
        config.groupSettings[youtubeGroup]?.timeWindows = [allDay]
        config.groupSettings[redditGroup]?.lockMinutes = 60
        config.groupSettings[redditGroup]?.timeWindows = [allDay]
        expectNil(state.applyConfigEdit(config), "both groups are locked and blocked around the clock")
        state.settingsWindowOpened()

        expectEqual(blockReason(state, youtubeGroup), .schedule, "the immune group is blocked")
        expect(state.useEmergencyPass(), "and the week's pass is spent")

        expectEqual(
            blockReason(state, youtubeGroup), .schedule,
            "its blocks stand — which is the reason somebody switches this on"
        )
        expectNil(
            blockReason(state, redditGroup),
            "while the group that never asked to be left alone unblocks"
        )
        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == true,
            "its door stays shut"
        )
        expectEqual(
            state.groupLockStates[redditGroup]?.unlockSeconds, nil,
            "the other group's wait has let go"
        )

        var loosened = state.config
        loosened.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectEqual(
            state.applyConfigEdit(loosened), "Enter the passcode for Social to change it",
            "and an edit that would make it easier is refused by the lock the pass did not lift"
        )
        var neighbour = state.config
        neighbour.groupSettings[redditGroup]?.pauseSeconds = 3
        expectNil(state.applyConfigEdit(neighbour), "the same edit next door goes through")

        expectEqual(
            AllGroupsSwitch.caption(state.allGroupsSwitch),
            "1 group will go off. 1 group with a lock on it is left alone.",
            "and the all-at-once switch still leaves the held one where it is"
        )
        expect(!state.emergencyPassAvailable, "the week's pass is spent, whatever it reached")
        expectEqual(
            state.emergencyPassLine, "Unblocked until 13:00, except the groups that ignore it",
            "and the line about it stops claiming everything is open"
        )
    }
}

/// The direction, on the toggle itself: **on goes through a running lock, off is held by it.**
///
/// Switching it on takes the week's one way out away from this group, which is the user making
/// their own commitment harder — the lock rule covers it without needing a case of its own,
/// the way it covers adding a passcode. Switching it off hands the escape back, which is a
/// loosening and is exactly what the lock is standing there for.
@MainActor
private func testPassImmunityGoesOnAndNotOffWhileALockStands() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(locked(twoGroupConfig(), group: youtubeGroup, minutes: 10)),
            "the lock goes on while nothing is holding the group"
        )
        state.settingsWindowOpened()

        var immune = state.config
        immune.groupSettings[youtubeGroup]?.ignoresAppWideUnblocks = true
        expectNil(state.applyConfigEdit(immune), "putting the group out of the pass's reach passes")
        expect(
            state.config.groupSettings[youtubeGroup]?.ignoresAppWideUnblocks == true,
            "and it is on"
        )

        var reachable = state.config
        reachable.groupSettings[youtubeGroup]?.ignoresAppWideUnblocks = false
        expectEqual(
            state.applyConfigEdit(reachable), "Held by the lock on Social",
            "taking it back off is the loosening, and the running wait holds it"
        )
        expect(
            state.config.groupSettings[youtubeGroup]?.ignoresAppWideUnblocks == true, "nothing moved"
        )

        clock.advance(seconds: 601)
        state.tickForTesting()
        expectNil(
            state.applyConfigEdit(reachable), "when the wait runs out it can be taken off again"
        )
        expect(
            state.config.groupSettings[youtubeGroup]?.ignoresAppWideUnblocks == false, "and it is off"
        )
    }
}
