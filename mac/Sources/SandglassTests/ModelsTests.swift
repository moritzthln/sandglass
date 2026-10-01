import Foundation
import SandglassCore

func runModelsTests() {
    testTargetIDAndDefaultGroup()
    testTargetExplicitGroupID()
    testTargetLowercasesDomain()
    testTargetDecodeRederivesID()
    testStandardPresetValues()
    testGentlePresetValues()
    testStrictPresetIsStrictInItsKnobs()
    testStandardValuesCanBeDrawnOnAWeek()
    testConfigSettingsLookup()
    testConfigCodableRoundtrip()
    testPresetsAreSeededOnFirstLoad()
    testTheOldPresetEnumMigratesOntoTheSeededThree()
    testRetiredZenKeysAreIgnoredRatherThanRefused()
    testCategoriesSurviveTheDisk()
    testAGroupThatBlocksWithoutTargetsIsNotABlankSlate()
    testDayKeyBoundaryAt3AM()
    testDayKeyExactBoundary()
    testEngineStateInitial()
}

private func testTargetIDAndDefaultGroup() {
    let t = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    expectEqual(t.id, "domain:youtube.com", "target id")
    expectEqual(t.groupID, "domain:youtube.com", "target default groupID")
}

private func testTargetExplicitGroupID() {
    let t = Target(kind: .domain, value: "youtube.com", displayName: "YouTube", groupID: "grp:yt")
    expectEqual(t.id, "domain:youtube.com", "explicit-group target keeps derived id")
    expectEqual(t.groupID, "grp:yt", "explicit groupID wins over default")
}

private func testTargetLowercasesDomain() {
    let domain = Target(kind: .domain, value: "YouTube.com", displayName: "YouTube")
    expectEqual(domain.id, "domain:youtube.com", "domain id is lowercased")
    expectEqual(domain.value, "youtube.com", "domain value is lowercased")
    // Bundle ids are case-sensitive on disk, so they must survive untouched.
    let app = Target(kind: .app, value: "com.google.Chrome", displayName: "Chrome")
    expectEqual(app.value, "com.google.Chrome", "app value keeps its case")
    expectEqual(app.id, "app:com.google.Chrome", "app id keeps its case")
}

private func testTargetDecodeRederivesID() {
    let json = """
    {"id":"domain:reddit.com","kind":"domain","value":"YouTube.com","displayName":"YouTube","groupID":"grp:yt"}
    """
    guard let data = json.data(using: .utf8) else {
        failTest("target json fixture could not be encoded")
        return
    }
    do {
        let t = try JSONDecoder().decode(Target.self, from: data)
        expectEqual(t.id, "domain:youtube.com", "hand-edited id is re-derived on decode")
        expectEqual(t.value, "youtube.com", "decoded domain value is lowercased")
        expectEqual(t.groupID, "grp:yt", "decoded groupID is preserved")
    } catch {
        failTest("target decode threw \(error)")
    }
}

private func testStandardPresetValues() {
    let s = GroupSettings.standard
    expectEqual(s.pauseSeconds, 10, "standard pauseSeconds")
    expectEqual(s.opensPerDay, 5, "standard opensPerDay")
    expectEqual(s.sessionMinutes, 5, "standard sessionMinutes")
    expectEqual(s.cooldownMinutes, 10, "standard cooldownMinutes")
    expectEqual(s.escalationSeconds, 5, "standard escalationSeconds")
    expect(s.earnBackEnabled, "standard earnBackEnabled")
    expect(s.timeWindows.isEmpty, "standard has no time windows")
}

private func testGentlePresetValues() {
    let s = GroupSettings.gentle
    expectEqual(s.presetID, NamedPreset.gentleID, "gentle preset")
    expectEqual(s.pauseSeconds, 10, "gentle pauseSeconds")
    expectNil(s.opensPerDay, "gentle opensPerDay is unlimited")
    expectNil(s.sessionMinutes, "gentle sessionMinutes is no-relock")
    expectEqual(s.cooldownMinutes, 0, "gentle cooldownMinutes")
    expectEqual(s.escalationSeconds, 0, "gentle escalationSeconds")
    expect(!s.earnBackEnabled, "gentle earnBackEnabled is off")
    expect(s.timeWindows.isEmpty, "gentle has no time windows")
}

