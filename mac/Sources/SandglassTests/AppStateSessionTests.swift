import SandglassAppCore
import SandglassCore
import Foundation

/// What one running session does to the app around it: which targets are sent away when it ends,
/// what leaving early is worth, and the one warning before it relocks.
///
/// Split out of `AppStateTests`, which had grown past the 800-line cap. The seam is the one that
/// was already marked in it: everything here is about a session, and every fixture it needs is a
/// session fixture.
func runAppStateSessionTests() {
    MainActor.assumeIsolated {
        testSessionEndHidesAppTargetsOnly()
        testEndingASessionEarlyEarnsBackAndHides()
        testASessionThatEarnsNothingBackSaysSo()
        testRelockWarningIsDeliveredOnce()
    }
}

@MainActor
private func testSessionEndHidesAppTargetsOnly() {
    withTempDir { dir in
        let store = Store(directory: dir)
        try? store.saveConfig(groupedConfig())
        try? store.saveState(stateWithSession(endingAt: noon.addingTimeInterval(30), startedAt: noon))

        let clock = FakeClock(noon)
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)

        clock.advance(seconds: 31)
        state.tickForTesting()
        expectEqual(
            blocker.hidden, ["com.apple.Notes"],
            "the session's apps are sent away; a website has no window to hide"
        )
        expectNil(state.activeSession, "the finished session leaves no countdown behind")
    }
}

@MainActor
private func testEndingASessionEarlyEarnsBackAndHides() {
    withTempDir { dir in
        let store = Store(directory: dir)
        try? store.saveConfig(groupedConfig())
        var seeded = stateWithSession(endingAt: noon.addingTimeInterval(300), startedAt: noon)
        seeded.opensUsed["grp:demo"] = 1
        try? store.saveState(seeded)

        let clock = FakeClock(noon.addingTimeInterval(10))         // inside the first half
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: clock, blocker: blocker)
        state.prime()
        expectEqual(
            state.activeSession, SessionRow(groupID: "grp:demo", name: "Notes", secondsLeft: 290, earnsBack: true),
            "the row names the group and counts the seconds up, not down, to a whole one"
        )

        state.endActiveSessionEarly()
        expectNil(state.activeSession, "the session is over")
        expectEqual(blocker.hidden, ["com.apple.Notes"], "its apps are sent away")
        expectEqual(
            Store(directory: dir).loadState()?.opensUsed["grp:demo"], 0.5,
            "and leaving early earns half an open back"
        )
    }
}

/// The other half of the same row: the popover's button names the earn-back in its label, and
/// `RulesEngine.end` credits nothing unless the group asked for it — which Strict and Gentle do
/// not. Over a Strict group the label was promising half an open nothing would ever pay.
@MainActor
private func testASessionThatEarnsNothingBackSaysSo() {
    withTempDir { dir in
        let store = Store(directory: dir)
        var config = groupedConfig()
        config.groupSettings["grp:demo"] = .strict           // earnBackEnabled: false
        try? store.saveConfig(config)
        var seeded = stateWithSession(endingAt: noon.addingTimeInterval(300), startedAt: noon)
        seeded.opensUsed["grp:demo"] = 1
        try? store.saveState(seeded)

        let state = makeState(dir, clock: FakeClock(noon.addingTimeInterval(10)))
        state.prime()
        expectEqual(
            state.activeSession, SessionRow(groupID: "grp:demo", name: "Notes", secondsLeft: 290, earnsBack: false),
            "the row says there is nothing to earn back here"
        )

        state.endActiveSessionEarly()
        expectEqual(
            Store(directory: dir).loadState()?.opensUsed["grp:demo"], 1,
            "and the engine agrees: leaving early costs the open in full"
        )
    }
}

@MainActor
private func testRelockWarningIsDeliveredOnce() {
    withTempDir { dir in
        let store = Store(directory: dir)
        try? store.saveConfig(groupedConfig())
        try? store.saveState(stateWithSession(endingAt: noon.addingTimeInterval(45), startedAt: noon))

        let clock = FakeClock(noon)
        let notifier = RecordingNotifier()
        let state = makeState(dir, clock: clock, notifier: notifier)

        state.tickForTesting()
        expectEqual(
            notifier.delivered, ["Notes relocks in 45 seconds"],
            "the warning names the group and the seconds the engine actually reported"
        )
        for _ in 0..<3 { clock.advance(seconds: 1); state.tickForTesting() }
        expectEqual(notifier.delivered.count, 1, "one session warns once, not once a second")
    }
}
