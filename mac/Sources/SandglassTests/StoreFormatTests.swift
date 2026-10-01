import Foundation
import SandglassCore

/// What every Sandglass file looks like on disk, pinned in bytes rather than in prose.
///
/// Kept apart from the behaviour tests because these fail for a different reason and want a
/// different answer: a red check here means the format moved, and the question is whether
/// files written by an earlier build can still be read — not whether the store works.
///
/// The other end of that question is `StoreSchemaTests`: what an **older** document, or a
/// hand-edited one, does when this build reads it. The two halves grew up together in this file
/// and were split when it passed the size limit, along the seam its own note already named.
func runStoreFormatTests() {
    testWindowWeekdaysAreSortedAndStable()
    testOnDiskFormatIsFrozen()
    testConfigDocumentIsFrozen()
    testTheSeededCategoriesSurviveASave()
    testStateDocumentIsFrozen()
    testAPresetsThreeAnswersAboutTheWeekAreFrozen()
    testUptimeTwinsSurviveARoundTrip()
}

/// A `Set` iterates in a per-process random order, so an unsorted encoding would rewrite
/// config.json with different bytes on every launch — invisible until someone diffs or
/// syncs the file.
private func testWindowWeekdaysAreSortedAndStable() {
    let ascending = strictWindow(weekdays: [2, 3, 4, 5, 6], from: 540, to: 1020)
    let descending = strictWindow(weekdays: [6, 5, 4, 3, 2], from: 540, to: 1020)
    guard let a = try? SandglassJSON.encoder.encode(ascending),
          let b = try? SandglassJSON.encoder.encode(descending) else {
        failTest("schedule could not be encoded")
        return
    }
    expectEqual(a, b, "two differently built weekday sets encode to the same bytes")
    if let raw = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any] {
        expectEqual(raw["weekdays"] as? [Int] ?? [], [2, 3, 4, 5, 6], "weekdays are written in ascending order")
    } else {
        failTest("schedule json could not be read back")
    }
    guard let back = try? SandglassJSON.decoder.decode(TimeWindow.self, from: a) else {
        failTest("window could not be decoded")
        return
    }
    expectEqual(back, ascending, "weekdays decode back into a set")
}

/// The two encoders, in full. If key order, indentation or the date format ever moves, this
/// is the test that says so — before a released build rewrites files nobody can read back.
private func testOnDiskFormatIsFrozen() {
    // Compact, one line, keys alphabetical, dates ISO-8601 in UTC. This exact shape is what
    // `events.jsonl` is parsed as line by line.
    let event = Event(ts: august(10, 12), kind: EventKind.open, groupID: "grp:yt")
    expectEqualText(
        (try? SandglassJSON.compactEncoder.encode(event)).flatMap { String(data: $0, encoding: .utf8) },
        #"{"groupID":"grp:yt","kind":"open","ts":"2026-08-10T10:00:00Z"}"#,
        "event line format"
    )
    // Pretty-printed, keys alphabetical, weekdays ascending. This is what a user opening
    // config.json in an editor sees. No `preset`: which one-tap shape a window is is read off
    // the values it holds, so storing it was a second copy of a fact and it drifted.
    let window = strictWindow(weekdays: [6, 2, 4, 3, 5], from: 540, to: 1020)
    expectEqualText(encodedText(window), """
        {
          "endMinutes" : 1020,
          "id" : "strictBlock-23456-540-1020",
          "kind" : "strictBlock",
          "startMinutes" : 540,
          "weekdays" : [
            2,
            3,
            4,
            5,
            6
          ]
        }
        """, "document format")
}

