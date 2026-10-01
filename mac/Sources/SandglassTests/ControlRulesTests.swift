import SandglassAppCore
import SandglassCore
import Foundation

/// What a control does with a value it was not built to offer, wherever the value came from.
///
/// The first rules exist because each was got wrong, in the same way and in the same direction: a
/// control that cannot display a value quietly replaces it. That is the worst of the three
/// options — worse than showing something odd, and worse than refusing — because the user came to
/// look at a screen and left with an edit they did not make.
///
/// The typed number is the same question asked of the keyboard rather than of the file, and it has
/// a second half the file never had: a typed number can be **out of range**, and out of range must
/// not mean out of mind. A field that swallowed 900 would be the first fault in a new place.
func runControlRulesTests() {
    testAMenuKeepsTheValuesItWasGiven()
    testAStoredValueIsAlwaysOnTheMenu()
    testARangeStretchesToHoldTheValueItWasGiven()
    testASwitchGivesBackTheNumberItWasTurnedOffWith()
    testATypedNumberInsideTheSpanIsTakenAsItIs()
    testATypedNumberOutsideTheSpanLandsOnTheBound()
    testNonsenseIsNotANumberAndChangesNothing()
    testAHeldNumberMayOnlyBeTypedTowardsMoreFriction()
    testABareHourIsAnHour()
    testDigitsWithNoSeparatorAreHoursAndMinutes()
    testTheSeparatorsPeopleActuallyType()
    testAMeridiemReadsATwelveHourFace()
    testATimeOutsideTheDayRevertsRatherThanClamping()
    testBothEdgesOfTheDayAreTimesAndTheyAreDifferentNumbers()
    testNothingUsableTypedIntoATimeFieldChangesNothing()
    testEveryMinuteOfTheDaySurvivesTheRoundTrip()
    testTheDraftIsTheSameFaceTheRowPrints()
    testTheFarEdgeOfTheDayHasAName()
    testAWindowEndingAtTheEndOfTheDayReadsAsMidnight()
    testAReadTimeComesBackInTheRowsOwnNotation()
    testOnePressOfATimeControlLandsOnTheQuarterHour()
    testTheWarningStepperWalksHalfMinutesAndUndoesItself()
    testALengthInSecondsReadsAsMinutesPastTheMinute()
}

/// The two ends of a time window, by the ranges the editor hands their fields. They differ by one
/// minute and the minute matters: see `TimeWindow.startRange`.
private let startRange = TimeWindow.startRange
private let endRange = TimeWindow.endRange

/// The ordinary case has to stay ordinary: a selection the menu already offers changes nothing,
/// and in particular does not duplicate the row.
private func testAMenuKeepsTheValuesItWasGiven() {
    expectEqual(
        ControlRules.menu([1, 5, 10, 30, 60, 180], containing: 10), [1, 5, 10, 30, 60, 180],
        "a value already on the menu leaves it alone"
    )
    expectEqual(
        ControlRules.menu([1, 5, 10], containing: 1), [1, 5, 10],
        "including the first one"
    )
    expectEqual(ControlRules.menu([Int](), containing: 7), [7], "an empty menu gains the value")
}

/// The bug: `SettingsLock.timerMinutes` was once rendered from a fixed list of six. A
/// `config.json` holding anything else drew a blank dropdown, and blank is not a value — the next
/// click wrote whichever row it landed on, so the lock the user had set was replaced by one they
/// had not. That row is a stepper now and the six are gone, but three other selects still take
/// their values off disk, which is why the rule lives in the control rather than in the caller.
private func testAStoredValueIsAlwaysOnTheMenu() {
    expectEqual(
        ControlRules.menu([1, 5, 10, 30, 60, 180], containing: 45),
        [1, 5, 10, 30, 60, 180, 45],
        "a hand-edited 45 minutes is added rather than dropped"
    )
    // Appended rather than sorted in: the menu's own order is the caller's business — the day
    // start sorts, the expiry warning keeps "None" first — and this rule only guarantees that
    // nothing goes missing.
    expectEqual(
        ControlRules.menu([30, 60, 300], containing: 15), [30, 60, 300, 15],
        "and it is added at the end, leaving the caller's order alone"
    )
    // Not only numbers: every select in the app is over some `Hashable`, and an optional one is
    // the shape `expiryWarningSeconds` uses, where `nil` is a real answer.
    expectEqual(
        ControlRules.menu([Int?.none, 30, 60], containing: 90), [Int?.none, 30, 60, 90],
        "an optional menu behaves the same"
    )
    expectEqual(
        ControlRules.menu([Int?.none, 30, 60], containing: nil), [Int?.none, 30, 60],
        "and nil is a value it can already hold, not a missing one"
    )
}

