import Foundation
import SandglassCore

/// The engine asked about a whole URL rather than a bare host: what a rule claims, what an
/// exception frees, and that a page claimed by a rule spends from the same one budget its group
/// already had.
///
/// `RuleMatcherTests` pins the matching itself. What is here is only what changes once the
/// engine, its clock and its counters are behind the answer.
func runEngineRuleTests() {
    testBareHostStillAnswersAsBefore()
    testARuleBlocksOnePathAndLeavesTheRest()
    testAnExceptionFreesOnePageOfABlockedSite()
    testARuleClaimedPageSpendsTheGroupsBudget()
    testTheAdultCategoryBlocksWithoutATarget()
    testASwitchedOffGroupsRulesDoNothing()
}

// MARK: - Nothing about the old path moved

private func testBareHostStillAnswersAsBefore() {
    let clock = FakeClock(noon)
    let (engine, _) = makeEngine(clock: clock)
    expectEqual(
        engine.decision(domain: "www.youtube.com"),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "a host with no path is a URL with no path"
    )
    expectEqual(
        engine.decision(url: "https://m.youtube.com/feed/subscriptions"),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and a full URL under the same target answers the same way"
    )
    expectEqual(engine.decision(url: "https://example.com/x"), .notManaged, "off-target is untouched")
}

// MARK: - Rules

private func testARuleBlocksOnePathAndLeavesTheRest() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.name = "Shorts"
    settings.rules = [Rule(pattern: "youtube.com/shorts", matchType: .websiteOrText, action: .block)]
    let engine = makeEngine(targets: [], groupSettings: ["grp:shorts": settings], clock: clock)

    expectEqual(
        engine.decision(url: "https://www.youtube.com/shorts/abc"),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "a rule claims a page with no target anywhere near it"
    )
    expectEqual(
        engine.decision(url: "https://www.youtube.com/watch?v=abc"), .notManaged,
        "and says nothing about the rest of the site"
    )
    expectEqual(
        engine.webMatch(forURL: "https://www.youtube.com/shorts/abc")?.displayName, "Shorts",
        "the pause screen is named after the group, there being no target to name it after"
    )
}

private func testAnExceptionFreesOnePageOfABlockedSite() {
    let clock = FakeClock(noon)
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    var settings = GroupSettings.standard
    settings.rules = [
        Rule(pattern: "music.youtube.com", matchType: .websiteOrText, action: .allow)
    ]
    let engine = makeEngine(
        targets: [target], groupSettings: [target.groupID: settings], clock: clock
    )
    expectEqual(
        engine.decision(url: "https://music.youtube.com/playlist"), .notManaged,
        "the carve-out is free"
    )
    expectEqual(
        engine.decision(url: "https://www.youtube.com/watch"),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and the site it was carved out of is not"
    )
}

private func testARuleClaimedPageSpendsTheGroupsBudget() {
    let clock = FakeClock(noon)
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    var settings = GroupSettings.standard
    settings.rules = [Rule(pattern: "shorts", matchType: .websiteOrText, action: .block)]
    let engine = makeEngine(
        targets: [target], groupSettings: [target.groupID: settings], clock: clock
    )

    // Spent through the rule, on a host the target does not cover at all.
    expectEqual(
        engine.consumeOpen(url: "https://vm.tiktok.com/shorts/x"), .granted(sessionSeconds: 300),
        "an open spent on a rule-claimed page is granted"
    )
    expectEqual(opensUsed(engine), 1, "and comes out of the group's one budget")
    // The session it bought covers the target too: one group, one session.
    expectEqual(
        engine.decision(domain: "youtube.com"), .allowed(remainingSessionSeconds: 300),
        "the session it bought is the group's, so the target is open too"
    )

    engine.recordDismissal(url: "https://vm.tiktok.com/shorts/x")
    expectEqual(engine.statsSnapshot().opensAvoidedToday, 1, "and a dismissal on it counts")
}

/// The adult list reaches a group the way every other category does: it is ticked, and then it
/// blocks with no target of its own. It used to be a switch with a private list behind it, read
/// at a priority nothing else used.
private func testTheAdultCategoryBlocksWithoutATarget() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.name = "Adult"
    settings.categories = ["adult"]
    let engine = makeEngine(targets: [], groupSettings: ["grp:adult": settings], clock: clock)

    guard let first = DistractionCategory.adult.domains.first else {
        return failTest("the adult category is empty")
    }
    expectEqual(
        engine.decision(url: "https://www.\(first)/some/page"),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "a ticked list blocks with no target and no rule written"
    )
    expectEqual(engine.decision(url: "https://youtube.com"), .notManaged, "and nothing else")
}

private func testASwitchedOffGroupsRulesDoNothing() {
    let clock = FakeClock(noon)
    var off = GroupSettings.standard
    off.enabled = false
    off.categories = ["adult"]
    off.rules = [Rule(pattern: "youtube.com", matchType: .websiteOrText, action: .block)]
    let engine = makeEngine(targets: [], groupSettings: ["grp:off": off], clock: clock)
    expectEqual(engine.decision(url: "https://youtube.com/watch"), .notManaged, "a rule of a switched-off group")
    expectEqual(
        engine.decision(url: "https://www.\(DistractionCategory.adult.domains[0])/x"),
        .notManaged, "and its ticked categories too"
    )
}
