import Foundation

/// One group of the usual distractions, offered as a single tick — and owned by the user.
///
/// macOS has no system notion of app categories — unlike iOS, where Screen Time hands them to
/// an app — so the six the app seeds are written out by hand. A category that carries something
/// wrong is worse than one that carries too little: the user only finds out about the first kind
/// when something they needed stopped opening, and by then they no longer trust the blocker. So
/// the bar for a seeded entry is that it is unambiguously the thing the category names, and the
/// lists lean towards what somebody reading German actually opens — a "News" category that knows
/// the New York Times and not the Tagesschau is a category for somebody else.
///
/// It used to be exactly six, compiled in, and that was the whole problem: ticking "Social" was
/// a leap of faith, because there was no screen anywhere that said what was in it and no way at
/// all to change it. They live in `Config.categories` now — seeded on first load, then renameable,
/// editable and deletable like anything else in it. Nothing treats the seeded six specially.
public struct DistractionCategory: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Hosts in the form `DomainInput.normalize` produces — lowercase, no scheme, no `www.`.
    /// Checked in the suite for the seeded six, and lowercased on the way in from disk, because a
    /// host in any other shape matches nothing at all.
    public var domains: [String]
    /// Bundle ids of well-known Mac apps.
    public var bundleIDs: [String]

    public init(id: String = UUID().uuidString, name: String, domains: [String], bundleIDs: [String]) {
        self.id = id
        self.name = name
        self.domains = domains.map { $0.lowercased() }
        self.bundleIDs = bundleIDs
    }

    private enum CodingKeys: String, CodingKey { case id, name, domains, bundleIDs }

    /// Written by hand so that an empty list is absent rather than `[]`: most categories carry no
    /// apps at all, and a `config.json` full of `"bundleIDs" : []` is a document that got longer
    /// without saying more. The same rule `GroupSettings` follows.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if !domains.isEmpty { try container.encode(domains, forKey: .domains) }
        if !bundleIDs.isEmpty { try container.encode(bundleIDs, forKey: .bundleIDs) }
    }

    /// A category with neither list is legal — it is what "Add category" makes, and it carries
    /// nothing until something is put in it. Domains are lowercased here rather than trusted:
    /// `Spiegel.de` in a hand-edited file would otherwise be an entry that matches no page ever.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        domains = (try container.decodeIfPresent([String].self, forKey: .domains) ?? [])
            .map { $0.lowercased() }
        bundleIDs = try container.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
    }

    /// Every member as a target id — `domain:zdf.de`, `app:com.apple.TV`.
    ///
    /// That is the vocabulary `GroupSettings.categoryExceptions` is written in, so the two
    /// cannot drift: an exception is a target id whether the thing it strikes off is a site or
    /// an app, and it is the same id a hand-picked `Target` would have.
    public var targetIDs: [String] {
        domains.map { Target.id(ofKind: .domain, value: $0) }
            + bundleIDs.map { Target.id(ofKind: .app, value: $0) }
    }

    /// The list entry this target id names, or `nil` when the category does not carry it.
    public func entry(forTargetID targetID: String) -> String? {
        if let domain = domains.first(where: { Target.id(ofKind: .domain, value: $0) == targetID }) {
            return domain
        }
        return bundleIDs.first { Target.id(ofKind: .app, value: $0) == targetID }
    }

    /// A name nothing else in the list answers to, with a counter appended until that is true.
    ///
    /// The same rule `NamedPreset.freeName(basedOn:among:)` follows, and for the same reason: ids
    /// are what everything is keyed by, but two rows reading "Social" in a list whose whole job is
    /// to be ticked from is a list nobody can use.
    public static func freeName(basedOn name: String, among categories: [DistractionCategory]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "New category" : trimmed
        let taken = Set(categories.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
}

extension DistractionCategory {

    /// Every category the app seeds, in the **rounds** it seeded them in.
    ///
    /// A round rather than a flat list because a seed that arrives late has to reach a
    /// `config.json` that already exists — Adult did — and "add the ones whose id is missing"
    /// would put a deleted category back on the next launch. `Config.categorySeed` records how
    /// many rounds a file has been offered, so each round is offered exactly once and a deletion
    /// holds forever after. See `Config.seeding(from:into:)`.
    public static let seedRounds: [[DistractionCategory]] = [firstSix, [adult]]

    /// All of them, flat: what a fresh install starts with, and what the suite checks the shape
    /// and the non-overlap of.
    public static let builtIns: [DistractionCategory] = seedRounds.flatMap { $0 }

    /// What used to be a switch on every group with a hard-coded list behind it.
    ///
    /// **A starting list, not a filter.** Forty of the best-known sites is enough to be worth
    /// having and small enough to be verifiable by reading it; nothing here pretends to be
    /// exhaustive, and no third-party blocklist is downloaded — this app has no network and no
    /// accounts. Anything missing is one entry away, which is the honest shape of the promise.
    ///
    /// Deliberately conservative in the other direction too, for the reason the six below are:
    /// a list that blocks something it should not is discovered when a page the user needed
    /// stopped loading, and by then they no longer trust the blocker. Every entry is an
    /// unambiguous adult site and none is a general-purpose host.
    ///
    /// **Nothing about it is privileged any more.** It was `GroupSettings.adultBlocked` reading
    /// `AdultDomains.rules` at the lowest priority the matcher had — a second mechanism, with its
    /// own switch, its own list and its own rule about precedence, doing what a category does. It
    /// is a category now: rename it, edit it, delete it, tick it per group like any other.
    public static let adult = DistractionCategory(
        id: "adult",
        name: "Adult",
        domains: [
            "pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com", "youporn.com",
            "redtube.com", "tube8.com", "spankbang.com", "eporner.com", "txxx.com",
            "beeg.com", "porntrex.com", "hqporner.com", "porn.com", "sex.com",
            "youjizz.com", "tnaflix.com", "empflix.com", "drtuber.com", "nuvid.com",
            "sunporno.com", "pornhd.com", "porndoe.com", "3movs.com", "gotporn.com",
            "onlyfans.com", "fansly.com", "chaturbate.com", "stripchat.com", "bongacams.com",
            "livejasmin.com", "cam4.com", "myfreecams.com", "camsoda.com", "flirt4free.com",
            "brazzers.com", "realitykings.com", "naughtyamerica.com", "bangbros.com",
            "rule34.xxx", "e-hentai.org", "nhentai.net", "hanime.tv",
        ],
        // None of these is a Mac app, and the browser is where they are read.
        bundleIDs: []
    )

    /// The six a fresh install started with, and what a `config.json` written before categories
    /// were the user's own is seeded with too.
    ///
    /// Readable ids rather than UUIDs, and **the ids a group already holds**: a group written by
    /// an earlier build carries `"categories": ["social"]`, and that word has to keep naming this
    /// list or the group would silently stop blocking anything. The same reasoning as
    /// `NamedPreset.gentleID` and its two neighbours.
    ///
    /// **A bundle id for an app this Mac does not have is harmless.** Apps are matched against
    /// what `AppScanner` actually found, so an id nobody here has installed simply never becomes a
    /// target and never appears in a category's member list. Domains have no such filter and
    /// always apply, which is why a domain has to be certain in a way a bundle id does not.
    ///
    /// **Suffix matching is what keeps the lists short.** A host here covers everything under it —
    /// `zdf.de` is the whole ZDF Mediathek — so a service gets one entry unless it genuinely lives
    /// on two names (`pinterest.com` and `pinterest.de`, `rtlplus.de` and `plus.rtl.de`). The one
    /// place that runs the other way is a subdomain listed on purpose: `meet.google.com` is in
    /// Messaging and `google.com` is in nothing, because a category called Messaging must not take
    /// the search engine with it.
    ///
    /// **No entry appears in two of these**, domain or bundle id. Membership is live — see
    /// `GroupSettings.categories` — so an overlap is a host two groups can both claim, resolved by
    /// whichever group id sorts first. The suite enforces it for the seeded six; a list the user
    /// has edited is theirs, and the resolution stays deterministic either way.
    private static let firstSix: [DistractionCategory] = [
        DistractionCategory(
            id: "social",
            name: "Social",
            domains: [
                "x.com",
                // The old name, which bookmarks and typed addresses still reach X by.
                "twitter.com",
                "instagram.com", "facebook.com", "reddit.com", "linkedin.com",
                "threads.net", "bsky.app", "mastodon.social",
                "pinterest.com", "pinterest.de",
                "tumblr.com", "snapchat.com", "xing.com", "quora.com",
                "9gag.com", "imgur.com",
            ],
            // None of these ship a Mac app: they are browser tabs here, and the frontmost-tab
            // watcher is what blocks them.
            bundleIDs: []
        ),
        DistractionCategory(
            id: "video",
            name: "Video",
            domains: [
                "youtube.com", "netflix.com", "twitch.tv",
                "disneyplus.com", "primevideo.com", "tiktok.com",
                "vimeo.com", "dailymotion.com",
                // Wakanim was folded into Crunchyroll; the old host still resolves, and a
                // bookmark to it is still an evening of anime.
                "crunchyroll.com", "wakanim.tv",
                "ardmediathek.de", "zdf.de", "arte.tv", "joyn.de",
                // RTL+ answers to both: the old product domain and where it actually lives now.
                "rtlplus.de", "plus.rtl.de",
                "mediathekviewweb.de", "sky.de", "wowtv.de",
                "dazn.com", "paramountplus.com",
            ],
            bundleIDs: ["com.apple.TV"]
        ),
        DistractionCategory(
            id: "news",
            name: "News",
            domains: [
                "spiegel.de", "zeit.de", "faz.net", "sueddeutsche.de", "welt.de",
                "tagesschau.de", "n-tv.de", "focus.de", "stern.de", "t-online.de",
                "bild.de", "taz.de", "handelsblatt.com",
                "nytimes.com", "bbc.com", "theguardian.com",
                "heise.de", "golem.de", "news.ycombinator.com",
                "theverge.com", "arstechnica.com", "techcrunch.com",
            ],
            bundleIDs: ["com.apple.news"]
        ),
        DistractionCategory(
            id: "shopping",
            name: "Shopping",
            domains: [
                "amazon.de", "amazon.com", "ebay.de", "ebay.com",
                "zalando.de", "otto.de", "aboutyou.de", "etsy.com",
                "idealo.de", "geizhals.de", "mediamarkt.de", "saturn.de",
                "alternate.de", "notebooksbilliger.de", "thomann.de",
                "aliexpress.com", "temu.com", "shein.com",
                "kleinanzeigen.de", "momox.de",
            ],
            bundleIDs: []
        ),
        DistractionCategory(
            id: "games",
            name: "Games",
            domains: [
                "steampowered.com", "steamcommunity.com",
                "epicgames.com", "gog.com", "itch.io", "humblebundle.com",
                "battle.net", "ea.com", "ubisoft.com",
                "playstation.com", "xbox.com", "nintendo.de",
                "roblox.com", "minecraft.net",
                "chess.com", "lichess.org",
                "miniclip.com", "jetztspielen.de", "spielaffe.de",
            ],
            // Steam is the one that is not on this Mac. It stays because it is the single most
            // likely game launcher on any Mac, and an id nobody has installed costs nothing;
            // everything else here was read off a bundle in `/System/Applications`.
            bundleIDs: ["com.valvesoftware.steam", "com.apple.games", "com.apple.Chess"]
        ),
        DistractionCategory(
            id: "messaging",
            name: "Messaging",
            domains: [
                "web.whatsapp.com", "web.telegram.org",
                "discord.com",
                // Discord's previous domain, still reached by old links and bookmarks.
                "discordapp.com",
                "messenger.com", "slack.com",
                "teams.microsoft.com", "meet.google.com", "chat.google.com",
                "zoom.us", "web.skype.com", "element.io",
            ],
            bundleIDs: [
                "com.tinyspeck.slackmacgap",
                "com.hnc.Discord",
                "net.whatsapp.WhatsApp",
                "ru.keepcoder.Telegram",       // Telegram for macOS
                "com.tdesktop.Telegram",       // Telegram Desktop, the cross-platform build
                "org.whispersystems.signal-desktop",
                "us.zoom.xos",
                "com.apple.MobileSMS",         // Messages
                "com.apple.FaceTime",
            ]
        ),
    ]
}
