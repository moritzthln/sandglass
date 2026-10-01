import Foundation
import SandglassCore

/// What happens to a file an **earlier** build wrote, or a hand-edited one.
///
/// Split off `StoreFormatTests`, which pins what this build writes. The two halves fail for
/// different reasons and want different answers: a red check there means the format moved, and a
/// red check here means an old document stopped loading — which is the more expensive of the two,
/// because `Store` reads a document it cannot decode as corruption, renames it to `.bad` and
/// starts from nothing. Every case below is worth one user's whole configuration.
func runStoreSchemaTests() {
    testV1DocumentsStillDecode()
    testARetiredSettingIsReadPastRatherThanRefused()
    testARetiredGroupSettingIsReadPastRatherThanRefused()
    testAGroupWithNoOpinionAboutTheAppWideUnblocksDecodes()
    testAGroupCarryingTheOldPassOnlyKeyKeepsItsOptOut()
    testAGroupWithNoDatedBlockDecodes()
    testAnUnreadableDatedBlockIsReadPastRatherThanRefused()
    testV1BlockingShapesMigrateToWindows()
    testAWindowStillCarryingItsPresetLabelDecodes()
    testMigratedGroupsAreWrittenBackInTheNewShape()
    testAStoredPresetLosesItsWindowsAndAGroupKeepsItsOwn()
}

/// The schema-evolution rule in `SandglassJSON`, applied to the three fields V1.1 added.
///
/// A `state.json` written by a V1 build has none of them, and a decode failure is not read as
/// "an old file" anywhere in this codebase — `Store` renames the file to `.bad` and starts from
/// nothing, which costs the user their streak. So the old shape has to keep decoding, and the
/// missing fields have to arrive as the empty day rather than as anything else.
private func testV1DocumentsStillDecode() {
    let v1 = """
        {
          "cooldownUntil" : {},
          "dayKey" : "2026-08-10",
          "deniedAttempts" : {},
          "opensAvoided" : 0,
          "opensUsed" : { "grp:a" : 1 },
          "sessions" : {},
          "streakDays" : 3,
          "version" : 1
        }
        """
    guard let state = try? SandglassJSON.decoder.decode(EngineState.self, from: Data(v1.utf8)) else {
        failTest("a state document written by V1 no longer decodes")
        return
    }
    expectEqual(state.streakDays, 3, "a V1 state document still decodes, streak and all")
    expectEqual(state.usageSecondsToday, [:], "usage starts empty rather than failing the decode")
    expectNil(state.emergencyPassUsedInWeek, "and the week's emergency pass is unspent")
    expectNil(state.emergencyPassEndsAt, "with none running")
    expect(state.cooldownUntilUptime.isEmpty, "a file from before the uptime twins carries none")
    expectNil(state.uptimeAnchor, "nor the reading they would be measured from")

    // The same rule for `config.json`: a group written by V1 has no `dailyMinutes` key at all,
    // and none of the three the group editor added either.
    // `promptOverride` rides along: the pause question was taken out in an earlier version, and a group
    // carrying one has to keep decoding rather than cost the user their whole configuration.
    let v1Group = #"{"cooldownMinutes":10,"earnBackEnabled":true,"escalationSeconds":5,"pauseSeconds":10,"preset":"standard","promptOverride":"Is this the thing?"}"#
    guard let settings = try? SandglassJSON.decoder.decode(
        GroupSettings.self, from: Data(v1Group.utf8)
    ) else {
        failTest("a group written by V1 no longer decodes")
        return
    }
    expectNil(settings.dailyMinutes, "a V1 group decodes with no time limit rather than failing")
    expect(settings.enabled, "a group written before the switch existed is switched on")
    expect(settings.timeWindows.isEmpty, "and has no time windows")
    expectNil(settings.name, "and carries no name of its own")
    let withoutPrompt = #"{"cooldownMinutes":10,"earnBackEnabled":true,"escalationSeconds":5,"pauseSeconds":10,"preset":"standard"}"#
    expectEqual(
        settings,
        try? SandglassJSON.decoder.decode(GroupSettings.self, from: Data(withoutPrompt.utf8)),
        "and a question this build no longer asks is read past rather than refused"
    )

    // And the document around them: neither general setting existed when this was written.
    let v1Config = """
        {
          "groupSettings" : {},
          "reflectionPrompt" : "Why are you here?",
          "targets" : [],
          "version" : 1
        }
        """
    guard let config = try? SandglassJSON.decoder.decode(Config.self, from: Data(v1Config.utf8)) else {
        failTest("a config document written by V1 no longer decodes")
        return
    }
    expectEqual(config.dayStartMinutes, 180, "the day still starts at 03:00 by default")
    expect(config.showsMenuBarCountdown, "and the menu bar still counts a session down")
    expectEqual(config.expiryWarningSeconds, 60, "and the relock warning is the minute V1 gave")
    expect(config.preventTimeChange, "a file written before the switch existed gets it switched on")
    expectEqual(
        config.breakWaitSeconds, 30,
        "and the unblock wait is the thirty seconds it was hard-coded to before it was a setting"
    )
    expect(
        config.groupOrder.isEmpty,
        "and a file written before the groups had an order of their own carries none"
    )
    expect(
        config.switchedOffTogether.isEmpty,
        "and one written before the all-at-once switch existed has nothing off from it"
    )

    // "None" is a value, not an absence: a written null has to survive a round trip, or the
    // setting would quietly turn itself back on at the next launch.
    var silent = config
    silent.expiryWarningSeconds = nil
    // Zero is a value here too: a wait of none has to come back as none rather than as the
    // thirty seconds an absent key means.
    silent.breakWaitSeconds = 0
    guard let bytes = try? SandglassJSON.encoder.encode(silent),
          let back = try? SandglassJSON.decoder.decode(Config.self, from: bytes) else {
        failTest("a config with no relock warning could not be round-tripped")
        return
    }
    expectNil(back.expiryWarningSeconds, "no warning stays no warning across a save")
    expectEqual(back.breakWaitSeconds, 0, "and no wait stays no wait")
}