/// The bug's other shape: `Stepper(value:in:)` disables the arrow that would leave its bounds, so
/// a stored value outside them cannot be walked back into range. A 600-second pause countdown on
/// a 5...120 stepper was a number you could only look at.
private func testARangeStretchesToHoldTheValueItWasGiven() {
    expectEqual(
        ControlRules.reachableRange(5...120, holding: 30), 5...120,
        "a value inside the range leaves it exactly as it was"
    )
    expectEqual(
        ControlRules.reachableRange(5...120, holding: 5), 5...120, "and so does one on the edge"
    )
    expectEqual(
        ControlRules.reachableRange(5...120, holding: 600), 5...600,
        "one above it stretches the top, so the down arrow works"
    )
    expectEqual(
        ControlRules.reachableRange(5...120, holding: 1), 1...120,
        "and one below it stretches the bottom"
    )
    // A negative is not a number any of these controls means, but the range still has to be
    // well-formed: `lower...upper` traps when they are the wrong way round, and a trap is a
    // crash on a screen somebody only opened to read.
    expectEqual(
        ControlRules.reachableRange(0...20, holding: -5), -5...20,
        "a nonsense value widens rather than inverting the range"
    )
}

/// The third version of the same fault: a control handing out its default over the top of a
/// number the user chose. Open length 30 → off → on gave 5.
private func testASwitchGivesBackTheNumberItWasTurnedOffWith() {
    var session = RememberedNumber(fallback: 5)
    expectNil(session.flipped(to: false, from: 30), "switching it off clears the setting")
    expectEqual(session.flipped(to: true, from: nil), 30, "and switching it on gives 30 back")

    var opens = RememberedNumber(fallback: 5)
    expectEqual(
        opens.flipped(to: true, from: nil), 5,
        "a switch turned on with nothing to remember lands on the default"
    )
    expectNil(opens.flipped(to: false, from: 12), "then off with a different number")
    expectNil(opens.flipped(to: false, from: nil), "off again while already off remembers nothing new")
    expectEqual(opens.flipped(to: true, from: nil), 12, "and the newest number is the one that comes back")

    // The value on screen is always the file's: a flip that changes nothing must not reach past
    // what is stored and hand back an older number.
    var daily = RememberedNumber(fallback: 60)
    expectNil(daily.flipped(to: false, from: 90), "off with 90")
    expectEqual(daily.flipped(to: true, from: 120), 120, "on over a stored 120 keeps the 120")
    expectEqual(daily.remembered, 90, "though the memory is still there for the next time")
}

// MARK: - Typing the number instead of stepping it

/// The ordinary case: a number inside the span is the number, and the field says nothing.
private func testATypedNumberInsideTheSpanIsTakenAsItIs() {
    expectEqual(
        ControlRules.typed("45", into: 3...180),
        ControlRules.TypedNumber(value: 45, wasClamped: false),
        "a pause countdown typed inside its span is written as typed"
    )
    expectEqual(
        ControlRules.typed("3", into: 3...180),
        ControlRules.TypedNumber(value: 3, wasClamped: false),
        "and a value on the bottom bound is inside it, not outside"
    )
    expectEqual(
        ControlRules.typed("180", into: 3...180),
        ControlRules.TypedNumber(value: 180, wasClamped: false), "as is one on the top bound"
    )
    // Three shapes a keyboard produces that are still the number they look like. A field that
    // reverted any of them would read as a field that had ignored a correct answer.
    expectEqual(
        ControlRules.typed(" 45 ", into: 3...180),
        ControlRules.TypedNumber(value: 45, wasClamped: false),
        "spaces around a number are trimmed rather than making it nonsense"
    )
    expectEqual(
        ControlRules.typed("+45", into: 3...180),
        ControlRules.TypedNumber(value: 45, wasClamped: false), "and so is a leading plus"
    )
    expectEqual(
        ControlRules.typed("060", into: 3...180),
        ControlRules.TypedNumber(value: 60, wasClamped: false),
        "and a leading zero is 60, not 0 and not nothing"
    )
}

