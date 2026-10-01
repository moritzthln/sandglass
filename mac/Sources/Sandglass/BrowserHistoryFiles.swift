import SandglassAppCore
import Foundation
import SQLite3

/// The file half of `BrowserHistory`: copying a database out from under a running browser and
/// asking it what has been visited.
///
/// Everything that decides what the user sees is next door and tested. What is here is the part
/// that needs a real Mac — a directory that may not exist, a file macOS may refuse, and a SQLite
/// handle — and it is written so that each of those three has a different, honest answer.
///
/// **The copy is not an optimisation.** A running browser holds its history open, and Chrome in
/// particular keeps an exclusive lock on it; opening the live file gets `SQLITE_BUSY` for as long
/// as the browser is running, which is always. The copy is to a fresh temporary directory, read
/// once and deleted, and the write-ahead log goes with it because Firefox keeps most of a session
/// in there.
///
/// **Nothing here can raise a permission dialogue.** The only path macOS protects is Safari's,
/// which is behind Full Disk Access — a checkbox in System Settings that is never prompted for.
/// A refusal comes back as an error, and that is the honest line the picker shows.
///
/// **Where it is read from.** The target picker in the group editor, every time it opens — which
/// is where the suggestion is worth something, once per group somebody builds rather than once per
/// Mac. It used to be the setup wizard's middle column, seen for thirty seconds and never again.
enum BrowserHistoryFiles {

