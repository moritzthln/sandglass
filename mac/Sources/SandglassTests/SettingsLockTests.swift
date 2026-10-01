import SandglassAppCore
import SandglassCore
import Foundation

/// The two frictions on changing the configuration: what they refuse, when they stop refusing
/// it, and the one thing they must never do — trap somebody in a configuration they cannot edit.
///
/// **The value layers, which is the first two of three.** What is stored — the passcode hash and
/// the lock on disk — and the gate's rules on their own, asked as arithmetic over a lock and a
/// moment. The third layer is the whole app refusing a real edit, and it is the one that matters
/// most: a gate that refuses correctly and is never asked would pass every check here. It lives
/// next door in `SettingsLockEditTests`, the split `GroupLockTests` and `GroupLockEditTests`
/// already follow, and it is where every `AppState` case went when this file reached the
/// 800-line ceiling.
func runSettingsLockTests() {
    testPasscodeHashRoundTrips()
    testPasscodeHashRejectsAWrongPasscode()
    testPasscodeHashIsSaltedPerPasscode()
    testTheTimerStepGrowsWithTheNumberAndUndoesItself()
    testTimerRefusesThenPermits()
    testTheCountdownReadsAsMinutesAndSeconds()
    testAnUnannouncedWindowIsRefusedInFull()
    testTheTimerDoesNotApplyOutsideASettingsWindow()
    testThePasscodeAppliesToEveryScope()
    testAStandaloneAnswerIsRememberedNowhere()
    testClosingTheWindowStartsTheTimerAgain()
    testTheVisitThatSwitchesTheTimerOnIsNotHeldByIt()
    testAMarkLeftWithNoWindowOpenExemptsNoVisit()
    testPasscodeRefusesUntilItIsEnteredOncePerVisit()
    testNeitherFrictionAppliesWhenBothAreOff()
    testAnEmergencyPassLiftsBothFrictions()
    testForgotCompletesOnlyAfterTheFullHour()
    testForgotIsImmuneToAClockJump()
    testForgotFallsBackToTheWallClockAfterAReboot()
    testForgotIsIgnoredWhileRecoveryIsOff()
    testAConfigWithoutALockStillDecodes()
    testALockSurvivesTheDisk()
}

// MARK: - What is stored

private func testPasscodeHashRoundTrips() {
    guard let hash = PasscodeHash.make("2468") else {
        failTest("a four-character passcode is long enough")
        return
    }
    expect(hash.matches("2468"), "the passcode it was made from matches")
    expect(hash.salt.count == 32, "the salt is 32 bytes")
    guard let data = try? SandglassJSON.encoder.encode(hash),
          let back = try? SandglassJSON.decoder.decode(PasscodeHash.self, from: data) else {
        failTest("a passcode hash survives JSON")
        return
    }
    expectEqual(back, hash, "the hash comes back off disk unchanged")
    expect(back.matches("2468"), "and still recognises its passcode")
    // The point of storing a hash: the passcode is not in the document.
    expect(
        !(String(data: data, encoding: .utf8) ?? "").contains("2468"),
        "the passcode itself is nowhere in what is written"
    )
}

private func testPasscodeHashRejectsAWrongPasscode() {
    guard let hash = PasscodeHash.make("2468") else {
        failTest("passcode could not be hashed")
        return
    }
    expect(!hash.matches("2469"), "one digit out is refused")
    expect(!hash.matches(""), "and so is nothing at all")
    expect(!hash.matches("24680"), "and so is the right passcode with more after it")
    expectNil(PasscodeHash.make("123"), "three characters is not a passcode")
    expectNil(PasscodeHash.make(""), "nor is an empty one")
}

/// Two people choosing 1234 must not produce the same digest, or a table computed once would
/// read every Sandglass passcode there is.
private func testPasscodeHashIsSaltedPerPasscode() {
    guard let first = PasscodeHash.make("1234"), let second = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    expect(first.salt != second.salt, "the same passcode twice gets two salts")
    expect(first.digest != second.digest, "and therefore two digests")
    expect(second.matches("1234"), "both still match the passcode")
}

// MARK: - The gate, on its own

