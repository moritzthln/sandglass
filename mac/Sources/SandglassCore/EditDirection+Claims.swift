import Foundation

/// The half of a group's lock that is decided across groups: **which group a site or an app
/// belongs to.**
///
/// A group's own fields are compared one group at a time, and that comparison cannot see the
/// claims. Which group a page belongs to is settled across every group at once — a block rule in
/// any group, the most specific entry, the first group by id on a tie (`WebResolver`,
/// `CategoryMembership`) — so an edit that never touches a locked group can still take its sites:
/// a new group ticking the same category, a block rule next door, a subdomain typed somewhere
/// else, a shared list growing a more specific entry. The locked group's settings, targets and
/// carried members are all unchanged, and the page is then judged by a group with nothing in
/// front of it.
///
/// So the question is asked of the sites and apps themselves: **for everything this group held a
/// moment ago, who holds it after the edit?** Still this group, or a group that holds it at least
/// as hard, and nothing was handed back. Any other group, or none at all, and the edit is this
/// group's loosening — whichever group's page it was made on.
extension EditDirection {

    /// Whether the edit moves anything `groupID` holds into a group that holds it less hard.
    ///
    /// A page cannot be enumerated, so what is asked is every address the two configurations
    /// name: each domain target, each entry of each list, each rule's pattern, and each of this
    /// group's hosts with each text block pattern after it — the last is the page a rule such as
    /// `watch` takes from a group that holds the whole site. Only a pattern that is a habit is
    /// put after a host: one that names a host, `x.com` or `reddit.com/r/`, is an address, and is
    /// asked as the address it is. Apps are asked by every bundle id a
    /// target or a list names. The resolution is `GroupLookup`'s, the one every decision goes
    /// through, so this cannot disagree with the engine about who holds what.
    ///
    /// Skipped outright when nothing a claim is made of has changed, which is the ordinary edit:
    /// a pause, a window, a name.
    static func handsAway(
        group groupID: String, from current: Config, to proposed: Config, onDay today: String
    ) -> Bool {
        guard let before = current.activeSettings(forGroup: groupID),
              ClaimShape(current) != ClaimShape(proposed) else { return false }
        let now = GroupLookup(config: current)
        let next = GroupLookup(config: proposed)
        var verdicts: [String: Bool] = [:]
        func handedAway(_ owner: String?) -> Bool {
            guard let owner else { return true }
            guard owner != groupID else { return false }
            if let known = verdicts[owner] { return known }
            let lax = proposed.activeSettings(forGroup: owner).map {
                !holdsAsHard($0, as: before, onDay: today)
            } ?? true
            verdicts[owner] = lax
            return lax
        }
        let pages = heldPages(of: groupID, from: current, to: proposed, by: now)
        if pages.contains(where: { handedAway(next.managed(url: $0)?.groupID) }) { return true }
        return appIDs(in: current, proposed).contains {
            now.managed(targetID: $0)?.groupID == groupID
                && handedAway(next.managed(targetID: $0)?.groupID)
        }
    }

    // MARK: - What is asked

    /// Every address either configuration names that `groupID` holds now.
    private static func heldPages(
        of groupID: String, from current: Config, to proposed: Config, by now: GroupLookup
    ) -> [String] {
        let named = Set(
            [current, proposed].flatMap { config in
                domains(in: config) + config.groupSettings.values.flatMap(\.rules).map(\.pattern)
            }
        )
        let held = named.filter { now.managed(url: $0)?.groupID == groupID }
        let habits = Set(
            proposed.groupSettings.values.flatMap(\.rules)
                .filter { $0.action == .block && $0.matchType == .websiteOrText }
                .map(\.pattern)
                .filter { !RuleMatcher.host(of: $0).contains(".") }
        )
        let hosts = Set(held.map { RuleMatcher.host(of: RuleMatcher.normalize(url: $0)) })
        let underHosts = hosts.flatMap { host in habits.map { host + "/" + $0 } }
            .filter { now.managed(url: $0)?.groupID == groupID }
        return Array(held) + underHosts
    }

    private static func domains(in config: Config) -> [String] {
        config.targets.filter { $0.kind == .domain }.map(\.value)
            + config.categories.flatMap(\.domains)
    }

    private static func appIDs(in current: Config, _ proposed: Config) -> Set<String> {
        Set(
            [current, proposed].flatMap { config in
                config.targets.filter { $0.kind == .app }.map(\.id)
                    + config.categories.flatMap(\.bundleIDs).map { Target.id(ofKind: .app, value: $0) }
            }
        )
    }

    // MARK: - What a claim is made of

    /// Everything `GroupLookup` reads to decide who holds what, and nothing else: two
    /// configurations equal here put every site and app in the same group.
    private struct ClaimShape: Equatable {
        struct Group: Equatable {
            let categories: Set<String>
            let exceptions: Set<String>
            let rules: [Rule]
        }

        let targets: [Target]
        let categories: [DistractionCategory]
        let groups: [String: Group]

        init(_ config: Config) {
            targets = config.targets
            categories = config.categories
            groups = config.groupSettings.keys.reduce(into: [:]) { groups, groupID in
                guard let settings = config.activeSettings(forGroup: groupID) else { return }
                groups[groupID] = Group(
                    categories: settings.categories,
                    exceptions: settings.categoryExceptions,
                    rules: settings.rules
                )
            }
        }
    }
}
