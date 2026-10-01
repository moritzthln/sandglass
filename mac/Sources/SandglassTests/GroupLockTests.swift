import SandglassAppCore
import SandglassCore
import Foundation

/// A group's own lock: a wait of its own, a passcode of its own, and the rule every case below is
/// judged against — **every setting is editable unless a lock is there, and a lock holds only what
/// loosens.**
///
/// The middle layer, in the order a fault would hide in: which waits an edit starts, and what the
/// gate then refuses. Which way an edit moves a group is `EditDirectionTests`, one layer below;
/// the whole app refusing a real edit is `GroupLockEditTests`, one above, and it is the one that
/// matters most — a gate that refuses correctly and is never asked would pass every check here.
func runGroupLockTests() {
    testATimerSwitchedOnIsToldFromOneThatWasAlreadyThere()
    testTheForgottenHourIsAnHour()
    testAStaleWaitOnAGroupWithNoPasscodeCountsNothing()
    testTheGateRefusesThenPermits()
    testTheVisitThatSwitchesAGroupsTimerOnIsNotHeldByIt()
    testAFreshWaitArmsWhenItsPageIsLeft()
    testArmingOutranksTheCodeWhereAGroupCarriesBoth()
    testTheGateAsksOncePerVisitPerGroup()
    testACodedGroupsWaitCountsFromTheCodeRatherThanTheWindow()
    testAnUnannouncedWindowIsRefusedInFull()
    testTheDoorSaysWhichGroupIsAskingAndHowPastIt()
    testAPassLiftsAGroupsLockUnlessTheGroupSaysOtherwise()
    testAnImmuneGroupsDoorDoesNotOfferThePass()
    testTheBandCountsTheLongerOfTheTwoWaits()
    testTheBandOverAGroupSaysTheSameSentenceForEitherLock()
    testAGroupWithoutALockStillDecodes()
    testALockedGroupSurvivesTheDisk()
}

// MARK: - What an edit starts

/// Which groups a visit is let off, and it is only ever the ones whose wait it started.
///
/// The list behind "the visit that switches a group's timer on is not held by that group's fresh
/// timer". Everything else about the lock is untouched, so this has to be able to tell a wait
/// being **started** from a wait being changed — changing one is exactly what the wait is there
/// to hold.
private func testATimerSwitchedOnIsToldFromOneThatWasAlreadyThere() {
    let base = twoGroupConfig()
    expect(
        GroupLocks.timersSwitchedOn(from: base, to: base).isEmpty,
        "an edit that changes nothing switches nothing on"
    )

    let armed = locked(base, group: youtubeGroup, minutes: 10)
    expectEqual(
        GroupLocks.timersSwitchedOn(from: base, to: armed), [youtubeGroup],
        "nought to ten minutes is the switch-on this exists for, and it names that group only"
    )

    var longer = armed
    longer.groupSettings[youtubeGroup]?.lockMinutes = 240
    expect(
        GroupLocks.timersSwitchedOn(from: armed, to: longer).isEmpty,
        "raising a wait that is already there is not starting one — it is what the wait holds"
    )

    var off = armed
    off.groupSettings[youtubeGroup]?.lockMinutes = 0
    expect(
        GroupLocks.timersSwitchedOn(from: armed, to: off).isEmpty,
        "and nor is taking one away, which costs the wait one last time"
    )

    let coded = locked(base, group: youtubeGroup, minutes: 0, passcode: "1234")
    expect(
        GroupLocks.timersSwitchedOn(from: base, to: coded).isEmpty,
        "a passcode is the other friction, answered rather than waited out"
    )

    // A group that did not exist a moment ago has no wait behind it to have sat out.
    var born = base
    var settings = GroupSettings.standard
    settings.lockMinutes = 30
    born.groupSettings["grp:new"] = settings
    expectEqual(
        GroupLocks.timersSwitchedOn(from: base, to: born), ["grp:new"],
        "a group created with a lock on it switched that lock on"
    )
}

// MARK: - The hour that clears a forgotten code

