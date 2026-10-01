import SandglassAppCore
import SandglassCore
import Foundation

/// `AppState` is the app's loop, and everything in it is a rule rather than a pixel: what a
/// damaged file does to the status, when the state is written, when the blocker is disturbed,
/// what setup is allowed to overwrite, and what the stats screen is allowed to claim. All of
/// that is testable because `SandglassAppCore` imports no UI framework — see that module's
/// header. The pause button has enough rules of its own to have its own file next door.
///
/// The clock is always injected, so a schedule window, a session expiry and a day boundary
/// are crossed by arithmetic rather than by waiting. The fixtures are in `AppStateFixtures`.
func runAppStateTests() {
    // Every `AppState` is MainActor-isolated, and this executable's main thread is that
    // actor's executor. Asserting it once here keeps the annotation off every test below.
    MainActor.assumeIsolated {
        testFirstLaunchHasNothingToProtect()
        testALoadedConfigurationDoesNotOpenTheWindow()
        testDamagedConfigIsDegradedAndOpensTheWindow()
        testUnreadableStateIsNeverOverwritten()
        testStateIsWrittenOnlyWhenItChanges()
        testSaveFailureIsSurfacedAndClears()
        testPrimingNeverDisturbsTheBlocker()
        testEveryBeatSweepsTheVisibleBlockedApps()
        testBlockerIsDisturbedOnlyWhenTheBlockedSetChanges()
        testUpdateConfigAlwaysRechecksEvenWhenNothingIsBlocked()
        testUpdateConfigPropagatesANewBlock()
        testDayRollsOverWhileTheAppIsRunning()
        testInboundBlockerAPIResolvesLogsAndResyncs()
        testDisplayInfoNamesTheAppBehindABundleID()
        testAGroupMadeOfChipsIsVisibleAndProtects()
        testGentleOpenLeavesNothingBehindToUnblockIt()
        testAnUnreadableConfigIsNeverWrittenOver()
        testAnEditThatCannotBeWrittenIsNotRun()
        testAFailedDeleteGivesTheGroupBackWithTheDayItHad()
        testConfigEditIsAllowedInsideAStrictWindow()
        testResettingTodayIsAllowedInsideAStrictWindowToo()
            testAConfigEditGoesThroughDuringAFocusSession()
        testWeeklyOpensArePassedThroughWithTheirHonesty()
        testTodaysNumbersArePublished()
        testABudgetRowIsNamedAfterItsGroup()
        testAnIdleSecondPublishesNothing()
    }
}

// MARK: - Startup outcomes

/// What a launch does about it is open the main window — see `main.swift`. There is no wizard
/// behind that flag any more; what it means is "there is nothing here yet", and the window says
/// so in the sidebar with the `+` beside it.
@MainActor
private func testFirstLaunchHasNothingToProtect() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expect(state.hasNothingToProtect, "an empty directory is a first launch")
        expectEqual(state.statusKind, .active(targetCount: 0), "nothing is claimed to be protected")
        expect(state.warningLines.isEmpty, "a first launch is not a degraded state")
    }
}

@MainActor
private func testALoadedConfigurationDoesNotOpenTheWindow() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        expect(!state.hasNothingToProtect, "a configuration with targets is not a blank slate")
        expectEqual(state.statusKind, .active(targetCount: 1), "the one managed target is counted")
    }
}

@MainActor
private func testDamagedConfigIsDegradedAndOpensTheWindow() {
    withTempDir { dir in
        _ = Store(directory: dir)                                  // creates the directory
        try? Data("{ not json".utf8).write(to: configFile(dir))
        let state = makeState(dir, clock: FakeClock(noon))
        expectDegraded(
            state.statusKind, mentioning: "Settings file",
            "a damaged configuration is degraded from the first moment, not from the first tick"
        )
        expect(state.hasNothingToProtect, "a quarantined configuration leaves nothing to run on")
        expect(
            FileManager.default.fileExists(atPath: configFile(dir).path + ".bad"),
            "the damaged file is kept, not deleted"
        )
    }
}

