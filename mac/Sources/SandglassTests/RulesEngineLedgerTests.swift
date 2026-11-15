import Foundation
import SandglassCore

/// The engine's small ledgers that have no screen of their own: the pause screens turned away
/// from, the seconds a break window holds, and the effects a refused edit leaves behind.
///
/// Each of these is a number a person never sees change, which is why each one went wrong
/// quietly: the streak's practice signal, a time limit already spent when a break ends, and a
/// relock warning delivered twice.
func runEngineLedgerTests() {
    testAnImmuneGroupsDismissalsCountThroughABreak()
    testADismissalUnderThePassIsStale()
    testABreakWindowChargesNoTime()
    testARevertedEditDoesNotAnnounceTheSameEndTwice()
}

// MARK: - Dismissals

/// A group that opted out of the app's unblocks goes on showing its pause screen through a break,
/// so turning back at it is as real as on any other afternoon.
private func testAnImmuneGroupsDismissalsCountThroughABreak() {
    let clock = FakeClock(noon)
    var immune = GroupSettings.standard
    immune.ignoresAppWideUnblocks = true
    let (engine, youtube, reddit) = makeTwoGroupEngine(youtube: immune, clock: clock)
    expect(engine.pauseProtection(minutes: 10), "a break is running")
    engine.recordDismissal(targetID: youtube.id)
    expectEqual(
        engine.statsSnapshot().opensAvoidedToday, 1,
        "the immune group's screen was up, so turning back at it counts"
    )
    engine.recordDismissal(targetID: reddit.id)
    expectEqual(
        engine.statsSnapshot().opensAvoidedToday, 1,
        "while the lifted group had no screen to turn back at"
    )
}

/// The pass lifts what the break does, so a dismissal arriving under it is the same stale signal.
private func testADismissalUnderThePassIsStale() {
    let clock = FakeClock(noon)
    var immune = GroupSettings.standard
    immune.ignoresAppWideUnblocks = true
    let (engine, youtube, reddit) = makeTwoGroupEngine(youtube: immune, clock: clock)
    expect(engine.useEmergencyPass(), "the pass is running")
    engine.recordDismissal(targetID: reddit.id)
    expectEqual(engine.statsSnapshot().opensAvoidedToday, 0, "no screen stood over a lifted group")
    engine.recordDismissal(url: "https://reddit.com/r/x")
    expectEqual(engine.statsSnapshot().opensAvoidedToday, 0, "on the web either")
    engine.recordDismissal(targetID: youtube.id)
    expectEqual(engine.statsSnapshot().opensAvoidedToday, 1, "and the group the pass passed over counts")
}

// MARK: - Break windows

/// A break window is the group fully open with nothing spent — the decision says so, and the
/// counter now agrees. Time in it used to land on the daily limit, so the evening after a break
/// spent scrolling opened already used up.
private func testABreakWindowChargesNoTime() {
    let clock = FakeClock(august(10, 12, 30))
    var settings = standardSettings(windows: [
        window(.break, weekdays: TimeWindow.everyDay, from: 12 * 60, to: 13 * 60),
    ])
    settings.dailyMinutes = 30
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    expectEqual(engine.decision(targetID: target.id), .notManaged, "the break window is open")
    engine.recordUsage(groupID: target.groupID, seconds: 600)
    expectEqual(engine.statsSnapshot().usageSecondsToday[target.groupID] ?? 0, 0, "and it costs nothing")
    clock.now = august(10, 13, 30)
    engine.recordUsage(groupID: target.groupID, seconds: 60)
    expectEqual(
        engine.statsSnapshot().usageSecondsToday[target.groupID], 60,
        "while the minute after it is counted as always"
    )
}

// MARK: - A refused edit

/// The catch-up inside an edit that could not be written queues what it found, and the revert puts
/// the state back so the next tick finds the same thing again. The queue goes back with it, or the
/// one session that ran out is announced twice.
private func testARevertedEditDoesNotAnnounceTheSameEndTwice() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 6 * 60)
    let previous = (config: engine.config, state: engine.state)
    var edited = engine.config
    edited.groupSettings[target.groupID]?.opensPerDay = 4
    engine.updateConfig(edited)
    engine.revertConfig(to: previous.config, restoring: previous.state)
    let ended = engine.tick().filter { $0 == .sessionEnded(groupID: target.groupID) }
    expectEqual(ended.count, 1, "the session that ran out is announced once")
}
