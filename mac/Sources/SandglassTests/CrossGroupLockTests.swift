import SandglassAppCore
import SandglassCore
import Foundation

/// A locked group's sites, taken from it by an edit to **another** group.
///
/// `EditDirectionTests` walks one group's own fields. This is the half that comparison cannot see:
/// which group a site or an app belongs to is decided across every group at once — a block rule
/// anywhere, the most specific entry, the first group by id on a tie — so an edit that leaves the
/// locked group's page untouched can still hand its sites to a group with nothing standing in
/// front of them. Each way of doing that is asked here, in both directions: moved into a group
/// that holds them less hard is held, moved into one that holds them at least as hard is not.
///
/// The last cases are the precedence between two groups' rules, which is what decides where a
/// rule-claimed page goes, and the window-only password on paths its own suite does not walk.
@MainActor
func runCrossGroupLockTests() {
    testANewGroupTickingTheSameCategoryTakesItsSites()
    testANewGroupTickingTheSameCategoryTakesItsApps()
    testABlockRuleNextDoorTakesItsSites()
    testAMoreSpecificEntryNextDoorTakesItsSites()
    testASharedListGrowingAMoreSpecificEntryTakesItsSites()
    testWhatNeverBelongedToTheGroupIsNotItsLoss()
    testTheAppHoldsAnEditThatTakesALockedGroupsSites()
    testHighPriorityOutranksTheGroupOrder()
    testAWindowPasswordIsHeldByTheAppWideLockToo()
    testAWindowPasswordOnAGroupWithNoWindowsIsHeldAnyway()
    testTheAppHoldsAWindowPasswordSetInOneEdit()
}

// MARK: - The fixture

private let crossDay = "2026-08-20"

/// A group id that sorts before every other one, so a tie goes its way.
private let firstGroup = "a-first"

/// `categoryConfig`, with the group carrying the list made the strict one: a lock, a week and
/// Strict's knobs. The group next door is Standard with nothing standing in front of it.
private func crossBase() -> Config {
    var config = categoryConfig()
    config.categories[0].bundleIDs = ["com.burbn.instagram"]
    var strict = GroupSettings.strict
    strict.name = "Social"
    strict.categories = ["social"]
    strict.timeWindows = [officeHours]
    strict.lockMinutes = 30
    config.groupSettings[youtubeGroup] = strict
    return config
}

private func loosensSocial(_ change: (inout Config) -> Void) -> Bool {
    let base = crossBase()
    var edited = base
    change(&edited)
    return EditDirection.loosens(group: youtubeGroup, from: base, to: edited, onDay: crossDay)
}

private func loosensAnything(_ change: (inout Config) -> Void) -> Bool {
    let base = crossBase()
    var edited = base
    change(&edited)
    return EditDirection.loosens(from: base, to: edited, onDay: crossDay)
}

/// Both locks asked about one edit: the locked group's own, and the app-wide one.
private func expectHeld(_ name: String, _ change: @escaping (inout Config) -> Void) {
    expect(loosensSocial(change), "\(name): the locked group's lock holds it")
    expect(loosensAnything(change), "\(name): and so does the app-wide lock")
}

private func expectFree(_ name: String, _ change: @escaping (inout Config) -> Void) {
    expect(!loosensSocial(change), "\(name): the locked group's lock lets it through")
    expect(!loosensAnything(change), "\(name): and so does the app-wide lock")
}

private func blockRule(_ pattern: String, _ type: Rule.MatchType = .websiteOrText) -> Rule {
    Rule(pattern: pattern, matchType: type, action: .block)
}

// MARK: - The ways in

/// Two groups on one chip, and the first by id claims the list. A group that did not exist a
/// moment ago is not judged on its own, which is why the group it takes from has to be.
private func testANewGroupTickingTheSameCategoryTakesItsSites() {
    expectHeld("a lax new group on the same category") { config in
        var lax = GroupSettings.standard
        lax.categories = ["social"]
        config.groupSettings[firstGroup] = lax
    }
    expectFree("a new group on the same category that holds it as hard") { config in
        var copy = config.groupSettings[youtubeGroup] ?? .standard
        copy.name = "Copy"
        config.groupSettings[firstGroup] = copy
    }
    expectFree("a lax new group that sorts after the locked one") { config in
        var lax = GroupSettings.standard
        lax.categories = ["social"]
        config.groupSettings["z-last"] = lax
    }
}

