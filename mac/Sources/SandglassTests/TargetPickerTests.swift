import SandglassAppCore
import SandglassCore
import Foundation

/// The vocabulary both add sheets are built from: a row that can be ticked, the search over
/// those rows, and what a selection turns into.
///
/// The one thing that must never regress is at the top: a website typed by hand and the same
/// website ticked in a list have to be **the same target**. Two targets differing only in their
/// display name are two group keys — `ConfigBuilder` groups by name — so the difference would not
/// show up as a wrong name on a row, it would show up as a second budget for one site months
/// later, when nobody remembers which path it came in by.
///
/// What each sheet puts on offer is checked in `TargetSheetTests`.
func runTargetPickerTests() {
    testACandidateIsTheTargetTheOldFieldMade()
    testSearchMatchesAnywhereInARow()
    testAlreadyBlockedRowsCanNeverBeAdded()
    testARefusedAddNamesTheGroupThatHasIt()
}

private let rows = [
    TargetCandidate(
        kind: .app, value: "com.tinyspeck.slackmacgap", label: "Slack", alreadyBlocked: false
    ),
    TargetCandidate(kind: .app, value: "com.hnc.Discord", label: "Discord", alreadyBlocked: false),
    TargetCandidate(kind: .domain, value: "youtube.com", label: "youtube.com", alreadyBlocked: false),
]

/// The old text path, spelled out here so the comparison is against what it actually did rather
/// than against what this file thinks it did.
private func typedByHand(_ text: String) -> Target? {
    guard let host = DomainInput.normalize(text) else { return nil }
    return Target(kind: .domain, value: host, displayName: DomainInput.displayName(for: host))
}

private func testACandidateIsTheTargetTheOldFieldMade() {
    guard let picked = rows.first(where: { $0.value == "youtube.com" }),
          let typed = typedByHand("https://www.YouTube.com/feed/subscriptions") else {
        failTest("youtube.com is missing from the rows or could not be typed")
        return
    }
    expectEqual(picked.target, typed, "a ticked site and a typed one are one target")
    expectEqual(picked.target.displayName, "Youtube", "under the name the old field gave it")
    expectEqual(picked.target.groupID, typed.groupID, "which is also the group both land in")

    guard let app = rows.first(where: { $0.kind == .app }) else {
        failTest("no app row to check")
        return
    }
    expectEqual(app.target.value, "com.tinyspeck.slackmacgap", "an app is its bundle id")
    expectEqual(
        app.target.displayName, "Slack",
        "under the name the Finder gives it, which is what every screen then shows"
    )
    expectEqual(app.id, "app:com.tinyspeck.slackmacgap", "and is keyed by the id it will have")
}

private func testSearchMatchesAnywhereInARow() {
    expect(
        TargetPicker.matching("tube", in: rows).contains { $0.value == "youtube.com" },
        "a search matches anywhere in the row, not only at the start"
    )
    expect(
        TargetPicker.matching("disc", in: rows).contains { $0.kind == .app },
        "and finds apps by the name the Finder gives them"
    )
    expectEqual(
        TargetPicker.matching("SLACK", in: rows).map(\.value), ["com.tinyspeck.slackmacgap"],
        "whatever case it is typed in"
    )
    expectEqual(
        TargetPicker.matching("  ", in: rows).count, rows.count, "whitespace is not a search"
    )
    expectEqual(
        TargetPicker.matching("nothing here", in: rows), [], "and a miss is a miss"
    )
}

/// `Store` refuses a document with two targets of one id, so a stale tick must never be able to
/// produce one — the row says so and the selection is filtered on the way out.
private func testAlreadyBlockedRowsCanNeverBeAdded() {
    let taken = rows.map {
        TargetCandidate(
            kind: $0.kind, value: $0.value, label: $0.label,
            alreadyBlocked: $0.value == "youtube.com"
        )
    }
    let produced = TargetPicker.targets(picked: Set(taken.map(\.id)), from: taken)

    expect(
        !produced.contains { $0.value == "youtube.com" },
        "what is already there is dropped rather than added a second time"
    )
    expectEqual(produced.count, taken.count - 1, "and everything else still comes through")
    expectEqual(
        TargetPicker.targets(picked: ["domain:nothing.example"], from: taken), [],
        "an id nothing offers produces nothing"
    )
    expectEqual(
        produced.map(\.id), taken.filter { !$0.alreadyBlocked }.map(\.id),
        "in the order the list offered them"
    )

    // The other way to build a document `Store` refuses: one id twice. An app that is both
    // running and installed is on the sheet twice and `AppChoices.everything` dedupes it — but
    // that is a promise made in another file, and this is where the promise is worth keeping.
    let twice = rows + rows
    expectEqual(
        TargetPicker.targets(picked: Set(twice.map(\.id)), from: twice).map(\.id),
        rows.map(\.id),
        "a candidate offered twice is still one target, whoever assembled the list"
    )
}

/// "already blocked, in this group or another" was true and useless: the one question somebody
/// has at that moment is where it went.
private func testARefusedAddNamesTheGroupThatHasIt() {
    expectNil(RuleCopy.alreadyBlocked([]), "nothing refused is not a sentence")
    expectEqual(
        RuleCopy.alreadyBlocked([("youtube.com", "Social")]),
        "Already blocked: youtube.com in “Social”.",
        "one refusal names the group holding it"
    )
    expectEqual(
        RuleCopy.alreadyBlocked([("youtube.com", "Social"), ("Slack", "Work")]),
        "Already blocked: youtube.com in “Social”, Slack in “Work”.",
        "and several are named one by one, because they can be in different groups"
    )
    expectEqual(
        RuleCopy.alreadyBlocked([("youtube.com", nil)]),
        "Already blocked: youtube.com in another group.",
        "a group with no name to show falls back to the old honest vagueness"
    )
}