private func testTheForgottenHourIsAnHour() {
    var settings = GroupSettings.standard
    settings.passcode = PasscodeHash.make("2468")
    let start = ClockReading(wall: noon, uptime: 1_000)
    settings.passcodeForgotStartedAt = start

    let almost = ClockReading(wall: noon.addingTimeInterval(3_540), uptime: 4_540)
    expectEqual(settings.passcodeForgotSecondsLeft(at: almost), 60, "a minute left after 59")
    expect(!settings.passcodeForgotIsDue(at: almost), "and it is not due yet")

    let due = ClockReading(wall: noon.addingTimeInterval(3_600), uptime: 4_600)
    expectNil(settings.passcodeForgotSecondsLeft(at: due), "the hour runs out")
    expect(settings.passcodeForgotIsDue(at: due), "and the passcode is the app's to clear")

    // The clock cannot buy any of it: an hour measured on the wall would be over the moment
    // somebody set the date forward.
    let wound = ClockReading(wall: noon.addingTimeInterval(36_000), uptime: 1_100)
    expectEqual(settings.passcodeForgotSecondsLeft(at: wound), 3_500, "winding the clock buys nothing")

    var cleared = settings
    expect(cleared.clearForgottenPasscode(at: due), "the hour being up is a change")
    expectNil(cleared.passcode, "the passcode goes")
    expectNil(cleared.passcodeForgotStartedAt, "and the wait goes with it")
    expect(!cleared.clearForgottenPasscode(at: due), "and a second sweep finds nothing to do")
}

private func testAStaleWaitOnAGroupWithNoPasscodeCountsNothing() {
    var settings = GroupSettings.standard
    settings.passcodeForgotStartedAt = ClockReading(wall: noon, uptime: 1_000)
    let due = ClockReading(wall: noon.addingTimeInterval(7_200), uptime: 8_200)
    expectNil(settings.passcodeForgotSecondsLeft(at: due), "a wait with nothing to clear counts nothing")
    expect(!settings.passcodeForgotIsDue(at: due), "and is never due")
    var swept = settings
    expect(!swept.clearForgottenPasscode(at: due), "so nothing is cleared")
    expect(swept.passcodeForgotStartedAt != nil, "and the timestamp is left where it is")
}

// MARK: - The gate, on its own

private func testTheGateRefusesThenPermits() {
    var gate = GroupLockGate()
    var settings = GroupSettings.standard
    settings.lockMinutes = 10
    let opened = ClockReading(wall: noon, uptime: 100)
    gate.windowOpened(at: opened)

    let refusal = gate.refusal(
        for: settings, groupID: "grp", at: opened, emergencyPassRunning: false
    )
    expectEqual(refusal, .timer(secondsLeft: 600), "the whole wait is owed at the door")
    expectEqual(
        refusal?.text(groupNamed: "Social"), "Held by the lock on Social",
        "and the refusal names the group rather than a number"
    )

    let halfway = ClockReading(wall: noon.addingTimeInterval(300), uptime: 400)
    expectEqual(
        gate.refusal(for: settings, groupID: "grp", at: halfway, emergencyPassRunning: false),
        .timer(secondsLeft: 300), "half of it later, half of it is left"
    )
    let after = ClockReading(wall: noon.addingTimeInterval(601), uptime: 701)
    expectNil(
        gate.refusal(for: settings, groupID: "grp", at: after, emergencyPassRunning: false),
        "and it lets go when it runs out"
    )
    expectNil(
        gate.state(for: settings, groupID: "grp", at: after, emergencyPassRunning: false).unlockSeconds,
        "the editor stops counting with it"
    )

    // A second call must not restart it: clicking Settings again brings the window forward.
    gate.windowOpened(at: after)
    expectNil(
        gate.refusal(for: settings, groupID: "grp", at: after, emergencyPassRunning: false),
        "asking for a window that is already open does not put the wait back to full"
    )
    gate.windowClosed()
    gate.windowOpened(at: after)
    expectEqual(
        gate.refusal(for: settings, groupID: "grp", at: after, emergencyPassRunning: false),
        .timer(secondsLeft: 600), "a new visit owes it again"
    )
}