/// Two settings this build no longer has, in a file the last one wrote.
///
/// The cost of getting this wrong is the whole configuration: a document `Store` cannot decode is
/// renamed to `.bad` and the app starts from nothing. `unlockButtonPlacement` sent the pause
/// screen's Open button wandering between five slots. `browserWatchEnabled` switched website
/// blocking off wholesale — and was written by every build up to this one, so it is in the file of
/// anybody upgrading.
private func testARetiredSettingIsReadPastRatherThanRefused() {
    let withRetiredKeys = """
        {
          "browserWatchEnabled" : false,
          "groupSettings" : {},
          "targets" : [],
          "unlockButtonPlacement" : "everyTime",
          "version" : 1
        }
        """
    guard let config = try? SandglassJSON.decoder.decode(
        Config.self, from: Data(withRetiredKeys.utf8)
    ) else {
        failTest("a config carrying the two retired settings no longer decodes")
        return
    }
    expectEqual(config.version, 1, "the rest of the document is read exactly as before")
    guard let bytes = try? SandglassJSON.encoder.encode(config),
          let text = String(data: bytes, encoding: .utf8) else {
        failTest("the decoded config could not be written back")
        return
    }
    expect(
        !text.contains("unlockButtonPlacement"),
        "and the next save drops the unlock-button key rather than carrying a dead setting"
    )
    expect(
        !text.contains("browserWatchEnabled"),
        "and drops the website switch, which a file could otherwise carry as a false forever"
    )
}

/// The same retirement, one level down: a **group** setting this build no longer has.
///
/// `whitelistMode` was written into the group of anybody who ever switched it on, so it is in a
/// real `config.json` right now. The cost of refusing it is the same and worse — a document
/// `Store` cannot decode is renamed to `.bad`, and this one takes the groups with it.
private func testARetiredGroupSettingIsReadPastRatherThanRefused() {
    let withWhitelistMode = """
        {
          "groupSettings" : {
            "grp:deep" : {
              "cooldownMinutes" : 5,
              "earnBackEnabled" : true,
              "enabled" : true,
              "escalationSeconds" : 0,
              "pauseSeconds" : 10,
              "whitelistMode" : true
            }
          },
          "targets" : [],
          "version" : 1
        }
        """
    guard let config = try? SandglassJSON.decoder.decode(
        Config.self, from: Data(withWhitelistMode.utf8)
    ) else {
        failTest("a group carrying the retired whitelist mode no longer decodes")
        return
    }
    guard let settings = config.groupSettings["grp:deep"] else {
        failTest("the group itself was lost with the key")
        return
    }
    expectEqual(settings.pauseSeconds, 10, "the rest of the group is read exactly as before")
    guard let bytes = try? SandglassJSON.encoder.encode(config),
          let text = String(data: bytes, encoding: .utf8) else {
        failTest("the decoded config could not be written back")
        return
    }
    expect(
        !text.contains("whitelistMode"),
        "and the next save drops it rather than carrying a mode nothing reads"
    )
}

