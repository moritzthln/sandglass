import Foundation
import SandglassAppCore
import SandglassCore

// What keeps a password group from being two clicks deep: its settings are behind the same
// password, the app's unblocks and the forgot hour do not reach it, and switching the keep-alive
// off asks for it.

func runAccessGuardTests() {
    MainActor.assumeIsolated {
        testThePasswordIsTheGroupsDoor()
        testTheDoorIsNotLiftedByThePass()
        testTheSettingsPasscodeOpensTheDoorOfAGroupThatUsesIt()
        testTheForgotHourDoesNotClearAPasscodeAGroupOpensWith()
        testSwitchingTheKeepAliveOffAsksForAGroupsPassword()
    }
    testTheDoorsSayWhatTheyAreAbout()
}

private let password = "drive-2026"

private func passwordConfig(_ source: AccessPassword? = nil) -> Config {
    var config = webConfig()
    config.groupSettings[youtubeGroup]?.accessPassword =
        source ?? PasscodeHash.make(password).map(AccessPassword.custom)
    return config
}

@MainActor
private func withPasswordState(
    _ config: Config, keepAlive: RecordingKeepAlive? = nil,
    _ body: (AppState, FakeClock) -> Void
) {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(config)
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock, keepAlive: keepAlive)
        state.prime()
        state.settingsWindowOpened()
        body(state, clock)
        state.stop()
    }
}

/// Every loosening edit waits for the password, the way a group passcode's door works; every
/// tightening goes straight through.
@MainActor
private func testThePasswordIsTheGroupsDoor() {
    withPasswordState(passwordConfig()) { state, _ in
        expect(state.groupLockStates[youtubeGroup]?.passcodeRequired == true, "the page is behind the password")
        var off = state.config
        off.groupSettings[youtubeGroup]?.accessPassword = nil
        expectEqual(
            state.applyConfigEdit(off), "Enter the password for YouTube to change it",
            "turning the password off waits for it"
        )
        var disabled = state.config
        disabled.groupSettings[youtubeGroup]?.enabled = false
        expect(state.applyConfigEdit(disabled) != nil, "so does switching the group off")
        var emptied = state.config
        emptied.targets = []
        expect(state.applyConfigEdit(emptied) != nil, "and taking its site away")
        var stricter = state.config
        stricter.groupSettings[youtubeGroup]?.timeWindows = [officeHours]
        expectNil(state.applyConfigEdit(stricter), "a strict window goes on without it")

        expect(!state.unlockGroup(youtubeGroup, passcode: "nope"), "a wrong password opens nothing")
        expect(state.unlockGroup(youtubeGroup, passcode: password), "the right one opens the door")
        expectNil(state.applyConfigEdit(off), "and then the password may be turned off")
        expectNil(state.config.groupSettings[youtubeGroup]?.accessPassword, "and is")
    }
}

/// The door shares the engine's counter: guessing at the door is no faster than at the prompt.
@MainActor
private func testTheDoorIsNotLiftedByThePass() {
    withPasswordState(passwordConfig()) { state, _ in
        expect(state.useEmergencyPass(), "the pass is spent")
        expect(state.groupLockStates[youtubeGroup]?.passcodeRequired == true, "and the door stays shut")
        var off = state.config
        off.groupSettings[youtubeGroup]?.accessPassword = nil
        expect(state.applyConfigEdit(off) != nil, "so the password cannot be turned off under it")
        expectEqual(
            state.blockDecision(forURL: "youtube.com"),
            .blocked(reason: .passwordRequired, untilText: "Opens with its password"),
            "and the site stays blocked"
        )
        for _ in 1...5 { _ = state.unlockGroup(youtubeGroup, passcode: "nope") }
        expect(!state.unlockGroup(youtubeGroup, passcode: password), "five misses at the door earn the wait")
        expectEqual(
            state.accessDoorProblem(forGroup: youtubeGroup), "Too many tries. Try again in 1:00.",
            "and the door says so"
        )
    }
}