/// The one file rule that is worth data: a state that could not be *read* may still be
/// intact, and the streak is in it.
@MainActor
private func testUnreadableStateIsNeverOverwritten() {
    withTempDir { dir in
        let store = Store(directory: dir)
        var saved = EngineState.initial(now: noon, calendar: testCalendar)
        saved.streakDays = 7
        try? store.saveState(saved)
        setPermissions(0o000, on: stateFile(dir))

        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        expectDegraded(state.statusKind, mentioning: "History", "an unreadable history says so")
        state.startFocusSession(minutes: 25)                       // a real state change
        for _ in 0..<3 { clock.advance(seconds: 1); state.tickForTesting() }

        setPermissions(0o644, on: stateFile(dir))
        expectEqual(
            Store(directory: dir).loadState()?.streakDays, 7,
            "the file on disk still holds the streak it had"
        )
    }
}

// MARK: - Persistence

@MainActor
private func testStateIsWrittenOnlyWhenItChanges() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()
        expect(FileManager.default.fileExists(atPath: stateFile(dir).path), "the first tick writes")

        // Deleting is how an idle save is caught: an unchanged state must not bring it back.
        try? FileManager.default.removeItem(at: stateFile(dir))
        for _ in 0..<5 { clock.advance(seconds: 1); state.tickForTesting() }
        expect(
            !FileManager.default.fileExists(atPath: stateFile(dir).path),
            "an idle second is not written to disk"
        )

        state.startFocusSession(minutes: 25)
        expect(
            FileManager.default.fileExists(atPath: stateFile(dir).path),
            "a real change is written straight away"
        )
    }
}

/// A save that cannot be written is the one failure the user has to be told about: the app
/// keeps blocking, but the day it is recording is not reaching the disk.
@MainActor
private func testSaveFailureIsSurfacedAndClears() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()

        setPermissions(0o500, on: dir)                             // directory no longer writable
        state.startFocusSession(minutes: 25)
        expectDegraded(state.statusKind, mentioning: "Couldn't save history", "a failed save is shown")

        setPermissions(0o700, on: dir)
        state.startFocusSession(minutes: 50)                       // extends, so the state moves
        expectEqual(
            state.statusKind, .active(targetCount: 0),
            "and the warning clears as soon as a save gets through"
        )
    }
}

// MARK: - Talking to the blocker

/// Pins the deliberate gap `AppBlocker` is built around: `recheckFrontmost()` fires on a
/// *change* of the blocked set, and at launch there is nothing to differ from. Whatever is
/// already frontmost is Task 6's initial sweep to make, not this class's.
@MainActor
private func testPrimingNeverDisturbsTheBlocker() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let blocker = RecordingBlocker()
        // Inside the window: the group is already blocked at the moment of priming.
        let state = makeState(dir, clock: FakeClock(august(11, 10, 30)), blocker: blocker)
        state.prime()

        expectEqual(blocker.recheckCount, 0, "priming never disturbs the blocker")
        expectEqual(
            state.budgetsByGroup.first?.line, "Blocked until 11:00",
            "though the block itself is derived and shown"
        )
        // The popover says why as well as until when. "Blocked until 11:00" alone leaves the
        // user to work out whether they walked into a window, a budget or a session.
        expectEqual(
            state.budgetsByGroup.first?.reason, .schedule,
            "and the row carries what is doing the blocking"
        )

        state.startFocusSession(minutes: 25)
        expectEqual(
            state.budgetsByGroup.first?.reason, .focusSession,
            "which follows what actually outranks what"
        )
        expectEqual(
            state.focusSessionLine, "Everything is blocked until 10:55",
            "and the line above them says what a focus session does rather than what it is called"
        )
    }
}