/// The app-wide rule, one scope down: the visit that switches a group's timer on is not held by
/// that group's fresh timer — and the exemption is per group, like everything else here.
private func testTheVisitThatSwitchesAGroupsTimerOnIsNotHeldByIt() {
    var gate = GroupLockGate()
    var settings = GroupSettings.standard
    settings.lockMinutes = 10
    let opened = ClockReading(wall: noon, uptime: 100)
    gate.windowOpened(at: opened)
    gate.timerSwitchedOn(forGroup: "social")

    expectNil(
        gate.refusal(for: settings, groupID: "social", at: opened, emergencyPassRunning: false),
        "the visit that switched it on is free to change it"
    )
    expectNil(
        gate.state(for: settings, groupID: "social", at: opened, emergencyPassRunning: false)
            .unlockSeconds,
        "and the editor is not counting down at them while they pick a length"
    )
    expectEqual(
        gate.refusal(for: settings, groupID: "news", at: opened, emergencyPassRunning: false),
        .timer(secondsLeft: 600),
        "and it buys nothing at all for the group next door"
    )
    expect(
        gate.heldGroups(
            in: locked(twoGroupConfig(), group: youtubeGroup, minutes: 10), at: opened,
            emergencyPassRunning: false
        ) == [youtubeGroup],
        "a group nobody switched on this visit is held, and the all-at-once switch is told so"
    )

    gate.windowClosed()
    gate.windowOpened(at: opened)
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: opened, emergencyPassRunning: false),
        .timer(secondsLeft: 600),
        "the next visit is held for the whole of what was chosen"
    )

    // A mark left with no window open earns nothing, for the reason the app-wide one earns
    // nothing: an exemption is a fact about a visit. The all-at-once switch is what would
    // notice — it asks from wherever it is pressed, window or no window.
    var unopened = GroupLockGate()
    unopened.timerSwitchedOn(forGroup: "social")
    expectEqual(
        unopened.refusal(for: settings, groupID: "social", at: opened, emergencyPassRunning: false),
        .timer(secondsLeft: 600),
        "a lock switched on with no window open is owed whole, mark or no mark"
    )
}

/// A wait switched on this visit arms when its page is left, and counts from there.
///
/// The refined exemption: setting the minutes must not lock straight away, because the user is
/// still setting them — it takes hold when they switch groups.
private func testAFreshWaitArmsWhenItsPageIsLeft() {
    var gate = GroupLockGate()
    var settings = GroupSettings.standard
    settings.lockMinutes = 10
    let opened = ClockReading(wall: noon, uptime: 100)
    gate.windowOpened(at: opened)
    gate.timerSwitchedOn(forGroup: "social")

    let picking = ClockReading(wall: noon.addingTimeInterval(120), uptime: 220)
    expectNil(
        gate.refusal(for: settings, groupID: "social", at: picking, emergencyPassRunning: false),
        "two minutes at the stepper and nothing is holding it"
    )
    gate.leftGroup("social", at: picking)
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: picking, emergencyPassRunning: false),
        .timer(secondsLeft: 600),
        "stepping away arms it, at its full length rather than at what is left of the visit"
    )
    let later = ClockReading(wall: noon.addingTimeInterval(420), uptime: 520)
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: later, emergencyPassRunning: false),
        .timer(secondsLeft: 300),
        "and it counts from the step away rather than from the window, which is five minutes older"
    )
    // Coming back to the page changes nothing: the wait armed once and goes on running.
    gate.leftGroup("social", at: later)
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: later, emergencyPassRunning: false),
        .timer(secondsLeft: 300), "leaving it a second time does not put the wait back to full"
    )
    let over = ClockReading(wall: noon.addingTimeInterval(721), uptime: 821)
    expectNil(
        gate.refusal(for: settings, groupID: "social", at: over, emergencyPassRunning: false),
        "and it lets go ten minutes after the step away"
    )

    // Leaving the page of a group nobody armed this visit changes nothing about it: its countdown
    // has been running since the window opened.
    gate.leftGroup("news", at: later)
    expectEqual(
        gate.refusal(for: settings, groupID: "news", at: later, emergencyPassRunning: false),
        .timer(secondsLeft: 180),
        "the group next door counts from the window, and leaving its page does not restart it"
    )

    // The window going away is the other end of it: the exemption goes, and the wait is owed in
    // full at the next open. Arming it to burn down with no window open would be the opposite of
    // a lock — close the window, wait, come back free.
    var fresh = GroupLockGate()
    fresh.windowOpened(at: opened)
    fresh.timerSwitchedOn(forGroup: "social")
    fresh.windowClosed()
    let reopened = ClockReading(wall: noon.addingTimeInterval(3_600), uptime: 3_700)
    fresh.windowOpened(at: reopened)
    expectEqual(
        fresh.refusal(for: settings, groupID: "social", at: reopened, emergencyPassRunning: false),
        .timer(secondsLeft: 600), "an hour away does not spend the wait"
    )
}

