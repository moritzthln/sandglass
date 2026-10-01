import SandglassAppCore
import SandglassCore
import Foundation

/// The switch-on nobody asked for, and the switch-off that has to hold.
///
/// `LaunchAgentManager` is not here: the plist it writes and the drift it corrects belong to
/// `LaunchAgentTests`, and whether launchd accepts the job is `mac/scripts/test-keepalive.sh`'s.
/// What is pinned here is the app's side of the seam — when a launch installs an agent, when it
/// must not, and what reaches `config.json` either way.
func runKeepAliveSeedTests() {
    testTheRoundIsCountedRatherThanTheAgent()
    MainActor.assumeIsolated {
        testAFirstRunSwitchesTheAgentOn()
        testAFileOlderThanTheSeedIsOfferedTheRoundOnce()
        testASecondRunLeavesAnInstalledAgentAlone()
        testASecondRunDoesNotPutBackAnAgentThatWasSwitchedOff()
        testAnAgentAlreadyThereIsRecordedWithoutBeingTouched()
        testAFailedInstallIsNotRecordedAndIsTriedAgain()
    }
}

/// The rule itself: a round offered, not an agent counted.
private func testTheRoundIsCountedRatherThanTheAgent() {
    let fresh = webConfig()
    expect(KeepAliveSeed.isOwed(fresh), "a configuration nobody has offered it to is owed the round")
    let recorded = KeepAliveSeed.recorded(fresh)
    expect(!KeepAliveSeed.isOwed(recorded), "and is owed nothing once the round is written down")
    expectEqual(
        recorded.keepAliveSeed, Config.currentKeepAliveSeed, "which is the round this build offers"
    )
    guard let data = try? SandglassJSON.encoder.encode(recorded),
          let back = try? SandglassJSON.decoder.decode(Config.self, from: data) else {
        failTest("a recorded configuration could not be written and read back")
        return
    }
    expectEqual(back.keepAliveSeed, recorded.keepAliveSeed, "and it survives a trip to disk")
}

// MARK: - What a launch does

@MainActor
private func testAFirstRunSwitchesTheAgentOn() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let agent = RecordingKeepAlive()
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)

        expectNil(state.seedKeepAlive(), "a first run switches the agent on without a word")
        expectEqual(agent.asked, [true], "the manager was asked exactly once, for on")
        expect(state.keepAliveEnabled, "and the toggle shows what is now installed")
        expectEqual(storedSeed(dir), 1, "the round is on disk, where the next launch will read it")
    }
}

/// A `config.json` written before the key existed. There is no evidence in it either way — a
/// wizard that was never finished looks exactly like a switch that was turned off — so it is
/// offered the round once, and after that it is like every other file.
@MainActor
private func testAFileOlderThanTheSeedIsOfferedTheRoundOnce() {
    withTempDir { dir in
        let older = #"{"version":1,"targets":[],"groupSettings":{}}"#
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(older.utf8).write(to: configFile(dir))
        let agent = RecordingKeepAlive()
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)

        expectEqual(state.config.keepAliveSeed, 0, "an absent key is round zero")
        expectNil(state.seedKeepAlive(), "so the round is offered")
        expectEqual(agent.asked, [true], "and the agent goes on")
        expectEqual(storedSeed(dir), 1, "recorded, so this file is never offered it again")
    }
}

@MainActor
private func testASecondRunLeavesAnInstalledAgentAlone() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        makeState(dir, clock: FakeClock(noon), keepAlive: RecordingKeepAlive()).seedKeepAlive()

        let agent = RecordingKeepAlive(installed: true)
        let second = makeState(dir, clock: FakeClock(noon), keepAlive: agent)
        expectNil(second.seedKeepAlive(), "the second launch has nothing to do")
        expectEqual(agent.asked, [], "and asks the manager for nothing at all")
        expect(second.keepAliveEnabled, "the agent from the first launch is still what is installed")
        expectEqual(storedSeed(dir), 1, "and the round still stands at one")
    }
}

/// The one that matters. Somebody switched it off between the two launches, which is exactly what
/// the toggle is for — and an app that read "no agent" as "first run" would put it back.
@MainActor
private func testASecondRunDoesNotPutBackAnAgentThatWasSwitchedOff() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let first = makeState(dir, clock: FakeClock(noon), keepAlive: RecordingKeepAlive())
        first.seedKeepAlive()
        expectNil(first.setKeepAlive(false, requiring: .deliberateAction), "it is switched off")

        let agent = RecordingKeepAlive(installed: false)
        let second = makeState(dir, clock: FakeClock(noon), keepAlive: agent)
        expectNil(second.seedKeepAlive(), "the next launch finds no agent and leaves it that way")
        expectEqual(agent.asked, [], "nothing is installed a second time")
        expect(!second.keepAliveEnabled, "the switch stays off, which is the whole promise")
        expectEqual(storedSeed(dir), 1, "because what was recorded is the offer, not the agent")
    }
}

/// The migrating case: a file that has never been offered the round, and an agent already there —
/// installed by the wizard that used to do this, or re-pointed by `reconcileInstalledPath` earlier
/// in the same launch. The round is recorded and the agent is not touched, so nothing this does
/// can send a working agent at a bundle it should not name.
@MainActor
private func testAnAgentAlreadyThereIsRecordedWithoutBeingTouched() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let agent = RecordingKeepAlive(installed: true)
        let state = makeState(dir, clock: FakeClock(noon), keepAlive: agent)

        expectNil(state.seedKeepAlive(), "there is nothing to install")
        expectEqual(agent.asked, [], "so the manager is not asked to write anything")
        expect(state.keepAliveEnabled, "the agent that was there is still there")
        expectEqual(storedSeed(dir), 1, "and the round is recorded, so a switch-off from here holds")
    }
}

/// A write that failed must not be recorded as a round that happened, or one bad launch is the
/// last time the app ever tries to start at login.
@MainActor
private func testAFailedInstallIsNotRecordedAndIsTriedAgain() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let refusing = RecordingKeepAlive(refusal: "launchd said no")
        let first = makeState(dir, clock: FakeClock(noon), keepAlive: refusing)

        expectEqual(first.seedKeepAlive(), "launchd said no", "the reason comes back to the caller")
        expect(!first.keepAliveEnabled, "nothing was installed")
        expectEqual(storedSeed(dir), 0, "and no round was written against a write that did not take")

        let working = RecordingKeepAlive()
        let second = makeState(dir, clock: FakeClock(noon), keepAlive: working)
        expectNil(second.seedKeepAlive(), "so the next launch tries again")
        expectEqual(working.asked, [true], "asking for the agent a second time")
        expectEqual(storedSeed(dir), 1, "and records the round now that there is one to record")
    }
}

/// The round as `config.json` holds it, read back the way the next launch would read it.
private func storedSeed(_ dir: URL) -> Int? {
    Store(directory: dir).loadConfig()?.keepAliveSeed
}
