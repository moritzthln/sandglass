import SandglassAppCore
import SandglassCore
import Foundation

/// The order the sidebar lists the groups in, and the drag that changes it.
///
/// Two things are checked here and they fail for different reasons. The **arrangement** is
/// arithmetic on a list: a card dropped on a row takes that row's slot, and getting it wrong by
/// one puts every drop on the wrong side of its target. The **healing** is what happens when the
/// stored order and the groups disagree, which they will — `config.json` is a file the user is
/// invited to open, groups outlive the builds that made them, and a save can be interrupted. The
/// rule there is that the sidebar is a list of the groups, exactly: never a group short, never a
/// group twice, whatever the order says.
///
/// The drag itself is SwiftUI and is not tested here; what a drop *means* is, and that is the
/// part that could be wrong without anybody noticing until their groups were in a mess.
func runGroupOrderTests() {
    testAnArrangedOrderIsWhatTheSidebarShows()
    testAnOrderNamingAGroupThatIsGoneIsWalkedPast()
    testAGroupTheOrderDoesNotNameComesAtTheEnd()
    testAHalfWrittenOrderStillListsEveryGroupOnce()
    testAGroupCanBeDraggedToTheTop()
    testAGroupCanBeDraggedToTheBottom()
    testAGroupCanBeDroppedBetweenTwoOthers()
    testADropThatMeansNothingChangesNothing()
    testAMoveSurvivesASaveAndAReload()
}

// MARK: - Fixtures

/// Four groups with one target each, in storage order — so the derived order the healing falls
/// back to is `a, b, c, d` and any other answer came from `groupOrder`.
private func fourGroups(order: [String] = []) -> Config {
    var config = Config(
        version: 1,
        targets: ["a", "b", "c", "d"].map {
            Target(kind: .domain, value: "\($0).example", displayName: $0.uppercased(),
                   groupID: "grp:\($0)")
        },
        groupSettings: Dictionary(
            uniqueKeysWithValues: ["a", "b", "c", "d"].map { ("grp:\($0)", GroupSettings.standard) }
        )
    )
    config.groupOrder = order
    return config
}

private func listed(_ config: Config) -> [String] {
    ConfigBuilder.groups(in: config).map(\.id)
}

// MARK: - Reading the order

/// The stored order wins outright, and it is read through `groups(in:)` rather than only through
/// the ordering itself — the sidebar reads the groups, so that is the answer that has to move.
private func testAnArrangedOrderIsWhatTheSidebarShows() {
    let arranged = fourGroups(order: ["grp:d", "grp:c", "grp:b", "grp:a"])
    expectEqual(
        listed(arranged), ["grp:d", "grp:c", "grp:b", "grp:a"],
        "the sidebar lists the groups in the order the user arranged them"
    )
    expectEqual(
        ConfigBuilder.groups(in: arranged).first?.name, "D",
        "carrying everything each group holds, not just its id"
    )
    expectEqual(
        listed(fourGroups()), ["grp:a", "grp:b", "grp:c", "grp:d"],
        "and with no order stored it is the one storage happens to give — which is what it was"
    )
}

/// A deleted group, or a line somebody typed into `config.json`. The id points at nothing and
/// there is nothing to show for it, so it is walked past rather than turning into a blank row.
private func testAnOrderNamingAGroupThatIsGoneIsWalkedPast() {
    let haunted = fourGroups(order: ["grp:d", "grp:gone", "grp:c", "grp:b", "grp:a"])
    expectEqual(
        listed(haunted), ["grp:d", "grp:c", "grp:b", "grp:a"],
        "an id naming no group is not a row"
    )

    let deleted = ConfigBuilder.removingGroup(
        "grp:c", from: fourGroups(order: ["grp:d", "grp:c", "grp:b", "grp:a"])
    )
    expectEqual(
        listed(deleted), ["grp:d", "grp:b", "grp:a"],
        "which is how a group deleted out of the middle of the order leaves the rest of it alone"
    )
    expectEqual(
        deleted.groupOrder, ["grp:d", "grp:b", "grp:a"],
        "and the deletion takes the id out of the stored order too, so the file does not fill up "
            + "with the names of groups that are gone"
    )
}

/// A group made by a build that never wrote the key, or one made since the order was last
/// written. It is a real group with real settings and it has to be reachable.
private func testAGroupTheOrderDoesNotNameComesAtTheEnd() {
    let partial = fourGroups(order: ["grp:c", "grp:a"])
    expectEqual(
        listed(partial), ["grp:c", "grp:a", "grp:b", "grp:d"],
        "the arranged ones first, then the rest at the end in the order storage gives"
    )

    let (added, groupID) = ConfigBuilder.addingGroup(
        named: "Late arrival", to: fourGroups(order: ["grp:d", "grp:c", "grp:b", "grp:a"])
    )
    expectEqual(
        listed(added), ["grp:d", "grp:c", "grp:b", "grp:a", groupID],
        "so a group made after the arranging lands at the bottom, where a new row belongs"
    )
}

