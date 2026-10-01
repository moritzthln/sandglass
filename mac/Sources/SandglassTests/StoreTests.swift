import Foundation
import SandglassCore

func runStoreTests() {
    testDirectoryIsCreated()
    testDefaultDirectoryLocation()
    testConfigRoundtrip()
    testStateRoundtrip()
    testLoadFromEmptyDirectoryIsAbsent()
    testUnreadableFileIsNotAFirstLaunch()
    testCorruptConfigIsQuarantined()
    testCorruptStateIsQuarantined()
    testNewerCorruptionReplacesBadFile()
    testUnquarantinableFileIsLeftAlone()
    testDuplicateTargetIDsRejected()
    testConfigVersionRejected()
    testTamperedTargetIDIsRederived()
    testMalformedDayKeyRejected()
    testStateVersionRejected()
    testSaveRefusesAnInvalidConfig()
    testSaveRefusesAnInvalidState()
    testAppendEventWritesOneLinePerEvent()
    testWeekStartIsMondayAt3AM()
    testWeekStartAcrossDaylightSavingWeeks()
    testWeeklyOpensCountsOnlyThisWeeksOpens()
    testWeeklyOpensIncludesTheBoundarySecond()
    testWeeklyOpensIgnoresEventsWithoutAGroup()
    testWeeklyOpensStopsAtTheFirstOlderEvent()
    testWeeklyOpensStopsAtAnOutOfOrderEvent()
    testWeeklyOpensReportsAnUnreadableLog()
    testSaveLeavesNoTempFile()
    testFailedSaveCleansUpItsTempFile()
}

// MARK: - Harness

private let fm = FileManager.default

/// Every store test runs in its own directory: the store's whole job is what it leaves on
/// disk, so no test may ever see another one's files.
private func withTempStore(_ body: (Store, URL) -> Void) {
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: dir) }
    body(Store(directory: dir), dir)
}

private func configURL(_ dir: URL) -> URL { dir.appendingPathComponent("config.json") }
private func stateURL(_ dir: URL) -> URL { dir.appendingPathComponent("state.json") }
private func eventsURL(_ dir: URL) -> URL { dir.appendingPathComponent("events.jsonl") }

/// Flattens either outcome type to one comparable line, so config and state can share the
/// same expectations and a failure names what actually came back.
private func label<T>(_ outcome: LoadOutcome<T>) -> String {
    switch outcome {
    case .loaded: return "loaded"
    case .absent: return "absent"
    case .quarantined(let reason): return "quarantined: \(reason)"
    case .unreadable: return "unreadable"
    }
}

/// Two groups, one of them on a strict schedule — the schedule is what exercises the
/// hand-written `TimeWindow` coding.
private func sampleConfig() -> Config {
    let app = Target(kind: .app, value: "com.tinyspeck.slackmacgap", displayName: "Slack", groupID: "grp:work")
    let site = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    return Config(
        version: 1,
        targets: [app, site],
        groupSettings: ["grp:work": .standard, site.groupID: standardSettings(windows: [officeHours])]
    )
}

/// The same target twice under two different groups: the second one would be invisible to
/// every lookup in the engine, including the strict-window membership check.
private func duplicateTargetConfig() -> Config {
    Config(
        version: 1,
        targets: [
            Target(kind: .domain, value: "youtube.com", displayName: "YouTube", groupID: "grp:a"),
            Target(kind: .domain, value: "YouTube.com", displayName: "YouTube again", groupID: "grp:b"),
        ],
        groupSettings: ["grp:a": .standard, "grp:b": .gentle]
    )
}

/// Every field populated, including all four optional Dates and a half open — a state that
/// loses anything on the way to disk shows up here rather than in a user's streak.
private func sampleState() -> EngineState {
    EngineState(
        version: 1,
        dayKey: "2026-08-10",
        opensUsed: [youtubeGroup: 2.5, redditGroup: 0.5],
        opensAvoided: 3,
        sessions: [youtubeGroup: ActiveSession(
            groupID: youtubeGroup, startedAt: august(10, 12), endsAt: august(10, 12, 5), warned: true
        )],
        cooldownUntil: [redditGroup: august(10, 13)],
        focusSessionEndsAt: august(10, 14),
        protectionPausedUntil: august(10, 15),
        streakDays: 7,
        freezeUsedInWeek: "2026-W33",
        deniedAttempts: [youtubeGroup: 4]
    )
}

