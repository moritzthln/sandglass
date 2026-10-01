import SandglassAppCore
import SandglassCore
import Foundation

/// The third layer of a group's own lock: the whole app refusing a real edit.
///
/// `GroupLockTests` checks what an edit touches and what the gate says about it; this checks that
/// the gate is actually asked, on the one path every screen writes through —
/// `AppState.applyConfigEdit`. Every case here is judged against the lock rule: **every setting
/// is editable unless a lock is there.**
///
/// The lock standing is what this half is about — the wait, the door, the direction, and the lock
/// as a setting like any other. The ways past it are the other half, in
/// `GroupLockEscapeTests`: the two side doors that would have opened a locked group without
/// touching it, and the two escapes that are meant to. The fixtures below are shared with both,
/// and with `GroupLockTests`.
@MainActor
func runGroupLockEditTests() {
    testTheTimerHoldsEveryEditToItsOwnGroupAndReleasesIt()
    testSwitchingAGroupsTimerOnLeavesTheVisitThatSwitchedItFree()
    testFreshMinutesArmOnLeavingTheGroupsPage()
    testClosingTheWindowArmsAFreshWaitToo()
    testThePasscodeGatesThePageOncePerVisit()
    testACodedGroupsCountdownRunsBehindItsDoor()
    testALockHoldsWhatLoosensAndNothingElse()
    testTheLockItselfMayOnlyBeTightenedWhileItStands()
    testWhicheverOfTheTwoWaitsIsLongerHoldsTheGroup()
}

// MARK: - Fixtures

// Shared with `GroupLockTests`, which is why they are not file-scoped: `private` does not reach
// across files, and one set of fixtures is what keeps the two halves about the same groups.

/// Two groups, so "this group's lock" can be told from "every group's". Neither has a window:
/// the whole point of the per-group lock is that it holds without one.
func twoGroupConfig() -> Config {
    let youtube = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let reddit = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
    var social = GroupSettings.standard
    social.name = "Social"
    var news = GroupSettings.standard
    news.name = "News"
    return Config(
        version: 1,
        targets: [youtube, reddit],
        groupSettings: [youtube.groupID: social, reddit.groupID: news]
    )
}

func locked(
    _ config: Config, group groupID: String, minutes: Int = 0, passcode: String? = nil
) -> Config {
    var updated = config
    updated.groupSettings[groupID]?.lockMinutes = minutes
    updated.groupSettings[groupID]?.passcode = passcode.flatMap(PasscodeHash.make)
    return updated
}

/// One category, carried by the first group, holding two sites.
func categoryConfig() -> Config {
    var config = twoGroupConfig()
    config.categories = [
        DistractionCategory(
            id: "social", name: "Social", domains: ["instagram.com", "tiktok.com"], bundleIDs: []
        )
    ]
    config.groupSettings[youtubeGroup]?.categories = ["social"]
    return config
}



/// The timer holds every edit to its own group and lets go when it runs out — and holds nothing
/// else in the app while it does.
@MainActor
private func testTheTimerHoldsEveryEditToItsOwnGroupAndReleasesIt() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(locked(twoGroupConfig(), group: youtubeGroup, minutes: 10)),
            "a group can be given a lock while nothing is holding it"
        )
        state.settingsWindowOpened()

        var loosened = state.config
        loosened.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectEqual(
            state.applyConfigEdit(loosened), "Held by the lock on Social",
            "and then the lock refuses an edit to it"
        )
        expectEqual(state.config.groupSettings[youtubeGroup]?.pauseSeconds, 10, "nothing moved")

        var off = state.config
        off.groupSettings[youtubeGroup]?.enabled = false
        expectEqual(
            state.applyConfigEdit(off), "Held by the lock on Social", "the switch is held too"
        )
        expectEqual(
            state.applyConfigEdit(ConfigBuilder.removingGroup(youtubeGroup, from: state.config)),
            "Held by the lock on Social", "and so is the trash button"
        )

        // The group next door is nobody else's business, which is the whole point of a lock per
        // group: the rest of the app stays freely editable.
        var neighbour = state.config
        neighbour.groupSettings[redditGroup]?.pauseSeconds = 3
        expectNil(state.applyConfigEdit(neighbour), "the other group is editable throughout")
        var appWide = state.config
        appWide.breakWaitSeconds = 0
        expectNil(state.applyConfigEdit(appWide), "and so are the app's own settings")

        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 600,
            "the editor is told how long is left"
        )
        clock.advance(seconds: 601)
        state.tickForTesting()
        expectNil(state.groupLockStates[youtubeGroup]?.unlockSeconds, "the wait runs out")

        var again = state.config
        again.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectNil(state.applyConfigEdit(again), "and the edit goes through")
        expectEqual(state.config.groupSettings[youtubeGroup]?.pauseSeconds, 3, "with the number moved")
    }
}

