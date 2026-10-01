import SandglassAppCore
import SandglassCore
import Foundation

/// The lists a group can be a member of, and what it means for a group to be a live member of one.
///
/// Three kinds of failure are worth a suite. A domain written in any shape other than the one
/// `DomainInput` produces matches nothing at all — the target exists, the category reads as
/// ticked, and the site opens anyway. An entry in two categories makes which group claims it
/// depend on which group id happens to sort first. And a membership that stops being read is a
/// group that silently blocks nothing. None of the three shows up by clicking through the window
/// once.
///
/// A fourth arrived with the lists becoming the user's own: they live in `config.json` now, so a
/// file written before they did has to be **seeded** with exactly the ids its groups already
/// carry. Get that wrong and every category-only group on the Mac quietly blocks nothing.
func runCategoryTests() {
    testTheListsAreWellFormed()
    testNoDomainIsInTwoCategories()
    testNoAppIsInTwoCategories()
    testEveryDomainIsAlreadyNormalised()
    testEveryCategoryIsWorthTicking()
    testALiveCategoryClaimsItsSitesAndItsApps()
    testSubdomainsOfACategoryEntryBelongToIt()
    testAnExceptionTakesOneMemberOutAndLeavesTheRest()
    testAGroupThatIsOffCarriesNothing()
    testAHandPickedTargetOutranksACategoryUnlessTheCategoryIsMoreSpecific()
    testAnUnknownCategoryIdIsIgnoredRatherThanFatal()
    testTheEngineBlocksAndSpendsThroughACategory()
    testThePickerFindsACategoryByWhatIsInIt()
    testThePickerSaysWhatIsTickedWithoutBeingOpened()
    testAFileWithoutCategoriesIsSeededWithTheSix()
    testAnEmptyCategoryListIsKeptRatherThanReseeded()
    testEditingACategoryReachesEveryGroupThatTickedIt()
    testDeletingACategoryDetachesItsGroupsAndLeavesTheirTargets()
    testAnExceptionDiesWithTheEntryItStruckOff()
    testDeletingACategoryPrunesTheExceptionsItLeavesBehind()
    testANewCategoryIsEmptyAndNamedAgainstTheList()
    testACategoryKeepsItsShapeAcrossASave()
}

/// The six a fresh configuration is seeded with. Everything below about the *lists* reads them
/// from here; everything about a group reads them out of a `Config`, which is where they live.
private let seeded = DistractionCategory.builtIns

// MARK: - The picker over them

/// The reason the chips became a dropdown: with twenty entries in a list, "is Netflix already
/// covered" is the question somebody has, and six words on six buttons cannot answer it.
private func testThePickerFindsACategoryByWhatIsInIt() {
    expectEqual(
        CategoryPicker.matching("netflix", in: seeded).map(\.id), ["video"],
        "a site finds the category that carries it"
    )
    expectEqual(
        CategoryPicker.matching("SPIEGEL", in: seeded).map(\.id), ["news"],
        "case is not part of the question"
    )
    expectEqual(
        CategoryPicker.matching("Messaging", in: seeded).map(\.id), ["messaging"],
        "and the name still works, which is what it was before"
    )
    expect(
        CategoryPicker.matching("com.hnc.Discord", in: seeded).map(\.id) == ["messaging"],
        "an app is found by the id the list actually holds"
    )
    expectEqual(
        CategoryPicker.matching("   ", in: seeded).map(\.id), seeded.map(\.id),
        "whitespace is not a search, so everything is still on offer"
    )
    expect(
        CategoryPicker.matching("nothing-carries-this", in: seeded).isEmpty,
        "and a search that matches nothing says so rather than showing all six"
    )
}

private func testThePickerSaysWhatIsTickedWithoutBeingOpened() {
    expectEqual(CategoryPicker.summary(of: [], in: seeded), "No categories", "nothing ticked reads as nothing")
    expectEqual(CategoryPicker.summary(of: ["video"], in: seeded), "Video", "one is named")
    expectEqual(
        CategoryPicker.summary(of: ["video", "social"], in: seeded), "Social, Video",
        "and two are named in the order they are offered rather than the order of a set"
    )
    expectEqual(
        CategoryPicker.summary(of: ["video", "social", "news", "games"], in: seeded), "4 categories",
        "past three, a count says more than the names would"
    )
    expectEqual(
        CategoryPicker.summary(of: ["video", "seventh"], in: seeded), "Video",
        "and an id this build has never heard of is left out rather than printed raw"
    )
}