/// **Absent means both of the app's ways out reach the group**, which is what every file written
/// before the toggle existed meant and what the default has to be: the pass and the break are the
/// app's safety net, and a net that came back from disk with holes in it nobody cut would be the
/// worst kind of upgrade — a lock the user never chose, discovered on the evening they need it.
///
/// Written back only when it is on, like the three lock keys beside it: `"ignoresAppWideUnblocks" :
/// false` on every group and every preset is a document that got longer without saying more.
private func testAGroupWithNoOpinionAboutTheAppWideUnblocksDecodes() {
    let json = """
        {
          "cooldownMinutes" : 5,
          "earnBackEnabled" : true,
          "enabled" : true,
          "escalationSeconds" : 0,
          "pauseSeconds" : 10
        }
        """
    guard let settings = try? SandglassJSON.decoder.decode(
        GroupSettings.self, from: Data(json.utf8)
    ) else {
        failTest("a group written before the toggle existed still decodes")
        return
    }
    expect(!settings.ignoresAppWideUnblocks, "no key means the pass and the break both reach it")
    expect(
        encodedText(settings)?.contains("ignoresAppWideUnblocks") == false,
        "and saving it again writes no key, because off is what every group has"
    )

    var immune = settings
    immune.ignoresAppWideUnblocks = true
    guard let text = encodedText(immune),
          let back = try? SandglassJSON.decoder.decode(
              GroupSettings.self, from: Data(text.utf8)
          ) else {
        failTest("a group that ignores the unblocks could not be written and read back")
        return
    }
    expect(text.contains("\"ignoresAppWideUnblocks\" : true"), "the key appears once it says something")
    expectEqual(back, immune, "and comes back off disk unchanged")
}

/// The rename, from the only end that can go wrong: a `config.json` already on this Mac.
///
/// `ignoresEmergencyPass` is what the field was called while it held the pass alone, and a user
/// may well have it set on a group. Read as the same answer rather than defaulted away — an opt-out
/// is a deliberate choice about one group, and a build that handed the escape back on the first
/// launch after an upgrade would undo it silently, on exactly the group somebody had thought
/// hardest about.
///
/// The retirement pattern the file already has, one key at a time: read on the way in, never
/// written on the way out, so the next save leaves the document in one spelling rather than two
/// that could drift apart.
private func testAGroupCarryingTheOldPassOnlyKeyKeepsItsOptOut() {
    let json = """
        {
          "cooldownMinutes" : 5,
          "earnBackEnabled" : true,
          "enabled" : true,
          "escalationSeconds" : 0,
          "ignoresEmergencyPass" : true,
          "pauseSeconds" : 10
        }
        """
    guard let settings = try? SandglassJSON.decoder.decode(
        GroupSettings.self, from: Data(json.utf8)
    ) else {
        failTest("a group carrying the old key no longer decodes")
        return
    }
    expect(settings.ignoresAppWideUnblocks, "the opt-out carries over into the field that replaced it")
    expectEqual(settings.pauseSeconds, 10, "with the rest of the group read exactly as before")

    guard let text = encodedText(settings) else {
        failTest("the decoded group could not be written back")
        return
    }
    expect(text.contains("\"ignoresAppWideUnblocks\" : true"), "the next save writes the new spelling")
    expect(
        !text.contains("ignoresEmergencyPass"),
        "and drops the old one rather than leaving two keys to disagree later"
    )

    // The other half of the same key: off is off, and an old file saying so is not read as an
    // opt-out somebody never asked for.
    let reachable = """
        {
          "cooldownMinutes" : 5,
          "earnBackEnabled" : true,
          "enabled" : true,
          "escalationSeconds" : 0,
          "ignoresEmergencyPass" : false,
          "pauseSeconds" : 10
        }
        """
    guard let open = try? SandglassJSON.decoder.decode(
        GroupSettings.self, from: Data(reachable.utf8)
    ) else {
        failTest("a group carrying the old key switched off no longer decodes")
        return
    }
    expect(!open.ignoresAppWideUnblocks, "an old key written off is still off")
    expect(
        encodedText(open)?.contains("ignoresAppWideUnblocks") == false,
        "and writes no key at all, like every group that never opted out"
    )
}