/// The lock's duration was six numbers on a dropdown. It is a stepper over a minute to four hours
/// now, and a span that wide cannot have one step size: 1 makes an hour sixty presses, 15 puts
/// five minutes out of reach. So the step grows with the number — and the part worth pinning is
/// that **a press and its undo are each other**, which is the thing an uneven step gets wrong.
private func testTheTimerStepGrowsWithTheNumberAndUndoesItself() {
    let next = SettingsLock.timerMinutes(after:goingUp:)
    expectEqual(next(1, true), 2, "a minute at a time while a minute still means something")
    expectEqual(next(9, true), 10, "up to ten")
    expectEqual(next(10, true), 15, "then fives, so 45 is seven presses rather than unreachable")
    expectEqual(next(55, true), 60, "landing on the hour rather than stepping over it")
    expectEqual(next(60, true), 75, "and quarter-hours past it, where a minute buys nothing")
    expectEqual(next(10, false), 9, "ten steps down to nine rather than to five")
    expectEqual(next(60, false), 55, "and the hour steps down to 55 rather than to 45")

    // Every band edge, walked down and back up. Reading the band off the current value in both
    // directions would step 60 down to 45 and back up to 50 — an undo that lands somewhere else.
    for value in [2, 10, 15, 60, 75, 240] {
        expectEqual(
            next(next(value, false), true), value, "\(value) steps down and back up to itself"
        )
    }

    // A hand-edited `config.json` can hold anything, and a number on no grid has to walk onto one
    // rather than carry its offset up and down the span forever.
    expectEqual(next(11, true), 15, "an off-grid 11 steps up onto the grid")
    expectEqual(next(11, false), 10, "and down onto it")
    expectEqual(next(61, false), 60, "the same past the hour")
    expectEqual(next(600, false), 585, "a value past the span steps in the coarsest band")
    expectEqual(next(0, true), 1, "and one below it in the finest")
}

private func testTimerRefusesThenPermits() {
    let lock = SettingsLock(timerMinutes: 10)
    var gate = SettingsLockGate()
    gate.windowOpened(at: reading(at: noon))

    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow),
        .timer(secondsLeft: 600),
        "the settings open locked"
    )
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow)?.text,
        "Held by the settings lock",
        "and say what is holding it, without a number — see below"
    )
    let almost = reading(at: noon.addingTimeInterval(9 * 60 + 12))
    expectEqual(
        refusal(gate, lock, at: almost, scope: .settingsWindow),
        .timer(secondsLeft: 48),
        "the wait itself runs down while the window is open"
    )
    expectEqual(
        refusal(gate, lock, at: almost, scope: .settingsWindow)?.text,
        "Held by the settings lock",
        "and the words do not move with it: a refusal is stored in the screen's state and nothing "
            + "redraws it, so a number embedded here would be the one sentence in the app that "
            + "had stopped. The counting is the banner's, off the live lock"
    )
    expectNil(
        refusal(gate, lock, at: reading(at: noon.addingTimeInterval(600)), scope: .settingsWindow),
        "and lets go on the tenth minute"
    )
}

/// `m:ss`, and the banner across the top of the main window is its one caller — so the format is
/// pinned here rather than through a refusal string, which is where it used to be read.
private func testTheCountdownReadsAsMinutesAndSeconds() {
    expectEqual(SettingsLockGate.countdownText(600), "10:00", "ten whole minutes")
    expectEqual(SettingsLockGate.countdownText(48), "0:48", "under a minute keeps the leading 0:")
    expectEqual(SettingsLockGate.countdownText(95), "1:35", "and the seconds are always two digits")
    expectEqual(SettingsLockGate.countdownText(0), "0:00", "the last second before it goes away")
    expectEqual(SettingsLockGate.countdownText(-5), "0:00", "and it never counts past zero")
}

/// Fail-closed: a window that never said it had opened is treated as one that just did. Every
/// window that can edit announces itself, so the alternative would be a hole rather than a
/// convenience.
private func testAnUnannouncedWindowIsRefusedInFull() {
    let gate = SettingsLockGate()
    expectEqual(
        refusal(gate, SettingsLock(timerMinutes: 5), at: reading(at: noon), scope: .settingsWindow),
        .timer(secondsLeft: 300),
        "an edit with no window open is refused for the whole wait"
    )
}

/// The other half of the rule above, and the reason the scope exists at all. A wait measured from
/// a window that is not open cannot be waited out — so where there is no window to wait in, the
/// timer does not apply rather than refusing forever. See `SettingsLockScope`.
private func testTheTimerDoesNotApplyOutsideASettingsWindow() {
    let lock = SettingsLock(timerMinutes: 10)
    var gate = SettingsLockGate()

    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction),
        "a deliberate action with no window open is not made to wait"
    )
    gate.windowOpened(at: reading(at: noon))
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow),
        .timer(secondsLeft: 600),
        "the same second inside the window is refused for the full wait"
    )
    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction),
        "and an open window does not start applying the wait to what is outside it"
    )
}