/// All three rules on one group, in the order somebody meets them — and the tie-break between the
/// last two: **arming outranks the code**, because it is the later and the more specific fact.
///
/// A wait set at noon and armed at 12:02 starts at 12:02, whether or not the door was answered at
/// 11:58. Read the other way round, a group whose code was entered early in a visit would find its
/// fresh wait already half spent by the time it armed.
private func testArmingOutranksTheCodeWhereAGroupCarriesBoth() {
    var settings = GroupSettings.standard
    settings.lockMinutes = 10
    settings.passcode = PasscodeHash.make("1234")
    var gate = GroupLockGate()
    let opened = ClockReading(wall: noon, uptime: 100)
    gate.windowOpened(at: opened)

    expect(
        gate.accept(passcode: "1234", forGroup: "social", settings: settings, at: opened),
        "the door is answered as the visit begins"
    )
    gate.timerSwitchedOn(forGroup: "social")
    let picking = ClockReading(wall: noon.addingTimeInterval(120), uptime: 220)
    expectNil(
        gate.refusal(for: settings, groupID: "social", at: picking, emergencyPassRunning: false),
        "and the wait set behind it holds nothing while its page is open"
    )
    gate.leftGroup("social", at: picking)
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: picking, emergencyPassRunning: false),
        .timer(secondsLeft: 600),
        "the step away arms it, two minutes after the code rather than at the code"
    )
    let over = ClockReading(wall: noon.addingTimeInterval(721), uptime: 821)
    expectNil(
        gate.refusal(for: settings, groupID: "social", at: over, emergencyPassRunning: false),
        "so it lets go ten minutes after the step away, not ten after the code"
    )
}

private func testTheGateAsksOncePerVisitPerGroup() {
    var gate = GroupLockGate()
    var social = GroupSettings.standard
    social.passcode = PasscodeHash.make("1234")
    var news = GroupSettings.standard
    news.passcode = PasscodeHash.make("5678")
    let now = ClockReading(wall: noon, uptime: 100)
    gate.windowOpened(at: now)

    expectEqual(
        gate.refusal(for: social, groupID: "social", at: now, emergencyPassRunning: false),
        .passcode, "the code is owed"
    )
    expect(
        !gate.accept(passcode: "0000", forGroup: "social", settings: social, at: now),
        "a wrong one opens nothing"
    )
    expectEqual(
        gate.refusal(for: social, groupID: "social", at: now, emergencyPassRunning: false),
        .passcode, "and leaves the group shut"
    )
    expect(
        gate.accept(passcode: "1234", forGroup: "social", settings: social, at: now),
        "the right one opens it"
    )
    expectNil(
        gate.refusal(for: social, groupID: "social", at: now, emergencyPassRunning: false),
        "for the rest of the visit"
    )
    expectEqual(
        gate.refusal(for: news, groupID: "news", at: now, emergencyPassRunning: false),
        .passcode, "and buys nothing at all for the group next door"
    )
    expectEqual(
        gate.refusal(for: social, groupID: "social", at: now, emergencyPassRunning: false)?
            .text(groupNamed: "Social") ?? "open",
        "open", "the sentence is only reached while something is owed"
    )
    expectEqual(
        GroupLockGate.Refusal.passcode.text(groupNamed: "News"),
        "Enter the passcode for News to change it", "and it names the group when it is"
    )

    gate.windowClosed()
    expectEqual(
        gate.refusal(for: social, groupID: "social", at: now, emergencyPassRunning: false),
        .passcode, "the next visit asks again"
    )

    // The pass lifts both halves, which is what keeps a forgotten code from being a reinstall.
    expectNil(
        gate.refusal(for: social, groupID: "social", at: now, emergencyPassRunning: true),
        "an emergency pass opens it"
    )
    expect(
        !gate.state(for: social, groupID: "social", at: now, emergencyPassRunning: true)
            .passcodeRequired,
        "and the door is not drawn while one runs"
    )
}