// MARK: - The lists themselves

private func testTheListsAreWellFormed() {
    expectEqual(
        seeded.count, 7,
        "the six standard ones, plus Adult — which used to be a switch with a list behind it"
    )
    expectEqual(
        Set(seeded.map(\.id)).count, seeded.count,
        "each with an id of its own, because the ledger is keyed on it"
    )
    for category in seeded {
        expect(!category.name.isEmpty, "\(category.id) has a name to put on the chip")
        expect(
            !category.domains.isEmpty || !category.bundleIDs.isEmpty,
            "\(category.id) carries something: a chip that picks nothing is a lie"
        )
        expectEqual(
            Set(category.domains).count, category.domains.count,
            "\(category.id) lists no domain twice"
        )
        expectEqual(
            Set(category.bundleIDs).count, category.bundleIDs.count,
            "\(category.id) lists no app twice"
        )
        expect(
            category.bundleIDs.allSatisfy { $0.contains(".") && !$0.contains(" ") },
            "\(category.id) carries bundle ids rather than app names"
        )
    }
}

/// Overlap would make the claim order-dependent: two groups can tick two different chips that
/// both carry the site, and which one gets it would come down to which group id sorts first.
private func testNoDomainIsInTwoCategories() {
    var seen: [String: String] = [:]
    for category in seeded {
        for domain in category.domains {
            if let owner = seen[domain] {
                failTest("\(domain) is in both \(owner) and \(category.id)")
            } else {
                seen[domain] = category.id
            }
        }
    }
    expectEqual(seen.count, seeded.reduce(0) { $0 + $1.domains.count }, "every domain is its own")
}

/// The same rule for apps: a bundle id in two categories would be claimed by whichever group
/// sorts first, and the group the user believed was blocking it would quietly not be.
private func testNoAppIsInTwoCategories() {
    var seen: [String: String] = [:]
    for category in seeded {
        for bundleID in category.bundleIDs {
            if let owner = seen[bundleID] {
                failTest("\(bundleID) is in both \(owner) and \(category.id)")
            } else {
                seen[bundleID] = category.id
            }
        }
    }
    expectEqual(seen.count, seeded.reduce(0) { $0 + $1.bundleIDs.count }, "every app is its own")
}

/// The one that catches a typo silently: `www.spiegel.de` or `https://x.com` would be stored
/// verbatim and match no host the extension ever sees.
private func testEveryDomainIsAlreadyNormalised() {
    for category in seeded {
        for domain in category.domains {
            expectEqual(
                DomainInput.normalize(domain), domain,
                "\(domain) in \(category.id) is already the form a target holds"
            )
        }
    }
}

/// A chip that carries less than a handful of entries is a chip that reads as an offer and
/// behaves like a rounding error. The lower bound is the promise the settings screen makes.
private func testEveryCategoryIsWorthTicking() {
    for category in seeded {
        let entries = category.domains.count + category.bundleIDs.count
        expect(
            entries >= 12,
            "\(category.id) carries \(entries) entries, enough to be worth one tick"
        )
    }
}

// MARK: - Live membership

private func category(_ id: String) -> DistractionCategory {
    if let found = seeded.first(where: { $0.id == id }) { return found }
    failTest("no category with id \(id)")
    return DistractionCategory(id: id, name: id, domains: [], bundleIDs: [])
}

/// One group that is nothing but a live membership — the shape the chips now produce.
private func categoryConfig(
    _ ids: Set<String>,
    exceptions: Set<String> = [],
    enabled: Bool = true,
    targets: [Target] = [],
    extraGroups: [String: GroupSettings] = [:]
) -> Config {
    var settings = GroupSettings.standard
    settings.name = "Chips"
    settings.enabled = enabled
    settings.categories = ids
    settings.categoryExceptions = exceptions
    return Config(
        version: 1,
        targets: targets,
        groupSettings: extraGroups.merging(["grp:chips": settings]) { _, new in new }
    )
}

