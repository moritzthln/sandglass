import SandglassAppCore
import SandglassCore
import Foundation

/// Revoking a permission while a hard block stands: what it costs, and everything it must not
/// cost.
///
/// The most obvious bypass is the Accessibility pane, so this is the one feature written against a
/// user who is deliberately trying to get out. The first half here is the rule as arithmetic —
/// which applications a dead block covers, given a configuration and what macOS is granting. The
/// second half asks the same questions of the whole app, because two of the boundaries are the
/// engine's rather than the rule's: the emergency pass lifts the block and takes the response with
/// it, and a group that opted out of the pass keeps both.
///
/// What is deliberately not here is the hiding itself. `AppBlocker` calls into `NSWorkspace` and
/// the test target does not link that executable, so it is checked by hand: revoke the grant while
/// a hard block stands and watch Chrome go — the user trying to get out of their own block.
func runBluntBlockTests() {
    testTheTwoReasonsItAnswersAndTheFiveItDoesNot()
    testNothingIsBluntWhileTheGrantStands()
    testNothingIsBluntBeforeAnybodyHasLooked()
    testAGroupWithNoHardBlockIsLeftDegradedAndHarmless()
    testOnlyTheBrowsersWithNoRouteLeftAreHidden()
    testAnAppOnlyGroupReachesNoBrowser()
    testAGroupCoversItsAppsAndTheOnesItsCategoriesCarry()
    testOnlyTheDeadBlocksOwnGroupIsTouched()
    testASwitchedOffGroupNamedInTheSetClaimsNothing()
    testTheNeverHiddenListHoldsAbsolutely()
    testTheLineNamesWhatIsHappeningThePermissionAndTheWayBack()

    MainActor.assumeIsolated {
        testAStandingStrictWindowWithNoGrantHidesTheBrowserWhole()
        testADatedBlockDoesExactlyTheSame()
        testTheGrantComingBackEndsItOnTheSpot()
        testTheEmergencyPassLiftsTheBlockAndTheResponseWithIt()
        testAPassImmuneGroupKeepsBothThroughThePassHour()
    }
}

// MARK: - Fixtures

private let chrome = "com.google.Chrome"
private let safari = "com.apple.Safari"
private let firefox = "org.mozilla.firefox"
private let notes = "com.apple.Notes"

/// What macOS is granting, said in one line so a case reads as the permission state it is about.
private func granting(
    _ accessibility: BrowserAccess.Accessibility, refusing: [String] = []
) -> BrowserAccess {
    BrowserAccess(accessibility: accessibility, automationRefused: refusing.sorted())
}

/// One website in its own group — the shape a browser can be hidden over.
private func siteConfig() -> Config {
    let site = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    return Config(version: 1, targets: [site], groupSettings: [site.groupID: .standard])
}

/// One application in its own group, and nothing on the web at all.
private func appConfig() -> Config {
    let app = Target(kind: .app, value: notes, displayName: "Notes")
    return Config(version: 1, targets: [app], groupSettings: [app.groupID: .standard])
}

private let notesGroup = "app:\(notes)"

// MARK: - The rule

/// The two blocks this answers, stated against every case the enum has.
///
/// `CaseIterable` is walked rather than the two being asserted alone, so a reason added later
/// cannot quietly join or miss this list: whoever adds one has to come here and say which side it
/// is on. The five that are out are out for one reason each — every one of them has a way through,
/// or is already refusing everything by itself.
private func testTheTwoReasonsItAnswersAndTheFiveItDoesNot() {
    expectEqual(
        BluntBlock.hardReasons, [.schedule, .datedBlock],
        "a strict window standing and a dated block running, and nothing else"
    )
    let soft = BlockReason.allCases.filter { !BluntBlock.hardReasons.contains($0) }
    expectEqual(
        Set(soft), [.budgetExhausted, .cooldown, .focusSession, .timeLimit, .clockTampered],
        "the five that are deliberately left alone"
    )
}

/// The grant is the necessary condition, and the whole response hangs off it.
private func testNothingIsBluntWhileTheGrantStands() {
    let everyBrowserRefused = Browsers.all.map(\.name)
    let standing = BluntBlock.standing(
        hardBlockedGroups: [youtubeGroup],
        config: siteConfig(),
        access: granting(.granted, refusing: everyBrowserRefused)
    )
    expect(
        !standing.stands,
        "every browser refusing the direct route costs nothing while the other one is open"
    )
    expectNil(standing.line, "and there is nothing to say about it")
}