/// Dictionary keys are the half of the format that a lost `.sortedKeys` would break
/// quietly. Struct fields would still come out in declaration order, but every group id and
/// every counter key would land wherever this process's hash seed put it — a config.json
/// that differs from the one the same build wrote yesterday, for no reason a user could see.
/// Both documents below carry three-key dictionaries, so the exact bytes pin the order.
///
/// `targets` is an array and keeps the order it was built in; only keys are sorted. That is
/// visible in the golden and is part of what is frozen. `presets` is an array too, and its order
/// is the order they are offered in — the user's, once they have moved one.
private func testConfigDocumentIsFrozen() {
    expectEqualText(encodedText(threeGroupConfig()), """
        {
          "breakWaitSeconds" : 30,
          "categories" : [

          ],
          "categorySeed" : 2,
          "dayStartMinutes" : 180,
          "expiryWarningSeconds" : 60,
          "groupOrder" : [

          ],
          "groupSettings" : {
            "domain:a.example" : {
              "cooldownMinutes" : 0,
              "earnBackEnabled" : false,
              "enabled" : true,
              "escalationSeconds" : 0,
              "pauseSeconds" : 10,
              "presetID" : "gentle"
            },
            "domain:b.example" : {
              "cooldownMinutes" : 0,
              "earnBackEnabled" : false,
              "enabled" : true,
              "escalationSeconds" : 0,
              "pauseSeconds" : 10,
              "presetID" : "gentle"
            },
            "domain:c.example" : {
              "cooldownMinutes" : 0,
              "earnBackEnabled" : false,
              "enabled" : true,
              "escalationSeconds" : 0,
              "pauseSeconds" : 10,
              "presetID" : "gentle"
            }
          },
          "keepAliveSeed" : 0,
          "presets" : [
            {
              "id" : "gentle",
              "name" : "Gentle",
              "settings" : {
                "cooldownMinutes" : 0,
                "earnBackEnabled" : false,
                "enabled" : true,
                "escalationSeconds" : 0,
                "pauseSeconds" : 10,
                "presetID" : "gentle"
              }
            },
            {
              "id" : "standard",
              "name" : "Standard",
              "settings" : {
                "cooldownMinutes" : 10,
                "earnBackEnabled" : true,
                "enabled" : true,
                "escalationSeconds" : 5,
                "opensPerDay" : 5,
                "pauseSeconds" : 10,
                "presetID" : "standard",
                "sessionMinutes" : 5
              }
            },
            {
              "id" : "strict",
              "name" : "Strict",
              "settings" : {
                "cooldownMinutes" : 60,
                "earnBackEnabled" : false,
                "enabled" : true,
                "escalationSeconds" : 15,
                "opensPerDay" : 2,
                "pauseSeconds" : 30,
                "presetID" : "strict",
                "sessionMinutes" : 5
              }
            }
          ],
          "preventTimeChange" : true,
          "settingsLock" : {
            "allowForgot" : true,
            "coversQuickDisable" : false
          },
          "showsMenuBarCountdown" : true,
          "switchedOffTogether" : [

          ],
          "targets" : [
            {
              "displayName" : "C",
              "groupID" : "domain:c.example",
              "id" : "domain:c.example",
              "kind" : "domain",
              "value" : "c.example"
            },
            {
              "displayName" : "A",
              "groupID" : "domain:a.example",
              "id" : "domain:a.example",
              "kind" : "domain",
              "value" : "a.example"
            },
            {
              "displayName" : "B",
              "groupID" : "domain:b.example",
              "id" : "domain:b.example",
              "kind" : "domain",
              "value" : "b.example"
            }
          ],
          "version" : 1
        }
        """, "config document format")
}

/// The seeded categories, written out in full and read back — ids included.
///
/// Left out of the golden above because they are long, and checked here instead because they are
/// load-bearing: a group's membership is an id into this list, so an id that moved in a save is a
/// group that stops blocking. The values are compared whole, which also pins that a category with
/// no apps comes back with no apps rather than with a key nobody wrote.
private func testTheSeededCategoriesSurviveASave() {
    let config = Config(version: 1, targets: [], groupSettings: [:])
    guard let data = try? SandglassJSON.encoder.encode(config),
          let back = try? SandglassJSON.decoder.decode(Config.self, from: data) else {
        failTest("a fresh configuration could not be written and read back")
        return
    }
    expectEqual(back.categories, config.categories, "every category comes back as it went out")
    expectEqual(
        back.categories.map(\.id),
        ["social", "video", "news", "shopping", "games", "messaging", "adult"],
        "under the ids a group written by an earlier build already names"
    )
}