/// The headline: a group holding the word "social" claims every site on that list, and a group
/// holding "messaging" claims the apps on its own — neither has a single target in it.
private func testALiveCategoryClaimsItsSitesAndItsApps() {
    let config = categoryConfig(["social", "messaging"])

    for domain in category("social").domains {
        expectEqual(
            CategoryMembership.claim(host: domain, in: config)?.groupID, "grp:chips",
            "\(domain) belongs to the group that ticked Social"
        )
    }
    expectEqual(
        CategoryMembership.claim(host: "x.com", in: config)?.categoryID, "social",
        "and it can say which chip put it there"
    )
    expectNil(
        CategoryMembership.claim(host: "example.com", in: config),
        "a site on no list is claimed by nobody"
    )

    let discord = Target.id(ofKind: .app, value: "com.hnc.Discord")
    expectEqual(
        CategoryMembership.claim(targetID: discord, in: config)?.groupID, "grp:chips",
        "an app in Messaging belongs to the group too, with no target naming it"
    )
    expectNil(
        CategoryMembership.claim(targetID: Target.id(ofKind: .app, value: "com.apple.Notes"), in: config),
        "and an app in none of the lists is still nobody's business"
    )
}

/// Suffix matching, the same rule a domain target follows — and the dot that keeps it honest.
private func testSubdomainsOfACategoryEntryBelongToIt() {
    let config = categoryConfig(["video"])
    expectEqual(
        CategoryMembership.claim(host: "www.zdf.de", in: config)?.entry, "zdf.de",
        "www counts as the site"
    )
    expectEqual(
        CategoryMembership.claim(host: "m.youtube.com", in: config)?.entry, "youtube.com",
        "and so does any other subdomain"
    )
    expectNil(
        CategoryMembership.claim(host: "notzdf.de", in: config),
        "a host that merely ends in the same letters does not"
    )
    expectEqual(
        WebResolver.match(url: "https://www.zdf.de/nachrichten", in: config)?.groupID, "grp:chips",
        "and a whole URL resolves the same way, which is what the browser asks"
    )
}

/// The price of a live list: one member can be struck off without giving up the other twenty.
private func testAnExceptionTakesOneMemberOutAndLeavesTheRest() {
    let config = categoryConfig(
        ["social"], exceptions: [Target.id(ofKind: .domain, value: "linkedin.com")]
    )

    expectNil(
        CategoryMembership.claim(host: "linkedin.com", in: config),
        "the site the user struck off is claimed by nobody"
    )
    expectNil(
        CategoryMembership.claim(host: "de.linkedin.com", in: config),
        "including everything under it"
    )
    expectEqual(
        CategoryMembership.claim(host: "xing.com", in: config)?.groupID, "grp:chips",
        "and the rest of the category is untouched"
    )

    let settings = config.settings(forGroup: "grp:chips")!
    let members = CategoryMembership.members(of: category("social"), in: settings)
    expectEqual(
        members.domains.count, category("social").domains.count - 1,
        "the member list a card would show is one shorter"
    )
    expect(!members.domains.contains("linkedin.com"), "and it is short of exactly that one")
}

/// "Off" has to mean the same thing here it means everywhere else, or a disabled group would
/// still be shadowing what another one is trying to claim.
private func testAGroupThatIsOffCarriesNothing() {
    let config = categoryConfig(["news"], enabled: false)
    expectNil(CategoryMembership.claim(host: "heise.de", in: config), "a switched-off group claims nothing")
    expectNil(WebResolver.match(url: "heise.de", in: config), "so nothing on the web resolves to it")
}