/// Fail-closed, for the reason the app-wide timer fails closed: every window that can edit the
/// configuration announces itself, so the only way here with nothing open is a path that forgot.
/// The wait of a group that carries **both** halves of a lock counts from the moment the code was
/// entered, not from the window opening.
///
/// When a passcode is required, the time only starts going down once the code has been entered.
/// Counted from the window, the wait ran behind a shut door and had usually lapsed
/// before anybody typed the code — a ten-minute lock that held for nothing at all.
private func testACodedGroupsWaitCountsFromTheCodeRatherThanTheWindow() {
    var gate = GroupLockGate()
    var settings = GroupSettings.standard
    settings.lockMinutes = 10
    settings.passcode = PasscodeHash.make("1234")
    let opened = ClockReading(wall: noon, uptime: 100)
    gate.windowOpened(at: opened)

    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: opened, emergencyPassRunning: false),
        .passcode, "the code is owed before anything else"
    )
    let lapsed = ClockReading(wall: noon.addingTimeInterval(1_200), uptime: 1_300)
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: lapsed, emergencyPassRunning: false),
        .passcode, "and twenty minutes of a shut door do not spend a ten-minute wait"
    )
    expectNil(
        gate.state(for: settings, groupID: "social", at: lapsed, emergencyPassRunning: false)
            .unlockSeconds,
        "with nothing counting down, because nothing has started"
    )

    expect(
        gate.accept(passcode: "1234", forGroup: "social", settings: settings, at: lapsed),
        "the code is entered"
    )
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: lapsed, emergencyPassRunning: false),
        .timer(secondsLeft: 600), "and the wait starts there, at its full length"
    )
    let halfway = ClockReading(wall: noon.addingTimeInterval(1_500), uptime: 1_600)
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: halfway, emergencyPassRunning: false),
        .timer(secondsLeft: 300), "five minutes on, five are left"
    )
    // Once per visit: a second right answer must not push the countdown forward, or the group
    // could be held open by retyping the code.
    expect(
        gate.accept(passcode: "1234", forGroup: "social", settings: settings, at: halfway),
        "the code is entered again"
    )
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: halfway, emergencyPassRunning: false),
        .timer(secondsLeft: 300), "and the countdown does not go back to full"
    )
    let over = ClockReading(wall: noon.addingTimeInterval(1_801), uptime: 1_901)
    expectNil(
        gate.refusal(for: settings, groupID: "social", at: over, emergencyPassRunning: false),
        "when it runs out the group is free for the rest of the visit"
    )

    // A group with a wait and no code is untouched: there is no other moment to count from.
    var plain = GroupSettings.standard
    plain.lockMinutes = 10
    expectEqual(
        gate.refusal(for: plain, groupID: "news", at: opened, emergencyPassRunning: false),
        .timer(secondsLeft: 600), "the window is still where a codeless wait starts"
    )
    expectNil(
        gate.refusal(for: plain, groupID: "news", at: over, emergencyPassRunning: false),
        "and it lapses on the window's own clock"
    )

    // A fresh visit puts the door back, and the wait with it.
    gate.windowClosed()
    gate.windowOpened(at: over)
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: over, emergencyPassRunning: false),
        .passcode, "the next visit asks for the code again"
    )
    expect(
        gate.accept(passcode: "1234", forGroup: "social", settings: settings, at: over),
        "and answering it"
    )
    expectEqual(
        gate.refusal(for: settings, groupID: "social", at: over, emergencyPassRunning: false),
        .timer(secondsLeft: 600), "starts the whole wait over"
    )
}

