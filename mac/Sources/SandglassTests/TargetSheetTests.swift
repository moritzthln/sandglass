import SandglassAppCore
import SandglassCore
import Foundation

/// The two add sheets, checked where they decide something.
///
/// Websites and apps come apart into a field and a list, and each half has one thing that must
/// not regress. For the field it is the normaliser: a website typed as a pasted URL has to become
/// the same target it would have become typed by hand, or one site ends up with two group keys.
/// For the list it is what is on it: an agent, a browser or Sandglass itself appearing under
/// `Running now` is a row that should never have been offered.
func runTargetSheetTests() {
    testTheFieldTakesAnAddressAndSaysWhatItWillAdd()
    testAHostAlreadyOnTheListCannotBeAddedTwice()
    testTheSuggestionsFilterAsTheAddressIsTyped()
    testRunningNowIsOrdinaryAppsOnly()
    testRunningStaysInAllAppsAndBothFilterTogether()
    testATickIsResolvedAgainstEveryAppOnceOnly()
    testTheSuggestionsLeaveOutWhatIsAlreadyHeld()
    testAnAddThatTakesNothingIsNotASuccess()
    testWhatASelectionAddsToAGroup()
    testTheSectionsNameThemselvesAndTheirRows()
}

private func emptyConfig() -> Config {
    Config(version: 1, targets: [], groupSettings: [:])
}

/// The old text field, spelled out so the comparison is against what it did rather than against
/// what this file remembers it doing.
private func typedByHand(_ text: String) -> Target? {
    guard let host = DomainInput.normalize(text) else { return nil }
    return Target(kind: .domain, value: host, displayName: DomainInput.displayName(for: host))
}

// MARK: - Add a website

private func testTheFieldTakesAnAddressAndSaysWhatItWillAdd() {
    let config = emptyConfig()
    expectEqual(
        SiteField.state(of: "", alreadyThere: .configuration, config: config), .empty,
        "an untouched field is not a refusal"
    )
    expectEqual(
        SiteField.state(of: "   ", alreadyThere: .configuration, config: config), .empty,
        "and neither is whitespace"
    )
    expectNil(
        SiteField.note(for: "", alreadyThere: .configuration, config: config),
        "an empty field says nothing under itself"
    )
    expectEqual(
        SiteField.state(of: "not a host", alreadyThere: .configuration, config: config), .unusable,
        "something that is not an address cannot be added"
    )
    expect(
        !SiteField.state(of: "not a host", alreadyThere: .configuration, config: config).canAdd,
        "so Add stays dead"
    )
    expectEqual(
        SiteField.note(for: "not a host", alreadyThere: .configuration, config: config),
        "That is not a website address. One looks like youtube.com.",
        "and the reason is said rather than left as a button that will not press"
    )

    expectEqual(
        SiteField.state(of: "youtube.com", alreadyThere: .configuration, config: config),
        .ready("youtube.com"),
        "a plain host is ready as typed"
    )
    expectNil(
        SiteField.note(for: "youtube.com", alreadyThere: .configuration, config: config),
        "and needs nothing explained, because nothing was changed"
    )

    // The hint that carried over from the old picker: what is stored is not what was typed, so it
    // is shown before it happens rather than discovered afterwards in the list.
    expectEqual(
        SiteField.state(
            of: "https://www.YouTube.com/feed/subscriptions",
            alreadyThere: .configuration, config: config
        ),
        .ready("youtube.com"),
        "a pasted address is normalised the way it always was"
    )
    expectEqual(
        SiteField.note(
            for: "https://www.YouTube.com/feed/subscriptions",
            alreadyThere: .configuration, config: config
        ),
        "Adds “youtube.com” instead — a website is blocked whole, every page under it included.",
        "and the sheet says so first"
    )

    guard let host = SiteField.state(
        of: "https://www.YouTube.com/feed/subscriptions", alreadyThere: .configuration,
        config: config
    ).host, let typed = typedByHand("https://www.YouTube.com/feed/subscriptions") else {
        failTest("the field produced no host for an address it accepted")
        return
    }
    expectEqual(
        SiteField.target(forHost: host), typed,
        "and what it adds is the target the old field made, down to the display name"
    )
    expectEqual(
        SiteField.target(forHost: host).groupID, typed.groupID,
        "which is also the group it lands in"
    )
}