/// A valid document with one field bent out of shape: the shortest route to a file that
/// decodes cleanly but must not be trusted.
private func doctored<T: Encodable>(_ value: T, _ mutate: (inout [String: Any]) -> Void) -> Data? {
    guard let data = try? SandglassJSON.encoder.encode(value),
          var raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    mutate(&raw)
    return try? JSONSerialization.data(withJSONObject: raw)
}

/// Writes `data` into a fresh store directory, loads it, and asserts the store refused it
/// for the stated reason and moved it aside instead of throwing it away.
private func expectRejected(
    _ data: Data?,
    _ name: String,
    fileName: String,
    reason: String,
    outcome: (Store) -> String
) {
    guard let data else { failTest("\(name): fixture could not be built"); return }
    withTempStore { store, dir in
        let file = dir.appendingPathComponent(fileName)
        do { try data.write(to: file) } catch { failTest("\(name): fixture could not be written"); return }
        expectEqual(outcome(store), "quarantined: \(reason)", "\(name) is refused")
        expect(fm.fileExists(atPath: file.path + ".bad"), "\(name) is kept as .bad")
        expect(!fm.fileExists(atPath: file.path), "\(name) original is moved, not copied")
    }
}

private func expectConfigRejected(_ data: Data?, _ name: String, reason: String) {
    expectRejected(data, name, fileName: "config.json", reason: reason) { label($0.loadConfigOutcome()) }
}

private func expectStateRejected(_ data: Data?, _ name: String, reason: String) {
    expectRejected(data, name, fileName: "state.json", reason: reason) { label($0.loadStateOutcome()) }
}

// MARK: - Directory

private func testDirectoryIsCreated() {
    withTempStore { _, dir in
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: dir.path, isDirectory: &isDirectory)
        expect(exists && isDirectory.boolValue, "init creates its directory")
    }
}

private func testDefaultDirectoryLocation() {
    expect(
        Store.defaultDirectory.path.hasSuffix("Application Support/Sandglass"),
        "default directory is ~/Library/Application Support/Sandglass"
    )
}

// MARK: - Roundtrips

private func testConfigRoundtrip() {
    withTempStore { store, _ in
        let config = sampleConfig()
        expectNoThrow("config saves") { try store.saveConfig(config) }
        expectEqual(store.loadConfigOutcome(), .loaded(config), "config survives a roundtrip")
        expectEqual(store.loadConfig(), config, "the convenience accessor returns the same document")
    }
}

private func testStateRoundtrip() {
    withTempStore { store, _ in
        let state = sampleState()
        expectNoThrow("state saves") { try store.saveState(state) }
        guard let back = store.loadState() else {
            failTest("state did not load back")
            return
        }
        expectEqual(back, state, "state survives a roundtrip")
        // Spelled out for the fields a coarse equality check would let silently degrade.
        expectEqual(back.opensUsed[youtubeGroup], 2.5, "half opens survive")
        expectEqual(back.sessions[youtubeGroup]?.endsAt, august(10, 12, 5), "session end date survives")
        expectEqual(back.cooldownUntil[redditGroup], august(10, 13), "cooldown date survives")
        expectEqual(back.focusSessionEndsAt, august(10, 14), "focus session date survives")
        expectEqual(back.protectionPausedUntil, august(10, 15), "protection pause date survives")
        expectEqual(back.deniedAttempts[youtubeGroup], 4, "denied attempts survive")
        expectEqual(back.freezeUsedInWeek, "2026-W33", "week key survives")
    }
}

// MARK: - Absent and corrupt files

/// A missing file is a first launch, not damage. It is also the one outcome that opens the
/// window by itself, so it must never be confused with a file that could not be read.
private func testLoadFromEmptyDirectoryIsAbsent() {
    withTempStore { store, dir in
        expectEqual(label(store.loadConfigOutcome()), "absent", "config in an empty directory")
        expectEqual(label(store.loadStateOutcome()), "absent", "state in an empty directory")
        expectNil(store.loadConfig(), "the convenience accessor still returns nil")
        expect(!fm.fileExists(atPath: configURL(dir).path + ".bad"), "no .bad for an absent config")
        expect(!fm.fileExists(atPath: stateURL(dir).path + ".bad"), "no .bad for an absent state")
    }
}