/// The beat the whole relentlessness rests on, and the one thing the loop owes it.
///
/// Nothing else retries a hide that did not land: no notification announces an app that is still
/// standing after being told to go, and none announces a window opening over an app that is
/// already in front. So the sweep is asked for on every single beat — unlike the recheck, which
/// deliberately fires only when the blocked set changes.
@MainActor
private func testEveryBeatSweepsTheVisibleBlockedApps() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()
        expectEqual(blocker.sweepCount, 0, "priming sweeps nothing, as it disturbs nothing")

        for _ in 0..<3 { clock.advance(seconds: 1); state.tickForTesting() }
        expectEqual(blocker.sweepCount, 3, "every beat asks for the visible blocked apps again")
        expectEqual(
            blocker.recheckCount, 0,
            "and it does not wait for the blocked set to change, which is the whole point"
        )
    }
}

@MainActor
private func testBlockerIsDisturbedOnlyWhenTheBlockedSetChanges() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let clock = FakeClock(august(10, 9, 30))                   // Monday, before the window
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()

        for _ in 0..<4 { clock.advance(seconds: 1); state.tickForTesting() }
        expectEqual(blocker.recheckCount, 0, "an unchanged picture never disturbs the blocker")

        clock.now = august(10, 10, 0)                              // the window opens
        state.tickForTesting()
        expectEqual(blocker.recheckCount, 1, "a window opening is noticed, though it emits no effect")

        for _ in 0..<4 { clock.advance(seconds: 1); state.tickForTesting() }
        expectEqual(blocker.recheckCount, 1, "staying blocked is not a change")

        clock.now = august(10, 11, 0).addingTimeInterval(1)        // and closes
        state.tickForTesting()
        expectEqual(blocker.recheckCount, 2, "a window closing is a change too")
    }
}

/// Pins the *unconditional* re-check. Nothing is blocked before or after this change, so the
/// changed-set gate would report no news — but a configuration change can hand the frontmost
/// app to a new group, or drop the group whose session was holding it open, and neither of
/// those moves the blocked set.
@MainActor
private func testUpdateConfigAlwaysRechecksEvenWhenNothingIsBlocked() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: FakeClock(noon), blocker: blocker)
        state.prime()
        let before = blocker.recheckCount

        var widened = groupedConfig()
        widened.targets.append(
            Target(kind: .app, value: "com.apple.Mail", displayName: "Mail", groupID: "grp:demo")
        )
        expectNoThrow("a configuration outside every window is locked by nothing") {
            try state.updateConfig(widened)
        }
        expectEqual(
            blocker.recheckCount, before + 1,
            "a configuration change re-examines what is in front even with the blocked set unmoved"
        )
        expectEqual(state.statusKind, .active(targetCount: 3), "and the new target is counted")
    }
}

@MainActor
private func testUpdateConfigPropagatesANewBlock() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(august(11, 10, 30)))   // inside the window
        state.prime()
        expect(state.budgetsByGroup.isEmpty, "nothing is configured yet")

        expectNoThrow("a first configuration is locked by nothing") {
            try state.updateConfig(windowConfig())
        }
        expectEqual(
            state.budgetsByGroup.first?.line, "Blocked until 11:00",
            "a group that lands inside a live window is blocked at once"
        )
        expect(!state.hasNothingToProtect, "a configuration with targets is something to protect")
    }
}

// MARK: - Time passing

/// The day boundary is noticed by polling. Nothing waits for `.dayRolledOver`: the effect is
/// drained by the same tick that re-derives the budgets, so the numbers must be right either
/// way — and a Mac that slept through 03:00 gets the same answer on its first tick.
@MainActor
private func testDayRollsOverWhileTheAppIsRunning() {
    withTempDir { dir in
        let store = Store(directory: dir)
        try? store.saveConfig(groupedConfig())
        var yesterday = EngineState.initial(now: august(10, 2, 59), calendar: testCalendar)
        yesterday.opensUsed["grp:demo"] = 3
        try? store.saveState(yesterday)

        let clock = FakeClock(august(10, 2, 59))
        let state = makeState(dir, clock: clock)
        state.prime()
        expectEqual(
            state.budgetsByGroup.first?.line, "2 of 5 opens left today",
            "before 03:00 the night's spending still counts against the day that is ending"
        )

        clock.now = august(10, 3, 1)
        state.tickForTesting()
        expectEqual(
            state.budgetsByGroup.first?.line, "5 of 5 opens left today",
            "and the new day starts with the whole budget"
        )
    }
}

