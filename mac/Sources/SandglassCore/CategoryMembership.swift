import Foundation

/// Which group a live category puts a site or an app in.
///
/// The other half of `GroupSettings.categories`. A group that is a member of Social does not
/// hold seventeen targets; it holds the word "social", and this is where that word becomes an
/// answer to "who claims `xing.com`". Reading the list at match time rather than copying it into
/// the group is the whole point: a site added to the Social category — by a later build, or by
/// the user in the Categories card — reaches every group that ever ticked it at once.
///
/// **A group that is switched off claims nothing.** `activeSettings` is what asks, the same
/// accessor every decision goes through — "off means the group does nothing" has to be true here
/// too, or a disabled group's category would shadow another group's claim on the page and it
/// would end up managed by nobody.
///
/// **Groups are visited in sorted id order.** Two groups can both be in a category, and
/// dictionary order is per-process random: which one claims a host must not change between
/// launches. Categories do not overlap — the suite enforces it — so this only decides between
/// two groups that ticked the same chip.
public enum CategoryMembership {

    /// A group's claim on something, and which of its categories made it.
    public struct Claim: Equatable, Sendable {
        public let groupID: String
        public let categoryID: String
        /// The list entry that matched: `zdf.de` for a page on `www.zdf.de`, or a bundle id.
        public let entry: String

        public init(groupID: String, categoryID: String, entry: String) {
            self.groupID = groupID
            self.categoryID = categoryID
            self.entry = entry
        }
    }

    /// The group whose categories claim `host`, by the same suffix rule a domain target follows:
    /// `zdf.de` covers `www.zdf.de`, and the dot is what keeps `notzdf.de` out.
    ///
    /// The **most specific** entry wins, so `meet.google.com` in Messaging beats a hypothetical
    /// `google.com` elsewhere. `WebResolver` compares that same specificity against the plain
    /// targets before it decides, which is why the length of `entry` is worth carrying out.
    public static func claim(host: String, in config: Config) -> Claim? {
        let needle = RuleMatcher.normalizeHost(host)
        guard !needle.isEmpty else { return nil }
        var best: (claim: Claim, length: Int)?
        forEachCategory(in: config) { groupID, settings, category in
            for domain in category.domains {
                guard needle == domain || needle.hasSuffix("." + domain) else { continue }
                guard !settings.categoryExceptions
                    .contains(Target.id(ofKind: .domain, value: domain)) else { continue }
                guard domain.count > (best?.length ?? -1) else { continue }
                best = (Claim(groupID: groupID, categoryID: category.id, entry: domain), domain.count)
            }
        }
        return best?.claim
    }

    /// The same question asked with a target id — `app:com.hnc.Discord`, `domain:zdf.de`.
    ///
    /// An exact identity rather than a suffix: a target id names one member of one list, which
    /// is what the app path has in its hand when an application comes to the front and what
    /// `categoryExceptions` is written in.
    public static func claim(targetID: String, in config: Config) -> Claim? {
        var found: Claim?
        forEachCategory(in: config) { groupID, settings, category in
            guard found == nil, !settings.categoryExceptions.contains(targetID),
                  let entry = category.entry(forTargetID: targetID) else { return }
            found = Claim(groupID: groupID, categoryID: category.id, entry: entry)
        }
        return found
    }

    // MARK: - What a group carries

    /// The members of `category` that `settings` actually carries: the whole list, minus what
    /// the user struck off.
    ///
    /// The one place the exceptions are applied, so the count on a card and the answer the
    /// engine gives cannot disagree about what is in a category. Installed-app filtering is not
    /// done here and cannot be: which apps exist is a fact about this Mac that only the app
    /// layer can see, and a bundle id nobody has installed is harmless anyway — nothing can
    /// bring it to the front.
    public static func members(
        of category: DistractionCategory, in settings: GroupSettings
    ) -> (domains: [String], bundleIDs: [String]) {
        (
            domains: category.domains.filter {
                !settings.categoryExceptions.contains(Target.id(ofKind: .domain, value: $0))
            },
            bundleIDs: category.bundleIDs.filter {
                !settings.categoryExceptions.contains(Target.id(ofKind: .app, value: $0))
            }
        )
    }

    /// Every website a group carries through its live categories, exceptions already applied.
    ///
    /// Websites and not apps, because that is the honest half: a domain always applies, while a
    /// bundle id means nothing unless that app is on this Mac. Callers that count protection use
    /// this and undercount rather than claim what may not be there.
    ///
    /// The configuration is asked for rather than a global list, because the lists are the user's
    /// now: two documents can disagree about what Social carries, and the answer has to come from
    /// the one the group lives in.
    public static func carriedDomains(_ settings: GroupSettings, in config: Config) -> [String] {
        settings.categories.sorted()
            .compactMap { config.category(id: $0) }
            .flatMap { members(of: $0, in: settings).domains }
    }

    /// Every bundle id a group carries through its live categories, exceptions already applied.
    ///
    /// Unfiltered by what is installed, and that is safe for what asks: sending an app away that
    /// is not running is a no-op, while missing one that is means an app left in front of a user
    /// whose session has just relocked.
    public static func carriedBundleIDs(_ settings: GroupSettings, in config: Config) -> [String] {
        settings.categories.sorted()
            .compactMap { config.category(id: $0) }
            .flatMap { members(of: $0, in: settings).bundleIDs }
    }

    // MARK: - Walking

    /// Every (switched-on group, category it is a member of) pair, in an order that does not
    /// change between launches. Unknown ids are skipped rather than trapped; see
    /// `Config.category(id:)`.
    private static func forEachCategory(
        in config: Config,
        _ body: (String, GroupSettings, DistractionCategory) -> Void
    ) {
        for groupID in config.groupSettings.keys.sorted() {
            guard let settings = config.activeSettings(forGroup: groupID),
                  !settings.categories.isEmpty else { continue }
            for categoryID in settings.categories.sorted() {
                guard let category = config.category(id: categoryID) else { continue }
                body(groupID, settings, category)
            }
        }
    }
}