/// A target that exists cannot be added a second time — `Store` refuses a document holding two of
/// one id — so the field says so while it is being typed rather than after Add is pressed.
private func testAHostAlreadyOnTheListCannotBeAddedTwice() {
    var config = emptyConfig()
    config.targets = [Target(kind: .domain, value: "youtube.com", displayName: "Youtube")]

    expectEqual(
        SiteField.state(of: "www.youtube.com", alreadyThere: .configuration, config: config),
        .alreadyThere("youtube.com"),
        "the configuration is what the group editor measures against"
    )
    expect(
        !SiteField.state(of: "youtube.com", alreadyThere: .configuration, config: config).canAdd,
        "and Add is dead for it"
    )
    expectEqual(
        SiteField.note(for: "youtube.com", alreadyThere: .configuration, config: config),
        "youtube.com is already blocked.",
        "under the word the group editor uses, because some group is blocking it"
    )

    // The category editor fills a list of its own. Judging by the configuration there would grey
    // out every site some group happens to block — two unrelated facts confused for one.
    let inTheList = AlreadyThere.list([Target.id(ofKind: .domain, value: "reddit.com")])
    expectEqual(
        SiteField.state(of: "youtube.com", alreadyThere: inTheList, config: config),
        .ready("youtube.com"),
        "a site some group blocks is still free to be put in a category"
    )
    expectEqual(
        SiteField.state(of: "reddit.com", alreadyThere: inTheList, config: config),
        .alreadyThere("reddit.com"),
        "while what the list already carries is refused"
    )
    expectEqual(
        SiteField.note(for: "reddit.com", alreadyThere: inTheList, config: config),
        "reddit.com is already there.",
        "and is not called blocked, which no group has said"
    )
}

/// The history is help, not the menu: it narrows as the address is typed, so picking one stays a
/// single click at any point.
private func testTheSuggestionsFilterAsTheAddressIsTyped() {
    let sites = [
        BrowserHistory.Site(host: "youtube.com", visits: 412),
        BrowserHistory.Site(host: "reddit.com", visits: 88),
        BrowserHistory.Site(host: "news.ycombinator.com", visits: 12),
    ]
    expectEqual(
        SiteField.matching("", in: sites).count, 3,
        "an empty field is the whole list, which is what opens with the sheet"
    )
    expectEqual(
        SiteField.matching("  ", in: sites).count, 3, "whitespace is not a search"
    )
    expectEqual(
        SiteField.matching("you", in: sites).map(\.host), ["youtube.com"],
        "a few letters narrow it"
    )
    expectEqual(
        SiteField.matching("YOU", in: sites).map(\.host), ["youtube.com"],
        "whatever case they are typed in"
    )
    expectEqual(
        SiteField.matching("combinator", in: sites).map(\.host), ["news.ycombinator.com"],
        "and match anywhere in the host, not only at the front"
    )
    expectEqual(
        SiteField.matching("https://www.youtube.com/feed", in: sites).map(\.host),
        ["youtube.com"],
        "a pasted address filters to the site it names rather than emptying the list"
    )
    expectEqual(
        SiteField.matching("nothing.example", in: sites), [],
        "and a host nobody has visited leaves the section empty, for the field alone to handle"
    )

    // A query that is only a path names no host, so the answer is the whole list. Refusing to cut
    // at position zero left the slash in the needle and emptied the section instead.
    expectEqual(
        SiteField.matching("/", in: sites).count, 3,
        "a lone slash is not a search anybody meant"
    )
    expectEqual(
        SiteField.matching("#top", in: sites).count, 3, "and neither is a bare fragment"
    )

    // The list is lowercased upstream today, which is what has been hiding the difference between
    // this filter and the app list's. The filter is not the place that gets to assume it.
    expectEqual(
        SiteField.matching("you", in: [BrowserHistory.Site(host: "YouTube.com", visits: 1)])
            .map(\.host),
        ["YouTube.com"],
        "a host is matched case-insensitively, the way every other list on these sheets is"
    )
}