/// The app-wide rule, one scope down: the visit that gives a group a lock is not held by that
/// group's fresh timer — while a group that was locked before the window opened is held as ever.
///
/// Both halves matter. Without the first, switching the stepper off nought landed the default and
/// then froze the stepper that chose it; without the second, a lock would be one edit away from
/// being no lock at all.
@MainActor
private func testSwitchingAGroupsTimerOnLeavesTheVisitThatSwitchedItFree() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(
            state.applyConfigEdit(locked(twoGroupConfig(), group: redditGroup, minutes: 10)),
            "News is locked before anybody opens the window"
        )
        state.settingsWindowOpened()

        var arming = state.config
        arming.groupSettings[youtubeGroup]?.lockMinutes = 10
        expectNil(state.applyConfigEdit(arming), "Social is given a lock halfway through the visit")
        expectNil(
            state.groupLockStates[youtubeGroup]?.unlockSeconds,
            "and its editor is not counting down at the visit that gave it one"
        )
        expect(
            EditorFreeze.notices(
                lock: state.settingsLockState, groupLock: state.groupLockStates[youtubeGroup],
                focusSessionLine: nil
            ).isEmpty,
            "so the page is not banded with a notice saying nothing on it can change"
        )

        var longer = state.config
        longer.groupSettings[youtubeGroup]?.lockMinutes = 45
        expectNil(state.applyConfigEdit(longer), "the duration is free to pick")
        expectEqual(
            state.config.groupSettings[youtubeGroup]?.lockMinutes, 45, "and forty-five landed"
        )

        var neighbour = state.config
        neighbour.groupSettings[redditGroup]?.lockMinutes = 0
        expectEqual(
            state.applyConfigEdit(neighbour), "Held by the lock on News",
            "while the group that was already locked is held exactly as it was"
        )

        state.settingsWindowClosed()
        state.settingsWindowOpened()
        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 2700,
            "the next visit arms it, for the length that was chosen"
        )
        var removing = state.config
        removing.groupSettings[youtubeGroup]?.lockMinutes = 0
        expectEqual(
            state.applyConfigEdit(removing), "Held by the lock on Social",
            "and taking it off costs the wait, which is what the lock is for"
        )
    }
}

/// Fresh minutes arm as the user walks away from the stepper that set them — and count from
/// there — rather than at the next visit to the window.
///
/// Setting the minutes must not lock straight away, because the user is still setting them — it
/// takes hold when they switch groups. The exemption is there so
/// nobody is locked out of the control they are standing at; waiting for the whole window to close
/// left the group open for the rest of a visit that might last an hour.
@MainActor
private func testFreshMinutesArmOnLeavingTheGroupsPage() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(twoGroupConfig()), "two groups, neither of them locked")
        state.settingsWindowOpened()

        var arming = state.config
        arming.groupSettings[youtubeGroup]?.lockMinutes = 10
        expectNil(state.applyConfigEdit(arming), "the wait is switched on halfway through a visit")
        expectNil(
            state.groupLockStates[youtubeGroup]?.unlockSeconds,
            "and nothing holds the page it was set on"
        )
        clock.advance(seconds: 120)
        state.tickForTesting()
        var longer = state.config
        longer.groupSettings[youtubeGroup]?.lockMinutes = 30
        expectNil(state.applyConfigEdit(longer), "two minutes of picking a length, still free")
        var shorter = state.config
        shorter.groupSettings[youtubeGroup]?.lockMinutes = 15
        expectNil(
            state.applyConfigEdit(shorter),
            "and back down again, because nothing has armed to hold it"
        )

        state.settingsGroupLeft(youtubeGroup)
        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 900,
            "stepping away arms it, at the full length rather than at what is left of the visit"
        )
        clock.advance(seconds: 300)
        state.tickForTesting()
        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 600,
            "counting from the step away rather than from the window, which is seven minutes older"
        )
        var undo = state.config
        undo.groupSettings[youtubeGroup]?.lockMinutes = 0
        expectEqual(
            state.applyConfigEdit(undo), "Held by the lock on Social",
            "and the wait now holds the stepper that set it"
        )

        // Coming back to the page changes nothing, and leaving it again does not restart the wait.
        state.settingsGroupLeft(youtubeGroup)
        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 600,
            "leaving a second time is not a second arming"
        )
        clock.advance(seconds: 601)
        state.tickForTesting()
        expectNil(state.applyConfigEdit(undo), "ten minutes after the step away it lets go")
    }
}