@MainActor
private func testTheSettingsPasscodeOpensTheDoorOfAGroupThatUsesIt() {
    var config = passwordConfig(.settingsPasscode)
    config.settingsLock.passcode = PasscodeHash.make("2468")
    withPasswordState(config) { state, _ in
        expect(state.unlockSettings(passcode: "2468"), "the settings open with the passcode")
        expect(state.groupLockStates[youtubeGroup]?.passcodeRequired == true, "and the group's door is its own")
        var recoded = state.config
        recoded.settingsLock.passcode = PasscodeHash.make("1357")
        expect(
            state.applyConfigEdit(recoded) != nil,
            "changing the settings passcode waits for the group that opens with it"
        )
        expect(state.unlockGroup(youtubeGroup, passcode: "2468"), "its door opens with the settings passcode")
        expectNil(state.applyConfigEdit(recoded), "and then the passcode may change")
    }
    var bare = passwordConfig(.settingsPasscode)
    bare.settingsLock.passcode = nil
    withPasswordState(bare) { state, _ in
        expect(!state.unlockGroup(youtubeGroup, passcode: "anything"), "with no passcode set the door opens to nothing")
        expectEqual(state.accessDoorProblem(forGroup: youtubeGroup), AccessCopy.noSettingsPasscode, "and says why")
        var coded = state.config
        coded.settingsLock.passcode = PasscodeHash.make("2468")
        expectNil(state.applyConfigEdit(coded), "setting one again is the way back")
        expect(state.unlockGroup(youtubeGroup, passcode: "2468"), "and it opens the group")
    }
}

/// The hour recovers the settings, not the site: a passcode a group opens with is not cleared.
@MainActor
private func testTheForgotHourDoesNotClearAPasscodeAGroupOpensWith() {
    var config = passwordConfig(.settingsPasscode)
    config.settingsLock.passcode = PasscodeHash.make("2468")
    withPasswordState(config) { state, clock in
        state.setPasscodeReset(true)
        clock.advance(seconds: 2 * 3600)
        state.tickForTesting()
        expect(state.config.settingsLock.passcode != nil, "two hours later the passcode is still there")
        let door = SettingsDoor(
            lock: state.config.settingsLock, state: state.settingsLockState,
            opensAGroup: state.config.opensAGroupWithSettingsPasscode
        )
        expectEqual(door.recovery, .heldByPasswordGroup, "and the door offers no hour")
        expect(door.recovery.offersOnlyThePass, "only the pass, which does not open the group")
    }
    var mixed = passwordConfig()
    mixed.groupSettings[youtubeGroup]?.passcode = PasscodeHash.make("1111")
    withPasswordState(mixed) { state, _ in
        expectNil(
            state.groupLockStates[youtubeGroup]?.resetSeconds,
            "a group whose door is its password has no hour of its own either"
        )
        expect(!state.unlockGroup(youtubeGroup, passcode: "1111"), "and its own passcode is not the door")
    }
}

@MainActor
private func testSwitchingTheKeepAliveOffAsksForAGroupsPassword() {
    let keepAlive = RecordingKeepAlive(installed: true)
    withPasswordState(passwordConfig(), keepAlive: keepAlive) { state, _ in
        expect(state.leavingNeedsAccessPassword, "a password group guards the keep-alive")
        expect(state.setKeepAlive(false, requiring: .settingsWindow) != nil, "without its password it stays on")
        expect(
            state.setKeepAlive(false, requiring: .deliberateAction, accessPassword: "nope") != nil,
            "the quit dialogue's wrong password changes nothing"
        )
        expect(keepAlive.isInstalled, "the agent is still installed")
        expect(state.useEmergencyPass(), "a pass is spent")
        expect(state.setKeepAlive(false, requiring: .settingsWindow) != nil, "and lifts none of it")
        expectNil(
            state.setKeepAlive(false, requiring: .deliberateAction, accessPassword: password),
            "the right password lets it go"
        )
        expect(!keepAlive.isInstalled, "and the agent is gone")
        expectNil(state.setKeepAlive(true, requiring: .settingsWindow), "switching it on never asks")
    }
    withPasswordState(webConfig(), keepAlive: RecordingKeepAlive(installed: true)) { state, _ in
        expect(!state.leavingNeedsAccessPassword, "with no password group nothing extra is asked")
    }
}

private func testTheDoorsSayWhatTheyAreAbout() {
    let door = GroupDoor(name: "Drive", state: GroupLockState(passcodeRequired: true), opensWithPassword: true)
    expectEqual(door.title, "Enter the password for Drive", "the door names a password")
    expectEqual(door.recovery, .passwordOnly, "with no hour to offer")
    expect(!door.offersEmergencyPass, "and no pass")
    expectEqual(door.fieldLabel, "Password", "the field says so too")
    let plain = GroupDoor(name: "Social", state: GroupLockState(passcodeRequired: true))
    expectEqual(plain.title, "Enter the passcode for Social", "a passcode door is unchanged")
    expectEqual(plain.recovery, .offer, "with its hour")
}