/// Warning is one lie; hiding a browser on the strength of not having checked is a worse one.
private func testNothingIsBluntBeforeAnybodyHasLooked() {
    let standing = BluntBlock.standing(
        hardBlockedGroups: [youtubeGroup], config: siteConfig(), access: granting(.unknown)
    )
    expect(!standing.stands, "an unasked question is not a missing permission")
}

/// The boundary that keeps this from being a punishment: a budget is not a wall.
private func testAGroupWithNoHardBlockIsLeftDegradedAndHarmless() {
    let standing = BluntBlock.standing(
        hardBlockedGroups: [], config: siteConfig(), access: granting(.denied, refusing: ["Chrome"])
    )
    expect(
        !standing.stands,
        "a spent budget with the grant revoked stays what it is today — degraded and harmless"
    )
}

/// **The headline boundary.** Reading a browser has two consents and a browser is out of reach
/// only when both are shut, so a partial revocation must not cascade.
///
/// Firefox is the one that falls the moment Accessibility goes: no dictionary can name its tab, so
/// the accessibility tree is the only route it ever had. Every other browser keeps its own
/// Automation grant, and revoking Chrome's is what finally takes Chrome.
private func testOnlyTheBrowsersWithNoRouteLeftAreHidden() {
    let config = siteConfig()
    let accessibilityGone = BluntBlock.standing(
        hardBlockedGroups: [youtubeGroup], config: config, access: granting(.denied)
    )
    expect(
        accessibilityGone.covers(firefox),
        "Firefox has nothing but the accessibility tree, so it goes with the grant"
    )
    expect(
        !accessibilityGone.covers(chrome),
        "Chrome answers its own dictionary and is read perfectly well, so it is left alone"
    )
    expect(!accessibilityGone.covers(safari), "and so is Safari")

    let chromeAlso = BluntBlock.standing(
        hardBlockedGroups: [youtubeGroup], config: config,
        access: granting(.denied, refusing: ["Chrome"])
    )
    expect(chromeAlso.covers(chrome), "with both of its routes shut, Chrome goes whole")
    expect(!chromeAlso.covers(safari), "and Safari, which refused nothing, still does not")

    let automationOnly = BluntBlock.standing(
        hardBlockedGroups: [youtubeGroup], config: config,
        access: granting(.granted, refusing: ["Chrome"])
    )
    expect(
        !automationOnly.covers(chrome),
        "revoking Automation for Chrome alone must not hide Chrome — the fallback still works"
    )
}

/// A group made of applications reaches no browser, so a browser permission takes nothing from it.
private func testAnAppOnlyGroupReachesNoBrowser() {
    let standing = BluntBlock.standing(
        hardBlockedGroups: [notesGroup], config: appConfig(),
        access: granting(.denied, refusing: Browsers.all.map(\.name))
    )
    expectEqual(
        standing.bundleIDs, [notes],
        "the group's own application, and not one browser it never had an opinion about"
    )
    expectEqual(standing.hiddenBrowsers, [], "so there is no browser to name")
    expectNil(standing.line, "and no new sentence to say — the general warning already covers it")
}

/// Both halves of what a group holds, the pair `SessionEffects.hideApps` already walks: a target
/// somebody typed, and a bundle id a live category carries. And the categories decide the web
/// reach too — a group whose only websites come from a ticked list still loses its browser.
private func testAGroupCoversItsAppsAndTheOnesItsCategoriesCarry() {
    var settings = GroupSettings.standard
    settings.name = "Social"
    settings.categories = ["social"]
    var config = Config(
        version: 1,
        targets: [Target(kind: .app, value: notes, displayName: "Notes", groupID: "grp:social")],
        groupSettings: ["grp:social": settings]
    )
    config.categories = [
        DistractionCategory(
            id: "social", name: "Social", domains: ["instagram.com"], bundleIDs: ["com.hnc.Discord"]
        )
    ]
    let standing = BluntBlock.standing(
        hardBlockedGroups: ["grp:social"], config: config, access: granting(.denied)
    )
    expect(standing.covers(notes), "the application the group names")
    expect(standing.covers("com.hnc.Discord"), "and the one its live category carries")
    expect(
        standing.covers(firefox),
        "and the browser, because a category carrying websites is a group that reaches the web"
    )
}