/// The other side of that line: a file that exists but cannot be read is not a first
/// launch either. A blank slate is `.absent` alone, so confusing the two would greet a
/// long-time user with an empty group list and then write a fresh config over the one it
/// could not read — losing every target and the whole streak to a permissions problem.
private func testUnreadableFileIsNotAFirstLaunch() {
    withTempStore { store, dir in
        do { try Data("{}".utf8).write(to: configURL(dir)) } catch { failTest("fixture write failed"); return }
        setPermissions(0, on: configURL(dir))
        defer { setPermissions(0o600, on: configURL(dir)) }
        expectEqual(label(store.loadConfigOutcome()), "unreadable", "a file that cannot be read is not absent")
        expectNil(store.loadConfig(), "the convenience accessor still returns nil")
        expect(fm.fileExists(atPath: configURL(dir).path), "the file is left in place")
        expect(!fm.fileExists(atPath: configURL(dir).path + ".bad"), "an unreadable file is not quarantined")
    }
}

private func testCorruptConfigIsQuarantined() {
    let garbage = Data("{ this is not json".utf8)
    withTempStore { store, dir in
        do { try garbage.write(to: configURL(dir)) } catch { failTest("corrupt fixture write failed"); return }
        expectEqual(label(store.loadConfigOutcome()), "quarantined: not valid JSON", "corrupt config")
        let bad = URL(fileURLWithPath: configURL(dir).path + ".bad")
        expectEqual(try? Data(contentsOf: bad), garbage, "the .bad copy keeps the original bytes")
        expect(!fm.fileExists(atPath: configURL(dir).path), "the corrupt config is moved away")
    }
}

private func testCorruptStateIsQuarantined() {
    let garbage = Data("\u{0}\u{1}not json at all".utf8)
    withTempStore { store, dir in
        do { try garbage.write(to: stateURL(dir)) } catch { failTest("corrupt fixture write failed"); return }
        expectEqual(label(store.loadStateOutcome()), "quarantined: not valid JSON", "corrupt state")
        let bad = URL(fileURLWithPath: stateURL(dir).path + ".bad")
        expectEqual(try? Data(contentsOf: bad), garbage, "the .bad copy keeps the original bytes")
        expect(!fm.fileExists(atPath: stateURL(dir).path), "the corrupt state is moved away")
    }
}

/// Latest corruption wins. The previous `.bad` is replaced in one move rather than deleted
/// first, so there is no moment where neither copy exists.
private func testNewerCorruptionReplacesBadFile() {
    withTempStore { store, dir in
        let bad = URL(fileURLWithPath: configURL(dir).path + ".bad")
        for text in ["first damage", "second damage"] {
            do { try Data(text.utf8).write(to: configURL(dir)) } catch { failTest("fixture write failed"); return }
            expectEqual(label(store.loadConfigOutcome()), "quarantined: not valid JSON", "corrupt config (\(text))")
        }
        expectEqual(try? Data(contentsOf: bad), Data("second damage".utf8), "newest corruption is the one kept")
    }
}

/// If the damaged file cannot even be moved aside, it stays exactly where it is and the
/// outcome is `.unreadable` — the app then knows not to overwrite it. Quarantine failing is
/// no reason to put the user's only recovery copy at risk.
private func testUnquarantinableFileIsLeftAlone() {
    withTempStore { store, dir in
        do { try Data("{ broken".utf8).write(to: configURL(dir)) } catch { failTest("fixture write failed"); return }
        // Readable, but nothing in it can be renamed.
        setPermissions(0o500, on: dir)
        defer { setPermissions(0o700, on: dir) }
        expectEqual(label(store.loadConfigOutcome()), "unreadable", "a file that cannot be quarantined")
        expect(fm.fileExists(atPath: configURL(dir).path), "the damaged file is left in place")
        expect(!fm.fileExists(atPath: configURL(dir).path + ".bad"), "no half-made .bad file")
    }
}

// MARK: - Validation on load

/// Two targets resolving to the same id would let the second one hide behind the first in
/// every lookup — including the membership check that locks a group during a strict window.
private func testDuplicateTargetIDsRejected() {
    expectConfigRejected(
        try? SandglassJSON.encoder.encode(duplicateTargetConfig()),
        "config with duplicate target ids",
        reason: "duplicate target 'domain:youtube.com'"
    )
}

private func testConfigVersionRejected() {
    expectConfigRejected(
        doctored(sampleConfig()) { $0["version"] = 2 },
        "config from a future version",
        reason: "config version 2, expected 1"
    )
    expectConfigRejected(
        doctored(sampleConfig()) { $0["version"] = 0 },
        "config with version 0",
        reason: "config version 0, expected 1"
    )
}

