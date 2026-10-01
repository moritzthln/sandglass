import Foundation
import SandglassCore

// Shared fixtures live in EngineFixtures.swift; the schedule, focus-session and pause
// tests live next door in RulesEngineScheduleTests.swift.

// The order here follows the file.
func runEngineStreakTests() {
    testACleanDayExtendsTheStreak()
    testADayOfOnlyDismissalsCounts()
    testABustedDaySpendsTheWeeklyFreeze()
    testASecondBustedDayInTheSameWeekEndsTheStreak()
    testTheFreezeComesBackWithTheNewWeek()
    testDaysTheAppNeverSawLeaveTheStreakAlone()
    testABustedSundaySpendsItsOwnWeeksFreeze()
    testAnEmptyDayDoesNotCount()
    testABustedDayWithAnUnreadableKeyChargesNoFreeze()
    testMovingTheStartOfDayNeitherClearsTodayNorScoresIt()
    testMovingTheStartOfDayStillLetsTheRealDayRollAfterwards()
    testALateStartOfDayStillAdvancesTheStreak()
}

// MARK: - Driving the days

/// Spend the whole budget and knock once more — the definition of a busted day.
private func bustTheDay(_ engine: RulesEngine, _ targetID: String, _ clock: FakeClock) {
    for _ in 0..<5 { spendOneOpen(engine, targetID, clock) }
    _ = engine.consumeOpen(targetID: targetID)
}

/// Move the clock past 03:00 of the given August day and let the engine notice.
private func rollInto(_ day: Int, _ engine: RulesEngine, _ clock: FakeClock) {
    clock.now = august(day, 3, 1)
    _ = engine.tick()
}

// MARK: - Streak

private func testACleanDayExtendsTheStreak() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    spendOneOpen(engine, target.id, clock)
    rollInto(11, engine, clock)
    expectEqual(engine.state.streakDays, 1, "a day inside the budget counts")
    expectEqual(engine.statsSnapshot().freezesLeft, 1, "and costs no freeze")
}

/// Turning around at the pause screen is the best kind of day — it counts as practised.
private func testADayOfOnlyDismissalsCounts() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    engine.recordDismissal(targetID: target.id)
    rollInto(11, engine, clock)
    expectEqual(engine.state.streakDays, 1, "a day spent avoiding opens counts too")
}

/// Busted means "kept knocking after the budget was gone", not "used the whole budget".
/// This also pins the rollover order: judging the day after clearing its counters would
/// find nothing to judge and leave the freeze untouched.
private func testABustedDaySpendsTheWeeklyFreeze() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    spendOneOpen(engine, target.id, clock)
    rollInto(11, engine, clock)                    // Monday was clean → streak 1
    bustTheDay(engine, target.id, clock)
    rollInto(12, engine, clock)
    expectEqual(engine.state.streakDays, 1, "the freeze absorbs the busted day")
    expectEqual(engine.statsSnapshot().freezesLeft, 0, "and is gone for the week")
    expectEqual(engine.state.freezeUsedInWeek, "2026-W33", "spent in the week the busted day belonged to")
}

private func testASecondBustedDayInTheSameWeekEndsTheStreak() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    spendOneOpen(engine, target.id, clock)
    rollInto(11, engine, clock)                    // streak 1
    bustTheDay(engine, target.id, clock)
    rollInto(12, engine, clock)                    // freeze spent
    bustTheDay(engine, target.id, clock)
    rollInto(13, engine, clock)
    expectEqual(engine.state.streakDays, 0, "the second bust of the week costs the streak")
    expectEqual(engine.statsSnapshot().freezesLeft, 0, "the freeze stays spent for the rest of the week")
}