/// Only what the dead block actually covers. A second group blocking nothing is not swept up by
/// its neighbour's window.
private func testOnlyTheDeadBlocksOwnGroupIsTouched() {
    let blocked = Target(kind: .app, value: notes, displayName: "Notes", groupID: "grp:blocked")
    let free = Target(kind: .app, value: "com.tinyspeck.slackmacgap", displayName: "Slack",
                      groupID: "grp:free")
    let config = Config(
        version: 1,
        targets: [blocked, free],
        groupSettings: ["grp:blocked": .standard, "grp:free": .standard]
    )
    let standing = BluntBlock.standing(
        hardBlockedGroups: ["grp:blocked"], config: config, access: granting(.denied)
    )
    expectEqual(standing.bundleIDs, [notes], "the blocked group's app, and nothing next door")
}

/// A group that is switched off blocks nothing, so it can hold nothing back either — the rule
/// every decision in this app goes through, asked here too.
private func testASwitchedOffGroupNamedInTheSetClaimsNothing() {
    var config = appConfig()
    config.groupSettings[notesGroup]?.enabled = false
    let standing = BluntBlock.standing(
        hardBlockedGroups: [notesGroup], config: config, access: granting(.denied)
    )
    expect(!standing.stands, "an off group covers nothing, whatever a stale set says about it")
}

/// **The way out has to stay open, or this feature is a trap rather than friction.**
///
/// System Settings is where the grant is put back, so a response that could hide it would be a
/// response nobody could escape — a published report of two hours of lost work behind another
/// blocker is what that looks like from the far side. The list is
/// filtered here as well as in `AppHider`, so a hand-edited `config.json` cannot reach it either.
private func testTheNeverHiddenListHoldsAbsolutely() {
    var config = appConfig()
    for essential in HideExemptions.essentialBundleIDs.sorted() {
        config.targets.append(
            Target(kind: .app, value: essential, displayName: essential, groupID: notesGroup)
        )
    }
    let standing = BluntBlock.standing(
        hardBlockedGroups: [notesGroup], config: config, access: granting(.denied)
    )
    expectEqual(
        standing.bundleIDs, [notes],
        "Finder, System Settings, Activity Monitor and Sandglass itself are never covered"
    )
    expect(
        !standing.covers("com.apple.systempreferences"),
        "and the pane the way back runs through least of all"
    )
}

/// The sentence, in full: what is happening, which permission, and the way back. All three, because
/// a browser vanishing with no explanation is how somebody ends up reaching for the uninstaller
/// instead of for the pane.
private func testTheLineNamesWhatIsHappeningThePermissionAndTheWayBack() {
    let one = BluntBlock.standing(
        hardBlockedGroups: [youtubeGroup], config: siteConfig(),
        access: granting(.denied, refusing: ["Chrome"])
    )
    expectEqual(
        one.line,
        "Chrome and Firefox are hidden whole: a block is standing and the Accessibility permission"
            + " is missing. Grant it in System Settings.",
        "two browsers, named as a sentence rather than as a list"
    )
    let firefoxAlone = BluntBlock.standing(
        hardBlockedGroups: [youtubeGroup], config: siteConfig(), access: granting(.denied)
    )
    expectEqual(
        firefoxAlone.line,
        "Firefox is hidden whole: a block is standing and the Accessibility permission is missing."
            + " Grant it in System Settings.",
        "and one browser reads as one browser"
    )
}

// MARK: - The same questions, asked of the whole app

/// The everyday case, end to end: a window is holding a group shut, the grant is gone, and the
/// browser that can no longer be read walks into the hide ladder — while the one that still
/// answers its own dictionary is untouched.
@MainActor
private func testAStandingStrictWindowWithNoGrantHidesTheBrowserWhole() {
    withTempDir { dir in
        try? Store(directory: dir)
            .saveConfig(webConfig(settings: standardSettings(windows: [officeHours])))
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()

        state.setBrowserAccess(BrowserAccess(accessibility: .granted))
        expect(
            !state.hidesWhole(bundleID: chrome),
            "a block with the grant in place blocks the tab and leaves the browser alone"
        )

        state.setBrowserAccess(
            BrowserAccess(accessibility: .denied, automationRefused: ["Chrome"])
        )
        expect(state.hidesWhole(bundleID: chrome), "revoking both of Chrome's routes takes Chrome")
        expect(state.hidesWhole(bundleID: firefox), "and Firefox, which only ever had the one")
        expect(!state.hidesWhole(bundleID: safari), "Safari still answers, so Safari stays")
        expectDegraded(
            state.statusKind, mentioning: "hidden whole",
            "and the menu bar says what is being done rather than only that something is missing"
        )
        expectDegraded(
            state.statusKind, mentioning: "System Settings",
            "with the way back named in the same breath"
        )
    }
}