/// The passcode asks who you are, which is a question with an answer wherever it is put. Both
/// scopes carry it — but they do not remember it the same way, and that is the point below.
private func testThePasscodeAppliesToEveryScope() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let lock = SettingsLock(passcode: hash)
    var gate = SettingsLockGate()

    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction), .passcode,
        "a deliberate action is refused until the passcode is entered"
    )
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow), .passcode,
        "and so is an edit"
    )
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction, answered: "0000"),
        .wrongPasscode, "a standalone action is judged on what it carries, and this is wrong"
    )
    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction, answered: "1234"),
        "and this is right"
    )
    expect(gate.accept(passcode: "1234", for: lock), "the passcode is entered in a settings visit")
    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow),
        "which is what the edit was waiting for"
    )
}

/// The two scopes remember differently, and nothing crosses between them.
///
/// A standalone action carries its own answer and leaves no trace: it neither reads the visit
/// flag nor sets one. Reading it meant a single settings unlock waved every later break through;
/// setting it meant the first break after launch was the only one ever challenged, because a
/// popover opens no window and only `windowOpened`/`windowClosed` clear the flag.
private func testAStandaloneAnswerIsRememberedNowhere() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let lock = SettingsLock(passcode: hash)
    var gate = SettingsLockGate()

    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction, answered: "1234"),
        "one standalone action is answered"
    )
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction), .passcode,
        "and the next one asks again, with no window ever having opened or closed"
    )
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow), .passcode,
        "and the settings are no more unlocked than they were"
    )

    // The other direction: a settings visit's unlock is not an answer for a standalone action.
    gate.windowOpened(at: reading(at: noon))
    expect(gate.accept(passcode: "1234", for: lock), "the visit is unlocked")
    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow), "so edits go through"
    )
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction), .passcode,
        "but a break started from the menu bar still asks for itself"
    )
}

private func testClosingTheWindowStartsTheTimerAgain() {
    let lock = SettingsLock(timerMinutes: 10)
    var gate = SettingsLockGate()
    gate.windowOpened(at: reading(at: noon))
    let later = noon.addingTimeInterval(600)
    expectNil(refusal(gate, lock, at: reading(at: later), scope: .settingsWindow), "the wait is over")

    // Asking for a window that is already open must not restart the countdown, or clicking
    // "Settings" a second time would be the way round the lock.
    gate.windowOpened(at: reading(at: later))
    expectNil(
        refusal(gate, lock, at: reading(at: later), scope: .settingsWindow),
        "re-opening an open window changes nothing"
    )

    gate.windowClosed()
    gate.windowOpened(at: reading(at: later))
    expectEqual(
        refusal(gate, lock, at: reading(at: later), scope: .settingsWindow),
        .timer(secondsLeft: 600),
        "a fresh visit waits again"
    )
}

/// The visit that switches the timer on is never held by it.
///
/// The trap this undoes: the wait is measured from the window opening, which has already
/// happened, so the toggle used to land with the whole default already owed — and the "Locked
/// for" stepper that chooses the length sits on the same page, behind the same wait. Nobody
/// picked ten minutes; they were given the default and then could not change it without sitting
/// out the default.
///
/// The mark is on the visit rather than on the lock, which is what keeps the other half intact:
/// the countdown arms from the **next** window open, and from then on it holds the duration, the
/// toggle and everything else.
private func testTheVisitThatSwitchesTheTimerOnIsNotHeldByIt() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let lock = SettingsLock(timerMinutes: 10)
    var gate = SettingsLockGate()
    gate.windowOpened(at: reading(at: noon))
    gate.timerSwitchedOn()

    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow),
        "the visit that switched it on is free to change it"
    )
    expectNil(
        gate.state(for: lock, at: reading(at: noon), emergencyPassRunning: false).unlockSeconds,
        "and nothing is counting down at them while they pick a length"
    )
    expectEqual(
        refusal(
            gate, SettingsLock(timerMinutes: 10, passcode: hash), at: reading(at: noon),
            scope: .settingsWindow
        ),
        .passcode,
        "the passcode is the other question, and this mark is no answer to it"
    )

    gate.windowClosed()
    gate.windowOpened(at: reading(at: noon))
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow),
        .timer(secondsLeft: 600),
        "and the next visit is held for the whole of what was chosen"
    )
}