/// The bound this whole feature is bounded for: 600 typed where 60 was meant.
///
/// It happened once — a ten-hour lockout escapable only by the week's emergency pass — with a
/// field that had no span at all. The number lands on the bound rather than being dropped, and
/// `wasClamped` is what the row uses to say so: a typed number that quietly does nothing is the
/// app appearing to ignore the user, which is the one outcome worse than a wrong number.
private func testATypedNumberOutsideTheSpanLandsOnTheBound() {
    expectEqual(
        ControlRules.typed("900", into: 5...600),
        ControlRules.TypedNumber(value: 600, wasClamped: true),
        "a daily time limit typed past its top lands on the top"
    )
    expectEqual(
        ControlRules.typed("1", into: 5...600),
        ControlRules.TypedNumber(value: 5, wasClamped: true), "and one under its bottom on the bottom"
    )
    // A negative is a number, so it clamps rather than reverting — and every span in the app has
    // its strict end at or above zero, so the bound it lands on is the safe one.
    expectEqual(
        ControlRules.typed("-5", into: 1...30),
        ControlRules.TypedNumber(value: 1, wasClamped: true), "a negative opens goal lands on one"
    )
    // The span offered is the reachable one, which is already stretched around a stored value the
    // written range does not cover — so typing may walk a hand-edited 600 back down the same way
    // the arrows can, rather than being snapped to a top the file has already passed.
    expectEqual(
        ControlRules.typed("400", into: ControlRules.reachableRange(3...180, holding: 600)),
        ControlRules.TypedNumber(value: 400, wasClamped: false),
        "a stretched span may be typed into anywhere the arrows could reach"
    )
}

/// Nothing usable typed is nothing done: the row keeps the number it had, with no error state to
/// dismiss. The distinction that matters is between "not a number" and "a number out of range" —
/// the second one is clamped above, and only the first one reverts.
private func testNonsenseIsNotANumberAndChangesNothing() {
    expectNil(ControlRules.typed("", into: 3...180), "an emptied field reverts")
    expectNil(ControlRules.typed("   ", into: 3...180), "and so does one holding only spaces")
    expectNil(ControlRules.typed("abc", into: 3...180), "letters are not a number")
    expectNil(ControlRules.typed("4a", into: 3...180), "nor is a number with one stuck to it")
    // The row's own notation is not what the field takes: it shows "45s" at rest and the bare
    // number while it is being typed into, so a pasted "45 min" is a paste, not an amount.
    expectNil(ControlRules.typed("45 min", into: 3...180), "nor the unit the row displays")
    expectNil(ControlRules.typed("-", into: 3...180), "a bare minus sign is not a number yet")
    expectNil(ControlRules.typed("+", into: 3...180), "nor a bare plus")
    expectNil(ControlRules.typed("4.5", into: 3...180), "nor a fraction of a minute")
    // Too long to be an `Int`, which is a paste rather than a typo. It reverts rather than
    // saturating: a number nobody can have meant must not become the largest one there is.
    expectNil(
        ControlRules.typed("99999999999999999999", into: 3...180),
        "and a number too long to hold is not one either"
    )
}