/// Strict used to be Standard's values plus a Monday–Friday block, which made a week part of
/// what a preset was — and so something picking a preset overwrote. It says the same thing in
/// knobs now, and carries no window at all.
private func testStrictPresetIsStrictInItsKnobs() {
    let s = GroupSettings.strict
    expectEqual(s.presetID, NamedPreset.strictID, "strict preset")
    expect(s.timeWindows.isEmpty, "and it blocks no particular hours: the week is the group's")
    expect(
        s.pauseSeconds > GroupSettings.standard.pauseSeconds, "a longer wait than Standard's"
    )
    expect(
        (s.opensPerDay ?? 0) < (GroupSettings.standard.opensPerDay ?? 0), "fewer opens a day"
    )
    expect(
        s.cooldownMinutes > GroupSettings.standard.cooldownMinutes, "longer between them"
    )
    expect(
        s.escalationSeconds > GroupSettings.standard.escalationSeconds,
        "escalation that bites harder"
    )
    expect(!s.earnBackEnabled, "and no earning any of it back")
}

/// The fixture the engine suite is built on: the ordinary knobs, blocked between set hours. It
/// is Standard, because a window is not what makes a preset.
private func testStandardValuesCanBeDrawnOnAWeek() {
    let window = strictWindow(weekdays: [2, 3, 4, 5, 6], from: 540, to: 1020)
    let s = standardSettings(windows: [window])
    expectEqual(s.presetID, NamedPreset.standardID, "still Standard")
    expectEqual(s.timeWindows, [window], "carrying the window it was built with")
    expectEqual(s.opensPerDay, 5, "and Standard's budget")
}

private func testConfigSettingsLookup() {
    let t = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let config = Config(
        version: 1,
        targets: [t],
        groupSettings: [t.groupID: .standard]
    )
    expectEqual(config.settings(forGroup: t.groupID), .standard, "settings for a known group")
    expectNil(config.settings(forGroup: "grp:unknown"), "settings for an unknown group is nil")
}

private func testConfigCodableRoundtrip() {
    let t = Target(kind: .app, value: "com.tinyspeck.slackmacgap", displayName: "Slack")
    let config = Config(
        version: 1,
        targets: [t],
        groupSettings: [t.groupID: .standard]
    )
    do {
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(Config.self, from: data)
        expectEqual(back, config, "config codable roundtrip")
    } catch {
        failTest("config codable roundtrip threw \(error)")
    }
}

/// A configuration with no presets in it is seeded with the three the old enum used to name, and
/// a user who has deleted every one of them keeps an empty list rather than getting them back on
/// the next launch. The difference is "no key" against "an empty array", which is why the encoder
/// writes the key even when there is nothing in it.
private func testPresetsAreSeededOnFirstLoad() {
    let fresh = Config(version: 1, targets: [], groupSettings: [:])
    expectEqual(fresh.presets.map(\.id), ["gentle", "standard", "strict"], "seeded, in that order")
    expectEqual(fresh.presets.map(\.name), ["Gentle", "Standard", "Strict"], "under those names")
    expect(
        fresh.presets.allSatisfy { $0.settings.timeWindows.isEmpty },
        "and not one of them carries a time window: a preset is friction, a window is a schedule"
    )

    let none = #"{"groupSettings":{},"presets":[],"targets":[],"version":1}"#
    expect(
        (try? SandglassJSON.decoder.decode(Config.self, from: Data(none.utf8)))?.presets.isEmpty
            == true,
        "an empty list stays empty: the three are seeded, not enforced"
    )
    guard let emptied = try? SandglassJSON.encoder.encode(
        Config(version: 1, targets: [], groupSettings: [:], presets: [])
    ) else {
        failTest("a config with no presets could not be encoded")
        return
    }
    expect(
        String(decoding: emptied, as: UTF8.self).contains("\"presets\" : ["),
        "which needs the key written even when it says nothing"
    )
}

/// The migration. Every `config.json` in the world carries the old four-case enum, and the three
/// that were presets have to arrive pointing at the seeded entries that hold exactly their
/// values — `custom` was never a preset at all, so it arrives pointing at nothing.
private func testTheOldPresetEnumMigratesOntoTheSeededThree() {
    func decode(_ preset: String) -> GroupSettings? {
        let document = #"{"cooldownMinutes":10,"earnBackEnabled":true,"escalationSeconds":5,"#
            + #""pauseSeconds":10,"preset":""# + preset + #""}"#
        return try? SandglassJSON.decoder.decode(GroupSettings.self, from: Data(document.utf8))
    }
    expectEqual(decode("gentle")?.presetID, NamedPreset.gentleID, "gentle names the seeded Gentle")
    expectEqual(decode("standard")?.presetID, NamedPreset.standardID, "standard names Standard")
    expectEqual(decode("strict")?.presetID, NamedPreset.strictID, "strict names Strict")
    expectNil(decode("custom")?.presetID, "custom was the name for no preset, and stays that")
    expectNil(decode("nonsense")?.presetID, "and a name this build never had costs one label")

    // The new key wins where a file somehow carries both, and a migrated group is written back
    // in the new shape rather than migrated again on every launch.
    let both = #"{"cooldownMinutes":10,"earnBackEnabled":true,"escalationSeconds":5,"#
        + #""pauseSeconds":10,"preset":"gentle","presetID":"strict"}"#
    expectEqual(
        (try? SandglassJSON.decoder.decode(GroupSettings.self, from: Data(both.utf8)))?.presetID,
        NamedPreset.strictID,
        "the new key wins over an old one left beside it"
    )
    guard let written = try? SandglassJSON.encoder.encode(GroupSettings.standard) else {
        failTest("a standard group could not be encoded")
        return
    }
    let text = String(decoding: written, as: UTF8.self)
    expect(text.contains("\"presetID\" : \"standard\""), "the new key is what a save writes")
    expect(!text.contains("\"preset\" :"), "and the old one is never written again")

    var custom = GroupSettings.standard
    custom.presetID = nil
    expect(
        (try? SandglassJSON.encoder.encode(custom))
            .map { !String(decoding: $0, as: UTF8.self).contains("presetID") } == true,
        "while a Custom group writes no key about it at all"
    )
}