// MARK: - The inbound API Task 6 and Task 9 use

/// `AppBlocker` never touches `RulesEngine`: it comes through here, so
/// every spent open leaves the same trail — saved state, re-derived menu bar, logged event.
@MainActor
private func testInboundBlockerAPIResolvesLogsAndResyncs() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        expectEqual(
            state.blockDecision(forBundleID: "com.apple.Notes"),
            pauseDecision(countdown: 10, opensLeft: 5, of: 5),
            "an app target is resolved from a bare bundle id"
        )
        expectEqual(
            state.blockDecision(forBundleID: "com.apple.Safari"), .notManaged,
            "and an app nobody asked to block is left alone"
        )

        expectEqual(
            state.consumeOpen(targetID: "app:com.apple.Notes"), .granted(sessionSeconds: 300),
            "spending an open starts the group's session"
        )
        expectEqual(
            state.activeSession, SessionRow(groupID: "grp:demo", name: "Notes", secondsLeft: 300, earnsBack: true),
            "which the menu bar shows without waiting for a tick"
        )

        state.recordDismissal(targetID: "domain:youtube.com")
        let weekly = Store(directory: dir).weeklyOpens(now: noon, calendar: testCalendar)
        expect(weekly.complete, "the log was readable")
        expectEqual(weekly.counts["grp:demo"], 1, "the granted open is in the log; the dismissal is not an open")
    }
}

/// The overlay names the app it is standing in front of from this one answer, and spends the
/// open from the `targetID` in it — so a wrong or missing lookup here is a pause screen with
/// the wrong name on it, or an open charged to the wrong group.
@MainActor
private func testDisplayInfoNamesTheAppBehindABundleID() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        let state = makeState(dir, clock: FakeClock(noon))

        expectEqual(
            state.displayInfo(forBundleID: "com.apple.Notes"),
            TargetDisplayInfo(targetID: "app:com.apple.Notes", name: "Notes"),
            "an app target answers with its id and its name"
        )
        expectNil(
            state.displayInfo(forBundleID: "youtube.com"),
            "a domain target is not an app, whatever its value looks like"
        )
        expectNil(
            state.displayInfo(forBundleID: "com.apple.Safari"),
            "and an app nobody asked to block has nothing to show"
        )
    }
}

/// A group that is nothing but a ticked chip has no targets at all, and every screen that walks
/// the targets would leave it out: no budget row, no name for its pause screen, and a menu bar
/// reporting nothing protected while the engine blocks eleven sites. All four are the same bug
/// wearing different clothes.
@MainActor
private func testAGroupMadeOfChipsIsVisibleAndProtects() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(chipsConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        expect(
            !state.hasNothingToProtect,
            "a group made of categories is a configuration, not a blank slate"
        )
        expectEqual(
            state.displayInfo(forBundleID: "com.hnc.Discord"),
            TargetDisplayInfo(targetID: "app:com.hnc.Discord", name: "Messaging"),
            "an app the chip carries names its pause screen after the group"
        )
        expectEqual(
            state.blockDecision(forBundleID: "com.hnc.Discord"),
            pauseDecision(countdown: 10, opensLeft: 5, of: 5),
            "and meets that group's pause screen"
        )
        expectNil(
            state.displayInfo(forBundleID: "com.apple.Notes"),
            "an app in no category is still nobody's business"
        )

        expectEqual(
            state.budgetsByGroup.map(\.id), ["grp:chips"],
            "the group appears in the popover although nothing names it"
        )
        expectEqual(state.budgetsByGroup.first?.name, "Messaging", "under the name the chip gave it")
        let carried = DistractionCategory.builtIns.first { $0.id == "messaging" }!.domains.count
        expectEqual(
            state.statusKind, .active(targetCount: carried),
            "and the menu bar counts the websites it carries, apps excluded as unverifiable"
        )
    }
}

