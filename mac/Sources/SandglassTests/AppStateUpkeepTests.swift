import SandglassAppCore
import SandglassCore
import Foundation

// The loop's housekeeping, driven through a whole `AppState`: what one second is charged, what a
// failing disk costs the loop, and what a demo run is allowed to leave behind.
//
// Shared doubles and fixtures (RecordingBlocker, withTempDir, makeState) live in
// AppStateFixtures.swift; the moments come from EngineFixtures.swift.

func runAppStateUpkeepTests() {
    MainActor.assumeIsolated {
        testABrowserInAnAppGroupIsChargedOncePerSecond()
        testAPasscodeHourThatCannotBeSavedIsNotRetriedEverySecond()
        testADemoSeedIsNeverWrittenToTheRealConfig()
    }
}

// MARK: - One second, one charge

/// A browser listed as an app in the same group as the site it is showing: the tick charges the
/// app, the page poll charges the page, and both land on the one group. That second was counted
/// twice, so a 30-minute limit ran out after fifteen.
@MainActor
private func testABrowserInAnAppGroupIsChargedOncePerSecond() {
    withTempDir { dir in
        let app = Target(kind: .app, value: "com.google.Chrome", displayName: "Chrome", groupID: "grp:yt")
        let site = Target(kind: .domain, value: "youtube.com", displayName: "YouTube", groupID: "grp:yt")
        let other = Target(kind: .domain, value: "reddit.com", displayName: "Reddit")
        try? Store(directory: dir).saveConfig(Config(
            version: 1, targets: [app, site, other],
            groupSettings: ["grp:yt": .standard, other.groupID: .standard]
        ))
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()
        blocker.frontmost = "com.google.Chrome"
        var page = "https://www.youtube.com/watch?v=x"
        blocker.onPagePoll = { state.recordPageSecond(forURL: page) }
        for _ in 0..<5 {
            clock.advance(seconds: 1)
            state.tickForTesting()
        }
        expectEqual(state.stats.usageSecondsToday["grp:yt"], 5, "five seconds in Chrome on YouTube is five")

        page = "https://www.reddit.com/"
        clock.advance(seconds: 1)
        state.tickForTesting()
        expectEqual(
            state.stats.usageSecondsToday["grp:yt"], 6, "a page of another group leaves the app's second"
        )
        expectEqual(
            state.stats.usageSecondsToday[other.groupID], 1,
            "and is charged to its own group, which is a second of that group's too"
        )
    }
}

// MARK: - A disk that will not take the write

/// The forgotten-passcode hour is cleared by the loop, and the clearing is a config write. When
/// the disk refuses it the engine is rolled back, so the hour is still due next second — and every
/// second after, each one a write, a recheck of the frontmost app and an Apple event.
@MainActor
private func testAPasscodeHourThatCannotBeSavedIsNotRetriedEverySecond() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        expectNil(state.applyConfigEdit(lockedConfig(passcode: "1234")), "a passcode is set")
        expectNil(state.setPasscodeReset(true), "and forgotten")
        clock.advance(seconds: 3601)
        setPermissions(0o444, on: configFile(dir))
        setPermissions(0o555, on: dir)
        defer {
            setPermissions(0o755, on: dir)
            setPermissions(0o644, on: configFile(dir))
        }
        let before = blocker.recheckCount
        for _ in 0..<10 {
            clock.advance(seconds: 1)
            state.tickForTesting()
        }
        expect(state.config.settingsLock.passcode != nil, "the write failed, so the passcode is still set")
        expect(
            blocker.recheckCount - before <= 1,
            "and the failed write is tried once in ten seconds, not ten times"
        )
        setPermissions(0o755, on: dir)
        setPermissions(0o644, on: configFile(dir))
        clock.advance(seconds: 60)
        state.tickForTesting()
        expectNil(state.config.settingsLock.passcode, "a disk that recovers gets the write a minute later")
    }
}

// MARK: - The demo harness

/// `SANDGLASS_SEED_DEMO` seeds a configuration in memory so a verification run has something to
/// block. Its contract is that the user's own `config.json` is left alone — and the first edit
/// made during the run used to write the demo target out as if it were theirs.
@MainActor
private func testADemoSeedIsNeverWrittenToTheRealConfig() {
    withTempDir { dir in
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()
        DemoSeed.app(state)
        expectEqual(state.config.targets.map(\.value), ["com.apple.Notes"], "the demo target is running")
        var edited = state.config
        edited.breakWaitSeconds = 120
        expectNil(state.applyConfigEdit(edited), "an edit during the demo goes through")
        expectEqual(state.config.breakWaitSeconds, 120, "and is in force")
        let onDisk = Store(directory: dir).loadConfig()?.targets ?? []
        expect(onDisk.isEmpty, "but nothing of the demo reaches the file the next launch reads")
    }
}