// MARK: - Add apps

private func running(_ bundleID: String, _ name: String, ordinary: Bool = true) -> AppChoices.RunningApp {
    AppChoices.RunningApp(bundleID: bundleID, name: name, isOrdinary: ordinary)
}

/// What is running is some eighty processes, and about ten of them are apps. The filter is the
/// whole reason the section is readable.
private func testRunningNowIsOrdinaryAppsOnly() {
    let answered = [
        running("com.tinyspeck.slackmacgap", "Slack"),
        running("com.apple.dock", "Dock", ordinary: false),
        running("", "Nameless helper"),
        running(AppChoices.appBundleID, "Sandglass"),
        running("com.google.Chrome", "Google Chrome"),
        running("com.tinyspeck.slackmacgap", "Slack"),
        running("com.example.unnamed", "  "),
    ]
    let offered = AppChoices.running(answered)

    expectEqual(
        offered.map(\.bundleID), ["com.example.unnamed", "com.tinyspeck.slackmacgap"],
        "agents, nameless bundles, browsers and Sandglass itself are all left out, and nothing twice"
    )
    expectEqual(
        offered.first?.name, "com.example.unnamed",
        "an app macOS has no name for is shown by its bundle id rather than dropped"
    )
    expect(
        AppChoices.excludedBundleIDs.contains("com.apple.Safari"),
        "the browsers come from the one list they are written down in"
    )
    expectEqual(
        AppChoices.running([]).count, 0, "a Mac with nothing running has no section"
    )
}

/// A list where Slack vanishes from `All apps` because it happens to be open is a list that lies.
private func testRunningStaysInAllAppsAndBothFilterTogether() {
    var config = emptyConfig()
    config.targets = [
        Target(kind: .app, value: "com.tinyspeck.slackmacgap", displayName: "Slack")
    ]
    let installed = [
        TargetPicker.App(bundleID: "com.hnc.Discord", name: "Discord"),
        TargetPicker.App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        TargetPicker.App(bundleID: "com.spotify.client", name: "Spotify"),
    ]
    let open = AppChoices.running([
        running("com.tinyspeck.slackmacgap", "Slack"), running("com.spotify.client", "Spotify"),
    ])

    let sections = AppChoices.sections(
        running: open, installed: installed, alreadyThere: .configuration, config: config,
        search: ""
    )
    expectEqual(
        sections.running.map(\.label), ["Slack", "Spotify"], "what is open is offered on top"
    )
    expectEqual(
        sections.all.map(\.label), ["Discord", "Slack", "Spotify"],
        "and is still in the list of everything installed"
    )
    expect(
        sections.running.allSatisfy { $0.label != "Slack" || $0.alreadyBlocked },
        "an app the group already has reads as taken in both sections"
    )
    expect(
        sections.all.contains { $0.label == "Slack" && $0.alreadyBlocked },
        "including the one underneath"
    )
    expectEqual(
        TargetPicker.targets(picked: Set(sections.all.map(\.id)), from: sections.all)
            .filter { $0.value == "com.tinyspeck.slackmacgap" },
        [],
        "and cannot be added a second time even with a stale tick on it"
    )

    let searched = AppChoices.sections(
        running: open, installed: installed, alreadyThere: .configuration, config: config,
        search: "spot"
    )
    expectEqual(searched.running.map(\.label), ["Spotify"], "one search filters the top section")
    expectEqual(searched.all.map(\.label), ["Spotify"], "and the bottom one at the same time")
    expect(
        AppChoices.sections(
            running: open, installed: installed, alreadyThere: .configuration, config: config,
            search: "nothing here"
        ).isEmpty,
        "a search matching nothing leaves both sections empty"
    )

    // An app running from somewhere the installed scan does not walk — a nested folder — is still
    // offered, because it is in front of the person asking.
    let unscanned = AppChoices.sections(
        running: AppChoices.running([running("com.adobe.something", "Photoshop")]),
        installed: installed, alreadyThere: .list([]), config: config, search: ""
    )
    expectEqual(
        unscanned.running.map(\.label), ["Photoshop"],
        "running is read from what is running, not from what was scanned"
    )
    expect(
        unscanned.running.allSatisfy { !$0.alreadyBlocked },
        "and a list of the caller's own is what decides taken, when it is given one"
    )
}