/// **Absent means no dated block**, which is what every file written before the control existed
/// means and what a fresh group gets. Written only where there is one, like the four keys beside
/// it: almost no group carries a dated block, and `"blockedUntilDay" : null` on every group and
/// every preset is a document that got longer without saying more.
private func testAGroupWithNoDatedBlockDecodes() {
    let json = """
        {
          "cooldownMinutes" : 5,
          "earnBackEnabled" : true,
          "enabled" : true,
          "escalationSeconds" : 0,
          "pauseSeconds" : 10
        }
        """
    guard let settings = try? SandglassJSON.decoder.decode(
        GroupSettings.self, from: Data(json.utf8)
    ) else {
        failTest("a group written before the dated block existed still decodes")
        return
    }
    expectNil(settings.blockedUntilDay, "no key means no day to be blocked until")
    expect(
        encodedText(settings)?.contains("blockedUntilDay") == false,
        "and saving it again writes no key"
    )

    var dated = settings
    dated.blockedUntilDay = "2026-08-24"
    guard let text = encodedText(dated),
          let back = try? SandglassJSON.decoder.decode(
              GroupSettings.self, from: Data(text.utf8)
          ) else {
        failTest("a group blocked until a day could not be written and read back")
        return
    }
    expect(
        text.contains("\"blockedUntilDay\" : \"2026-08-24\""),
        "the key appears once it says something"
    )
    expectEqual(back, dated, "and the day comes back off disk unchanged")
}