private func testTheFreezeComesBackWithTheNewWeek() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    spendOneOpen(engine, target.id, clock)
    rollInto(11, engine, clock)                    // streak 1
    bustTheDay(engine, target.id, clock)
    rollInto(12, engine, clock)                    // freeze of 2026-W33 spent
    expectEqual(engine.statsSnapshot().freezesLeft, 0, "this week's freeze is gone")

    clock.now = august(17, 12)                     // Monday of the next ISO week
    _ = engine.tick()
    expectEqual(engine.statsSnapshot().freezesLeft, 1, "the new week brings a new freeze")
    bustTheDay(engine, target.id, clock)
    rollInto(18, engine, clock)
    expectEqual(engine.state.freezeUsedInWeek, "2026-W34", "which the next busted day spends")
    expectEqual(engine.state.streakDays, 1, "leaving the streak alone")
}

/// The Mac was off for three days. The last day it saw was a real one, but the engine
/// only learns it ended long afterwards — that is a gap, and a gap neither extends the
/// streak nor breaks it.
private func testDaysTheAppNeverSawLeaveTheStreakAlone() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    spendOneOpen(engine, target.id, clock)
    rollInto(11, engine, clock)                    // Monday was clean and seen → streak 1
    spendOneOpen(engine, target.id, clock)         // Tuesday was clean too, but then the lid closed
    clock.now = august(14, 12)                     // Friday
    expectEqual(engine.tick(), [.dayRolledOver], "the engine notices the jump once")
    expectEqual(engine.state.streakDays, 1, "a day that only ends three days later does not extend the streak")
    expectEqual(engine.statsSnapshot().freezesLeft, 1, "and the gap costs no freeze")
}

/// A freeze belongs to the week of the day it saves, not to the week the engine happens
/// to be in when it notices: a busted Sunday must not eat Monday's fresh freeze.
private func testABustedSundaySpendsItsOwnWeeksFreeze() {
    let clock = FakeClock(august(16, 12))          // Sunday, the last day of 2026-W33
    let (engine, target) = makeEngine(clock: clock)
    bustTheDay(engine, target.id, clock)
    rollInto(17, engine, clock)                    // Monday, the first day of 2026-W34
    expectEqual(engine.state.freezeUsedInWeek, "2026-W33", "the busted day's own week pays for it")
    expectEqual(engine.statsSnapshot().freezesLeft, 1, "and the new week starts with its freeze intact")
}

/// A state file damaged badly enough to lose its day key cannot be placed in a week, and
/// guessing "this week" would spend a freeze the user may still need for a day they lived.
private func testABustedDayWithAnUnreadableKeyChargesNoFreeze() {
    let clock = FakeClock(noon)
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    var damaged = initialState(clock)
    damaged.dayKey = "not-a-day"
    damaged.deniedAttempts = [youtubeGroup: 3]
    damaged.streakDays = 4
    let engine = makeEngine(
        targets: [target],
        groupSettings: [target.groupID: .standard],
        state: damaged,
        clock: clock
    )
    expectEqual(engine.tick(), [.dayRolledOver], "the unreadable key still rolls into today")
    expectNil(engine.state.freezeUsedInWeek, "but no week is charged for a day that cannot be placed")
    expectEqual(engine.statsSnapshot().freezesLeft, 1, "so the freeze is still there")
    expectEqual(engine.state.streakDays, 4, "and the streak is left exactly as it was")
    expect(engine.state.deniedAttempts.isEmpty, "while the damaged day's counters are cleared")
}

private func testAnEmptyDayDoesNotCount() {
    let clock = FakeClock(noon)
    let (engine, target) = makeEngine(clock: clock)
    spendOneOpen(engine, target.id, clock)
    rollInto(11, engine, clock)                    // streak 1
    rollInto(12, engine, clock)                    // Tuesday: nothing happened at all
    expectEqual(engine.state.streakDays, 1, "a day without a single open was not practised")
    clock.advance(seconds: 3600)
    spendOneOpen(engine, target.id, clock)
    rollInto(13, engine, clock)
    expectEqual(engine.state.streakDays, 2, "and the next real day picks up where it left off")
}

