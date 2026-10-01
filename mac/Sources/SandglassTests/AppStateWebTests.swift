import SandglassAppCore
import SandglassCore
import Foundation

/// The half of `AppState`'s inbound API that answers about websites.
///
/// The domain path matters for one reason above all: it must spend from the *same* budget the
/// app path does. A website and an app in one group are one rule, and two code paths that each
/// resolved a target their own way is exactly how that stops being true.
func runAppStateWebTests() {
    MainActor.assumeIsolated {
        testWebOpensAndAppOpensShareOneBudget()
        testWebDisplayInfoNamesTheSiteBehindAHost()
        testWebDismissalIsCountedAndLogged()
        testAGroupThatBlocksThroughRulesAloneIsOnTheScreens()
    }
}

/// A group whose whole scope is advanced rules or the adult list — no target of
/// its own, no live category — blocks pages, and every screen has to know it exists.
///
/// It was invisible to the projection, which walks the targets and then the groups carrying a
/// category. That is one list short: `WebResolver` reads every group's rules whatever the targets
/// say. So a group blocking `/shorts` had no budget row, no line in the popover, "Nothing in it
/// yet" on its own editor — and, because a strict window over it was in nobody's blocked set,
/// every break failed after its thirty-second wait with "Protection couldn't be paused".
@MainActor
private func testAGroupThatBlocksThroughRulesAloneIsOnTheScreens() {
    withTempDir { dir in
        var settings = GroupSettings.standard
        settings.name = "Shorts"
        settings.rules = [Rule(pattern: "shorts", matchType: .websiteOrText, action: .block)]
        try? Store(directory: dir).saveConfig(
            Config(version: 1, targets: [], groupSettings: ["grp:shorts": settings])
        )
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        expectEqual(
            state.blockDecision(forURL: "youtube.com/shorts/abc"),
            pauseDecision(countdown: 10, opensLeft: 5, of: 5),
            "the rule blocks the page — nothing about this group is hypothetical"
        )
        expectEqual(
            state.budgetsByGroup.map(\.id), ["grp:shorts"],
            "so it is one of the rows every screen is drawn from"
        )
        expectEqual(
            state.budgetsByGroup.first?.name, "Shorts", "under the name the user gave it"
        )
        expect(
            !state.hasNothingToProtect,
            "and the configuration does not read as an empty one"
        )
        state.stop()
    }
}

// MARK: - The domain path

@MainActor
private func testWebOpensAndAppOpensShareOneBudget() {
    withTempDir { dir in
        // One group holding an app and a site, which is the whole point of the shared budget.
        try? Store(directory: dir).saveConfig(groupedConfig())
        let clock = FakeClock(noon)
        let state = makeState(dir, clock: clock)
        state.prime()

        expectEqual(
            state.blockDecision(forURL: "www.youtube.com"),
            pauseDecision(countdown: 10, opensLeft: 5, of: 5),
            "a host is resolved by suffix, exactly as the engine's own matcher does it"
        )
        expectEqual(
            state.blockDecision(forURL: "notyoutube.com"), .notManaged,
            "and a host that merely ends in the same letters is not the same site"
        )

        expectEqual(
            state.consumeOpen(forURL: "www.youtube.com"), .granted(sessionSeconds: 300),
            "spending a web open starts the group's session"
        )
        expectEqual(
            state.blockDecision(forBundleID: "com.apple.Notes"),
            .allowed(remainingSessionSeconds: 300),
            "which the app in the same group is inside too — one budget, two doors"
        )
        expectEqual(
            state.consumeOpen(forURL: "example.com"), .denied(.notManaged),
            "a site nobody asked to block cannot spend anything"
        )

        let weekly = Store(directory: dir).weeklyOpens(now: noon, calendar: testCalendar)
        expectEqual(weekly.counts["grp:demo"], 1, "and the web open is in the log like any other")
    }
}

@MainActor
private func testWebDisplayInfoNamesTheSiteBehindAHost() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let state = makeState(dir, clock: FakeClock(noon))

        expectEqual(
            state.webDisplayInfo(forURL: "m.youtube.com"),
            TargetDisplayInfo(targetID: "domain:youtube.com", name: "YouTube"),
            "the web pause screen gets the app's own name for the rule, not the host it happens to be on"
        )
        expectNil(
            state.webDisplayInfo(forURL: "youtube.com.evil.example"),
            "a host that only contains the domain is not under it"
        )
        expectNil(state.webDisplayInfo(forURL: ""), "and an empty host names nothing")
    }
}

@MainActor
private func testWebDismissalIsCountedAndLogged() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig())
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        state.recordDismissal(forURL: "www.youtube.com")
        expectEqual(state.stats.opensAvoidedToday, 1, "turning back on the web is turning back")

        state.recordDismissal(forURL: "example.com")
        expectEqual(
            state.stats.opensAvoidedToday, 1,
            "and a dismissal from a page under no rule counts for nothing"
        )
    }
}
