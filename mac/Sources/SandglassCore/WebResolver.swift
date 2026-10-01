import Foundation

/// Which group a URL belongs to, and what put it there.
///
/// A rule claim carries no target: a rule is a statement about the web, not about a row in the
/// configuration, so `music.youtube.com/watch` can be blocked by the Video group without
/// anything named `music.youtube.com` existing anywhere.
public struct WebMatch: Equatable, Sendable {
    public let groupID: String
    /// The domain target that claimed the URL, or `nil` when a rule or a category did.
    public let targetID: String?
    /// What the pause screen should call it: the target's name, else the group's, else the host.
    public let displayName: String

    public init(groupID: String, targetID: String?, displayName: String) {
        self.groupID = groupID
        self.targetID = targetID
        self.displayName = displayName
    }
}

/// The one place a URL becomes a group.
///
/// Rules and plain domain targets both decide, and they are read in order of how deliberate a
/// statement each one is:
///
/// 1. **An explicit `block` rule**, from any group — the most specific thing anybody wrote.
/// 2. **A domain target or a live category**, unless the group owning it also wrote an `allow`
///    for this URL. That exception is the headline case: block `youtube.com`, allow
///    `music.youtube.com`. Which of the two claims wins is decided by specificity — see
///    `hostMatch(forHost:in:)`.
///
/// There used to be a third: a whitelist group's fallback, the least specific statement there is,
/// read last so that a group blocking everything could not outrank a rule somebody typed. The
/// mode is gone and so is the step — a window that permits is where "everything except" lives now.
/// The adult list was a source of rules at step one and is an ordinary category now, so it comes
/// in at step two like every other list.
///
/// Groups are visited in sorted id order rather than dictionary order, which is per-process
/// random: two groups can both claim a URL, and which one gets it must not change between
/// launches. A switched-off group claims nothing — `activeSettings` is what asks.
public enum WebResolver {

    public static func match(url: String, in config: Config) -> WebMatch? {
        let normalized = RuleMatcher.normalize(url: url)
        guard !normalized.isEmpty else { return nil }
        let verdicts = ruleVerdicts(for: normalized, in: config)

        if let claim = verdicts.block {
            return webMatch(groupID: claim.groupID, host: normalized, in: config)
        }
        if let claim = hostMatch(forHost: RuleMatcher.host(of: normalized), in: config),
           !verdicts.allowed.contains(claim.groupID) {
            return claim
        }
        return nil
    }

    /// The configured target a host belongs to, by the suffix rule the app has always used: a
    /// target for `youtube.com` covers `m.youtube.com`, and the dot is the whole point —
    /// without it `notyoutube.com` would end with `youtube.com` too.
    ///
    /// The **most specific** of several matches, not the first. With both `youtube.com` and
    /// `music.youtube.com` configured, a page on the second belongs to the second whichever
    /// order they happen to sit in. Without it a page could be named after one group on the
    /// pause screen and counted against another in the budget.
    ///
    /// A target whose group has no settings still answers: naming it is harmless, and the
    /// decision is what decides whether anything is shown at all.
    public static func domainTarget(forHost host: String, in config: Config) -> Target? {
        bestDomainTarget(forHost: host, in: config)?.target
    }

    private static func bestDomainTarget(
        forHost host: String, in config: Config
    ) -> (target: Target, length: Int)? {
        let needle = RuleMatcher.normalizeHost(host)
        guard !needle.isEmpty else { return nil }
        var best: (target: Target, length: Int)?
        for target in config.targets where target.kind == .domain {
            let value = RuleMatcher.normalizeHost(target.value)
            guard !value.isEmpty, needle == value || needle.hasSuffix("." + value) else { continue }
            if value.count > (best?.length ?? -1) { best = (target, value.count) }
        }
        return best
    }

    /// What a host belongs to when no rule has claimed it: a target somebody typed, or a group
    /// that is a live member of a category carrying it.
    ///
    /// Specificity decides between the two, the same rule that already picks between two
    /// targets: with `google.com` typed into one group and `meet.google.com` carried by
    /// another's Messaging category, the video call belongs to Messaging. A tie goes to the
    /// plain target, because somebody typed that one on purpose and a category is a default.
    private static func hostMatch(forHost host: String, in config: Config) -> WebMatch? {
        let target = bestDomainTarget(forHost: host, in: config)
        let category = CategoryMembership.claim(host: host, in: config)
        if let target, target.length >= (category?.entry.count ?? 0) {
            return WebMatch(
                groupID: target.target.groupID,
                targetID: target.target.id,
                displayName: target.target.displayName
            )
        }
        guard let category else { return nil }
        return WebMatch(
            groupID: category.groupID,
            targetID: nil,
            displayName: name(ofGroup: category.groupID, in: config)
                ?? config.category(id: category.categoryID)?.name
                ?? RuleMatcher.normalizeHost(host)
        )
    }

    // MARK: - Reading every group's rules

    private struct Claim {
        let groupID: String
        let rule: Rule
    }

    private struct Verdicts {
        var block: Claim?
        /// Groups that explicitly stepped aside, so their own targets do not claim it anyway.
        var allowed: Set<String> = []
    }

    private static func ruleVerdicts(for url: String, in config: Config) -> Verdicts {
        var verdicts = Verdicts()
        for groupID in config.groupSettings.keys.sorted() {
            guard let settings = config.activeSettings(forGroup: groupID),
                  let rule = RuleMatcher.match(url: url, rules: settings.rules)
            else { continue }
            if rule.action == .allow {
                verdicts.allowed.insert(groupID)
            } else if verdicts.block == nil {
                verdicts.block = Claim(groupID: groupID, rule: rule)
            }
        }
        return verdicts
    }

    private static func webMatch(groupID: String, host: String, in config: Config) -> WebMatch {
        WebMatch(
            groupID: groupID,
            targetID: nil,
            displayName: name(ofGroup: groupID, in: config) ?? RuleMatcher.host(of: host)
        )
    }

    /// What a rule-claimed page is called: the group's own name, else the name of whatever is in
    /// it, else nothing and the caller falls back to the host.
    private static func name(ofGroup groupID: String, in config: Config) -> String? {
        config.groupDisplayName(forGroup: groupID)
    }
}