/// The exercises are gone — breathing, retyping a sentence and arithmetic — and a pause screen
/// counts `pauseSeconds` down and does nothing else. What has to survive them is every
/// `config.json` that ever named one: the keys are read past, not refused, or a file written by
/// any earlier build would be quarantined as corrupt and replaced by an empty
/// configuration. See the schema-evolution rule in `SandglassJSON`.
private func testRetiredZenKeysAreIgnoredRatherThanRefused() {
    func decode(_ json: String) -> GroupSettings? {
        let document = #"{"cooldownMinutes":10,"earnBackEnabled":true,"escalationSeconds":5,"#
            + #""pauseSeconds":45,"preset":"standard","# + json + "}"
        return try? SandglassJSON.decoder.decode(GroupSettings.self, from: Data(document.utf8))
    }
    let carriers = [
        #""zenAction":"breathing","breathingSeconds":36"#,
        #""zenAction":"typeSentence""#,
        #""zenAction":"math""#,
        #""zenScreen":{"mode":"intervention","intervention":"breathing","seconds":36}"#,
        #""zenScreen":{"mode":"mindfulPause"},"promptOverride":"why this, now?""#,
        // Half-written, and by hand: the value is not even the right shape.
        #""zenScreen":7,"zenAction":"nonsense""#,
    ]
    for carrier in carriers {
        expectEqual(
            decode(carrier)?.pauseSeconds, 45,
            "a group carrying \(carrier) still loads, and keeps its own countdown"
        )
        expectEqual(
            decode(carrier)?.presetID, NamedPreset.standardID,
            "with everything else about it intact"
        )
    }

    guard let written = try? SandglassJSON.encoder.encode(GroupSettings.standard) else {
        failTest("a standard group could not be encoded")
        return
    }
    let text = String(decoding: written, as: UTF8.self)
    for key in ["zenAction", "breathingSeconds", "zenScreen", "promptOverride"] {
        expect(!text.contains(key), "and a save never writes \(key) again")
    }
}

/// Live categories survive a save, are written as sorted arrays, and are absent from a group
/// that has none.
///
/// The sorting is not cosmetic: a `Set` has no order of its own, so encoding it directly would
/// reshuffle these two arrays on every save and turn every `config.json` diff into noise. And a
/// group written before the field existed has to decode as "in no category" rather than take the
/// whole document down — the schema-evolution rule in `SandglassJSON`.
private func testCategoriesSurviveTheDisk() {
    var settings = GroupSettings.standard
    settings.categories = ["social", "messaging"]
    settings.categoryExceptions = ["domain:xing.com", "app:com.hnc.Discord"]
    do {
        let data = try SandglassJSON.encoder.encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        let back = try SandglassJSON.decoder.decode(GroupSettings.self, from: data)
        expectEqual(back.categories, settings.categories, "the memberships come back")
        expectEqual(back.categoryExceptions, settings.categoryExceptions, "and so do the exceptions")
        let messaging = text.range(of: "\"messaging\"")?.lowerBound
        let social = text.range(of: "\"social\"")?.lowerBound
        expect(
            messaging != nil && social != nil && messaging! < social!,
            "written sorted, so two saves of one group produce one document"
        )

        let plain = try SandglassJSON.encoder.encode(GroupSettings.standard)
        let plainText = String(decoding: plain, as: UTF8.self)
        expect(!plainText.contains("categories"), "a group in no category writes no key about it")
        let plainBack = try SandglassJSON.decoder.decode(GroupSettings.self, from: plain)
        expect(plainBack.categories.isEmpty, "and a document without the key reads as no category")
        expect(plainBack.categoryExceptions.isEmpty, "with no exceptions either")
    } catch {
        failTest("category roundtrip threw \(error)")
    }
}