/// The other half of the same rule, for `state.json`.
///
/// Every nil optional is absent rather than null (`focusSessionEndsAt`, `uptimeAnchor`, the two
/// sessions without an end and every uptime twin), and a whole Double is written without a
/// fraction. Both are part of what an old file may look like when a future build reads it.
private func testStateDocumentIsFrozen() {
    expectEqualText(encodedText(threeGroupState()), """
        {
          "cooldownUntil" : {
            "grp:a" : "2026-08-10T12:00:00Z",
            "grp:b" : "2026-08-10T13:00:00Z",
            "grp:c" : "2026-08-10T11:00:00Z"
          },
          "cooldownUntilUptime" : {

          },
          "dayKey" : "2026-08-10",
          "deniedAttempts" : {
            "grp:a" : 3,
            "grp:b" : 2,
            "grp:c" : 1
          },
          "opensAvoided" : 4,
          "opensUsed" : {
            "grp:a" : 2.5,
            "grp:b" : 0.5,
            "grp:c" : 1
          },
          "sessions" : {
            "grp:a" : {
              "groupID" : "grp:a",
              "startedAt" : "2026-08-10T09:00:00Z",
              "warned" : true
            },
            "grp:b" : {
              "groupID" : "grp:b",
              "startedAt" : "2026-08-10T08:00:00Z",
              "warned" : false
            },
            "grp:c" : {
              "endsAt" : "2026-08-10T10:05:00Z",
              "groupID" : "grp:c",
              "startedAt" : "2026-08-10T10:00:00Z",
              "warned" : false
            }
          },
          "streakDays" : 3,
          "usageSecondsToday" : {
            "grp:a" : 900,
            "grp:b" : 60,
            "grp:c" : 15
          },
          "version" : 1
        }
        """, "state document format")
}


/// The three states a preset's week has, pinned as bytes. A document the store cannot read costs
/// the user their whole setup, so each state's shape is frozen rather than assumed.
///
/// The distinction that has to survive a save is `nil` against `[]`: "says nothing about the
/// week" and "clears the week" do opposite things to a group, and one written as the other is a
/// silent edit to every group later put on that preset. No key is the first, an empty array the
/// second. See `NamedPreset.timeWindows`.
private func testAPresetsThreeAnswersAboutTheWeekAreFrozen() {
    let week = [TimeWindow.make(.workDay, kind: .strictBlock, id: "office-hours")]
    let presets = [
        NamedPreset(id: "quiet", name: "Quiet", settings: .gentle),
        NamedPreset(id: "always", name: "Always on", settings: .gentle, timeWindows: []),
        NamedPreset(id: "office", name: "Office", settings: .gentle, timeWindows: week),
    ]
    guard let saved = (try? SandglassJSON.encoder.encode(presets))
        .flatMap({ String(data: $0, encoding: .utf8) }) else {
        failTest("the presets could not be encoded")
        return
    }
    expect(!saved.contains("\"timeWindows\" : null"), "no opinion is no key, never a written null")
    expectEqual(
        saved.components(separatedBy: "\"timeWindows\" :").count - 1, 2,
        "so two of the three write the key, and the one that says nothing does not"
    )

    guard let back = try? SandglassJSON.decoder
        .decode([NamedPreset].self, from: Data(saved.utf8)) else {
        failTest("the presets could not be read back")
        return
    }
    expectNil(back[0].timeWindows, "and all three come back as themselves")
    expect(back[1].timeWindows?.isEmpty == true, "an empty week is an empty week, not a missing one")
    expectEqual(back[2].timeWindows ?? [], week, "and a week comes back whole, ids and all")
}

