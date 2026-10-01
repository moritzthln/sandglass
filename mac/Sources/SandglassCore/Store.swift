import Foundation

/// What a load found on disk.
///
/// The four cases need four different answers from the app, which is why loading does not
/// simply return an optional:
///
/// - `.loaded` — use it.
/// - `.absent` — first launch. This, and only this, is what opens the window by itself.
/// - `.quarantined` — the file was damaged; it has been moved to `<name>.json.bad` and the
///   app starts from defaults. The user should see a degraded status and be told the copy is
///   still there, because their streak is in it.
/// - `.unreadable` — the file is there but could not be read, or could not be moved aside.
///   Starting from defaults is fine; **overwriting is not**. A permissions problem that
///   clears up later should find the user's data where they left it.
public enum LoadOutcome<T> {
    case loaded(T)
    case absent
    case quarantined(reason: String)
    case unreadable

    /// The document, for callers that genuinely do not care why it is missing.
    public var value: T? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

extension LoadOutcome: Equatable where T: Equatable {}

/// Why a document could not be saved.
///
/// Every throw out of `Store` is one of these: a caller should never have to catch a raw
/// Cocoa error to find out that a save failed.
public enum StoreError: Error, Equatable {
    /// The finished temp file could not be moved into place; the payload is `rename(2)`'s
    /// errno. The previous document is still intact when this is thrown.
    case renameFailed(Int32)
    /// The document could not be encoded or the temp file could not be written.
    case writeFailed(underlying: String)
    /// The document itself is not fit to store — the same rules a load applies, applied on
    /// the way out, so a bug upstream cannot write a file the app will refuse to read back.
    case invalidDocument(reason: String)
}

/// Everything Sandglass keeps on disk: `config.json`, `state.json`, `events.jsonl`.
///
/// The store does I/O and nothing else. It decides whether a file may be believed, never
/// what it means — no budgets, no schedules, no streak arithmetic live here. That split is
/// what keeps `RulesEngine` testable without a filesystem and the store testable without a
/// clock.
///
/// **Failures are reported three different ways, on purpose:**
///
/// | Path | On failure |
/// |---|---|
/// | Saving a document | throws `StoreError` — losing a save silently is losing user data |
/// | Loading a document | returns a `LoadOutcome` — "missing" and "damaged" need different answers |
/// | Appending an event | nothing — the log feeds statistics, and no stat is worth failing an open over |
///
/// **Writes are atomic.** Every document is written to a temp file next to its target,
/// flushed, and renamed over it. A reader sees either the old document or the new one; a
/// crash mid-save leaves the old one, and a failed save leaves no temp file behind.
///
/// **Damaged files are kept, never deleted.** A file that will not decode, or that decodes
/// into something the engine must not run on, is renamed to `<name>.json.bad` and left
/// there. If even that move fails, the file stays exactly where it is and the outcome is
/// `.unreadable`: the recovery copy is worth more than a tidy directory.
///
/// Not thread-safe; confine it to one thread or actor (the app confines it to the MainActor).
public final class Store {
    private let directory: URL
    private let fm = FileManager.default

    /// The only schema version V1 accepts. See `SandglassJSON` for how the format may grow.
    private static let supportedVersion = 1

    /// How many log lines one weekly count will walk before giving up on finding the week's
    /// first event. See `weeklyOpens` for why a scan might not stop on its own.
    private static let maxScannedLines = 50_000

    public init(directory: URL) {
        self.directory = directory
        ensureDirectory()
    }

    private var configURL: URL { directory.appendingPathComponent("config.json") }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var eventsURL: URL { directory.appendingPathComponent("events.jsonl") }

    // MARK: - Documents

    /// The stored configuration and what happened while looking for it.
    public func loadConfigOutcome() -> LoadOutcome<Config> {
        load(Config.self, from: configURL, validate: Store.validate(_:))
    }

    /// The stored runtime state and what happened while looking for it.
    public func loadStateOutcome() -> LoadOutcome<EngineState> {
        load(EngineState.self, from: stateURL, validate: Store.validate(_:))
    }