/// The other end of the same rule: the window closing arms it too, and the wait is then owed in
/// full at the next open rather than burnt down while nothing was on screen.
///
/// Arming it to run with no window open would be the opposite of a lock — close the window, wait,
/// come back free — and it is the fault Rule 2 had just fixed one scope up.
@MainActor
private func testClosingTheWindowArmsAFreshWaitToo() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(state.applyConfigEdit(twoGroupConfig()), "two groups, neither of them locked")
        state.settingsWindowOpened()

        var arming = state.config
        arming.groupSettings[youtubeGroup]?.lockMinutes = 10
        expectNil(state.applyConfigEdit(arming), "the wait is switched on")
        // Away from the page and the window in one move, which is what quitting the settings
        // window from a group's own page is.
        state.settingsWindowClosed()
        clock.advance(seconds: 3_600)
        state.settingsWindowOpened()
        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 600,
            "an hour away does not spend the wait: it is owed in full at the next open"
        )
        var undo = state.config
        undo.groupSettings[youtubeGroup]?.lockMinutes = 0
        expectEqual(
            state.applyConfigEdit(undo), "Held by the lock on Social", "which is what holds it"
        )
    }
}

/// The door: the page does not open, and one code opens one group for one visit.
@MainActor
private func testThePasscodeGatesThePageOncePerVisit() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        var both = locked(twoGroupConfig(), group: youtubeGroup, passcode: "1234")
        both.groupSettings[redditGroup]?.passcode = PasscodeHash.make("5678")
        expectNil(state.applyConfigEdit(both), "both groups get a code")
        state.settingsWindowOpened()

        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == true,
            "the group's page is shut"
        )
        expect(
            !state.unlockGroup(youtubeGroup, passcode: "0000"), "a wrong code opens nothing"
        )
        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == true, "and leaves it shut"
        )
        var edit = state.config
        edit.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectEqual(
            state.applyConfigEdit(edit), "Enter the passcode for Social to change it",
            "and an edit that got past the door anyway is refused in the same words"
        )

        expect(state.unlockGroup(youtubeGroup, passcode: "1234"), "the right one opens it")
        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == false, "the page is readable"
        )
        expectNil(state.applyConfigEdit(edit), "and the edit goes through")
        expect(
            state.groupLockStates[redditGroup]?.passcodeRequired == true,
            "the group next door is still shut — the answer bought one group"
        )

        state.settingsWindowClosed()
        state.settingsWindowOpened()
        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == true,
            "and the next visit asks again"
        )
    }
}