/// The other half of the same rule, for the fields that arrived with the uptime twins: a state
/// that *has* them has to come back with them, or quitting the app would be a way of turning
/// every wait back into a wall-clock one.
private func testUptimeTwinsSurviveARoundTrip() {
    var state = threeGroupState()
    state.cooldownUntil["grp:a"] = august(10, 14)
    state.cooldownUntilUptime["grp:a"] = 10_600
    state.sessions["grp:c"]?.endsAtUptime = 10_300
    state.emergencyPassEndsAt = august(10, 15)
    state.emergencyPassEndsAtUptime = 13_600
    state.uptimeAnchor = 10_000

    guard let bytes = try? SandglassJSON.encoder.encode(state),
          let back = try? SandglassJSON.decoder.decode(EngineState.self, from: bytes) else {
        failTest("a state with uptime twins could not be round-tripped")
        return
    }
    expectEqual(back.cooldownUntilUptime["grp:a"], 10_600, "a cooldown's twin survives the save")
    expectEqual(back.sessions["grp:c"]?.endsAtUptime, 10_300, "a session's does too")
    expectEqual(back.emergencyPassEndsAtUptime, 13_600, "and the emergency pass's")
    expectEqual(back.uptimeAnchor, 10_000, "with the reading they are all measured from")
    expectEqual(back, state, "and nothing else moved")
}

// MARK: - Fixtures

/// A `config.json` in the shape a V1-era build wrote: one group on a strict schedule, one with

/// Shared with `StoreSchemaTests`, which reads the other half of the same rule: what a build
/// writes and what it can still read are one question asked from two ends.
func encodedText<T: Encodable>(_ value: T) -> String? {
    (try? SandglassJSON.encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
}

/// Written in scrambled order, so ascending output is visibly the encoder's doing and not
/// the literal's.
///
/// `categories: []` rather than the six a real document carries: the golden below is read by
/// people, and a hundred and thirty hosts in the middle of it would hide everything this test
/// exists to pin. That the seeded six are written at all, and read back, is
/// `testTheSeededCategoriesSurviveASave` — and the empty array here is itself part of the format,
/// because an absent key means "seed them".
private func threeGroupConfig() -> Config {
    Config(
        version: 1,
        targets: [
            Target(kind: .domain, value: "c.example", displayName: "C"),
            Target(kind: .domain, value: "a.example", displayName: "A"),
            Target(kind: .domain, value: "b.example", displayName: "B"),
        ],
        groupSettings: [
            "domain:c.example": .gentle,
            "domain:a.example": .gentle,
            "domain:b.example": .gentle,
        ],
        categories: []
    )
}

private func threeGroupState() -> EngineState {
    EngineState(
        version: 1,
        dayKey: "2026-08-10",
        opensUsed: ["grp:c": 1, "grp:a": 2.5, "grp:b": 0.5],
        opensAvoided: 4,
        sessions: [
            "grp:c": ActiveSession(groupID: "grp:c", startedAt: august(10, 12), endsAt: august(10, 12, 5), warned: false),
            "grp:a": ActiveSession(groupID: "grp:a", startedAt: august(10, 11), endsAt: nil, warned: true),
            "grp:b": ActiveSession(groupID: "grp:b", startedAt: august(10, 10), endsAt: nil, warned: false),
        ],
        cooldownUntil: ["grp:c": august(10, 13), "grp:a": august(10, 14), "grp:b": august(10, 15)],
        focusSessionEndsAt: nil,
        protectionPausedUntil: nil,
        streakDays: 3,
        freezeUsedInWeek: nil,
        deniedAttempts: ["grp:c": 1, "grp:b": 2, "grp:a": 3],
        usageSecondsToday: ["grp:c": 15, "grp:a": 900, "grp:b": 60]
    )
}
