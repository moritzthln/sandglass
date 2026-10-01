import Foundation

/// Which group a target or a page belongs to, and what settings it brings with it.
///
/// Split out of `RulesEngine` for the same reason `GroupBudget` was: it decides nothing. It reads
/// the configuration, never the clock and never the state, and hands back the two facts every
/// decision is made of. The engine keeps the precedence and the mutations.
struct GroupLookup {
    let config: Config

    /// A group and its settings. The target that led here is deliberately not among them: a rule
    /// can claim a URL that no target names, and a decision must not be able to tell the two
    /// apart.
    struct Managed {
        let groupID: String
        let settings: GroupSettings
    }

    /// A target the configuration lists, or — failing that — one a group carries through a live
    /// category. The two are indistinguishable from here on, which is the point: an app in a
    /// group's Messaging category spends that group's budget exactly as a hand-picked one does.
    func managed(targetID: String) -> Managed? {
        if let target = config.targets.first(where: { $0.id == targetID }) {
            return managed(inGroup: target.groupID)
        }
        guard let claim = CategoryMembership.claim(targetID: targetID, in: config) else { return nil }
        return managed(inGroup: claim.groupID)
    }

    /// The same question for a page in a browser, asked about the whole address. See
    /// `WebResolver` for how a URL finds its rule.
    func managed(url: String) -> Managed? {
        guard let match = WebResolver.match(url: url, in: config) else { return nil }
        return managed(inGroup: match.groupID)
    }

    /// A switched-off group is looked up as no group at all — `activeSettings`, not `settings`.
    /// That is what makes "off" mean `.notManaged` everywhere at once rather than in each caller.
    private func managed(inGroup groupID: String) -> Managed? {
        guard let settings = config.activeSettings(forGroup: groupID) else { return nil }
        return Managed(groupID: groupID, settings: settings)
    }
}