private func testAnUnannouncedWindowIsRefusedInFull() {
    let gate = GroupLockGate()
    var settings = GroupSettings.standard
    settings.lockMinutes = 5
    expectEqual(
        gate.refusal(
            for: settings, groupID: "grp", at: ClockReading(wall: noon, uptime: 1), emergencyPassRunning: false
        ),
        .timer(secondsLeft: 300), "a wait nobody started is owed whole"
    )
    var off = GroupSettings.standard
    off.lockMinutes = 0
    expectNil(
        gate.refusal(
            for: off, groupID: "grp", at: ClockReading(wall: noon, uptime: 1), emergencyPassRunning: false
        ),
        "and a group with no lock is held by nothing"
    )
    expect(!off.hasOwnLock, "which is what having no lock means")
    off.lockMinutes = 1
    expect(off.hasOwnLock, "one minute is a lock")
}

/// The screen a shut group shows. It stands inside a window that is already open, so it says
/// which **group** is asking rather than which app — and it carries both ways out, because a door
/// with no way past a forgotten code is a reinstall.
private func testTheDoorSaysWhichGroupIsAskingAndHowPastIt() {
    let shut = GroupDoor(name: "Social", state: GroupLockState(passcodeRequired: true))
    expect(shut.isClosed, "a code that is owed shuts the page")
    expectEqual(shut.title, "Enter the passcode for Social", "and the title names the group")
    expectEqual(
        shut.subtitle, "This group's settings are behind its own passcode.",
        "with one line saying why this page and not the others"
    )
    expectEqual(shut.recovery, .offer, "the hour is there to start")
    expectEqual(
        shut.recovery.actionTitle, "Forgot this group's passcode?", "under a control that says so"
    )
    expectNil(shut.recovery.note, "and nothing is counting yet")

    let waiting = GroupDoor(
        name: "Social", state: GroupLockState(passcodeRequired: true, resetSeconds: 90)
    )
    expectEqual(waiting.recovery, .waiting(secondsLeft: 90), "a started hour is what it shows")
    expectEqual(waiting.recovery.actionTitle, "Cancel", "what a countdown offers is calling it off")
    expectEqual(
        waiting.recovery.note, "Passcode clears in 1:30", "and it counts in the app's own shape"
    )

    let open = GroupDoor(name: "Social", state: GroupLockState(unlockSeconds: 300))
    expect(
        !open.isClosed,
        "the group's own wait does not shut the page — it refuses changes behind it, and \"have"
            + " you sat with this\" is no question to ask of somebody who came to read"
    )
}

// MARK: - The group that has opted out of the pass