/// An app that is both running and installed is on the sheet twice, and ticking it is one
/// decision. Resolved against both lists as they stand, it would ask the configuration to add one
/// target twice — and the second attempt comes back reading as "already blocked", which is the
/// sheet accusing the user of something it did itself.
private func testATickIsResolvedAgainstEveryAppOnceOnly() {
    let installed = [
        TargetPicker.App(bundleID: "com.hnc.Discord", name: "Discord"),
        TargetPicker.App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
    ]
    let open = AppChoices.running([running("com.tinyspeck.slackmacgap", "Slack")])
    let everything = AppChoices.everything(
        running: open, installed: installed, alreadyThere: .configuration, config: emptyConfig()
    )

    expectEqual(
        everything.map(\.id).count, Set(everything.map(\.id)).count,
        "each app is on the list once, however many sections showed it"
    )
    expectEqual(
        TargetPicker.targets(picked: ["app:com.tinyspeck.slackmacgap"], from: everything)
            .map(\.value),
        ["com.tinyspeck.slackmacgap"],
        "so one tick is one target"
    )
    expectEqual(
        TargetPicker.targets(picked: Set(everything.map(\.id)), from: everything).count, 2,
        "and ticking everything adds every app once"
    )
}

/// The sheet is opened to add something, so it does not spend its list suggesting what is already
/// there. Which list "already" means is the caller's business — see `AlreadyThere`.
private func testTheSuggestionsLeaveOutWhatIsAlreadyHeld() {
    var config = emptyConfig()
    config.targets = [
        Target(kind: .domain, value: "youtube.com", displayName: "Youtube"),
        Target(kind: .app, value: "com.tinyspeck.slackmacgap", displayName: "Slack"),
    ]
    expectEqual(
        AlreadyThere.configuration.hosts(in: config), ["youtube.com"],
        "the group editor leaves out every website the configuration names, and no app"
    )
    expectEqual(
        AlreadyThere.list([
            Target.id(ofKind: .domain, value: "reddit.com"),
            Target.id(ofKind: .app, value: "com.hnc.Discord"),
        ]).hosts(in: config),
        ["reddit.com"],
        "and a caller's own list leaves out what that list carries, whatever else is blocked"
    )
    expectEqual(
        AlreadyThere.list([]).hosts(in: config), [],
        "an empty list holds nothing back"
    )
}

// MARK: - What an add comes to

/// The pair a sheet reads as success is "nothing added, nothing wrong", and a selection can
/// resolve to nothing while its ticks are still on screen: every row it named has become already
/// blocked since. Answering `nil` there closed the sheet over the whole selection, wrote nothing
/// and said nothing — the one thing the sheet's own contract exists to prevent.
private func testAnAddThatTakesNothingIsNotASuccess() {
    let config = emptyConfig()
    let outcome = TargetAdd.adding([], toGroup: "grp:social", in: config)

    expectEqual(outcome.added, [], "an empty selection adds nothing, which is not in dispute")
    expectEqual(outcome.config, config, "and leaves the configuration exactly as it was")
    expectEqual(
        outcome.problem, RuleCopy.nothingToAdd,
        "but it answers with a reason, because silence is what closes the sheet"
    )
    expect(
        outcome.problem != nil,
        "which is the whole check: nothing added and nothing said reads as a successful add"
    )
}

