import Foundation

/// A bundle of settings with a name on it — what somebody reaches for when they say "block this
/// the way I block everything else".
///
/// It used to be an enum of four: gentle, standard, strict, and `custom` for values that matched
/// none of them. Which meant the three the app shipped with were the only three there could ever
/// be, and that "I want my own" had no answer but moving eight knobs on every group. They are
/// ordinary entries in a list the user owns now — seeded on first load, then renameable, editable
/// and deletable like anything else in it. Nothing anywhere treats the seeded three specially.
///
/// A group holds the **id** it was made from plus its own copy of the values, so deleting a
/// preset costs a group nothing but its label — see `GroupSettings.presetID`, and
/// `ConfigBuilder.presetID(matching:in:)` for what happens when the two disagree.
public struct NamedPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// What a group made from this preset runs.
    ///
    /// The fields a preset has no opinion about — what the group is called, whether it is on, its
    /// rules and its live categories — are carried across from the group rather than taken from
    /// here. See `ConfigBuilder.settings(forPreset:current:)`.
    public var settings: GroupSettings

    /// The week this preset puts on a group, in **three** states:
    ///
    /// - `nil` — no opinion about the week at all; applying it leaves the group's windows alone.
    /// - `[]` — deliberately no windows; applying it clears the group's.
    /// - `[…]` — a week of its own; applying it replaces the group's.
    ///
    /// The first state is what a plain `[TimeWindow]` cannot express, and doing without it is
    /// what caused the bug this field is built around: `ConfigBuilder.settings(forPreset:
    /// current:)` used to hand a preset's windows to the group unconditionally, so picking a
    /// preset silently threw away the week the user had drawn. `nil` is the answer — a preset
    /// that says nothing about the week takes nothing away — and it is what every preset written
    /// before this field existed decodes to, so no `config.json` needs rewriting to be safe.
    ///
    /// **Beside `settings` rather than inside it**, because `GroupSettings.timeWindows` is a
    /// group's own list and has no third state to spare: `[]` there means "this group has no
    /// windows", which is exactly the statement that must stay distinguishable from "this preset
    /// has no opinion". A preset's own `settings.timeWindows` is always empty — see
    /// `Config.presetsWithoutWindows` and `PresetEditorSheet.save`.
    public var timeWindows: [TimeWindow]?

    public init(
        id: String = UUID().uuidString,
        name: String,
        settings: GroupSettings,
        timeWindows: [TimeWindow]? = nil
    ) {
        self.id = id
        self.name = name
        self.settings = settings
        self.timeWindows = timeWindows
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey { case id, name, settings, timeWindows }

    /// Written only when the preset has an opinion, which is what keeps the three states three on
    /// disk: `[]` is an empty array, and "no opinion" is no key at all. Most presets say nothing,
    /// and a `config.json` full of `"timeWindows" : null` would be a document that got longer
    /// without saying more — the rule `GroupSettings.encode(to:)` already follows.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(timeWindows, forKey: .timeWindows)
    }

    /// Hand-written for one field, and through `DecodedTimeWindow` for the reason `GroupSettings`
    /// decodes its own windows that way: a window naming a kind this build has dropped costs the
    /// user that window rather than the whole document. See the schema-evolution rule in
    /// `SandglassJSON`.
    ///
    /// An absent key and a written `null` both mean "no opinion". A hand-edited file may say
    /// either; nothing this build writes says the second.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        settings = try container.decode(GroupSettings.self, forKey: .settings)
        timeWindows = try container.decodeIfPresent([DecodedTimeWindow].self, forKey: .timeWindows)?
            .compactMap(\.window)
    }

    // MARK: - The three that are seeded

    // Readable ids rather than UUIDs, because they are also what a `config.json` written against
    // the old enum is migrated onto: `"preset": "standard"` becomes `"presetID": "standard"`, and
    // a file somebody opens in an editor still says what it means.

    public static let gentleID = "gentle"
    public static let standardID = "standard"
    public static let strictID = "strict"

    /// What a fresh install starts with, and what a `config.json` written before presets were the
    /// user's own is seeded with.
    ///
    /// **None of the three says anything about the week** — `timeWindows` is `nil` on all of
    /// them, so picking one leaves a group's windows exactly where they were. Strict used to
    /// hard-block Monday to Friday, 09:00 to 17:00, and handing that out silently threw away
    /// whatever the user had drawn; strictness is said in knobs here instead. A preset the user
    /// makes may carry a week, deliberately and one answer at a time; see `timeWindows`.
    public static let builtIns: [NamedPreset] = [
        NamedPreset(id: gentleID, name: "Gentle", settings: .gentle),
        NamedPreset(id: standardID, name: "Standard", settings: .standard),
        NamedPreset(id: strictID, name: "Strict", settings: .strict),
    ]

    /// The seeded preset a group written against the old enum meant, or `nil` for `custom` —
    /// which was never a preset at all, only the name for values that matched none.
    ///
    /// A name this build has never heard of also answers `nil`, for the reason every other
    /// unknown value here does: a hand-edited `config.json` costs one label rather than the whole
    /// document. See the schema-evolution rule in `SandglassJSON`.
    public static func id(forLegacyPreset raw: String) -> String? {
        switch raw {
        case "gentle": return gentleID
        case "standard": return standardID
        case "strict": return strictID
        default: return nil
        }
    }

    /// A name nothing else in the list answers to, with a counter appended until that is true.
    ///
    /// Duplicated names are not illegal — ids are what everything is keyed by — but two rows
    /// reading "Standard" in a list whose whole job is to be picked from is a list nobody can
    /// use.
    public static func freeName(basedOn name: String, among presets: [NamedPreset]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "New preset" : trimmed
        let taken = Set(presets.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
}