/// A running pass lifts a group's lock, unless that group has said it should not.
///
/// All three answers the gate gives, because they have to agree: the refusal, the state the editor
/// redraws from, and the set the all-at-once switch is handed. `heldGroups` used to answer `[]` on
/// the strength of a running pass alone, which is exactly the shape of thing that survives a
/// feature like this and quietly sweeps up the one group it must not.
private func testAPassLiftsAGroupsLockUnlessTheGroupSaysOtherwise() {
    var gate = GroupLockGate()
    var settings = GroupSettings.standard
    settings.lockMinutes = 10
    settings.passcode = PasscodeHash.make("2468")
    let opened = ClockReading(wall: noon, uptime: 100)
    gate.windowOpened(at: opened)

    expectNil(
        gate.refusal(for: settings, groupID: "grp", at: opened, emergencyPassRunning: true),
        "the pass lifts an ordinary group's lock, exactly as it always did"
    )

    var immune = settings
    immune.ignoresAppWideUnblocks = true
    expectEqual(
        gate.refusal(for: immune, groupID: "grp", at: opened, emergencyPassRunning: true),
        .passcode, "a group that ignores the pass keeps its door shut through the hour"
    )
    let state = gate.state(
        for: immune, groupID: "grp", at: opened, emergencyPassRunning: true
    )
    expect(state.passcodeRequired, "and the page it draws is still the door")

    var waitOnly = immune
    waitOnly.passcode = nil
    expectEqual(
        gate.refusal(for: waitOnly, groupID: "grp", at: opened, emergencyPassRunning: true),
        .timer(secondsLeft: 600), "its wait goes on holding too"
    )
    expectEqual(
        gate.state(for: waitOnly, groupID: "grp", at: opened, emergencyPassRunning: true)
            .unlockSeconds,
        600, "and goes on counting, so the band over its page still says how long"
    )
    expectNil(
        gate.refusal(
            for: waitOnly, groupID: "grp", at: opened, emergencyPassRunning: true, tightening: true
        ),
        "what it still does not hold is the direction no lock has ever held"
    )

    var config = twoGroupConfig()
    config.groupSettings[youtubeGroup]?.lockMinutes = 10
    config.groupSettings[youtubeGroup]?.ignoresAppWideUnblocks = true
    config.groupSettings[redditGroup]?.lockMinutes = 10
    expectEqual(
        gate.heldGroups(in: config, at: opened, emergencyPassRunning: true), [youtubeGroup],
        "and the all-at-once switch is told to leave it alone while it sweeps up the other one"
    )
    expect(
        gate.heldGroups(in: config, at: opened, emergencyPassRunning: false)
            == [youtubeGroup, redditGroup],
        "with no pass running both are held, which is what says the pass is what moved"
    )
}

/// **The escape that remains is the hour, and the door says so.**
///
/// A pass spent from this screen would open every other group and leave this one shut, so offering
/// the button would cost the week's one net for nothing. The line that replaces it names the hour
/// rather than only stating the absence: somebody reading this screen cannot get in, and told what
/// is gone but not what is left they would go and spend the pass anyway.
///
/// The hour itself is unconditional here — `GroupDoor.Recovery` has two states and neither of them
/// is "switched off", unlike `SettingsDoor`'s `emergencyPassOnly`. That is what makes a passcode
/// plus immunity survivable rather than a reinstall.
private func testAnImmuneGroupsDoorDoesNotOfferThePass() {
    let shut = GroupDoor(name: "Social", state: GroupLockState(passcodeRequired: true))
    expect(shut.offersEmergencyPass, "an ordinary group's door offers the week's pass")

    let immune = GroupDoor(
        name: "Social", state: GroupLockState(passcodeRequired: true), ignoresAppWideUnblocks: true
    )
    expect(
        !immune.offersEmergencyPass,
        "a group that ignores the pass does not, because spending one would not open it"
    )
    expectEqual(immune.recovery, .offer, "the hour is there, and it is the only way in")
    expectEqual(
        immune.recovery.actionTitle, "Forgot this group's passcode?",
        "under the same control every other group has"
    )
    expect(
        GroupDoor.appWideUnblocksDoNotApply.contains("hour above"),
        "and the line in the button's place points at it rather than only saying what is gone"
    )
    expect(
        GroupDoor.appWideUnblocksDoNotApply.contains("unblocking everything"),
        "while ruling out the other door too, before somebody walks to the other page for it"
    )

    let waiting = GroupDoor(
        name: "Social",
        state: GroupLockState(passcodeRequired: true, resetSeconds: 60),
        ignoresAppWideUnblocks: true
    )
    expectEqual(
        waiting.recovery, .waiting(secondsLeft: 60),
        "and once started it counts down here like anywhere else — there is no configuration in"
            + " which a coded, immune group has no way past a forgotten code"
    )
}

// MARK: - The one band over the page