/// Everything else one selection can do to one group, in one edit rather than one per target.
private func testWhatASelectionAddsToAGroup() {
    var config = emptyConfig()
    config.groupSettings = ["grp:social": .standard, "grp:work": .standard]
    config.targets = [
        Target(kind: .app, value: "com.tinyspeck.slackmacgap", displayName: "Slack", groupID: "grp:work")
    ]
    let youtube = Target(kind: .domain, value: "youtube.com", displayName: "Youtube")
    let slack = Target(kind: .app, value: "com.tinyspeck.slackmacgap", displayName: "Slack")

    let landed = TargetAdd.adding([youtube], toGroup: "grp:social", in: config)
    expectEqual(landed.added.map(\.id), [youtube.id], "what is free is taken")
    expectNil(landed.problem, "and nothing is wrong with it, so the sheet closes")
    expectEqual(
        landed.config.targets.first { $0.id == youtube.id }?.groupID, "grp:social",
        "into the group the card is about, whatever it is called"
    )

    let taken = TargetAdd.adding([slack], toGroup: "grp:social", in: config)
    expectEqual(taken.added, [], "a target some group already holds is not added a second time")
    expectEqual(taken.config, config, "so nothing is written")
    expect(
        taken.problem?.contains("Slack") == true,
        "and the reason names it rather than the count of what failed"
    )

    // Half a selection landing still closes the sheet: something did happen, and the note goes
    // on the card where the list it is about is.
    let partly = TargetAdd.adding([youtube, slack], toGroup: "grp:social", in: config)
    expectEqual(partly.added.map(\.id), [youtube.id], "the free half of a selection still lands")
    expect(
        partly.config.targets.contains { $0.id == youtube.id },
        "and is in the configuration handed back"
    )
    expect(partly.problem != nil, "with the other half explained")
}

// MARK: - What the card's sections say

private func testTheSectionsNameThemselvesAndTheirRows() {
    expectEqual(RuleCopy.sectionHeading("Websites", count: 2), "Websites (2)", "a heading counts")
    expectEqual(
        RuleCopy.sectionHeading("Rules", count: 0), "Rules (0)",
        "including when it is empty, for a caller that decides to draw one anyway"
    )
    expectEqual(
        RuleCopy.rowTitle(Target(kind: .domain, value: "youtube.com", displayName: "Youtube")),
        "youtube.com",
        "a website reads as the address that is blocked"
    )
    expectEqual(
        RuleCopy.rowTitle(
            Target(kind: .app, value: "com.tinyspeck.slackmacgap", displayName: "Slack")
        ),
        "Slack",
        "and an app as what the Finder calls it, not as its bundle id"
    )
    expectEqual(
        RuleCopy.rowTitle(Target(kind: .app, value: "com.example.thing", displayName: "  ")),
        "com.example.thing",
        "with the bundle id as the fallback for a target nobody named"
    )

    let rule = Rule(
        id: "1", pattern: "music.youtube.com", matchType: .specificPage, action: .allow,
        highPriority: true
    )
    expectEqual(
        RuleCopy.summary(rule), "Allow · exact page · priority",
        "a rule's line reads as a sentence rather than a row of badges"
    )
    expectEqual(
        RuleCopy.summary(
            Rule(id: "2", pattern: "reddit.com/r/", matchType: .websiteOrText, action: .block)
        ),
        "Block · address contains",
        "and priority is only named when it is set, or the marker would be decoration"
    )
    // The one rule type that reads two ways: a block matches its text anywhere in an address, an
    // allow names a place. The row has to say which, or half of them are described wrongly.
    expectEqual(
        RuleCopy.summary(
            Rule(id: "3", pattern: "music.youtube.com", matchType: .websiteOrText, action: .allow)
        ),
        "Allow · site or page",
        "an exception is a place, and its row says so"
    )
}