private func testANewGroupTickingTheSameCategoryTakesItsApps() {
    let app = Target.id(ofKind: .app, value: "com.burbn.instagram")
    var edited = crossBase()
    var lax = GroupSettings.standard
    lax.categories = ["social"]
    lax.categoryExceptions = [Target.id(ofKind: .domain, value: "instagram.com"),
                              Target.id(ofKind: .domain, value: "tiktok.com")]
    edited.groupSettings[firstGroup] = lax
    expectEqual(
        CategoryMembership.claim(targetID: app, in: edited)?.groupID, firstGroup,
        "the new group carries the app and none of the sites"
    )
    expect(
        EditDirection.loosens(group: youtubeGroup, from: crossBase(), to: edited, onDay: crossDay),
        "and taking only the app is held as well"
    )
}

/// A block rule outranks every target and every category, so a rule written next door claims a
/// locked group's page without touching it.
private func testABlockRuleNextDoorTakesItsSites() {
    expectHeld("a block rule for the whole site next door") {
        $0.groupSettings[redditGroup]?.rules.append(blockRule("youtube.com"))
    }
    expectHeld("a block rule for a habit on the site next door") {
        $0.groupSettings[redditGroup]?.rules.append(blockRule("watch"))
    }
    expectHeld("a block rule for one page next door") {
        $0.groupSettings[redditGroup]?.rules.append(blockRule("youtube.com/watch", .specificPage))
    }
    expectFree("a block rule next door for a site nobody else holds") {
        $0.groupSettings[redditGroup]?.rules.append(blockRule("x.com"))
    }
}

/// The most specific entry wins, so a subdomain typed into another group is that group's.
private func testAMoreSpecificEntryNextDoorTakesItsSites() {
    expectHeld("a subdomain typed into the group next door") {
        $0.targets.append(
            Target(kind: .domain, value: "m.youtube.com", displayName: "M", groupID: redditGroup)
        )
    }
    expectFree("a subdomain typed into a group that holds it as hard") { config in
        config.groupSettings[firstGroup] = config.groupSettings[youtubeGroup]
        config.targets.append(
            Target(kind: .domain, value: "m.youtube.com", displayName: "M", groupID: firstGroup)
        )
    }
}

/// The lists are shared, so growing one another group carries can outbid the locked group's own.
private func testASharedListGrowingAMoreSpecificEntryTakesItsSites() {
    let news = DistractionCategory(id: "news", name: "News", domains: ["zeit.de"], bundleIDs: [])
    var base = crossBase()
    base.categories.append(news)
    base.groupSettings[redditGroup]?.categories = ["news"]
    var edited = base
    edited.categories[1].domains.append("help.instagram.com")
    expect(
        EditDirection.loosens(group: youtubeGroup, from: base, to: edited, onDay: crossDay),
        "a more specific entry on the list next door takes the page from the locked group"
    )
    expect(
        !EditDirection.loosens(group: redditGroup, from: base, to: edited, onDay: crossDay),
        "while for the group that gains it, it is one more site"
    )
}

private func testWhatNeverBelongedToTheGroupIsNotItsLoss() {
    expectFree("a lax new group on a list the locked group does not carry") { config in
        config.categories.append(
            DistractionCategory(id: "news", name: "News", domains: ["zeit.de"], bundleIDs: [])
        )
        var lax = GroupSettings.standard
        lax.categories = ["news"]
        config.groupSettings[firstGroup] = lax
    }
    expectFree("a stricter group taking the site") { config in
        var harder = config.groupSettings[youtubeGroup] ?? .strict
        harder.pauseSeconds += 30
        config.groupSettings[redditGroup] = harder
        config.groupSettings[redditGroup]?.rules = [blockRule("youtube.com")]
    }
}

/// The whole path: the edit is to the group next door, and the locked group's lock answers.
@MainActor private func testTheAppHoldsAnEditThatTakesALockedGroupsSites() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(state.applyConfigEdit(crossBase()), "the strict group is locked")
        state.settingsWindowOpened()

        var taken = state.config
        taken.groupSettings[redditGroup]?.rules.append(blockRule("youtube.com"))
        expectEqual(
            state.applyConfigEdit(taken), "Held by the lock on Social",
            "a rule next door that takes the locked group's site is that group's loosening"
        )
        expectEqual(
            state.config.groupSettings[redditGroup]?.rules, [],
            "and nothing moved"
        )
        var unrelated = state.config
        unrelated.groupSettings[redditGroup]?.rules.append(blockRule("x.com"))
        expectNil(state.applyConfigEdit(unrelated), "while a rule about another site goes through")
    }
}