/// **Never two numbers, and always the one that is still refusing things.** Decided before it was
/// built: if the app-wide wait is longer than the group's, show the app-wide one, otherwise just
/// the group's — two times make no sense.
///
/// Both orders, because the two waits start at different moments — a group's counts from its code
/// being entered, or from its page being left — so either can be the longer and neither order is
/// the special case.
private func testTheBandCountsTheLongerOfTheTwoWaits() {
    expectEqual(
        LockBanner.secondsLeft(global: 600, group: 120), 600,
        "the app-wide wait outlasts the group's, so that is the one shown"
    )
    expectEqual(
        LockBanner.secondsLeft(global: 120, group: 600), 600,
        "and the other way round, which is the case a band reading only the window would miss"
    )
    expectEqual(
        LockBanner.secondsLeft(global: 300, group: 300), 300,
        "two waits ending in the same second are one number, not two"
    )
    expectEqual(
        LockBanner.secondsLeft(global: 240, group: nil), 240,
        "the app-wide wait alone is what every page other than a group's shows"
    )
    expectEqual(
        LockBanner.secondsLeft(global: nil, group: 240), 240,
        "and a group's own alone, which is the whole point: it used to be shown nowhere"
    )
    expectNil(
        LockBanner.secondsLeft(global: nil, group: nil), "with neither running there is no band"
    )
    expectNil(LockBanner.secondsLeft(global: nil), "and a page with no group on it says so by omission")
}

/// One sentence for both, because it is true of both: what the number means for the page in front
/// of you is when the things on it stop being refused.
///
/// The lifecycle is not restated here — the band takes `GroupLockState.unlockSeconds` as it comes,
/// so a wait that is off, run out, not yet armed or waiting behind an unanswered code arrives as
/// `nil` and is not counted. `testTheGateRefusesThenPermits` and the two arming cases above are
/// where those answers are pinned.
private func testTheBandOverAGroupSaysTheSameSentenceForEitherLock() {
    expectEqual(
        LockBanner.text(272), "Settings unlock in 4:32",
        "the band's whole sentence, in the shape every countdown in this app is written in"
    )
    expectEqual(LockBanner.text(7), "Settings unlock in 0:07", "including the last few seconds")

    let held = GroupLockState(unlockSeconds: 90)
    expectEqual(
        LockBanner.secondsLeft(global: nil, group: held.unlockSeconds).map(LockBanner.text),
        "Settings unlock in 1:30",
        "a group held only by its own wait finally has a number on screen"
    )
    let behindItsCode = GroupLockState(passcodeRequired: true)
    expectNil(
        LockBanner.secondsLeft(global: nil, group: behindItsCode.unlockSeconds),
        "and a wait that has not started because nobody has entered the code counts nothing"
    )
}

// MARK: - What is on disk

private func testAGroupWithoutALockStillDecodes() {
    let json = """
        {
          "cooldownMinutes" : 10,
          "earnBackEnabled" : true,
          "enabled" : true,
          "escalationSeconds" : 5,
          "pauseSeconds" : 10,
          "presetID" : "standard"
        }
        """
    guard let settings = try? SandglassJSON.decoder.decode(
        GroupSettings.self, from: Data(json.utf8)
    ) else {
        failTest("a group written before the lock existed still decodes")
        return
    }
    expectEqual(settings.lockMinutes, 0, "no lock key means no lock")
    expectNil(settings.passcode, "and no passcode")
    expectNil(settings.passcodeForgotStartedAt, "and no hour running")
    expectEqual(
        String(data: (try? SandglassJSON.encoder.encode(settings)) ?? Data(), encoding: .utf8)?
            .contains("lockMinutes"), false,
        "and saving it again writes no lock keys, because it still says nothing"
    )
}

private func testALockedGroupSurvivesTheDisk() {
    var settings = GroupSettings.standard
    settings.lockMinutes = 45
    settings.passcode = PasscodeHash.make("2468")
    settings.passcodeForgotStartedAt = ClockReading(wall: noon, uptime: 500)
    guard let data = try? SandglassJSON.encoder.encode(settings),
          let text = String(data: data, encoding: .utf8),
          let back = try? SandglassJSON.decoder.decode(GroupSettings.self, from: data) else {
        failTest("a locked group could not be written and read back")
        return
    }
    expect(text.contains("\"lockMinutes\" : 45"), "the keys appear on the next save")
    expect(text.contains("\"passcode\""), "including the hash")
    expect(!text.contains("2468"), "and the passcode itself is nowhere in it")
    expectEqual(back, settings, "and the whole lock comes back off disk unchanged")
}