/// The other half of the same rule, and the sharper one: the stored day is a **string**, every
/// comparison over it is a string comparison, and a `config.json` `Store` cannot decode is renamed
/// to `.bad` — which would cost the user every group they have, over one hand-edited word.
///
/// So anything that is not a day this build can read decodes as no dated block, and the next save
/// drops it. A day written short is re-derived rather than left to sort as its own string:
/// "2026-8-5" falls before "2026-08-24" alphabetically and after it in the calendar.
private func testAnUnreadableDatedBlockIsReadPastRatherThanRefused() {
    let nonsense = #"""
    {"cooldownMinutes":5,"earnBackEnabled":true,"enabled":true,"escalationSeconds":0,\#
    "pauseSeconds":10,"blockedUntilDay":"next Tuesday"}
    """#
    guard let settings = try? SandglassJSON.decoder.decode(
        GroupSettings.self, from: Data(nonsense.utf8)
    ) else {
        failTest("a group carrying an unreadable dated block no longer decodes")
        return
    }
    expectEqual(settings.pauseSeconds, 10, "the rest of the group is read exactly as before")
    expectNil(settings.blockedUntilDay, "and the day nothing can read is read as none")
    expect(
        encodedText(settings)?.contains("blockedUntilDay") == false,
        "the next save drops it rather than carrying a block whose end has no meaning"
    )

    let short = #"""
    {"cooldownMinutes":5,"earnBackEnabled":true,"enabled":true,"escalationSeconds":0,\#
    "pauseSeconds":10,"blockedUntilDay":"2026-8-5"}
    """#
    expectEqual(
        (try? SandglassJSON.decoder.decode(GroupSettings.self, from: Data(short.utf8)))?
            .blockedUntilDay,
        "2026-08-05",
        "and a day written short is re-derived on the way in, where every comparison can see it"
    )
}

/// The whole time-window migration, from a `config.json` a V1-era build actually wrote.
///
/// This is the case that costs the user their entire setup if it regresses: a document `Store`
/// cannot decode is renamed to `.bad` and the app starts from nothing. The two old blocking
/// shapes have to arrive as windows, and the group around them has to survive intact.
private func testV1BlockingShapesMigrateToWindows() {
    guard let config = try? SandglassJSON.decoder.decode(Config.self, from: Data(v1EraConfig.utf8)) else {
        failTest("a V1-era config with a schedule and an always-block no longer decodes")
        return
    }
    expectEqual(config.targets.count, 2, "both targets survive the migration")
    expectEqual(config.groupSettings["grp:social"]?.name, "Social", "the group keeps its name")

    guard let social = config.groupSettings["grp:social"]?.timeWindows.first else {
        failTest("the scheduled group came back with no window")
        return
    }
    expectEqual(social.kind, .strictBlock, "a V1 schedule was always a hard block")
    expectEqual(social.weekdays, [2, 3, 4, 5, 6], "and keeps its weekdays")
    expectEqual(social.startMinutes, 540, "its start")
    expectEqual(social.endMinutes, 1020, "and its end")

    guard let always = config.groupSettings["domain:news.example"]?.timeWindows.first else {
        failTest("the always-blocked group came back with no window")
        return
    }
    expectEqual(always.kind, .strictBlock, "always-block becomes a hard block too")
    expectEqual(always.weekdays, TimeWindow.everyDay, "over all seven days")
    expectEqual(always.startMinutes, 0, "from midnight")
    expectEqual(always.endMinutes, 24 * 60, "to midnight")
    expectEqual(always.livePreset, .allDay, "and reads as the all-day preset it is")
}

/// `TimeWindow.preset` was a field beside the values it described, and it is gone: which one-tap
/// shape a window is is read off the values now (`livePreset`). That is an **on-disk format
/// change**, and every build before it wrote the key.
///
/// So the question is the one every dropped key raises: does a file that still carries it load.
/// `Store` reads a document it cannot decode as corruption and renames it to `.bad`, which would
/// cost the user every group they have over a label nothing reads any more. The stale label is
/// also allowed to disagree with the values — it did, on every window those builds created — and
/// the values are what wins.
private func testAWindowStillCarryingItsPresetLabelDecodes() {
    // Written by a build that stored the label: work-day values under a `custom` label, which is
    // the exact pair `make(.custom, …)` produced.
    let json = #"""
    {"id":"w1","kind":"strictBlock","preset":"custom","weekdays":[2,3,4,5,6],\#
    "startMinutes":540,"endMinutes":1020}
    """#
    guard let window = try? SandglassJSON.decoder.decode(
        TimeWindow.self, from: Data(json.utf8)
    ) else {
        failTest("a window carrying the old preset label no longer decodes at all")
        return
    }
    expectEqual(window.startMinutes, 540, "the window keeps its hours")
    expectEqual(window.weekdays, TimeWindow.workWeek, "and its days")
    expectEqual(
        window.livePreset, .workDay,
        "and reads as the shape its values are, not as the label beside them"
    )
    expect(
        (try? SandglassJSON.encoder.encode(window))
            .map { !String(decoding: $0, as: UTF8.self).contains("preset") } == true,
        "the dead key is not written back, so one save is the end of it"
    )
    // The same key on a whole group, which is the path `Store` actually takes.
    let group = #"""
    {"cooldownMinutes":10,"earnBackEnabled":true,"escalationSeconds":5,"pauseSeconds":10,\#
    "timeWindows":[{"id":"w1","kind":"break","preset":"bedtime","weekdays":[1],\#
    "startMinutes":1320,"endMinutes":480}]}
    """#
    expectEqual(
        (try? SandglassJSON.decoder.decode(GroupSettings.self, from: Data(group.utf8)))?
            .timeWindows.count,
        1,
        "and a group carrying one loads with the window intact"
    )
}

/// Migrating on load is only half of it: the new shape has to be what the next save writes, or
/// every launch would migrate the same file again and a wave-C build reading it would still be
/// looking at V1 keys.
private func testMigratedGroupsAreWrittenBackInTheNewShape() {
    guard let config = try? SandglassJSON.decoder.decode(Config.self, from: Data(v1EraConfig.utf8)),
          let saved = (try? SandglassJSON.encoder.encode(config))
            .flatMap({ String(data: $0, encoding: .utf8) }) else {
        failTest("the migrated config could not be re-encoded")
        return
    }
    expect(!saved.contains("\"schedule\""), "the old schedule key is not written again")
    expect(!saved.contains("\"alwaysBlock\""), "nor the old always-block key")
    expect(saved.contains("\"timeWindows\""), "the new shape is")
    // The same rule for presets: the old enum is read once and written back as an id.
    expect(!saved.contains("\"preset\" : \"strict\""), "the old preset enum is not written again")
    expect(saved.contains("\"presetID\" : \"strict\""), "the id it migrated onto is")
    expect(saved.contains("\"presets\" : ["), "and the list those ids point into came with it")
}

/// The migration that came with "a preset owns the friction knobs, not the week".
///
/// An earlier build seeded Strict with a Monday–Friday 09:00–17:00 block and handed a preset's
/// windows to any group set to it. Both are gone, so a window left on a stored preset is dead
/// weight that would otherwise be written back on every save. The half of this that matters more
/// is the second: the same load must not touch a *group's* windows, because throwing those away
/// is the bug this whole change is about.
private func testAStoredPresetLosesItsWindowsAndAGroupKeepsItsOwn() {
    let stored = """
    {"version":1,"targets":[],"groupSettings":{"domain:youtube.com":{\
    "cooldownMinutes":10,"earnBackEnabled":true,"escalationSeconds":5,"pauseSeconds":10,\
    "presetID":"strict","enabled":true,"timeWindows":[{"id":"bedtime","kind":"strictBlock",\
    "weekdays":[1,2,3,4,5,6,7],"startMinutes":1320,"endMinutes":480}]}},"presets":[\
    {"id":"strict","name":"Strict","settings":{"cooldownMinutes":30,"earnBackEnabled":false,\
    "escalationSeconds":15,"pauseSeconds":30,"enabled":true,"timeWindows":[\
    {"id":"strictBlock-workday","kind":"strictBlock","weekdays":[2,3,4,5,6],\
    "startMinutes":540,"endMinutes":1020}]}}]}
    """
    guard let config = try? SandglassJSON.decoder.decode(Config.self, from: Data(stored.utf8)) else {
        failTest("a config carrying a preset with a window could not be decoded")
        return
    }
    expect(
        config.presets.first?.settings.timeWindows.isEmpty ?? false,
        "the week an old build put on the Strict preset is dropped on the way in"
    )
    expectEqual(config.presets.first?.name, "Strict", "and nothing else about the preset moves")
    expectEqual(
        config.presets.first?.settings.pauseSeconds, 30, "its knobs are what a preset does own"
    )

    guard let group = config.groupSettings["domain:youtube.com"]?.timeWindows else {
        failTest("the group came back without a window list")
        return
    }
    expectEqual(group.count, 1, "the group's own window is left exactly where it was")
    expectEqual(group.first?.id, "bedtime", "id and all")
    expectEqual(group.first?.startMinutes, 1320, "and every field of it")

    // Written back in the migrated shape, or every launch would migrate the same file again.
    guard let saved = (try? SandglassJSON.encoder.encode(config))
        .flatMap({ String(data: $0, encoding: .utf8) }) else {
        failTest("the migrated config could not be re-encoded")
        return
    }
    expect(!saved.contains("strictBlock-workday"), "the preset's window is not written again")
    expect(saved.contains("\"bedtime\""), "while the group's is")

    // And the week it lost does not come back as an *opinion* about one. A preset now has three
    // states — say nothing, clear the group's, replace them — and an upgrade that turned a dead
    // window into either of the last two would start editing weeks nobody asked it to touch.
    expectNil(
        config.presets.first?.timeWindows,
        "a preset written before this field existed says nothing about the week"
    )
}

// MARK: - Fixtures

/// the always-block switch on, and not a `timeWindows` key in sight.
private let v1EraConfig = """
        {
          "dayStartMinutes" : 180,
          "groupSettings" : {
            "domain:news.example" : {
              "alwaysBlock" : true,
              "cooldownMinutes" : 10,
              "earnBackEnabled" : true,
              "escalationSeconds" : 5,
              "pauseSeconds" : 10,
              "preset" : "custom"
            },
            "grp:social" : {
              "cooldownMinutes" : 10,
              "earnBackEnabled" : true,
              "escalationSeconds" : 5,
              "name" : "Social",
              "opensPerDay" : 5,
              "pauseSeconds" : 10,
              "preset" : "strict",
              "schedule" : {
                "endMinutes" : 1020,
                "startMinutes" : 540,
                "weekdays" : [ 2, 3, 4, 5, 6 ]
              },
              "sessionMinutes" : 5
            }
          },
          "reflectionPrompt" : "Why are you here?",
          "showsMenuBarCountdown" : true,
          "targets" : [
            {
              "displayName" : "YouTube",
              "groupID" : "grp:social",
              "id" : "domain:youtube.com",
              "kind" : "domain",
              "value" : "youtube.com"
            },
            {
              "displayName" : "News",
              "groupID" : "domain:news.example",
              "id" : "domain:news.example",
              "kind" : "domain",
              "value" : "news.example"
            }
          ],
          "version" : 1
        }
        """