/// A mark that belongs to no visit belongs to nothing.
///
/// Fail-closed, for the reason `timerSecondsLeft` fails closed on a window that never announced
/// itself: the exemption is a fact about one visit, so a visit that opens afterwards inherits
/// none of it.
private func testAMarkLeftWithNoWindowOpenExemptsNoVisit() {
    let lock = SettingsLock(timerMinutes: 10)
    var gate = SettingsLockGate()
    gate.timerSwitchedOn()

    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow),
        .timer(secondsLeft: 600),
        "an edit with no window open is refused whole, mark or no mark"
    )
    gate.windowOpened(at: reading(at: noon))
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow),
        .timer(secondsLeft: 600),
        "and the visit that opens afterwards is held like any other"
    )
}

private func testPasscodeRefusesUntilItIsEnteredOncePerVisit() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let lock = SettingsLock(passcode: hash)
    var gate = SettingsLockGate()
    gate.windowOpened(at: reading(at: noon))

    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow),
        .passcode,
        "a passcode-locked settings refuses an edit"
    )
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow)?.text,
        "Enter the passcode to change settings",
        "and says what it wants"
    )
    expect(!gate.accept(passcode: "4321", for: lock), "the wrong passcode is not accepted")
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow), .passcode,
        "and changes nothing"
    )
    expect(gate.accept(passcode: "1234", for: lock), "the right one is")
    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow),
        "and every edit after it goes through, without asking again"
    )

    gate.windowClosed()
    gate.windowOpened(at: reading(at: noon))
    expectEqual(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow), .passcode,
        "the next visit asks again"
    )
    expect(
        !gate.accept(passcode: "1234", for: SettingsLock()),
        "a lock with no passcode accepts nothing"
    )
}

private func testNeitherFrictionAppliesWhenBothAreOff() {
    var gate = SettingsLockGate()
    gate.windowOpened(at: reading(at: noon))
    let off = SettingsLock()
    expectNil(
        refusal(gate, off, at: reading(at: noon), scope: .settingsWindow),
        "an unlocked settings refuses nothing"
    )
    expectNil(
        refusal(gate, off, at: reading(at: noon), scope: .deliberateAction),
        "and neither does a deliberate action"
    )
    expectEqual(
        gate.state(for: off, at: reading(at: noon), emergencyPassRunning: false),
        SettingsLockState(),
        "and shows no countdown, no passcode and no reset"
    )
}

/// The escape that keeps the lock from being a trap: with recovery switched off, a forgotten
/// passcode would otherwise freeze the configuration for good.
private func testAnEmergencyPassLiftsBothFrictions() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let lock = SettingsLock(timerMinutes: 30, passcode: hash, allowForgot: false)
    var gate = SettingsLockGate()
    gate.windowOpened(at: reading(at: noon))

    expect(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow) != nil,
        "locked, with no way back inside the app"
    )
    expect(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction) != nil,
        "and so is what happens outside the window"
    )
    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .settingsWindow, emergencyPass: true),
        "an emergency pass unlocks both frictions at once"
    )
    expectNil(
        refusal(gate, lock, at: reading(at: noon), scope: .deliberateAction, emergencyPass: true),
        "for every scope, not only the one with a window"
    )
    expectEqual(
        gate.state(for: lock, at: reading(at: noon), emergencyPassRunning: true),
        SettingsLockState(),
        "and the screen stops counting down"
    )
}

// MARK: - Forgetting the passcode

private func testForgotCompletesOnlyAfterTheFullHour() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let started = reading(at: noon)
    var lock = SettingsLock(passcode: hash, forgotStartedAt: started)

    expectEqual(lock.forgotSecondsLeft(at: started), 3600, "the wait is an hour")
    expectEqual(
        lock.forgotSecondsLeft(at: reading(at: noon.addingTimeInterval(59 * 60))), 60,
        "fifty-nine minutes in, a minute is left"
    )
    expect(!lock.forgotIsDue(at: reading(at: noon.addingTimeInterval(59 * 60))), "and it is not due")
    expect(
        !lock.clearForgottenPasscode(at: reading(at: noon.addingTimeInterval(59 * 60))),
        "so nothing is cleared"
    )
    expect(lock.passcode != nil, "the passcode is still there")

    let hourLater = reading(at: noon.addingTimeInterval(3600))
    expectNil(lock.forgotSecondsLeft(at: hourLater), "on the hour the countdown is over")
    expect(lock.clearForgottenPasscode(at: hourLater), "and the passcode is cleared")
    expectNil(lock.passcode, "there is no passcode any more")
    expectNil(lock.forgotStartedAt, "and no wait left behind to clear the next one")
    expect(!lock.clearForgottenPasscode(at: hourLater), "clearing again reports no change")
}