/// The way the keyboard could have defeated the whole feature.
///
/// A group with a lock running over it may still be turned towards more friction and never back
/// (`EditDirection`), and the arrows draw that by losing the one that loosens. A typed field
/// reading the row's written range instead of the narrowed one would be a way round the lock that
/// took one keystroke — so it reads the narrowed span, and a smaller number lands on the value the
/// group is already running.
private func testAHeldNumberMayOnlyBeTypedTowardsMoreFriction() {
    // A pause countdown of 60s under a running lock: more is allowed, less is not.
    let pause = ControlRules.upwards(0...180, from: 60, tighteningOnly: true)
    expectEqual(pause, 60...180, "the span keeps only the direction that adds friction")
    expectEqual(
        ControlRules.typed("30", into: pause),
        ControlRules.TypedNumber(value: 60, wasClamped: true),
        "so typing a shorter countdown lands on the one that is running, not on 30"
    )
    expectEqual(
        ControlRules.typed("0", into: pause),
        ControlRules.TypedNumber(value: 60, wasClamped: true),
        "and nought — no pause screen at all — is the furthest of those, so it lands there too"
    )
    expectEqual(
        ControlRules.typed("120", into: pause),
        ControlRules.TypedNumber(value: 120, wasClamped: false),
        "while a longer one is a promise the lock has no reason to refuse"
    )

    // The three where less is stricter narrow the other way. A five-open budget may be cut and
    // not raised, and the top of the written range is out of reach while the lock stands.
    let opens = ControlRules.downwards(1...30, to: 5, tighteningOnly: true)
    expectEqual(opens, 1...5, "a budget may be cut to the written floor and no higher than today")
    expectEqual(
        ControlRules.typed("20", into: opens),
        ControlRules.TypedNumber(value: 5, wasClamped: true),
        "so typing a bigger budget lands on today's"
    )
    expectEqual(
        ControlRules.typed("2", into: opens),
        ControlRules.TypedNumber(value: 2, wasClamped: false), "and a smaller one is taken"
    )

    // Unheld, both hand back the range the row was written with — the span is narrowed by the
    // lock rather than by the value, and no lock means no narrowing.
    expectEqual(
        ControlRules.upwards(0...180, from: 60, tighteningOnly: false), 0...180,
        "with no lock standing over it the countdown has its whole span"
    )
    expectEqual(
        ControlRules.downwards(1...30, to: 5, tighteningOnly: false), 1...30,
        "and so does the budget"
    )
    // A stored value already outside the written range keeps the span well-formed either way:
    // `lower...upper` traps when they are the wrong way round, and a trap is a crash on a page
    // somebody only opened to read.
    expectEqual(
        ControlRules.upwards(0...180, from: 600, tighteningOnly: true), 600...600,
        "a countdown already past the top freezes where it is rather than inverting"
    )
    expectEqual(
        ControlRules.downwards(5...600, to: 2, tighteningOnly: true), 2...2,
        "and one already under the bottom does the same"
    )
}

// MARK: - Typing a time instead of stepping it

/// The ambiguity that kept this field switched off, and the way it is settled.
///
/// The stored number is minutes since midnight, so "9" read as a number is 00:09 under a label
/// saying 9 AM — which is why the row would not take a keyboard at all. One or two digits are an
/// hour, because that is what somebody typing the start of a window means by them.
private func testABareHourIsAnHour() {
    expectEqual(ControlRules.typedClock("9", into: startRange), 9 * 60, "9 is nine o'clock, not 00:09")
    expectEqual(ControlRules.typedClock("21", into: startRange), 21 * 60, "and 21 is nine in the evening")
    expectEqual(ControlRules.typedClock("09", into: startRange), 9 * 60, "a leading zero changes nothing")
    expectEqual(ControlRules.typedClock("17", into: startRange), 17 * 60, "as does any other hour")
    // The reading it is chosen over is still reachable, by writing it the way a clock is written.
    expectEqual(ControlRules.typedClock("0:09", into: startRange), 9, "nine past midnight has a spelling")
}

/// Three or four digits are the hours and the minutes, which is how anybody with a keyboard and no
/// patience for a colon types a time.
private func testDigitsWithNoSeparatorAreHoursAndMinutes() {
    expectEqual(ControlRules.typedClock("930", into: startRange), 9 * 60 + 30, "930 is half past nine")
    expectEqual(ControlRules.typedClock("2130", into: startRange), 21 * 60 + 30, "and 2130 is half past nine at night")
    expectEqual(ControlRules.typedClock("0930", into: startRange), 9 * 60 + 30, "padded to four, the same")
    expectEqual(ControlRules.typedClock("1745", into: startRange), 17 * 60 + 45, "quarter to six")
    expectEqual(ControlRules.typedClock("000", into: startRange), 0, "and three zeroes are midnight")
    // Five digits are not a time in any notation, and the field must not read the first four.
    expectNil(ControlRules.typedClock("09300", into: startRange), "five digits are nothing")
}

/// The keys people actually reach for. A German keyboard puts the comma under the right hand and
/// the colon behind a shift, and a field that took only one of the three would be a field that
/// looked broken to the person it was built for.
private func testTheSeparatorsPeopleActuallyType() {
    expectEqual(ControlRules.typedClock("9:30", into: startRange), 570, "a colon")
    expectEqual(ControlRules.typedClock("9.30", into: startRange), 570, "a full stop")
    expectEqual(ControlRules.typedClock("9,30", into: startRange), 570, "a comma")
    expectEqual(ControlRules.typedClock("09:30", into: startRange), 570, "with the hour padded")
    expectEqual(ControlRules.typedClock("21:30", into: startRange), 1290, "and on the 24-hour clock")
    // A separator has already said the rest is minutes, so a single digit after one is not
    // ambiguous — reading it as 9:50 would mean inventing a trailing zero, which nothing does.
    expectEqual(ControlRules.typedClock("9:5", into: startRange), 545, "one digit after it is five past")
    // Whitespace anywhere, because a paste carries it and a keyboard slips on it.
    expectEqual(ControlRules.typedClock(" 9:30 ", into: startRange), 570, "spaces around it are ignored")
    expectEqual(ControlRules.typedClock("9 : 30", into: startRange), 570, "and spaces inside it too")
    expectEqual(ControlRules.typedClock("9 30", into: startRange), 570, "which makes a space a separator")
}