/// Both disagreements at once, plus an id listed twice — the shape a save interrupted halfway
/// leaves, and the shape a hand-edited file can be any day. The list has to come out complete
/// and each group has to be in it exactly once.
private func testAHalfWrittenOrderStillListsEveryGroupOnce() {
    let mangled = fourGroups(order: ["grp:c", "grp:gone", "grp:c", "grp:a", "grp:c"])
    expectEqual(
        listed(mangled), ["grp:c", "grp:a", "grp:b", "grp:d"],
        "a group listed three times is one row, the missing ones are still there, the ghost is not"
    )
    expectEqual(
        listed(mangled).count, Set(listed(mangled)).count,
        "no group is listed twice, whatever the file says"
    )
    expectEqual(
        Set(listed(mangled)), Set(mangled.groupSettings.keys),
        "and every group the configuration holds is shown"
    )
}

// MARK: - Moving one

/// Dropped on the first card, the dragged one takes the top and everything else moves down.
private func testAGroupCanBeDraggedToTheTop() {
    let moved = ConfigBuilder.movingGroup("grp:c", onto: "grp:a", in: fourGroups())
    expectEqual(
        listed(moved), ["grp:c", "grp:a", "grp:b", "grp:d"],
        "a card dropped on the top row takes the top row"
    )
    expectEqual(
        moved.groupOrder, ["grp:c", "grp:a", "grp:b", "grp:d"],
        "and the whole order is written down, not just the two cards that moved"
    )
}

/// The other end: dropped on the last card, the dragged one takes the bottom. This is the
/// direction an off-by-one hides in — the removal has already shifted the target up by the time
/// the insertion happens.
private func testAGroupCanBeDraggedToTheBottom() {
    let moved = ConfigBuilder.movingGroup("grp:b", onto: "grp:d", in: fourGroups())
    expectEqual(
        listed(moved), ["grp:a", "grp:c", "grp:d", "grp:b"],
        "a card dropped on the bottom row takes the bottom row"
    )
}

/// The case a drop zone at each end could not reach at all, which is why the row is the target:
/// every slot in the list is some row, so there is no position that can only be arrived at from
/// an end. Both directions, because they take different paths through the arithmetic.
private func testAGroupCanBeDroppedBetweenTwoOthers() {
    let down = ConfigBuilder.movingGroup("grp:a", onto: "grp:c", in: fourGroups())
    expectEqual(
        listed(down), ["grp:b", "grp:c", "grp:a", "grp:d"],
        "dragged down, the card lands in the slot it was dropped on — between C and D"
    )

    let up = ConfigBuilder.movingGroup("grp:d", onto: "grp:b", in: fourGroups())
    expectEqual(
        listed(up), ["grp:a", "grp:d", "grp:b", "grp:c"],
        "dragged up, the same — between A and B"
    )
}

/// A drop is a gesture, and a gesture that means nothing must not be an edit: a card dropped on
/// itself, or a drag carrying an id from a configuration this one no longer resembles.
private func testADropThatMeansNothingChangesNothing() {
    let base = fourGroups(order: ["grp:d", "grp:c", "grp:b", "grp:a"])
    expectEqual(
        ConfigBuilder.movingGroup("grp:b", onto: "grp:b", in: base), base,
        "a card dropped on itself changes nothing at all"
    )
    expectEqual(
        ConfigBuilder.movingGroup("grp:gone", onto: "grp:a", in: base), base,
        "and neither does a drag of something that is not there"
    )
    expectEqual(
        ConfigBuilder.movingGroup("grp:a", onto: "grp:gone", in: base), base,
        "or a drop onto it"
    )
}

/// The point of storing it: the arrangement is a decision, so it has to outlive the window it was
/// made in. Written and read back through the real encoders, because an order that only lives in
/// memory is the derived one with extra steps.
private func testAMoveSurvivesASaveAndAReload() {
    let moved = ConfigBuilder.movingGroup("grp:d", onto: "grp:a", in: fourGroups())
    guard let bytes = try? SandglassJSON.encoder.encode(moved),
          let back = try? SandglassJSON.decoder.decode(Config.self, from: bytes) else {
        failTest("a configuration with an arranged order could not be written and read back")
        return
    }
    expectEqual(
        back.groupOrder, ["grp:d", "grp:a", "grp:b", "grp:c"],
        "the order comes back off disk as it went on"
    )
    expectEqual(
        listed(back), ["grp:d", "grp:a", "grp:b", "grp:c"],
        "and the sidebar shows the arrangement rather than deriving one again"
    )
}