/// The hour is measured on the uptime counter, which nobody can set. Winding the wall clock
/// forward two hours buys none of it.
private func testForgotIsImmuneToAClockJump() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let clock = FakeClock(noon)
    var lock = SettingsLock(passcode: hash, forgotStartedAt: reading(of: clock))

    clock.advance(seconds: 5 * 60)
    clock.moveWallClock(by: 2 * 3600)   // somebody in the Date & Time pane
    expectEqual(lock.forgotSecondsLeft(at: reading(of: clock)), 3300, "five real minutes have run")
    expect(!lock.clearForgottenPasscode(at: reading(of: clock)), "the clock buys nothing")

    clock.advance(seconds: 55 * 60)
    expect(lock.clearForgottenPasscode(at: reading(of: clock)), "an hour of real time does")
}

/// A restart leaves the uptime pair measured against a counter that no longer exists, so the
/// wall clock is all there is — the same trade `EngineState.dropUptimeTwins` makes.
private func testForgotFallsBackToTheWallClockAfterAReboot() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    let clock = FakeClock(noon)
    let lock = SettingsLock(passcode: hash, forgotStartedAt: reading(of: clock))

    clock.advance(seconds: 30 * 60)
    clock.reboot()
    expectEqual(
        lock.forgotSecondsLeft(at: reading(of: clock)), 1800,
        "the half hour that passed is still counted, from the wall clock"
    )
    clock.advance(seconds: 30 * 60)
    expect(lock.forgotIsDue(at: reading(of: clock)), "and the hour still finishes")
}

private func testForgotIsIgnoredWhileRecoveryIsOff() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    var lock = SettingsLock(passcode: hash, allowForgot: false, forgotStartedAt: reading(at: noon))
    let hourLater = reading(at: noon.addingTimeInterval(3600))
    expectNil(lock.forgotSecondsLeft(at: hourLater), "a wait left over from before is not counted")
    expect(!lock.clearForgottenPasscode(at: hourLater), "and it never clears the passcode")
    expect(lock.passcode != nil, "which is what switching recovery off promises")
}

// MARK: - On disk

/// The schema-evolution rule in `SandglassJSON`: a `config.json` written before the lock existed
/// keeps loading, and loads unlocked.
private func testAConfigWithoutALockStillDecodes() {
    let older = """
        {
          "dayStartMinutes" : 180,
          "groupSettings" : {},
          "reflectionPrompt" : "Why are you here?",
          "targets" : [],
          "version" : 1
        }
        """
    guard let config = try? SandglassJSON.decoder.decode(Config.self, from: Data(older.utf8)) else {
        failTest("a config written before the settings lock existed still decodes")
        return
    }
    expectNil(config.settingsLock.timerMinutes, "with no timer")
    expectNil(config.settingsLock.passcode, "no passcode")
    expect(config.settingsLock.allowForgot, "and recovery allowed, which is the default")
    expectNil(config.settingsLock.forgotStartedAt, "and nothing waiting")
    expect(
        !config.settingsLock.coversQuickDisable,
        "and the break ungated, which is what it was when the file was written"
    )
}

private func testALockSurvivesTheDisk() {
    guard let hash = PasscodeHash.make("1234") else {
        failTest("passcode could not be hashed")
        return
    }
    var config = webConfig()
    config.settingsLock = SettingsLock(
        timerMinutes: 30, passcode: hash, allowForgot: false,
        forgotStartedAt: ClockReading(wall: noon, uptime: 10_000),
        coversQuickDisable: true
    )
    guard let data = try? SandglassJSON.encoder.encode(config),
          let back = try? SandglassJSON.decoder.decode(Config.self, from: data) else {
        failTest("a config with a lock survives JSON")
        return
    }
    expectEqual(back.settingsLock, config.settingsLock, "every field comes back unchanged")
}

// MARK: - Fixtures

/// The gate, asked in fewer characters than its own signature takes. The scope is never defaulted
/// — which of the two frictions a case is about is the point of half of them.
private func refusal(
    _ gate: SettingsLockGate, _ lock: SettingsLock, at now: ClockReading,
    scope: SettingsLockScope, emergencyPass: Bool = false, answered: String? = nil
) -> SettingsLockGate.Refusal? {
    gate.refusal(
        for: lock, at: now, emergencyPassRunning: emergencyPass, scope: scope, answered: answered
    )
}

private func reading(at wall: Date) -> ClockReading {
    ClockReading(wall: wall, uptime: 10_000 + wall.timeIntervalSince(noon))
}

private func reading(of clock: FakeClock) -> ClockReading {
    ClockReading(wall: clock.now, uptime: clock.uptime)
}