/// What "run setup" is asked of, for the groups no target can name.
///
/// Setup is only reachable while the configuration blocks nothing, and it writes `targets` and
/// `groupSettings` **whole** — so a group this predicate does not recognise is a group setup
/// deletes on the next launch. Live categories were taught to it when they arrived; advanced
/// rules were not, and they block websites with nothing listed in `targets` at all.
private func testAGroupThatBlocksWithoutTargetsIsNotABlankSlate() {
    func config(_ change: (inout GroupSettings) -> Void) -> Config {
        var settings = GroupSettings.standard
        change(&settings)
        return Config(version: 1, targets: [], groupSettings: ["grp:web": settings])
    }
    expect(
        config { _ in }.blocksNothing,
        "a group made in the sidebar and never filled is a blank slate"
    )
    expect(
        !config { $0.rules = [Rule(pattern: "shorts", matchType: .websiteOrText, action: .block)] }
            .blocksNothing,
        "one advanced rule is a configuration that blocks something"
    )
    expect(!config { $0.categories = ["social"] }.blocksNothing, "as a live category already did")
    // Switched off is not deleted, and setup must not treat it as one either.
    expect(
        !config { $0.categories = ["social"]; $0.enabled = false }.blocksNothing,
        "and a group switched off still holds what the user put in it"
    )
}

private func testDayKeyBoundaryAt3AM() {
    let cal = testCalendar
    guard let feb1_0230 = cal.date(from: DateComponents(year: 2026, month: 2, day: 1, hour: 2, minute: 30)),
          let feb1_0330 = cal.date(from: DateComponents(year: 2026, month: 2, day: 1, hour: 3, minute: 30)) else {
        failTest("day key fixtures could not be built")
        return
    }
    // 02:30 belongs to the previous day, same as 01:30 an hour earlier.
    expectEqual(
        EngineState.dayKey(for: feb1_0230, calendar: cal),
        EngineState.dayKey(for: feb1_0230.addingTimeInterval(-3600), calendar: cal),
        "02:30 and 01:30 share a day key"
    )
    expect(
        EngineState.dayKey(for: feb1_0230, calendar: cal) != EngineState.dayKey(for: feb1_0330, calendar: cal),
        "03:00 starts a new day key"
    )
    expectEqual(EngineState.dayKey(for: feb1_0230, calendar: cal), "2026-01-31", "day key is zero-padded yyyy-MM-dd")
    expectEqual(EngineState.dayKey(for: feb1_0330, calendar: cal), "2026-02-01", "day key after 03:00")
}

/// The last second of the old day and the first of the new one, with no gap between them.
private func testDayKeyExactBoundary() {
    let cal = testCalendar
    guard let lastSecond = cal.date(from: DateComponents(
              year: 2026, month: 2, day: 1, hour: 2, minute: 59, second: 59)),
          let firstSecond = cal.date(from: DateComponents(
              year: 2026, month: 2, day: 1, hour: 3, minute: 0, second: 0)) else {
        failTest("day key boundary fixtures could not be built")
        return
    }
    expectEqual(EngineState.dayKey(for: lastSecond, calendar: cal), "2026-01-31", "02:59:59 is still yesterday")
    expectEqual(EngineState.dayKey(for: firstSecond, calendar: cal), "2026-02-01", "03:00:00 starts today")
}

private func testEngineStateInitial() {
    let cal = testCalendar
    guard let noon = cal.date(from: DateComponents(year: 2026, month: 2, day: 1, hour: 12)) else {
        failTest("engine state fixture could not be built")
        return
    }
    let s = EngineState.initial(now: noon, calendar: cal)
    expectEqual(s.version, 1, "initial version")
    expectEqual(s.dayKey, "2026-02-01", "initial dayKey")
    expect(s.opensUsed.isEmpty, "initial opensUsed is empty")
    expectEqual(s.opensAvoided, 0, "initial opensAvoided")
    expect(s.sessions.isEmpty, "initial sessions is empty")
    expect(s.cooldownUntil.isEmpty, "initial cooldownUntil is empty")
    expectNil(s.focusSessionEndsAt, "initial focusSessionEndsAt")
    expectNil(s.protectionPausedUntil, "initial protectionPausedUntil")
    expectEqual(s.streakDays, 0, "initial streakDays")
    expectNil(s.freezeUsedInWeek, "initial freezeUsedInWeek")
    expect(s.deniedAttempts.isEmpty, "initial deniedAttempts is empty")
}