/// macOS may be showing this user a 12-hour clock, and the row itself prints one — so the field has
/// to read what the row says back to it.
private func testAMeridiemReadsATwelveHourFace() {
    expectEqual(ControlRules.typedClock("9 pm", into: startRange), 21 * 60, "9 pm is 21:00")
    expectEqual(ControlRules.typedClock("9pm", into: startRange), 21 * 60, "with or without the space")
    expectEqual(ControlRules.typedClock("9 PM", into: startRange), 21 * 60, "and in either case")
    expectEqual(ControlRules.typedClock("9:30pm", into: startRange), 21 * 60 + 30, "minutes come along")
    expectEqual(ControlRules.typedClock("930pm", into: startRange), 21 * 60 + 30, "separator or not")
    expectEqual(ControlRules.typedClock("9 am", into: startRange), 9 * 60, "morning is itself")
    // The two the 12-hour clock gets wrong if it is written as arithmetic.
    expectEqual(ControlRules.typedClock("12 am", into: startRange), 0, "12 am is midnight, not noon")
    expectEqual(ControlRules.typedClock("12 pm", into: startRange), 12 * 60, "and 12 pm is noon, not midnight")
    expectEqual(ControlRules.typedClock("12:30 am", into: startRange), 30, "half past midnight")
    expectEqual(ControlRules.typedClock("11:59 pm", into: startRange), 1439, "and the last minute of the day")
    // Never a guess about which clock is meant: the two notations disagree, so nothing is read.
    expectNil(ControlRules.typedClock("13 pm", into: startRange), "13 pm is nonsense, not 13:00")
    expectNil(ControlRules.typedClock("0 am", into: startRange), "a 12-hour clock has no hour zero")
    expectNil(ControlRules.typedClock("21:30 pm", into: startRange), "nor an hour 21")
    expectNil(ControlRules.typedClock("24 am", into: startRange), "nor an hour 24")
    expectNil(ControlRules.typedClock("pm", into: startRange), "and a bare meridiem is not a time")
}

/// The rule this parser breaks with the typed *number* beside it: out of range reverts.
///
/// 900 minutes of countdown has an honest nearest neighbour and lands on the bound. 25:00 has none
/// — it is a typo, and a window put at 23:59 by one covers hours nobody asked for.
private func testATimeOutsideTheDayRevertsRatherThanClamping() {
    expectNil(ControlRules.typedClock("25:00", into: endRange), "an hour past the day is not a time")
    expectNil(ControlRules.typedClock("2500", into: endRange), "written either way")
    expectNil(ControlRules.typedClock("9:70", into: endRange), "nor is a seventieth minute")
    expectNil(ControlRules.typedClock("970", into: endRange), "written either way")
    expectNil(ControlRules.typedClock("99:99", into: endRange), "nor both at once")
    expectNil(ControlRules.typedClock("24:30", into: endRange), "and 24:00 is the last of them: 24:30 is not")
    expectNil(ControlRules.typedClock("2430", into: endRange), "written either way")
    // A time the day holds but this end of a window does not. A start of 24:00 is not a late
    // start, it is tomorrow — see `TimeWindow.startRange` — so it reverts rather than landing on
    // 23:59, which would keep a day the user did not type.
    expectNil(ControlRules.typedClock("24:00", into: startRange), "a start may not be the end of the day")
    expectNil(ControlRules.typedClock("2400", into: startRange), "written either way")
    expectNil(ControlRules.typedClock("24", into: startRange), "or as a bare hour")
}