/// `Target.init(from:)` re-derives the id, so a hand-edited id never reaches the engine and
/// the load succeeds. The store's own id check is the backstop for the day that decode path
/// changes; this test pins the behaviour the engine actually depends on.
private func testTamperedTargetIDIsRederived() {
    let tampered = doctored(sampleConfig()) { raw in
        guard var targets = raw["targets"] as? [[String: Any]], !targets.isEmpty else { return }
        targets[0]["id"] = "app:WRONG"
        raw["targets"] = targets
    }
    guard let tampered else {
        failTest("tampered config fixture could not be built")
        return
    }
    withTempStore { store, dir in
        do { try tampered.write(to: configURL(dir)) } catch { failTest("tampered write failed"); return }
        guard let loaded = store.loadConfig() else {
            failTest("tampered id should be repaired on decode, not rejected")
            return
        }
        let ids = Set(loaded.targets.map(\.id))
        expectEqual(ids, ["app:com.tinyspeck.slackmacgap", "domain:youtube.com"], "ids are re-derived from kind and value")
        expect(!fm.fileExists(atPath: configURL(dir).path + ".bad"), "a repairable id is not quarantined")
    }
}

/// The streak logic parses the day key and compares it against a freshly formatted one, so
/// anything but a real, zero-padded `yyyy-MM-dd` date breaks streak arithmetic quietly.
private func testMalformedDayKeyRejected() {
    let cases = ["not-a-day", "2026-8-10", "2026-13-10", "", "2026-02-30"]
    for key in cases {
        expectStateRejected(
            doctored(sampleState()) { $0["dayKey"] = key },
            "state with day key '\(key)'",
            reason: "day key '\(key)' is not a yyyy-MM-dd date"
        )
    }
}

private func testStateVersionRejected() {
    expectStateRejected(
        doctored(sampleState()) { $0["version"] = 2 },
        "state from a future version",
        reason: "state version 2, expected 1"
    )
}

// MARK: - Validation on save

/// The same rules, applied on the way out. A bug upstream should fail where it happened,
/// not two launches later as a quarantined file the user has to be told about.
private func testSaveRefusesAnInvalidConfig() {
    withTempStore { store, dir in
        var caught: StoreError?
        do { try store.saveConfig(duplicateTargetConfig()) } catch let error as StoreError { caught = error } catch {}
        expectEqual(caught, .invalidDocument(reason: "duplicate target 'domain:youtube.com'"), "invalid config is refused")
        expect(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty, "nothing is written, not even a temp file")
    }
}

private func testSaveRefusesAnInvalidState() {
    withTempStore { store, dir in
        var state = sampleState()
        state.dayKey = "2026-02-30"
        var caught: StoreError?
        do { try store.saveState(state) } catch let error as StoreError { caught = error } catch {}
        expectEqual(caught, .invalidDocument(reason: "day key '2026-02-30' is not a yyyy-MM-dd date"), "invalid state is refused")
        expect(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty, "nothing is written, not even a temp file")
    }
}

// MARK: - Event log