/// The other hard block, which ends on a day rather than at an hour. Same answer, and it is worth
/// asking separately: the two reach `decision(for:)` by different branches.
@MainActor
private func testADatedBlockDoesExactlyTheSame() {
    withTempDir { dir in
        try? Store(directory: dir).saveConfig(webConfig(settings: datedSettings(until: "2026-08-24")))
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        state.setBrowserAccess(BrowserAccess(accessibility: .denied))
        expect(state.hidesWhole(bundleID: firefox), "a fortnight shut is shut")
    }
}

/// **It ends with its cause.** No penalty period, nothing remembered, nothing on disk: the grant
/// comes back and the very next question answers no.
///
/// The budget case rides along, because it is the same assertion from the other end — the group is
/// blocked either way, and only one of the two blocks is a wall.
@MainActor
private func testTheGrantComingBackEndsItOnTheSpot() {
    withTempDir { dir in
        try? Store(directory: dir)
            .saveConfig(webConfig(settings: standardSettings(windows: [officeHours])))
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        state.setBrowserAccess(BrowserAccess(accessibility: .denied))
        expect(state.hidesWhole(bundleID: firefox), "the browser is gone while the grant is")

        state.setBrowserAccess(BrowserAccess(accessibility: .granted))
        expect(!state.hidesWhole(bundleID: firefox), "and it is back the instant the grant is")
        expectEqual(state.statusKind, .active(targetCount: 1), "with nothing left to warn about")
    }
    withTempDir { dir in
        var spent = GroupSettings.standard
        spent.opensPerDay = 0
        try? Store(directory: dir).saveConfig(webConfig(settings: spent))
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        state.setBrowserAccess(BrowserAccess(accessibility: .denied))
        expect(
            !state.hidesWhole(bundleID: firefox),
            "a group blocked because the day is spent is not a group anybody is walled into"
        )
        expectDegraded(
            state.statusKind, mentioning: "Accessibility",
            "so the honest, ordinary warning is what it gets"
        )
    }
}

/// The escape stays an escape. The pass lifts the block, so there is no dead block left for a
/// missing permission to be an exit from — and the browser comes back with everything else.
@MainActor
private func testTheEmergencyPassLiftsTheBlockAndTheResponseWithIt() {
    withTempDir { dir in
        try? Store(directory: dir)
            .saveConfig(webConfig(settings: standardSettings(windows: [officeHours])))
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        state.setBrowserAccess(BrowserAccess(accessibility: .denied))
        expect(state.hidesWhole(bundleID: firefox), "the browser is hidden whole before the pass")

        expect(state.useEmergencyPass(), "the week's pass is spent")
        expect(
            !state.hidesWhole(bundleID: firefox),
            "and the hour lifts the block, which takes the response with it"
        )
    }
}

/// The mirror image, and it follows from the ordering rather than from a rule of its own: a group
/// that opted out of the pass goes on being judged by its own week, so its block stands through
/// the hour — and so does everything that block is being enforced with.
@MainActor
private func testAPassImmuneGroupKeepsBothThroughThePassHour() {
    withTempDir { dir in
        var settings = standardSettings(windows: [officeHours])
        settings.ignoresAppWideUnblocks = true
        try? Store(directory: dir).saveConfig(webConfig(settings: settings))
        let state = makeState(dir, clock: FakeClock(noon))
        state.prime()
        state.setBrowserAccess(BrowserAccess(accessibility: .denied))

        expect(state.useEmergencyPass(), "the week's pass is spent all the same")
        expect(
            state.hidesWhole(bundleID: firefox),
            "and the group that asked to be left alone keeps its block, and keeps this with it"
        )
        // The running pass wins the icon, because "nothing is blocked" is the more urgent fact
        // about right now — and it is only half true here, which is exactly why the line under it
        // must survive. `StatusReadout` hands on whatever the icon had no room for.
        expect(
            state.warningLines.contains { $0.contains("hidden whole") },
            "which the popover goes on saying under the pass that did not reach it"
        )
    }
}