/// Specificity decides between a typed target and a carried category, the same way it already
/// decides between two typed targets.
private func testAHandPickedTargetOutranksACategoryUnlessTheCategoryIsMoreSpecific() {
    let typed = Target(kind: .domain, value: "zdf.de", displayName: "ZDF")
    let both = categoryConfig(
        ["video"], targets: [typed], extraGroups: [typed.groupID: .gentle]
    )
    expectEqual(
        WebResolver.match(url: "zdf.de", in: both)?.groupID, typed.groupID,
        "the site somebody typed wins the tie"
    )
    expectEqual(
        WebResolver.match(url: "zdf.de", in: both)?.targetID, typed.id,
        "and the match names the target rather than the category"
    )

    // A broad typed target against a narrow category entry: Messaging carries meet.google.com.
    let broad = Target(kind: .domain, value: "google.com", displayName: "Google")
    let mixed = categoryConfig(
        ["messaging"], targets: [broad], extraGroups: [broad.groupID: .gentle]
    )
    let call = WebResolver.match(url: "https://meet.google.com/abc-defg-hij", in: mixed)
    expectEqual(call?.groupID, "grp:chips", "the more specific category entry wins")
    expectNil(call?.targetID, "with no target behind it, because none was involved")
    expectEqual(call?.displayName, "Chips", "named after the group, since no target is behind it")
    expectEqual(
        WebResolver.match(url: "google.com", in: mixed)?.groupID, broad.groupID,
        "while the search engine still belongs to the target that names it"
    )
}

/// A group naming a category the configuration does not carry — one the user deleted, or a
/// hand-edited file — must load and behave, not trap.
private func testAnUnknownCategoryIdIsIgnoredRatherThanFatal() {
    let config = categoryConfig(["social", "podcasts-from-the-future"])
    expectNil(config.category(id: "podcasts-from-the-future"), "the id is genuinely unknown")
    expectEqual(
        CategoryMembership.claim(host: "reddit.com", in: config)?.groupID, "grp:chips",
        "the category alongside it still works"
    )
    expectNil(
        CategoryMembership.claim(host: "example.com", in: config),
        "and the unknown one carries nothing"
    )
}

/// End to end: the engine treats a carried site exactly as it treats a target, on both paths.
private func testTheEngineBlocksAndSpendsThroughACategory() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.name = "Chips"
    settings.categories = ["messaging"]
    let engine = makeEngine(
        targets: [], groupSettings: ["grp:chips": settings], clock: clock
    )

    expectEqual(
        engine.decision(url: "web.whatsapp.com"),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "a site the category carries meets the group's pause screen"
    )
    let discord = Target.id(ofKind: .app, value: "com.hnc.Discord")
    expectEqual(
        engine.decision(targetID: discord),
        pauseDecision(countdown: 10, opensLeft: 5, of: 5),
        "and so does an app it carries"
    )

    _ = engine.consumeOpen(targetID: discord)
    expectEqual(
        engine.state.opensUsed["grp:chips"], 1,
        "an open spent on the app is charged to the group that ticked the chip"
    )
    engine.endSession(targetID: discord, early: false)
    expectEqual(
        engine.decision(url: "web.whatsapp.com"),
        cooldownDecision(minutes: 10),
        "and the whole group is in the cooldown that open bought — one budget, not two"
    )
}

// MARK: - Lists the user owns

