import Foundation
import SandglassAppCore
import SandglassCore

// The app's half of the passwords: one entry at the keep-alive switch is one try, the forgot hour
// does not outlive the situation it was started in, and removing the settings passcode says what
// it would strand.

func runPasswordGuardTests() {
    MainActor.assumeIsolated {
        testTheRightPasswordAtTheSwitchCostsTheOtherGroupsNothing()
        testAGroupTakingUpTheSettingsPasscodeCallsOffTheForgotHour()
        testRemovingTheSettingsPasscodeNamesTheGroupsItStrands()
    }
    testAStaleForgotHourIsCalledOffOnTheWayToDisk()
    testCooldownAndEarnBackSayTheyNeedAnOpenLength()
}

private let first = "drive-2026"
private let second = "notes-2026"

private func twoPasswordGroups() -> Config {
    let youtube = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let reddit = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
    var shut = GroupSettings.standard
    shut.accessPassword = PasscodeHash.make(first).map(AccessPassword.custom)
    var other = GroupSettings.standard
    other.accessPassword = PasscodeHash.make(second).map(AccessPassword.custom)
    return Config(
        version: 1, targets: [youtube, reddit],
        groupSettings: [youtube.groupID: shut, reddit.groupID: other]
    )
}

@MainActor
private func withState(
    _ config: Config, keepAlive: RecordingKeepAlive? = nil, _ body: (AppState, FakeClock) -> Void
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

/// The switch asks for "a password" without asking whose, and used to try each group in turn —
/// counting a miss in every group sorted before the one that matched.
@MainActor
private func testTheRightPasswordAtTheSwitchCostsTheOtherGroupsNothing() {
    let keepAlive = RecordingKeepAlive(installed: true)
    withState(twoPasswordGroups(), keepAlive: keepAlive) { state, _ in
        for _ in 1...4 { _ = state.unlockGroup(youtubeGroup, passcode: "nope") }
        expectNil(
            state.setKeepAlive(false, requiring: .deliberateAction, accessPassword: second),
            "the other group's password lets the keep-alive go"
        )
        expectNil(state.accessDoorProblem(forGroup: youtubeGroup), "and was no fifth miss at the first group")
        expect(!keepAlive.isInstalled, "the agent is gone")
    }
}

@MainActor
private func testAGroupTakingUpTheSettingsPasscodeCallsOffTheForgotHour() {
    withState(lockedConfig(passcode: "2468")) { state, _ in
        expect(state.unlockSettings(passcode: "2468"), "the settings are open")
        state.setPasscodeReset(true)
        expect(state.config.settingsLock.forgotStartedAt != nil, "an hour is running")
        var config = state.config
        config.groupSettings[youtubeGroup]?.accessPassword = .settingsPasscode
        expectNil(state.applyConfigEdit(config), "a group starts opening with the settings passcode")
        expectNil(
            state.config.settingsLock.forgotStartedAt,
            "and the hour nobody could see or call off any more is gone"
        )
    }
}

@MainActor
private func testRemovingTheSettingsPasscodeNamesTheGroupsItStrands() {
    var config = lockedConfig(passcode: "2468")
    withState(config) { state, _ in
        expectNil(state.settingsPasscodeRemovalWarning, "with no group relying on it there is nothing to say")
    }
    config.groupSettings[youtubeGroup]?.accessPassword = .settingsPasscode
    withState(config) { state, _ in
        expectEqual(
            state.settingsPasscodeRemovalWarning,
            "YouTube opens with the settings passcode. "
                + "Without one, nothing opens it until a new passcode is set.",
            "removing it names the group it would leave shut"
        )
    }
}

private func testAStaleForgotHourIsCalledOffOnTheWayToDisk() {
    let started = ClockReading(wall: noon, uptime: 100)
    var current = lockedConfig(passcode: "2468")
    current.settingsLock.forgotStartedAt = started
    current.groupSettings[youtubeGroup]?.passcode = PasscodeHash.make("1111")
    current.groupSettings[youtubeGroup]?.passcodeForgotStartedAt = started

    var unrelated = current
    unrelated.groupSettings[youtubeGroup]?.opensPerDay = 3
    let kept = unrelated.callingOffStaleForgotHours(from: current)
    expectEqual(kept.settingsLock.forgotStartedAt, started, "an unrelated edit leaves the hour running")
    expectEqual(kept.groupSettings[youtubeGroup]?.passcodeForgotStartedAt, started, "and the group's")

    var changed = current
    changed.settingsLock.passcode = PasscodeHash.make("1357")
    changed.groupSettings[youtubeGroup]?.passcode = PasscodeHash.make("2222")
    let settled = changed.callingOffStaleForgotHours(from: current)
    expectNil(settled.settingsLock.forgotStartedAt, "a new passcode does not inherit the old one's hour")
    expectNil(settled.groupSettings[youtubeGroup]?.passcodeForgotStartedAt, "nor does a group's")

    var recoveryOff = current
    recoveryOff.settingsLock.allowForgot = false
    expectNil(
        recoveryOff.callingOffStaleForgotHours(from: current).settingsLock.forgotStartedAt,
        "switching recovery off leaves no timestamp to come back due"
    )
}

private func testCooldownAndEarnBackSayTheyNeedAnOpenLength() {
    expect(
        EditorCards.sessionOnlyCaption(sessionMinutes: nil) != nil,
        "with no open length the cooldown and earn-back say they are never reached"
    )
    expectNil(EditorCards.sessionOnlyCaption(sessionMinutes: 5), "with one they are live")
}