/// `0:00` and `24:00` are the same instant and two different numbers, and the model means both:
/// the near edge of the day and the far one. Neither is translated into the other.
private func testBothEdgesOfTheDayAreTimesAndTheyAreDifferentNumbers() {
    expectEqual(ControlRules.typedClock("0:00", into: startRange), 0, "a window may begin as the day does")
    expectEqual(ControlRules.typedClock("0", into: startRange), 0, "however it is written")
    expectEqual(ControlRules.typedClock("00:00", into: startRange), 0, "or written")
    expectEqual(ControlRules.typedClock("12 am", into: startRange), 0, "or written")
    expectEqual(
        ControlRules.typedClock("24:00", into: endRange), TimeWindow.minutesInDay,
        "and may end where the day does"
    )
    expectEqual(ControlRules.typedClock("24", into: endRange), TimeWindow.minutesInDay, "however written")
    // The end field holds both, and they are not the same window: 1440 is the whole of the ticked
    // day, 0 is a window whose end has walked back past its own start. `TimeWindow.crossesMidnight`
    // reads them apart, which it could not do if the field collapsed them.
    expectEqual(ControlRules.typedClock("0:00", into: endRange), 0, "an end of 0:00 stays 0:00")
    expect(
        ControlRules.typedClock("0:00", into: endRange) != ControlRules.typedClock("24:00", into: endRange),
        "the two edges of the day are two numbers"
    )
}

/// Nothing usable typed is nothing done, exactly as it is for a number: the field puts back what it
/// held, with no error state to dismiss.
private func testNothingUsableTypedIntoATimeFieldChangesNothing() {
    expectNil(ControlRules.typedClock("", into: endRange), "an emptied field reverts")
    expectNil(ControlRules.typedClock("   ", into: endRange), "and one holding only spaces")
    expectNil(ControlRules.typedClock("morning", into: endRange), "a word is not a time")
    expectNil(ControlRules.typedClock("9h30", into: endRange), "nor a separator this app does not take")
    expectNil(ControlRules.typedClock("-9", into: endRange), "nor a negative hour")
    expectNil(ControlRules.typedClock("+9", into: endRange), "nor a signed one")
    expectNil(ControlRules.typedClock("9:", into: endRange), "nor half a written time")
    expectNil(ControlRules.typedClock(":30", into: endRange), "nor the other half")
    expectNil(ControlRules.typedClock("9:30:00", into: endRange), "nor one with seconds on it")
    expectNil(ControlRules.typedClock("9:305", into: endRange), "nor three digits of minutes")
    expectNil(ControlRules.typedClock("930am930", into: endRange), "nor two times at once")
    expectNil(
        ControlRules.typedClock("99999999999999999999", into: endRange),
        "and a run of digits too long to hold is a paste, not a time"
    )
}

/// The pair that makes the field safe to click into: whatever the notation writes, it reads back as
/// the same minute. A field that failed this anywhere would rewrite a window somebody only looked
/// at — which is precisely what a 12-hour draft used to do at the end of the day, where `12 AM` is
/// both edges and only one of them survives. The word `midnight` is what buys the other 1440 their
/// own clock.
private func testEveryMinuteOfTheDaySurvivesTheRoundTrip() {
    let notation = FieldNotation.clock
    let broken = (endRange.lowerBound...endRange.upperBound).filter { minutes in
        notation.read(notation.draft(minutes), endRange)?.value != minutes
    }
    expectEqual(broken, [], "every minute an end may hold is written and read back as itself")
    let brokenStarts = (startRange.lowerBound...startRange.upperBound).filter { minutes in
        notation.read(notation.draft(minutes), startRange)?.value != minutes
    }
    expectEqual(brokenStarts, [], "and every minute a start may hold")
    // The draft is the row's own face — `TimeWindowCopy.endpoint`, the same function the row prints
    // with — so clicking into a time changes nothing about how it is written.
    expectEqual(notation.draft(570), "9:30 AM", "half past nine in the morning")
    expectEqual(notation.draft(1290), "9:30 PM", "half past nine at night")
    expectEqual(notation.draft(0), "12 AM", "the near edge of the day")
    expectEqual(notation.draft(TimeWindow.minutesInDay), "midnight", "and the far one, named apart")
    // A clock never clamps, so the row's "Most is…" note never fires under this notation.
    expectNil(notation.read("25:00", endRange), "an impossible time is not a value at all")
    expectEqual(
        notation.read("930", endRange), ControlRules.TypedNumber(value: 570, wasClamped: false),
        "and a possible one is never held back"
    )
}