    /// Convenience for callers that only want the document.
    ///
    /// `AppState` must not use this: it cannot tell a first launch from a damaged file, and
    /// those need opposite responses — an open window in one case, a degraded status and an
    /// untouched file in the other. Use `loadConfigOutcome()` there.
    public func loadConfig() -> Config? { loadConfigOutcome().value }

    /// Convenience for callers that only want the document. Same caveat as `loadConfig()`.
    public func loadState() -> EngineState? { loadStateOutcome().value }

    public func saveConfig(_ config: Config) throws {
        try Store.validate(config)
        try write(Store.encode(config), to: configURL)
    }

    public func saveState(_ state: EngineState) throws {
        try Store.validate(state)
        try write(Store.encode(state), to: stateURL)
    }

    private func load<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        validate: (T) throws -> Void
    ) -> LoadOutcome<T> {
        // Absent and unreadable are told apart before anything is read: a fresh install must
        // never be handed a `.bad` file it did not earn, and a file behind a permissions
        // problem must not be treated as damaged.
        guard fm.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        do {
            let value = try SandglassJSON.decoder.decode(type, from: data)
            try validate(value)
            return .loaded(value)
        } catch {
            return quarantined(url, reason: Store.reason(for: error))
        }
    }

    private func quarantined<T>(_ url: URL, reason: String) -> LoadOutcome<T> {
        quarantine(url) ? .quarantined(reason: reason) : .unreadable
    }

    // MARK: - Validation

    /// Whether a config may be stored or handed to the engine.
    ///
    /// Duplicate ids are the security-relevant case. Every lookup in the engine resolves a
    /// target by taking the *first* match, so a second target with the same id is invisible
    /// — including to the check that locks a group's membership during a strict window. A
    /// config with two `domain:youtube.com` entries in different groups would let the hidden
    /// one carry settings nobody can see. That file does not get to run.
    ///
    /// The id check is a backstop. `Target.init(from:)` already re-derives `id` from `kind`
    /// and `value`, so a hand-edited id never reaches here — but the invariant the engine
    /// depends on is "id names the target", and it must hold even if that decode path is
    /// ever changed or replaced.
    private static func validate(_ config: Config) throws {
        guard config.version == supportedVersion else {
            throw StoreError.invalidDocument(reason: "config version \(config.version), expected \(supportedVersion)")
        }
        var seen = Set<String>()
        for target in config.targets {
            guard target.id == "\(target.kind.rawValue):\(target.value)" else {
                throw StoreError.invalidDocument(
                    reason: "target id '\(target.id)' does not name \(target.kind.rawValue) '\(target.value)'"
                )
            }
            guard seen.insert(target.id).inserted else {
                throw StoreError.invalidDocument(reason: "duplicate target '\(target.id)'")
            }
        }
        for groupID in config.groupSettings.keys.sorted() {
            try validateWindows(of: config.groupSettings[groupID], in: groupID)
        }
    }