private func testAppendEventWritesOneLinePerEvent() {
    withTempStore { store, dir in
        let first = Event(ts: august(10, 12), kind: EventKind.open, groupID: youtubeGroup)
        let second = Event(ts: august(10, 13), kind: EventKind.dismissal, groupID: nil)
        store.appendEvent(first)
        store.appendEvent(second)
        guard let text = try? String(contentsOf: eventsURL(dir), encoding: .utf8) else {
            failTest("events file was not written")
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        expectEqual(lines.count, 2, "one line per event")
        let decoded = lines.compactMap { line in
            try? SandglassJSON.decoder.decode(Event.self, from: Data(line.utf8))
        }
        expectEqual(decoded.count, 2, "every line parses on its own")
        expectEqual(decoded.first, first, "first event roundtrips")
        expectEqual(decoded.last, second, "second event roundtrips, groupID stays nil")
    }
}

// MARK: - Weekly stats

private func testWeekStartIsMondayAt3AM() {
    expectEqual(Store.weekStart(for: august(10, 12), calendar: testCalendar), august(10, 3), "Monday noon")
    expectEqual(Store.weekStart(for: august(17, 3), calendar: testCalendar), august(17, 3), "Monday 03:00 exactly")
    expectEqual(Store.weekStart(for: august(16, 23, 59), calendar: testCalendar), august(10, 3), "Sunday night")
    // 02:59 on Monday is still the tail of the previous week, exactly as it is still the
    // tail of the previous day for the open budget.
    expectEqual(Store.weekStart(for: august(17, 2, 59), calendar: testCalendar), august(10, 3), "Monday 02:59")
}

/// The two weeks the clock changes in Europe: 2026-03-29 springs forward, 2026-10-25 falls
/// back, and both are Sundays. The Monday the week starts on is a normal 24-hour day either
/// way, so the boundary is 03:00 local in both — which is the whole reason the switch was
/// left on a raw three-hour offset.
private func testWeekStartAcrossDaylightSavingWeeks() {
    let springSunday = localTime(month: 3, day: 29, hour: 12)
    expectEqual(
        Store.weekStart(for: springSunday, calendar: testCalendar),
        localTime(month: 3, day: 23, hour: 3),
        "the spring-forward Sunday belongs to the week that began Monday 03:00"
    )
    let autumnSunday = localTime(month: 10, day: 25, hour: 12)
    expectEqual(
        Store.weekStart(for: autumnSunday, calendar: testCalendar),
        localTime(month: 10, day: 19, hour: 3),
        "the fall-back Sunday belongs to the week that began Monday 03:00"
    )
}

/// Only `open` events, only this week, grouped by group — and a line the store cannot read
/// costs one event, never the rest of the file.
private func testWeeklyOpensCountsOnlyThisWeeksOpens() {
    let now = august(12, 10)                       // Wednesday morning
    withTempStore { store, dir in
        store.appendEvent(Event(ts: august(9, 20), kind: EventKind.open, groupID: youtubeGroup))
        appendRawLine("{ not an event", to: dir)
        store.appendEvent(Event(ts: august(10, 3), kind: EventKind.open, groupID: youtubeGroup))
        store.appendEvent(Event(ts: august(11, 9), kind: EventKind.open, groupID: youtubeGroup))
        store.appendEvent(Event(ts: august(11, 10), kind: EventKind.dismissal, groupID: youtubeGroup))
        store.appendEvent(Event(ts: august(12, 9), kind: EventKind.open, groupID: redditGroup))
        let weekly = store.weeklyOpens(now: now, calendar: testCalendar)
        expectEqual(
            weekly.counts,
            [youtubeGroup: 2, redditGroup: 1],
            "last week's open and the dismissal are left out, the junk line is stepped over"
        )
        expect(weekly.complete, "a log that was read end to end is complete")
    }
    withTempStore { store, _ in
        let weekly = store.weeklyOpens(now: now, calendar: testCalendar)
        expect(weekly.counts.isEmpty && weekly.complete, "no log yet is an honest zero")
    }
}

/// The week starts *at* 03:00, so an open logged in that exact second belongs to the new
/// week. One second earlier belongs to the old one — the same inclusive edge the day budget
/// uses at its own rollover.
private func testWeeklyOpensIncludesTheBoundarySecond() {
    withTempStore { store, _ in
        store.appendEvent(Event(ts: august(10, 3).addingTimeInterval(-1), kind: EventKind.open, groupID: youtubeGroup))
        store.appendEvent(Event(ts: august(10, 3), kind: EventKind.open, groupID: youtubeGroup))
        expectEqual(
            store.weeklyOpens(now: august(12, 10), calendar: testCalendar).counts,
            [youtubeGroup: 1],
            "03:00:00 exactly counts, 02:59:59 does not"
        )
    }
}

/// An open nobody can attribute is not a statistic: it must not be counted, and it must not
/// invent a bucket of its own for the stats screen to render.
private func testWeeklyOpensIgnoresEventsWithoutAGroup() {
    withTempStore { store, _ in
        store.appendEvent(Event(ts: august(11, 9), kind: EventKind.open, groupID: nil))
        store.appendEvent(Event(ts: august(11, 10), kind: EventKind.open, groupID: youtubeGroup))
        expectEqual(
            store.weeklyOpens(now: august(12, 10), calendar: testCalendar).counts,
            [youtubeGroup: 1],
            "an open without a group is neither counted nor bucketed"
        )
    }
}

/// The scan walks the log backwards and stops at the first event from before the boundary,
/// rather than reading a year of history to answer a question about seven days.
private func testWeeklyOpensStopsAtTheFirstOlderEvent() {
    withTempStore { store, _ in
        for hour in [10, 12, 14] {
            store.appendEvent(Event(ts: august(5, hour), kind: EventKind.open, groupID: youtubeGroup))
        }
        store.appendEvent(Event(ts: august(11, 9), kind: EventKind.open, groupID: youtubeGroup))
        store.appendEvent(Event(ts: august(12, 9), kind: EventKind.open, groupID: youtubeGroup))
        expectEqual(
            store.weeklyOpens(now: august(12, 10), calendar: testCalendar).counts,
            [youtubeGroup: 2],
            "the week before the boundary is not counted"
        )
    }
}

/// The stop is a trade-off, and this is its price: one line logged out of order — a clock
/// that jumped backwards mid-week — hides everything written before it. The count comes out
/// low, never high, and nothing the engine decides is read from here.
///
/// Pinned so the cost is visible rather than assumed, and because it is the only place the
/// scan's direction is observable at all. A future scan that tolerates reordering may
/// legitimately change this expectation — it should have to say so.
private func testWeeklyOpensStopsAtAnOutOfOrderEvent() {
    withTempStore { store, _ in
        store.appendEvent(Event(ts: august(11, 9), kind: EventKind.open, groupID: youtubeGroup))
        store.appendEvent(Event(ts: august(5, 9), kind: EventKind.open, groupID: youtubeGroup))
        store.appendEvent(Event(ts: august(11, 11), kind: EventKind.open, groupID: youtubeGroup))
        expectEqual(
            store.weeklyOpens(now: august(12, 10), calendar: testCalendar).counts,
            [youtubeGroup: 1],
            "an out-of-order line ends the scan: what was written before it is not counted"
        )
    }
}

/// A log that exists but cannot be read is not zero opens. Reporting it as zero would tell
/// someone who spent all week on YouTube that they spent none — the one thing a tool built
/// on being trustworthy cannot do.
private func testWeeklyOpensReportsAnUnreadableLog() {
    withTempStore { store, dir in
        store.appendEvent(Event(ts: august(11, 9), kind: EventKind.open, groupID: youtubeGroup))
        setPermissions(0, on: eventsURL(dir))
        defer { setPermissions(0o600, on: eventsURL(dir)) }
        let weekly = store.weeklyOpens(now: august(12, 10), calendar: testCalendar)
        expect(weekly.counts.isEmpty, "an unreadable log yields no counts")
        expect(!weekly.complete, "an unreadable log is reported as incomplete, not as zero opens")
    }
}

private func appendRawLine(_ text: String, to dir: URL) {
    guard let handle = try? FileHandle(forWritingTo: eventsURL(dir)) else {
        failTest("events file missing for raw append")
        return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data((text + "\n").utf8))
}

// MARK: - Atomicity

/// The temp file is an implementation detail of one save; a leftover one means a save died
/// halfway and the next reader could find a half-written document.
private func testSaveLeavesNoTempFile() {
    withTempStore { store, dir in
        var config = sampleConfig()
        for index in 0..<50 {
            config.dayStartMinutes = index
            expectNoThrow("save \(index)") { try store.saveConfig(config) }
        }
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        expect(!names.contains { $0.hasSuffix(".tmp") }, "no temp file is left behind")
        expectEqual(names.count, 1, "50 saves leave exactly one file")
        expectEqual(store.loadConfig(), config, "the last save is the one on disk")
    }
}

/// The other half of the same promise: a save that cannot finish takes its temp file with
/// it. Otherwise the first save to fail would leave a half-written document lying next to a
/// good one for the rest of the app's life.
private func testFailedSaveCleansUpItsTempFile() {
    withTempStore { store, dir in
        // A directory standing where the document belongs: writing and flushing the temp
        // file both succeed, only the rename onto it cannot.
        do {
            try fm.createDirectory(at: configURL(dir), withIntermediateDirectories: true)
        } catch {
            failTest("blocking directory could not be created")
            return
        }
        var caught: StoreError?
        var unexpected: Error?
        do { try store.saveConfig(sampleConfig()) }
        catch let error as StoreError { caught = error }
        catch { unexpected = error }
        expect(caught != nil, "a save that cannot be completed throws StoreError (got \(String(describing: unexpected)))")
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        expect(!names.contains { $0.hasSuffix(".tmp") }, "a failed save leaves no temp file")
    }
}