/// The complaint this answers: AM/PM and 24-hour notation were mixed. The row
/// printed `9:30 AM` and a click into it handed the keyboard `09:30`, so the notation changed under
/// the cursor. One function now does both, and this says so about the whole day rather than about
/// the three values above.
private func testTheDraftIsTheSameFaceTheRowPrints() {
    let differing = (endRange.lowerBound...endRange.upperBound).filter { minutes in
        FieldNotation.clock.draft(minutes) != TimeWindowCopy.endpoint(minutes)
    }
    expectEqual(differing, [], "no minute of the day is written one way at rest and another typed")
    expectEqual(TimeWindowCopy.endpoint(1290), "9:30 PM", "and that way is the 12-hour clock")
}

/// The one minute the 12-hour clock cannot spell, and what it costs to leave it unnamed: an all-day
/// window clicked into and out of again would come back as one crossing midnight.
private func testTheFarEdgeOfTheDayHasAName() {
    expectEqual(TimeWindowCopy.endpoint(TimeWindow.minutesInDay), "midnight", "1440 is named")
    expectEqual(TimeWindowCopy.endpoint(0), "12 AM", "and 0 keeps the clock face it always had")
    expectEqual(
        ControlRules.typedClock(TimeWindowCopy.endOfDay, into: endRange), TimeWindow.minutesInDay,
        "an end field reads the word as the far edge"
    )
    expectEqual(
        ControlRules.typedClock("Midnight", into: endRange), TimeWindow.minutesInDay,
        "in any case, like every other face"
    )
    expectEqual(
        ControlRules.typedClock(" midnight ", into: endRange), TimeWindow.minutesInDay,
        "and with whatever whitespace around it"
    )
    // A start cannot be 1440 at all — see `TimeWindow.startRange` — so the only midnight it has is
    // the near one, which is also the one somebody typing the word into a start field means.
    expectEqual(
        ControlRules.typedClock("midnight", into: startRange), 0,
        "a start field reads the word as the near edge"
    )
    // The word is a face, not a licence: nothing else spelled out is a time.
    expectNil(ControlRules.typedClock("noon", into: endRange), "noon is not one of them")
    expectNil(ControlRules.typedClock("midnights", into: endRange), "nor a near miss of the one word")
    expectNil(ControlRules.typedClock("12 midnight", into: endRange), "nor the word with a face on it")
}

/// What the row reads once a window ends where the day does, which is the wording the field now
/// hands the keyboard as well.
private func testAWindowEndingAtTheEndOfTheDayReadsAsMidnight() {
    let evening = TimeWindow(
        kind: .strictBlock, weekdays: TimeWindow.everyDay,
        startMinutes: 21 * 60, endMinutes: TimeWindow.minutesInDay
    )
    expectEqual(TimeWindowCopy.range(evening), "9 PM – midnight", "the far edge is named on the row")
    let allDay = TimeWindow.make(.allDay, kind: .strictBlock)
    expectEqual(TimeWindowCopy.range(allDay), "All day", "and a whole day is still one phrase")
    let night = TimeWindow(
        kind: .strictBlock, weekdays: TimeWindow.everyDay, startMinutes: 22 * 60, endMinutes: 8 * 60
    )
    expectEqual(TimeWindowCopy.range(night), "10 PM – 8 AM", "an ordinary night is untouched")
}

/// The other direction, which is the field saying it understood: what comes back is the row's own
/// notation rather than the digits that were typed.
private func testAReadTimeComesBackInTheRowsOwnNotation() {
    let typed = ["930", "9:30", "9.30", "0930", "9:30 am", "930AM"]
    let read = typed.compactMap { ControlRules.typedClock($0, into: startRange) }
    expectEqual(read, Array(repeating: 570, count: typed.count), "six ways to write half past nine")
    expectEqual(read.map(TimeWindowCopy.hour12), Array(repeating: "9:30 AM", count: typed.count),
                "all of which the row prints back as one time")
    expectEqual(
        TimeWindowCopy.hour12(ControlRules.typedClock("2130", into: startRange) ?? -1), "9:30 PM",
        "and an evening typed on the 24-hour clock reads back on the 12-hour one"
    )
}