/// A group carrying **both** halves of a lock: the door first, then the wait, then the whole page.
///
/// When a passcode is required, the time only starts going down once the code has been entered.
/// Counted from the window opening, the wait ran behind a shut door and was usually
/// spent before anybody typed the code — so a group with the strongest lock in the app was the one
/// the app held for the shortest time.
///
/// The three rules composed, in the order somebody actually meets them: the door is answered, the
/// countdown starts, loosening is held and tightening free while it runs, and then everything is
/// free for the rest of the visit.
@MainActor
private func testACodedGroupsCountdownRunsBehindItsDoor() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(
                locked(twoGroupConfig(), group: youtubeGroup, minutes: 10, passcode: "1234")
            ),
            "the group gets both halves of a lock"
        )
        state.settingsWindowClosed()
        state.settingsWindowOpened()

        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == true, "the door is shut"
        )
        expectNil(
            state.groupLockStates[youtubeGroup]?.unlockSeconds,
            "and nothing is counting down behind it"
        )
        clock.advance(seconds: 1_200)
        state.tickForTesting()
        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == true,
            "twenty minutes of a shut door leave it shut"
        )
        var loosening = state.config
        loosening.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectEqual(
            state.applyConfigEdit(loosening), "Enter the passcode for Social to change it",
            "and the ten-minute wait has not been spent by them"
        )

        expect(state.unlockGroup(youtubeGroup, passcode: "1234"), "the code is entered")
        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 600,
            "and the wait starts there, at its full length"
        )
        expectEqual(
            state.applyConfigEdit(loosening), "Held by the lock on Social",
            "a shorter pause is held by the wait now, not by the door"
        )
        var tightening = state.config
        tightening.groupSettings[youtubeGroup]?.pauseSeconds = 60
        expectNil(state.applyConfigEdit(tightening), "while a longer one goes through")

        clock.advance(seconds: 300)
        state.tickForTesting()
        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 300, "five minutes on, five left"
        )
        clock.advance(seconds: 301)
        state.tickForTesting()
        expectNil(state.groupLockStates[youtubeGroup]?.unlockSeconds, "then it lets go")
        expectNil(
            state.applyConfigEdit(loosening),
            "and everything is free for the rest of the visit, in both directions"
        )

        // A group with a wait and no code is untouched by any of this: there is no other moment
        // for its countdown to start from than the window opening.
        state.settingsWindowClosed()
        var plain = state.config
        plain.groupSettings[redditGroup]?.lockMinutes = 10
        expectNil(state.applyConfigEdit(plain), "the group next door is given a wait alone")
        state.settingsWindowOpened()
        expectEqual(
            state.groupLockStates[redditGroup]?.unlockSeconds, 600,
            "which counts from the window, as it always has"
        )
    }
}

/// The lock rule, in the case the first build of this got backwards: **a lock is a direction
/// test.** Making the group stricter goes through while it stands, and only the move that hands
/// something back is refused.
///
/// In full: making things stricter must always work, only making them looser is held — apps and
/// websites can be added, a passcode can be added, and so on. Every clause of that sentence is one
/// line below, checked through the real app, and each is followed by its reverse.
@MainActor
private func testALockHoldsWhatLoosensAndNothingElse() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(
            state.applyConfigEdit(locked(twoGroupConfig(), group: youtubeGroup, minutes: 30)),
            "the group is locked"
        )
        state.settingsWindowOpened()

        var stricter = state.config
        stricter.groupSettings[youtubeGroup]?.pauseSeconds = 60
        stricter.groupSettings[youtubeGroup]?.opensPerDay = 1
        expectNil(state.applyConfigEdit(stricter), "a longer wait and a smaller budget go through")
        expectEqual(
            state.config.groupSettings[youtubeGroup]?.pauseSeconds, 60, "and the wait is longer"
        )
        var blocked = state.config
        blocked.groupSettings[youtubeGroup]?.timeWindows = [officeHours]
        expectNil(state.applyConfigEdit(blocked), "so does drawing a hard block over it")
        var site = state.config
        site.targets.append(
            Target(kind: .domain, value: "x.com", displayName: "X", groupID: youtubeGroup)
        )
        expectNil(state.applyConfigEdit(site), "so does putting one more site in")

        // The other half, from the same lock and the same visit.
        var shorter = state.config
        shorter.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectEqual(
            state.applyConfigEdit(shorter), "Held by the lock on Social",
            "a shorter wait is held"
        )
        var fewer = state.config
        fewer.targets.removeAll { $0.groupID == youtubeGroup }
        expectEqual(
            state.applyConfigEdit(fewer), "Held by the lock on Social", "so is taking the site out"
        )
        var open = state.config
        open.groupSettings[youtubeGroup]?.timeWindows = []
        expectEqual(
            state.applyConfigEdit(open), "Held by the lock on Social",
            "so is deleting the block that was just drawn"
        )
        var free = state.config
        free.groupSettings[youtubeGroup]?.timeWindows = [
            officeHours, window(.break, weekdays: [2], from: 600, to: 660)
        ]
        expectEqual(
            state.applyConfigEdit(free), "Held by the lock on Social",
            "and so is cutting a break into the week, which is the one window that opens time"
        )

        // Last, because it changes what the page is: a passcode may be put on a group a wait is
        // already holding — the rule's own example — and from that second the door is what
        // answers, since nobody has entered a code that did not exist a moment ago.
        var coded = state.config
        coded.groupSettings[youtubeGroup]?.passcode = PasscodeHash.make("1234")
        expectNil(state.applyConfigEdit(coded), "putting a passcode on top goes through")
        expect(
            state.groupLockStates[youtubeGroup]?.passcodeRequired == true,
            "and the door it just made is shut"
        )
        expectEqual(
            state.applyConfigEdit(shorter), "Enter the passcode for Social to change it",
            "so the loosening that was held by the wait is now held by the code"
        )
    }
}