/// Why `AppBlocker` needs an activation grace at all, stated in engine terms.
///
/// A gentle open grants nothing that outlives it: no session, so nothing a later decision can
/// see. The pause screen is therefore back the instant the app is asked about again — which is
/// the intended per-visit friction, and also an endless loop if the blocker treats the
/// activation its own "Open" performed as a visit. Only the app layer can tell those apart.
@MainActor
private func testGentleOpenLeavesNothingBehindToUnblockIt() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(gentleConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        let pause = Decision.pause(countdownSeconds: 10, budgetLine: nil)
        expectEqual(
            state.blockDecision(forBundleID: "com.apple.Notes"), pause,
            "a gentle group opens behind a pause screen, and has no budget to report"
        )
        expectEqual(
            state.consumeOpen(targetID: "app:com.apple.Notes"), .granted(sessionSeconds: nil),
            "the open is granted with no session behind it"
        )
        expectNil(state.activeSession, "so the menu bar has nothing to count down")
        expectEqual(
            state.blockDecision(forBundleID: "com.apple.Notes"), pause,
            "and the next activation is a pause screen again, one second after the last one"
        )
    }
}

// MARK: - Edits and stats

/// The `.unreadable` rule: a save is one `rename` over config.json, and a file that could not be
/// read today may be perfectly intact behind a permissions problem.
@MainActor
private func testAnUnreadableConfigIsNeverWrittenOver() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        setPermissions(0o000, on: configFile(dir))

        let state = makeState(dir, clock: FakeClock(noon))
        expectDegraded(state.statusKind, mentioning: "Settings file", "an unreadable settings file says so")
        expect(
            !state.hasNothingToProtect,
            "and does not read as a blank slate: the window would invite building it all again"
        )

        var replacement = Config(version: 1, targets: [], groupSettings: [:])
        let site = Target(kind: .domain, value: "x.com", displayName: "X")
        replacement.targets = [site]
        replacement.groupSettings[site.groupID] = .gentle
        expectEqual(
            state.applyConfigEdit(replacement),
            "Settings can't be saved while the settings file can't be read",
            "saving is refused, in words the window can show"
        )

        setPermissions(0o644, on: configFile(dir))
        expectEqual(
            Store(directory: dir).loadConfig()?.targets.count, 2,
            "and the file the user could not read still holds what it held"
        )
    }
}

/// The engine must never be left running a rule that is not on disk.
///
/// It was: the edit was adopted, the write failed into a degraded line, and `applyConfigEdit`
/// answered `nil` — so the editor showed a saved setting, the menu bar showed a disk problem, and
/// the next launch had neither. An edit that cannot be written does nothing and says why.
@MainActor
private func testAnEditThatCannotBeWrittenIsNotRun() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        let before = state.config

        setPermissions(0o500, on: dir)                             // directory no longer writable
        var edited = before
        edited.groupSettings[before.targets[0].groupID]?.opensPerDay = 11
        let problem = state.applyConfigEdit(edited)
        setPermissions(0o700, on: dir)

        expect(problem?.contains("Couldn't save settings") == true, "the editor is told, in words it can show")
        expectEqual(state.config, before, "and the configuration it is editing is the one still running")
        expectEqual(
            state.config.settings(forGroup: before.targets[0].groupID)?.opensPerDay,
            before.settings(forGroup: before.targets[0].groupID)?.opensPerDay,
            "the engine did not keep the edit it could not write"
        )
        expectEqual(
            Store(directory: dir).loadConfig()?.groupSettings.first?.value.opensPerDay,
            before.settings(forGroup: before.targets[0].groupID)?.opensPerDay,
            "and the file on disk is untouched"
        )

        // The way back is the same edit once the disk works, with nothing left over from the
        // failure: no stale degraded line, and the number where the user put it.
        expectNil(state.applyConfigEdit(edited), "the same edit goes through once the disk does")
        expectEqual(state.config.settings(forGroup: before.targets[0].groupID)?.opensPerDay, 11, "with the new value")
        expectEqual(state.statusKind, .active(targetCount: 1), "and the warning is gone")
    }
}