    /// Every browser this app knows, asked in the order it knows them.
    ///
    /// **Blocking.** Four copies and four queries take tens of milliseconds, which is a visible
    /// stutter on the main thread of a window that is opening; the caller runs it off it.
    static func readAll(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [BrowserHistory.Answer] {
        Browsers.all.compactMap { browser in
            guard let location = BrowserHistory.location(
                forBundleID: browser.bundleID, home: home
            ) else { return nil }
            return BrowserHistory.Answer(browser: browser.name, reading: read(location))
        }
    }

    // MARK: - One browser

    /// What one location yielded, folded from its profiles.
    ///
    /// The folding rule is `BrowserHistory.fold` — which of four per-file outcomes the browser's
    /// single answer is — and it lives next door because it decides what the user is told. What
    /// is left here is asking each file.
    private static func read(_ location: BrowserHistory.Location) -> BrowserHistory.Reading {
        let files: [URL]
        switch databases(in: location) {
        case .missing: return .absent
        case .denied: return .denied(needsFullDiskAccess: location.needsFullDiskAccess)
        case .found(let urls): files = urls
        }
        return BrowserHistory.fold(
            files.map { rows(from: $0, query: location.query) },
            needsFullDiskAccess: location.needsFullDiskAccess
        )
    }

    private enum Databases {
        case found([URL])
        case denied
        case missing
    }

    /// The database files behind a location: the file itself, or one per profile directory.
    ///
    /// Safari's is answered without looking, deliberately. `~/Library/Safari` is refused outright
    /// without Full Disk Access, and a refused `stat` is indistinguishable from a missing file —
    /// so asking first would report "no history" to every user who has not granted it. The copy
    /// below is what tells the two apart, which is what makes the honest line possible.
    private static func databases(in location: BrowserHistory.Location) -> Databases {
        guard let fileName = location.fileName else { return .found([location.root]) }
        let manager = FileManager.default
        do {
            let profiles = try manager.contentsOfDirectory(
                at: location.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            let files = profiles
                .map { $0.appendingPathComponent(fileName) }
                .filter { manager.fileExists(atPath: $0.path) }
            return files.isEmpty ? .missing : .found(files)
        } catch {
            return isPermission(error) ? .denied : .missing
        }
    }

    /// One database file, as the outcome the fold above is written against.
    ///
    /// Safari's path is never `stat`ed before it is copied — see `databases(in:)` — so this is
    /// the only place that can tell "no Full Disk Access" from "Safari has never been opened",
    /// and the three answers to a failed copy are exactly those two plus everything else.
    private static func rows(from database: URL, query: String) -> BrowserHistory.FileReading {
        let copied: URL
        do {
            copied = try copy(database)
        } catch {
            if isPermission(error) { return .denied }
            return isMissing(error) ? .missing : .unusable
        }
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        guard let visits = select(query, from: copied) else { return .unusable }
        return .visits(visits)
    }

    // MARK: - Copying

    /// The database, and its write-ahead log, in a directory of their own.
    ///
    /// The directory is taken away again when the copy fails, which is not a rare path: Safari
    /// without Full Disk Access throws every time, and a leak here would leave an empty
    /// `sandglass-history-<uuid>` behind on every open of setup, for ever.
    private static func copy(_ database: URL) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("sandglass-history-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(database.lastPathComponent)
        do {
            try manager.copyItem(at: database, to: destination)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        // Best effort: a database with no `-wal` beside it is one that has been checkpointed,
        // and a copy without it is simply a little behind.
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: database.path + suffix)
            guard manager.fileExists(atPath: side.path) else { continue }
            try? manager.copyItem(at: side, to: URL(fileURLWithPath: destination.path + suffix))
        }
        return destination
    }

    /// Whether an error is macOS saying no, rather than the file not being there.
    private static func isPermission(_ error: Error) -> Bool {
        matches(
            error,
            cocoa: [NSFileReadNoPermissionError, NSFileWriteNoPermissionError],
            posix: [EPERM, EACCES]
        )
    }

    /// Whether an error is the file not being there, rather than macOS saying no.
    private static func isMissing(_ error: Error) -> Bool {
        matches(error, cocoa: [NSFileNoSuchFileError, NSFileReadNoSuchFileError], posix: [ENOENT])
    }

    /// Whether an error — or anything it wraps — is one of these.
    ///
    /// Both domains, because Foundation reports a refused `open` as a Cocoa error and a refused
    /// directory listing sometimes as the POSIX one it wrapped. Wrapped errors are followed for
    /// the same reason: `copyItem` reports the underlying `open` inside a `NSFileWriteUnknown`.
    private static func matches(_ error: Error, cocoa: Set<Int>, posix: Set<Int32>) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, cocoa.contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, posix.contains(where: { Int($0) == error.code }) {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return matches(underlying, cocoa: cocoa, posix: posix)
    }

    // MARK: - Reading

    /// The rows, or `nil` when the copy would not open or the schema is not the one expected.
    ///
    /// **Opened for writing, deliberately** — of a copy this function's caller deletes seconds
    /// later, so nothing a browser owns is ever touched. Read-only is what a reader wants and is
    /// the wrong flag here: a database with a write-ahead log beside it has to *recover* that log
    /// before it can be read, and recovery is a write. `SQLITE_OPEN_READONLY` fails with
    /// `SQLITE_READONLY_RECOVERY` on exactly the databases most worth reading — Firefox keeps
    /// most of a session in its WAL — and a browser would drop out of the list with no line
    /// saying why.
    private static func select(_ query: String, from database: URL) -> [BrowserHistory.Visit]? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var visits: [BrowserHistory.Visit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = sqlite3_column_text(statement, 0) else { continue }
            visits.append(BrowserHistory.Visit(
                url: String(cString: url), count: Int(sqlite3_column_int(statement, 1))
            ))
        }
        return visits
    }
}

/// The browsers' answers, read once per launch.
///
/// The picker opens as often as somebody adds something to a group, and four database copies and
/// four queries each time is work nobody asked for — the same trade `AppScanner` makes, with the
/// same staleness: a site visited since Sandglass started counts from the next launch. What is
/// cached is the raw answers rather than the ranking, because the ranking depends on what the
/// configuration already blocks and that changes while the app runs.
///
/// `@MainActor` because the cache is mutable and every caller is a window. The read itself is
/// detached; two pickers opening at once would read twice, which costs a copy nobody notices.
@MainActor
enum BrowserHistoryCache {
    private static var answers: [BrowserHistory.Answer]?

    static func read() async -> [BrowserHistory.Answer] {
        if let answers { return answers }
        let fresh = await Task.detached { BrowserHistoryFiles.readAll() }.value
        answers = fresh
        return fresh
    }
}