/// "Where the global timer is also set, the longer holds for this group" — which falls out of
/// asking both, in that order.
@MainActor
private func testWhicheverOfTheTwoWaitsIsLongerHoldsTheGroup() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        var config = locked(twoGroupConfig(), group: youtubeGroup, minutes: 20)
        config.settingsLock = SettingsLock(timerMinutes: 5)
        expectNil(state.applyConfigEdit(config), "the app waits five minutes and the group twenty")
        state.settingsWindowOpened()

        var edit = state.config
        edit.groupSettings[youtubeGroup]?.pauseSeconds = 3
        expectEqual(
            state.applyConfigEdit(edit), "Held by the settings lock",
            "the wider lock answers first while it is running"
        )
        clock.advance(seconds: 301)
        state.tickForTesting()
        expectNil(state.settingsLockState.unlockSeconds, "the app-wide wait runs out")

        var neighbour = state.config
        neighbour.groupSettings[redditGroup]?.pauseSeconds = 3
        expectNil(state.applyConfigEdit(neighbour), "and the rest of the app is editable")
        expectEqual(
            state.applyConfigEdit(edit), "Held by the lock on Social",
            "while this group is still held by its own — the longer of the two"
        )

        clock.advance(seconds: 900)
        state.tickForTesting()
        expectNil(state.applyConfigEdit(edit), "and it lets go when that one is over too")

        // The other way round: the app-wide wait outlasts a short one on the group.
        var shorter = state.config
        shorter.groupSettings[youtubeGroup]?.lockMinutes = 1
        shorter.settingsLock = SettingsLock(timerMinutes: 60)
        expectNil(state.applyConfigEdit(shorter), "one minute on the group, an hour on the app")
        state.settingsWindowClosed()
        state.settingsWindowOpened()
        clock.advance(seconds: 120)
        state.tickForTesting()
        expectNil(state.groupLockStates[youtubeGroup]?.unlockSeconds, "the group's own has let go")
        var last = state.config
        last.groupSettings[youtubeGroup]?.pauseSeconds = 1
        expectEqual(
            state.applyConfigEdit(last), "Held by the settings lock",
            "and the app-wide one holds it for the rest of the hour"
        )
    }
}

/// The lock is a setting on the page like any other, so it moves the way the rest of them do
/// while it stands: **longer passes, shorter and off are held**, and a passcode may be put on top
/// of a running wait but never taken off or swapped.
///
/// Otherwise the way to remove a lock would be to remove it.
@MainActor
private func testTheLockItselfMayOnlyBeTightenedWhileItStands() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectNil(
            state.applyConfigEdit(locked(twoGroupConfig(), group: youtubeGroup, minutes: 10)),
            "the first lock goes on while nothing is holding the group"
        )
        state.settingsWindowOpened()

        var removing = state.config
        removing.groupSettings[youtubeGroup]?.lockMinutes = 0
        expectEqual(
            state.applyConfigEdit(removing), "Held by the lock on Social",
            "and cannot be taken off again while it stands"
        )
        var shortening = state.config
        shortening.groupSettings[youtubeGroup]?.lockMinutes = 1
        expectEqual(
            state.applyConfigEdit(shortening), "Held by the lock on Social", "nor shortened"
        )
        var raising = state.config
        raising.groupSettings[youtubeGroup]?.lockMinutes = 240
        expectNil(state.applyConfigEdit(raising), "but it may be made longer")
        expectEqual(
            state.groupLockStates[youtubeGroup]?.unlockSeconds, 14_400,
            "and the wait that is running grows with it, from the same window open"
        )

        clock.advance(seconds: 14_401)
        state.tickForTesting()
        var undone = state.config
        undone.groupSettings[youtubeGroup]?.lockMinutes = 0
        expectNil(state.applyConfigEdit(undone), "when it runs out the lock can be taken off")
        expectEqual(state.config.groupSettings[youtubeGroup]?.lockMinutes, 0, "and it is off")
    }
}