/// The half of the rollback that is not the configuration.
///
/// The engine drops the state of groups a new configuration does not know — that is what makes a
/// deleted group unable to come back carrying yesterday's counters. So a *failed* delete has to
/// put the counters back with the group, or a write that did not happen would have handed today's
/// budget out a second time, which is the one thing `resetToday` exists to do and it asks first.
@MainActor
private func testAFailedDeleteGivesTheGroupBackWithTheDayItHad() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        let groupID = state.config.targets[0].groupID
        _ = state.consumeOpen(targetID: state.config.targets[0].id)
        let spent = state.stats.opensUsedToday[groupID]
        expectEqual(spent, 1, "one open is spent")

        setPermissions(0o500, on: dir)
        let problem = state.applyConfigEdit(
            ConfigBuilder.removingGroup(groupID, from: state.config)
        )
        setPermissions(0o700, on: dir)

        expect(problem != nil, "the delete is refused, in words the editor can show")
        expectEqual(state.config.targets.count, 1, "the group is still there")
        expectEqual(
            state.stats.opensUsedToday[groupID], spent,
            "and so is the open it had already spent"
        )
    }
}

/// **A strict window survives the settings screen by blocking, not by freezing it.** The refusal
/// this used to check — "Locked until 11:00", with both doors named — is gone with the freeze it
/// belonged to; what stands in its place is the edit going through and the block ending with it.
/// See `EditDirection` for the lock rule.
@MainActor
private func testConfigEditIsAllowedInsideAStrictWindow() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let state = makeState(dir, clock: FakeClock(august(11, 10, 30)))   // inside 10:00-11:00
        state.prime()
        expectEqual(
            state.budgetsByGroup.first?.reason, .schedule, "the group is inside its own window"
        )

        var loosened = windowConfig()
        loosened.groupSettings["domain:youtube.com"] = .gentle
        expectNil(state.applyConfigEdit(loosened), "an edit inside the window goes through")
        expectEqual(
            state.config.groupSettings["domain:youtube.com"], .gentle,
            "and the running configuration is the edited one"
        )
    }
}

/// The button beside the one above, and the same change: handing today's budget back from inside a
/// window is an ordinary reset now. What still refuses it is "Block everything"; see
/// `UndoLockTests`.
@MainActor
private func testResettingTodayIsAllowedInsideAStrictWindowToo() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(windowConfig())
        let clock = FakeClock(august(11, 9, 30))          // before the window opens
        let state = makeState(dir, clock: clock)
        state.prime()
        _ = state.consumeOpen(targetID: "domain:youtube.com")
        expectEqual(
            state.stats.opensUsedToday["domain:youtube.com"], 1, "an open is spent beforehand"
        )

        clock.now = august(11, 10, 30)                    // inside 10:00-11:00
        state.tickForTesting()
        expectNil(state.resetTodaysCounters(), "the reset is not refused by the window")
        expectNil(
            state.stats.opensUsedToday["domain:youtube.com"],
            "and the spent open is handed back — the counter is cleared rather than zeroed"
        )
    }
}

/// "Block everything" freezes the configuration as a whole — it used to, and the refusal was the
/// last thing in the app that held a setting without being a lock. Under the lock rule it
/// holds nothing: the edit goes straight through, the week's pass is not needed to make it, and
/// the session goes on blocking everything afterwards.
@MainActor
private func testAConfigEditGoesThroughDuringAFocusSession() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        state.startFocusSession(minutes: 25)

        var widened = groupedConfig()
        widened.groupSettings["grp:demo"] = .gentle
        expectNil(state.applyConfigEdit(widened), "the edit is not refused")
        expectEqual(
            state.config.groupSettings["grp:demo"], .gentle, "and it landed"
        )
        expect(state.emergencyPassAvailable, "with the week's pass unspent — nothing was bought")
        expectEqual(
            state.focusSessionLine, "Everything is blocked until 12:25",
            "and everything is still blocked"
        )
    }
}