// MARK: - Moving the start of the day

/// Changing a preference is not a day passing.
///
/// The day key is derived from `dayStartMinutes`, so moving it across the current boundary made
/// the next `rollDayIfNeeded` see a key it had never seen and perform the whole ceremony: today's
/// opens and usage cleared, and the streak scored for a day the user was in the middle of. On a
/// settings row with no confirmation in front of it — while `resetToday`, which clears strictly
/// less, has one.
private func testMovingTheStartOfDayNeitherClearsTodayNorScoresIt() {
    let clock = FakeClock(august(10, 4))               // 04:00, with the day starting at 03:00
    let (engine, target) = makeEngine(clock: clock)
    spendOneOpen(engine, target.id, clock)
    engine.recordUsage(groupID: target.groupID, seconds: 120)
    let dayBefore = engine.state.dayKey
    expectEqual(engine.state.opensUsed[youtubeGroup], 1, "one open has been spent today")

    // 04:00 is before a 06:00 start, so this moment now belongs to the logical day that began
    // yesterday morning — a different key, which is the trigger the roll was firing on.
    var moved = engine.config
    moved.dayStartMinutes = 6 * 60
    engine.updateConfig(moved)

    expect(engine.state.dayKey != dayBefore, "the moment belongs to a different logical day now")
    expectEqual(engine.state.opensUsed[youtubeGroup], 1, "and the open already spent is still spent")
    expectEqual(
        engine.state.usageSecondsToday[youtubeGroup], 120, "with the minutes still counted"
    )
    expectEqual(engine.state.streakDays, 0, "no day was scored, because no day ended")
    expectEqual(engine.statsSnapshot().freezesLeft, 1, "and no freeze was spent")
    expectEqual(engine.tick(), [], "and the next tick has nothing left to announce")
}

/// The rebase must not swallow the real thing. Tomorrow still rolls, under the new start.
private func testMovingTheStartOfDayStillLetsTheRealDayRollAfterwards() {
    let clock = FakeClock(august(10, 4))
    let (engine, target) = makeEngine(clock: clock)
    spendOneOpen(engine, target.id, clock)

    var moved = engine.config
    moved.dayStartMinutes = 6 * 60
    engine.updateConfig(moved)
    expectEqual(engine.state.opensUsed[youtubeGroup], 1, "the open survives the change")

    clock.now = august(10, 6, 1)                       // one minute past the new start of day
    expectEqual(engine.tick(), [.dayRolledOver], "the new boundary rolls the day when it arrives")
    expect(engine.state.opensUsed.isEmpty, "and that roll does clear the counters")
    expectEqual(engine.state.streakDays, 1, "and score the day that really ended")
}

/// A day key is already a calendar date, so whether two of them are consecutive has nothing to do
/// with the start of day. Sending the candidate back through `EngineState.dayKey` applied the
/// shift twice, and past noon that was enough to move it a whole day: with a hand-edited start of
/// day of 18:00, every day looked like a gap and the streak could never advance.
private func testALateStartOfDayStillAdvancesTheStreak() {
    let clock = FakeClock(august(10, 20))              // 20:00, inside a day that began at 18:00
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let config = Config(
        version: 1, targets: [target], groupSettings: [target.groupID: .standard],
        dayStartMinutes: 18 * 60
    )
    let engine = RulesEngine(
        config: config,
        state: EngineState.initial(
            now: clock.now, calendar: testCalendar, dayStartMinutes: 18 * 60
        ),
        clock: clock,
        calendar: testCalendar
    )
    spendOneOpen(engine, target.id, clock)

    clock.now = august(11, 18, 1)                      // the next 18:00 boundary, one day later
    expectEqual(engine.tick(), [.dayRolledOver], "the day rolls")
    expectEqual(engine.state.streakDays, 1, "and the day that ended counts, as any other would")
}