// MARK: - Between two groups' rules

/// The order one group reads its rules in is the order two groups' rules are read in too:
/// high priority first, then the narrower match, and only then the group order.
private func testHighPriorityOutranksTheGroupOrder() {
    func config(_ first: Rule, _ second: Rule) -> Config {
        var a = GroupSettings.standard
        a.rules = [first]
        var b = GroupSettings.standard
        b.rules = [second]
        return Config(version: 1, targets: [], groupSettings: ["a": a, "b": b])
    }
    let url = "https://youtube.com/watch"
    var urgent = blockRule("youtube.com/watch", .specificPage)
    urgent.highPriority = true
    expectEqual(
        WebResolver.match(url: url, in: config(blockRule("youtube"), urgent))?.groupID, "b",
        "a high-priority page rule outranks a plain text rule in a group that sorts first"
    )
    var urgentText = blockRule("watch")
    urgentText.highPriority = true
    expectEqual(
        WebResolver.match(url: url, in: config(blockRule("youtube"), urgentText))?.groupID, "b",
        "and so does a high-priority text rule"
    )
    expectEqual(
        WebResolver.match(
            url: url, in: config(blockRule("youtube"), blockRule("youtube.com/watch", .specificPage))
        )?.groupID, "b",
        "at equal priority the narrower match wins"
    )
    expectEqual(
        WebResolver.match(url: url, in: config(blockRule("youtube"), blockRule("watch")))?.groupID,
        "a", "and a full tie still goes to the group that sorts first"
    )
}

// MARK: - The window-only password, on the paths its own suite does not walk

private func windowPassword(_ settings: GroupSettings) -> GroupSettings {
    var opened = settings
    opened.accessPassword = PasscodeHash.make("drive-2026").map(AccessPassword.custom)
    opened.passwordOnlyInStrictWindows = true
    return opened
}

private func testAWindowPasswordIsHeldByTheAppWideLockToo() {
    let base = crossBase()
    var edited = base
    edited.groupSettings[youtubeGroup] = edited.groupSettings[youtubeGroup].map(windowPassword)
    expect(
        EditDirection.loosens(from: base, to: edited, onDay: crossDay),
        "a password and its window scope set in one edit is held by the app-wide lock"
    )
    var everyHour = edited
    everyHour.groupSettings[youtubeGroup]?.passwordOnlyInStrictWindows = false
    expect(
        !EditDirection.loosens(from: edited, to: everyHour, onDay: crossDay),
        "and asking for the password at every hour again is not"
    )
}

/// A scope with no window to apply to opens nothing yet, but the week may only grow under a lock,
/// so the first strict window drawn afterwards would arrive already open.
private func testAWindowPasswordOnAGroupWithNoWindowsIsHeldAnyway() {
    let base = crossBase()
    var bare = base
    bare.groupSettings[youtubeGroup]?.timeWindows = []
    var edited = bare
    edited.groupSettings[youtubeGroup] = edited.groupSettings[youtubeGroup].map(windowPassword)
    expect(
        EditDirection.loosens(group: youtubeGroup, from: bare, to: edited, onDay: crossDay),
        "a window-only password with no window yet is held"
    )
    var later = edited
    later.groupSettings[youtubeGroup]?.timeWindows = [officeHours]
    expect(
        !EditDirection.loosens(group: youtubeGroup, from: edited, to: later, onDay: crossDay),
        "because a window drawn afterwards is a tightening, and it would open with the password"
    )
}

@MainActor private func testTheAppHoldsAWindowPasswordSetInOneEdit() {
    withTempDir { dir in
        let state = makeState(dir, clock: FakeClock(noon))
        expectNil(state.applyConfigEdit(crossBase()), "the strict group is locked")
        state.settingsWindowOpened()

        var opened = state.config
        opened.groupSettings[youtubeGroup] = opened.groupSettings[youtubeGroup].map(windowPassword)
        expectEqual(
            state.applyConfigEdit(opened), "Held by the lock on Social",
            "a password that would open the strict window is held by the group's lock"
        )
        expectNil(
            state.config.groupSettings[youtubeGroup]?.accessPassword, "and no password was set"
        )
    }
}