/// The stats screen reads the week from here, and `complete == false` is the one number it
/// must not print as zero.
@MainActor
private func testWeeklyOpensArePassedThroughWithTheirHonesty() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        let empty = state.weeklyOpenCounts()
        expect(empty.complete, "a log that does not exist yet is an honest zero")
        expect(empty.counts.isEmpty, "with nothing in it")

        _ = state.consumeOpen(targetID: "app:com.apple.Notes")
        expectEqual(state.weeklyOpenCounts().counts["grp:demo"], 1, "a spent open is counted for its group")

        setPermissions(0o000, on: dir.appendingPathComponent("events.jsonl"))
        let unreadable = state.weeklyOpenCounts()
        expect(!unreadable.complete, "a log that cannot be read is reported as incomplete")
        expect(unreadable.counts.isEmpty, "rather than as a week in which nothing happened")
        setPermissions(0o644, on: dir.appendingPathComponent("events.jsonl"))
    }
}

@MainActor
private func testTodaysNumbersArePublished() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        expectEqual(state.stats.opensAvoidedToday, 0, "a fresh day has nothing in it")

        _ = state.consumeOpen(targetID: "app:com.apple.Notes")
        state.recordDismissal(targetID: "domain:youtube.com")
        expectEqual(state.stats.opensUsedToday["grp:demo"], 1, "the spent open is published")
        expectEqual(state.stats.opensAvoidedToday, 1, "and so is the pause screen that was turned away from")
    }
}

/// A renamed group is renamed everywhere.
///
/// The budget rows used to be named after the group's first *target*, which is only the right
/// answer while nobody has renamed anything: a group called "Notes and YouTube" in the sidebar
/// appeared in the popover as "Notes". The name a group has is `Config.groupDisplayName`, which
/// falls back to the same first target when there is no name — so this is the answer the sidebar
/// and the pause screen were already giving.
@MainActor
private func testABudgetRowIsNamedAfterItsGroup() {
    withTempDir { dir in
        var config = groupedConfig()
        config.groupSettings["grp:demo"]?.name = "Evenings"
        try? Store(directory: dir).saveConfig(config)
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        expectEqual(
            state.budgetsByGroup.map(\.name), ["Evenings"],
            "the row says what the user called the group"
        )

        var unnamed = groupedConfig()
        unnamed.groupSettings["grp:demo"]?.name = nil
        try? state.updateConfig(unnamed)
        expectEqual(
            state.budgetsByGroup.map(\.name), ["Notes"],
            "and falls back to the first thing in it when there is no name"
        )
    }
}

/// The change-gating the settings window is built on, pinned.
///
/// `AppState` re-derives everything once a second. Assigning an unchanged value to an
/// `@Observable` property still wakes every observer, so without the gates in `recompute` a
/// settings window left open would rebuild itself all day — and the stats screen would re-read
/// the whole event log with it. The second half of the case is what keeps the first half
/// honest: tracking that never fires would pass a test that asserts it did not.
@MainActor
private func testAnIdleSecondPublishesNothing() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(groupedConfig())
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()

        let idle = ObservationFlag()
        withObservationTracking {
            _ = state.config
            _ = state.stats
            _ = state.streakLine
        } onChange: {
            idle.fired = true
        }
        clock.advance(seconds: 1)
        state.tickForTesting()
        expect(!idle.fired, "an idle second publishes neither settings, numbers nor streak")

        let real = ObservationFlag()
        withObservationTracking { _ = state.stats } onChange: { real.fired = true }
        _ = state.consumeOpen(targetID: "app:com.apple.Notes")
        expect(real.fired, "and a spent open still reaches whoever is watching")
    }
}

/// `withObservationTracking`'s callback is `@Sendable`, so what it sets cannot be a captured
/// local. Unchecked is honest here: every line above runs on the main thread, and the callback
/// is invoked synchronously by the mutation itself.
private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}