/// Half-hours were the whole grid, so 9:15 could not be reached with the arrows at all. A quarter
/// is the smallest unit anybody names a window in.
private func testOnePressOfATimeControlLandsOnTheQuarterHour() {
    expectEqual(ControlRules.clockMinutes(after: 540, goingUp: true), 555, "9:00 steps up to 9:15")
    expectEqual(ControlRules.clockMinutes(after: 555, goingUp: true), 570, "and on to 9:30")
    expectEqual(ControlRules.clockMinutes(after: 540, goingUp: false), 525, "and down to 8:45")
    // A destination, not a size: a typed value on no grid line steps onto the nearest one rather
    // than carrying its offset up and down the day forever.
    expectEqual(ControlRules.clockMinutes(after: 547, goingUp: true), 555, "9:07 steps up onto 9:15")
    expectEqual(ControlRules.clockMinutes(after: 547, goingUp: false), 540, "and down onto 9:00")
    expectEqual(ControlRules.clockMinutes(after: 1439, goingUp: false), 1425, "23:59 down to 23:45")
    // The ends of the day are on the grid, so the arrows reach them exactly.
    expectEqual(ControlRules.clockMinutes(after: 15, goingUp: false), 0, "the first quarter steps to midnight")
    expectEqual(
        ControlRules.clockMinutes(after: 1425, goingUp: true), TimeWindow.minutesInDay,
        "and the last one to the end of the day"
    )
    // A press and its undo are each other, everywhere on the grid — which is what going down asks
    // about the minute below for, rather than reading the same grid line twice.
    let asymmetric = stride(from: 15, through: 1425, by: 15).filter { minutes in
        ControlRules.clockMinutes(after: ControlRules.clockMinutes(after: minutes, goingUp: true), goingUp: false)
            != minutes
            || ControlRules.clockMinutes(after: ControlRules.clockMinutes(after: minutes, goingUp: false), goingUp: true)
            != minutes
    }
    expectEqual(asymmetric, [], "every quarter-hour steps back to itself")
    // Every press lands on the grid, from anywhere in the day, in both directions.
    let offGrid = (0...TimeWindow.minutesInDay).filter { minutes in
        ControlRules.clockMinutes(after: minutes, goingUp: true) % 15 != 0
            || ControlRules.clockMinutes(after: minutes, goingUp: false) % 15 != 0
    }
    expectEqual(offGrid, [], "and no press lands off it")
}

/// The relock warning was four rows on a dropdown — None, 30 seconds, a minute, five — which is
/// somebody else's opinion about how much warning is enough, offered as the only opinions
/// available. It is a stepper over nought to five minutes now, and nought is the off state.
private func testTheWarningStepperWalksHalfMinutesAndUndoesItself() {
    let next = Config.expiryWarningSeconds(after:goingUp:)
    expectEqual(next(0, true), 30, "off steps up to half a minute")
    expectEqual(next(30, true), 60, "and on to one")
    expectEqual(next(30, false), 0, "and back down to off")
    expectEqual(next(0, false), 0, "which is where the span stops")
    expectEqual(
        next(Config.expiryWarningRange.upperBound, false), 270, "and the top steps back off itself"
    )
    // A press and its undo are each other, and a value on no grid line — typed, or left by the
    // dropdown this replaces — steps onto the grid rather than carrying its offset up the span.
    let asymmetric = Array(stride(from: 30, through: 270, by: 30)).filter { seconds in
        next(next(seconds, true), false) != seconds || next(next(seconds, false), true) != seconds
    }
    expectEqual(asymmetric, [], "every half-minute steps back to itself")
    expectEqual(next(45, true), 60, "an off-grid 45 steps up onto the grid")
    expectEqual(next(45, false), 30, "and down onto it")
    let offGrid = Array(Config.expiryWarningRange).filter { seconds in
        next(seconds, true) % 30 != 0 || next(seconds, false) % 30 != 0
    }
    expectEqual(offGrid, [], "and no press lands off it")
}

/// The two seconds-long durations on the settings page are a few points apart, so they are one
/// function: two rows spelling the same ninety seconds two ways would read as two different units.
private func testALengthInSecondsReadsAsMinutesPastTheMinute() {
    expectEqual(DurationCopy.seconds(0), "0 sec", "nought is a length like any other here")
    expectEqual(DurationCopy.seconds(45), "45 sec", "under a minute, seconds")
    expectEqual(DurationCopy.seconds(60), "1 min", "a whole minute reads as one")
    expectEqual(DurationCopy.seconds(90), "1 min 30 sec", "and the rest comes after it, not instead")
    expectEqual(DurationCopy.seconds(600), "10 min", "ten minutes, not 600 seconds")
}