/// The migration that matters. A `config.json` written before the categories lived in it has to
/// come back carrying all six, under the ids its groups already name — otherwise every group made
/// of nothing but a category silently stops blocking on the first launch after the upgrade.
private func testAFileWithoutCategoriesIsSeededWithTheSix() {
    let json = #"""
    {"version":1,"targets":[],"groupSettings":{"grp:chips":{"cooldownMinutes":10,\#
    "earnBackEnabled":true,"escalationSeconds":5,"pauseSeconds":10,"enabled":true,\#
    "categories":["social"]}}}
    """#
    guard let config = try? SandglassJSON.decoder.decode(Config.self, from: Data(json.utf8)) else {
        failTest("a configuration written before the categories lived in it no longer decodes")
        return
    }
    expectEqual(
        config.categories.map(\.id), seeded.map(\.id),
        "all six are seeded, under the ids the groups already hold"
    )
    expectEqual(
        CategoryMembership.claim(host: "reddit.com", in: config)?.groupID, "grp:chips",
        "so a group that ticked Social goes on claiming everything Social carries"
    )
}

/// The other side of the same key, and the promise a late seed has to keep.
///
/// An absent list means "seed them" and a written empty one is somebody who threw the lot away —
/// confusing the two would hand them back on the next launch. A **round** that has not been
/// offered to this file yet is a different question, and arrives exactly once: Adult was added
/// after every config.json already had a `categories` key, so there was no absent key left to
/// trigger on. What must never happen is the round arriving twice, which would make deleting the
/// category impossible.
private func testAnEmptyCategoryListIsKeptRatherThanReseeded() {
    let legacy = #"{"version":1,"targets":[],"groupSettings":{},"categories":[]}"#
    guard let config = try? SandglassJSON.decoder.decode(Config.self, from: Data(legacy.utf8)) else {
        failTest("a configuration with no categories at all could not be decoded")
        return
    }
    expect(
        !config.categories.contains { $0.id == "social" },
        "the round this file was already offered stays thrown away"
    )
    expectEqual(
        config.categories.map(\.id), ["adult"],
        "and the round it was never offered arrives, once"
    )

    // Now delete it and reload, which is the case that would be maddening to get wrong.
    var emptied = config
    emptied.categories = []
    guard let data = try? SandglassJSON.encoder.encode(emptied),
          let back = try? SandglassJSON.decoder.decode(Config.self, from: data) else {
        failTest("the emptied configuration could not be written and read back")
        return
    }
    expect(back.categories.isEmpty, "a category deleted after its round stays deleted")
    expectEqual(
        back.categorySeed, Config.currentCategorySeed,
        "because what is recorded is the round offered, never what is present"
    )
}

/// What a live membership is *for*, now that the list is editable: one edit reaches every group
/// that ticked it, without touching a single group.
private func testEditingACategoryReachesEveryGroupThatTickedIt() {
    var config = categoryConfig(["social"])
    expectNil(
        CategoryMembership.claim(host: "forum.example", in: config),
        "the site is in nobody's list to begin with"
    )
    guard let index = config.categories.firstIndex(where: { $0.id == "social" }) else {
        failTest("the seeded Social category is there to edit")
        return
    }

    config.categories[index].domains.append("forum.example")
    expectEqual(
        CategoryMembership.claim(host: "www.forum.example", in: config)?.groupID, "grp:chips",
        "a site added to the list is claimed by every group that is a member, subdomains included"
    )

    config.categories[index].domains.removeAll { $0 == "x.com" }
    expectNil(
        CategoryMembership.claim(host: "x.com", in: config),
        "and one taken out stops being claimed everywhere at once"
    )
}

/// Deleting takes the membership away and nothing else. A group is more than the categories it
/// ticked, and losing its own targets to a list it happened to be on would be unforgivable.
private func testDeletingACategoryDetachesItsGroupsAndLeavesTheirTargets() {
    var typed = Target(kind: .domain, value: "example.com", displayName: "Example")
    typed.groupID = "grp:chips"
    let struckOff = Target.id(ofKind: .domain, value: "linkedin.com")
    var config = categoryConfig(["social", "video"], exceptions: [struckOff], targets: [typed])
    expectEqual(
        ConfigBuilder.groupCount(usingCategory: "social", in: config), 1,
        "the confirmation can say how many groups are about to stop claiming it"
    )

    config = ConfigBuilder.removingCategory("social", from: config)

    expect(!config.categories.contains { $0.id == "social" }, "the list is gone from the document")
    expectEqual(
        config.settings(forGroup: "grp:chips")?.categories, ["video"],
        "the group stops claiming it and keeps the category it still has"
    )
    expectEqual(config.targets.map(\.id), [typed.id], "its own targets are untouched")
    expectEqual(
        config.settings(forGroup: "grp:chips")?.categoryExceptions, [],
        "and the exception into the deleted list goes with it, since nothing else carries it"
    )
    expectNil(
        CategoryMembership.claim(host: "reddit.com", in: config),
        "nothing claims what the deleted list carried"
    )
    expectEqual(
        CategoryMembership.claim(host: "netflix.com", in: config)?.groupID, "grp:chips",
        "while the other category goes on working"
    )
}

private func testANewCategoryIsEmptyAndNamedAgainstTheList() {
    let config = Config(version: 1, targets: [], groupSettings: [:])
    let made = ConfigBuilder.newCategory(named: "Social", in: config)

    expectEqual(made.name, "Social 2", "a name the list already answers to gets a counter")
    expect(made.domains.isEmpty && made.bundleIDs.isEmpty, "and it starts empty, to be filled")
    expect(
        !config.categories.contains { $0.id == made.id },
        "nothing is written until it is saved — a cancelled Add leaves no orphan behind"
    )
    expectEqual(
        DistractionCategory.freeName(basedOn: "   ", among: seeded), "New category",
        "a name of nothing still has to be something"
    )
    expectEqual(
        DistractionCategory.freeName(basedOn: "Reading", among: seeded), "Reading",
        "and a free name is left exactly as it was typed"
    )
}

/// The shape one category has on disk: no empty lists written, and a host that arrives in any
/// other case comes back in the only one that matches anything.
private func testACategoryKeepsItsShapeAcrossASave() {
    let category = DistractionCategory(
        id: "reading", name: "Reading", domains: ["Example.COM"], bundleIDs: []
    )
    expectEqual(category.domains, ["example.com"], "a host is lowercased on the way in")
    guard let data = try? SandglassJSON.encoder.encode(category) else {
        failTest("a category could not be encoded")
        return
    }
    expect(
        !String(decoding: data, as: UTF8.self).contains("bundleIDs"),
        "an empty list is absent rather than written as []"
    )
    expectEqual(
        try? SandglassJSON.decoder.decode(DistractionCategory.self, from: data), category,
        "and what comes back is what went in"
    )

    let raw = #"{"id":"reading","name":"Reading","domains":["Spiegel.DE"]}"#
    expectEqual(
        (try? SandglassJSON.decoder.decode(DistractionCategory.self, from: Data(raw.utf8)))?.domains,
        ["spiegel.de"],
        "a hand-edited host is lowercased on the way in too"
    )
}

/// The hole editable lists opened, closed. An exception is a target id struck off a list; take the
/// entry out of every list and put it back next month, and the group that struck it off silently
/// goes on not blocking it — the expanded row shows what is *carried*, which has already had the
/// exceptions taken out, so there is nothing on screen to explain it.
private func testAnExceptionDiesWithTheEntryItStruckOff() {
    let linkedin = Target.id(ofKind: .domain, value: "linkedin.com")
    let discord = Target.id(ofKind: .app, value: "com.hnc.Discord")
    var config = categoryConfig(["social"], exceptions: [linkedin, discord])

    let untouched = ConfigBuilder.pruningDanglingExceptions(in: config)
    expectEqual(
        untouched.settings(forGroup: "grp:chips")?.categoryExceptions, [linkedin, discord],
        "an entry the lists still carry keeps the exception, whichever list carries it"
    )

    guard let index = config.categories.firstIndex(where: { $0.id == "social" }) else {
        failTest("the seeded Social category is there to edit")
        return
    }
    config.categories[index].domains.removeAll { $0 == "linkedin.com" }
    let pruned = ConfigBuilder.pruningDanglingExceptions(in: config)

    expectEqual(
        pruned.settings(forGroup: "grp:chips")?.categoryExceptions, [discord],
        "the one nothing carries any more is dropped, and the other is left alone"
    )

    var putBack = pruned
    putBack.categories[index].domains.append("linkedin.com")
    expectEqual(
        CategoryMembership.claim(host: "linkedin.com", in: putBack)?.groupID, "grp:chips",
        "so a site added back to the list is blocked rather than quietly held out"
    )
}

/// Deleting runs the same rule: what the deleted list carried is nobody's exception any more,
/// unless another list carries it too.
private func testDeletingACategoryPrunesTheExceptionsItLeavesBehind() {
    let linkedin = Target.id(ofKind: .domain, value: "linkedin.com")
    let netflix = Target.id(ofKind: .domain, value: "netflix.com")
    let config = ConfigBuilder.removingCategory(
        "social", from: categoryConfig(["social", "video"], exceptions: [linkedin, netflix])
    )
    expectEqual(
        config.settings(forGroup: "grp:chips")?.categoryExceptions, [netflix],
        "the exception into the deleted list goes, the one into the list that remains stays"
    )
}