    /// Whether a group's time windows are ones the engine can act on.
    ///
    /// Times outside the day and weekdays outside the week are nonsense the engine would read
    /// as "never matches", which is a window that silently blocks nothing — the failure this
    /// app must never ship. Duplicate ids matter for a duller reason: the editor keys its rows
    /// by them, so a second window with the same id is one the user cannot reach.
    ///
    /// Groups are walked in sorted order so a file with two problems always names the same one.
    private static func validateWindows(of settings: GroupSettings?, in groupID: String) throws {
        guard let settings else { return }
        var seen = Set<String>()
        for window in settings.timeWindows {
            let day = 0...TimeWindow.minutesInDay
            guard day.contains(window.startMinutes), day.contains(window.endMinutes) else {
                throw StoreError.invalidDocument(
                    reason: "time window in '\(groupID)' runs outside the day"
                )
            }
            guard window.weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw StoreError.invalidDocument(
                    reason: "time window in '\(groupID)' names a day that is not in the week"
                )
            }
            guard seen.insert(window.id).inserted else {
                throw StoreError.invalidDocument(
                    reason: "duplicate time window '\(window.id)' in '\(groupID)'"
                )
            }
        }
    }

    /// Whether a state may be stored or handed to the engine.
    ///
    /// The day key is the one field worth checking: the streak logic parses it and compares
    /// it against a freshly formatted key, so anything but a real, zero-padded `yyyy-MM-dd`
    /// date breaks streak arithmetic quietly — the kind of failure that is only noticed
    /// weeks later, by which time the streak is gone. Better to start today from zero than
    /// to keep counting wrong.
    private static func validate(_ state: EngineState) throws {
        guard state.version == supportedVersion else {
            throw StoreError.invalidDocument(reason: "state version \(state.version), expected \(supportedVersion)")
        }
        guard isValidDayKey(state.dayKey) else {
            throw StoreError.invalidDocument(reason: "day key '\(state.dayKey)' is not a yyyy-MM-dd date")
        }
    }

    /// Zero-padded, and a date that exists: `2026-02-30` has the right shape and is not a day.
    private static func isValidDayKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        var components = DateComponents()
        components.calendar = .sandglassGregorian(in: TimeZone(secondsFromGMT: 0) ?? .current)
        components.year = year
        components.month = month
        components.day = day
        return components.isValidDate
    }

    /// A short, printable reason a document was refused. It ends up in the degraded-status
    /// line the user reads, so it says which field is wrong rather than dumping a decoder's
    /// internals at them.
    private static func reason(for error: Error) -> String {
        if case let StoreError.invalidDocument(reason) = error { return reason }
        guard let decoding = error as? DecodingError else { return "could not be read" }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing field '\(key.stringValue)'\(fieldPath(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type for field\(fieldPath(context))"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not valid JSON" : "damaged value\(fieldPath(context))"
        @unknown default:
            return "could not be decoded"
        }
    }

    private static func fieldPath(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
        return path.isEmpty ? "" : " at \(path.joined(separator: "."))"
    }

    // MARK: - Event log

    /// Appends one event as a single JSON line. Best-effort by design: the log feeds the
    /// stats screen, and a stat that cannot be written is never worth failing an open over.
    public func appendEvent(_ event: Event) {
        guard var line = try? SandglassJSON.compactEncoder.encode(event) else { return }
        line.append(0x0A)
        ensureDirectory()
        if !fm.fileExists(atPath: eventsURL.path) {
            fm.createFile(atPath: eventsURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: eventsURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Opens per group since 03:00 last Monday — the number behind "this week" in the stats.
    ///
    /// `complete` is `false` when there is a log the store could not read. The counts are
    /// then empty, and empty is not the same as zero: a stats screen that shows "0 opens
    /// this week" to someone who spent an hour on YouTube has lied to them, which is exactly
    /// the kind of thing this app is not allowed to do. Show nothing, or show that the
    /// number is unavailable. A log that does not exist yet *is* an honest zero.
    ///
    /// The scan runs from the end of the file and stops at the first event older than the
    /// boundary, since the log is written in order. Two things follow from that. A clock
    /// that jumps backwards can put an out-of-order line in the log and cost this count the
    /// events before it — a slightly low statistic, never a wrong block, because nothing the
    /// engine decides is read from here. And a log whose oldest lines all look recent would
    /// never stop the scan on its own, which is what the line cap is for.
    public func weeklyOpens(
        now: Date = Date(),
        calendar: Calendar,
        dayStartMinutes: Int = EngineState.defaultDayStartMinutes
    ) -> (counts: [String: Int], complete: Bool) {
        guard fm.fileExists(atPath: eventsURL.path) else { return ([:], true) }
        guard let data = try? Data(contentsOf: eventsURL) else { return ([:], false) }
        let start = Store.weekStart(for: now, calendar: calendar, dayStartMinutes: dayStartMinutes)
        var counts: [String: Int] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")).suffix(Store.maxScannedLines).reversed() {
            // An unparseable line costs that line and nothing else — it does not end the
            // scan, or one bad append would hide every event written before it.
            guard let event = try? SandglassJSON.decoder.decode(Event.self, from: line) else { continue }
            guard event.ts >= start else { break }
            guard event.kind == EventKind.open, let groupID = event.groupID else { continue }
            counts[groupID, default: 0] += 1
        }
        return (counts, true)
    }

    /// The day's start time on the Monday of the week `date` falls in, read in the calendar's
    /// time zone.
    ///
    /// Public because it is the boundary the weekly numbers are measured against: a caller
    /// that shows "this week" should be able to name the week it means, and a test should be
    /// able to check the boundary itself rather than infer it from a count.
    ///
    /// Like `EngineState.dayKey`, the offset is applied as raw arithmetic rather than by
    /// calendar arithmetic, and it is the same `Config.dayStartMinutes` — the week has to
    /// start where a day starts. That only drifts if a DST switch falls on a Monday between
    /// midnight and the day's start, and EU and US switches are on Sundays.
    public static func weekStart(
        for date: Date, calendar: Calendar, dayStartMinutes: Int = EngineState.defaultDayStartMinutes
    ) -> Date {
        let offset = TimeInterval(dayStartMinutes * 60)
        let gregorian = Calendar.sandglassGregorian(in: calendar.timeZone)
        let shifted = date.addingTimeInterval(-offset)
        // Calendar.weekday: 1 = Sunday … 7 = Saturday, so Monday is 0 days back and Sunday 6.
        let daysSinceMonday = (gregorian.component(.weekday, from: shifted) + 5) % 7
        // Subtracting days from a Gregorian date has no failure case in practice. If it ever
        // found one, fixed-length days still land on the right Monday in every zone that is
        // not switching that week — a boundary an hour out beats a boundary that silently
        // becomes "today".
        let monday = gregorian.date(byAdding: .day, value: -daysSinceMonday, to: shifted)
            ?? shifted.addingTimeInterval(-Double(daysSinceMonday) * 86_400)
        return gregorian.startOfDay(for: monday).addingTimeInterval(offset)
    }

    // MARK: - Writing

    /// Writes `data` where a reader can only ever see all of it or none of it.
    ///
    /// The temp file lives in the same directory so the rename stays within one filesystem,
    /// which is what makes it atomic. It is removed again on every failure path: a leftover
    /// `.tmp` would be a half-written document sitting next to a good one, and the next
    /// person to look in this directory should not have to work out which is which.
    private func write(_ data: Data, to url: URL) throws {
        ensureDirectory()
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            try flush(tmp)
            guard rename(tmp.path, url.path) == 0 else { throw StoreError.renameFailed(errno) }
        } catch let error as StoreError {
            try? fm.removeItem(at: tmp)
            throw error
        } catch {
            try? fm.removeItem(at: tmp)
            throw StoreError.writeFailed(underlying: error.localizedDescription)
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try SandglassJSON.encoder.encode(value)
        } catch {
            throw StoreError.writeFailed(underlying: error.localizedDescription)
        }
    }

    /// `rename` is atomic against other readers but not against power loss: the directory
    /// entry can reach the disk before the bytes it points at do. One extra syscall per save
    /// buys a state file that is either the old one or the new one after a crash, never a
    /// mix of the two.
    private func flush(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// Moves a file the store refuses to use out of the way, keeping it. Reports whether it
    /// managed to; a caller that hears `false` must leave the file alone.
    ///
    /// An older `.bad` file is replaced rather than deleted first: latest corruption wins,
    /// because it is the one the user just hit, but there is no moment where neither copy
    /// exists. Nothing that still decodes is ever removed.
    private func quarantine(_ url: URL) -> Bool {
        let bad = url.appendingPathExtension("bad")
        do {
            if fm.fileExists(atPath: bad.path) {
                _ = try fm.replaceItemAt(bad, withItemAt: url)
            } else {
                try fm.moveItem(at: url, to: bad)
            }
            return true
        } catch {
            return false
        }
    }

    /// Called before every write as well as at init: a directory that disappears while the
    /// app runs (a cleaner, a synced home folder) should cost one save, not every save from
    /// then on.
    private func ensureDirectory() {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Location

    /// `~/Library/Application Support/Sandglass`. Not sandboxed, so this is the real path in
    /// the user's home folder — they can open it, read it and delete it without the app.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sandglass", isDirectory: true)
    }
}
