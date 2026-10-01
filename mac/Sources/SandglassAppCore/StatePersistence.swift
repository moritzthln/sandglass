import SandglassCore
import Foundation

/// Everything `AppState` keeps on disk, and the rules about when it may be written.
///
/// Split out of `AppState` because none of it is part of the loop: the loop asks what time has
/// made true, and this decides whether the answer is allowed to reach the disk. The two rules
/// worth reading in one place are both refusals —
///
/// - a document that could not be **read** is never **written**. The file may well be intact
///   behind a permissions problem, and saving would replace a user's history (or their
///   settings) with something built on top of nothing. The suspension lasts until the next
///   launch, deliberately: re-reading later and resuming would mean merging a file the app
///   never saw with a session's worth of divergent state, and there is no honest way to do that.
/// - a state that has not changed is not saved. `EngineState` is `Equatable`, so an idle second
///   costs one comparison instead of an fsync, once a second, forever.
///
/// A third rule is a delay rather than a refusal: a second of usage is the one change the 1 Hz
/// loop produces *constantly*, and writing the whole document for it would mean an fsync per
/// second for as long as somebody is looking at a managed app. Those seconds are coalesced —
/// see `saveStateIfChanged(_:now:)` — and `flushState(_:now:)` is what makes the delay safe.
///
/// Every failure leaves a line in `degradedLines` rather than a thrown error: the app keeps
/// blocking either way, and the user has to be told that what they are doing is not being
/// recorded. The lines are the caller's to show — see `AppState.refreshStatus`.
///
/// `@MainActor` for the same reason as `AppState`: `Store` is documented as "not thread-safe;
/// confine it to one thread or actor", and this class is the only thing that touches it.
@MainActor
final class StatePersistence {

    /// A configuration load, as the two facts the caller acts on.
    struct LoadedConfig {
        let config: Config
        /// `true` only for a configuration there is nothing to run on — which is what a launch
        /// opens the main window for. An unreadable file is deliberately *not* one of those —
        /// see `loadConfig`.
        let hasNothingToProtect: Bool
    }

    private let store: Store
    /// The last state written to disk, or `nil` when there is nothing on disk to compare with.
    private var lastSavedState: EngineState?
    /// When that write happened, or `nil` when nothing has been written this launch. What the
    /// usage coalescing measures from.
    private var lastStateSaveAt: Date?
    private var stateSavesSuspended = false
    private var configSavesSuspended = false

    /// Everything the user has to be told about the files, in the order it was discovered.
    private(set) var degradedLines: [String] = []

    private static let stateSavePrefix = "Couldn't save history: "
    private static let configSavePrefix = "Couldn't save settings: "

    /// How long a run of usage-only seconds may go unwritten.
    ///
    /// Fifteen because that is what the browser heartbeat already reports in, so neither half of
    /// usage tracking writes more often than the other. What is at stake if the process dies
    /// without flushing is at most fifteen seconds of one group's daily total — and the flush is
    /// wired into both ways the app goes away, so that is the crash case rather than the quit one.
    private static let usageCoalesceSeconds: TimeInterval = 15

    /// What the app runs on when there is no configuration: nothing is a target, so nothing is
    /// blocked and every screen still has something honest to show.
    static let emptyConfig = Config(version: 1, targets: [], groupSettings: [:])

    init(store: Store) {
        self.store = store
    }

    /// Whether a settings edit may be written at all. `false` means the file on disk could not
    /// be read, and the screens say so before the user has retyped anything.
    var canSaveConfig: Bool { !configSavesSuspended }

    // MARK: - Loading

    /// Both halves of what a launch reads, in the order they have to be read in.
    ///
    /// The configuration first, because where a day starts is in it: a state built against
    /// midnight and then run by an engine that rolls at 05:00 would spend its first launch
    /// believing yesterday is today. One call rather than two, so no caller can get that
    /// ordering wrong — it is a rule about these two files, and this is the type that owns them.
    func load(now: Date, calendar: Calendar) -> (config: LoadedConfig, state: EngineState) {
        let loaded = loadConfig()
        let state = loadState(
            now: now, calendar: calendar, dayStartMinutes: loaded.config.dayStartMinutes
        )
        return (loaded, state)
    }

    /// The stored configuration, or the empty one plus a line saying why.
    func loadConfig() -> LoadedConfig {
        switch store.loadConfigOutcome() {
        case .loaded(let config):
            return LoadedConfig(config: config, hasNothingToProtect: config.blocksNothing)
        case .absent:
            return LoadedConfig(config: Self.emptyConfig, hasNothingToProtect: true)
        case .quarantined:
            // The damaged file is kept as config.json.bad; there is nothing left to run on, so
            // the window opens on an empty list.
            degradedLines.append("Settings file was damaged and set aside")
            return LoadedConfig(config: Self.emptyConfig, hasNothingToProtect: true)
        case .unreadable:
            // `false`, though the configuration this hands back is empty: the file may be
            // perfectly intact behind a permissions problem, and a window inviting somebody to
            // build their groups again over one is the app lying about what it lost. The degraded
            // line above is what they get instead, and no edit can be written until it reads.
            degradedLines.append("Settings file can't be read")
            configSavesSuspended = true
            return LoadedConfig(config: Self.emptyConfig, hasNothingToProtect: false)
        }
    }

    /// The stored state, or a fresh one plus a line saying why.
    func loadState(
        now: Date,
        calendar: Calendar,
        dayStartMinutes: Int = EngineState.defaultDayStartMinutes
    ) -> EngineState {
        let fresh = EngineState.initial(
            now: now, calendar: calendar, dayStartMinutes: dayStartMinutes
        )
        switch store.loadStateOutcome() {
        case .loaded(let state):
            lastSavedState = state
            return state
        case .absent:
            // Nothing on disk yet, so the first save has something to do.
            return fresh
        case .quarantined:
            degradedLines.append("History was damaged and set aside")
            return fresh
        case .unreadable:
            // Saving would turn a permissions problem that clears up later into real data loss
            // — the streak is in that file. Run without persisting until it reads again.
            degradedLines.append("History can't be read; nothing is being saved")
            stateSavesSuspended = true
            return fresh
        }
    }

    // MARK: - Saving

    /// Saves the state if it moved, unless the only thing that moved is today's usage seconds
    /// and the last write was less than fifteen seconds ago.
    ///
    /// Returns `true` when the degraded lines changed, so a status derived from them is refreshed
    /// in the same breath rather than a second later.
    ///
    /// Deferring loses nothing. The caller asks on every tick, so a deferred second is written by
    /// the first tick after the window closes; any change that is *not* just usage — a session
    /// ending, an open spent, the day rolling over — is not deferred at all and carries the
    /// pending seconds to disk with it; and going away flushes. What it buys is an idle-looking
    /// app that writes four times a minute instead of sixty.
    @discardableResult
    func saveStateIfChanged(_ state: EngineState, now: Date) -> Bool {
        guard !stateSavesSuspended, state != lastSavedState else { return false }
        guard !isCoalescing(state, now: now) else { return false }
        return write(state, at: now)
    }

    /// Writes whatever the coalescing is still holding back, whenever it was last written.
    ///
    /// Called when the app is going away — `applicationWillTerminate` and the SIGTERM handler
    /// both reach it through `AppState.stop()`. Without it a normal quit would throw away up to
    /// fifteen seconds of counted time, and the daily limit would drift a little further from
    /// the truth with every quit.
    @discardableResult
    func flushState(_ state: EngineState, now: Date) -> Bool {
        guard !stateSavesSuspended, state != lastSavedState else { return false }
        return write(state, at: now)
    }

    /// Whether this change is one the fifteen-second window is still holding back.
    ///
    /// Both guards are needed. Nothing on disk yet has to be written now — there is no baseline
    /// to defer against — and a clock that jumped backwards must not be able to hold a write for
    /// as long as the jump was, so a negative interval counts as "long enough ago".
    private func isCoalescing(_ state: EngineState, now: Date) -> Bool {
        guard let lastSavedState, let lastStateSaveAt else { return false }
        guard isUsageOnlyChange(from: lastSavedState, to: state) else { return false }
        let elapsed = now.timeIntervalSince(lastStateSaveAt)
        return elapsed >= 0 && elapsed < Self.usageCoalesceSeconds
    }

    /// Whether today's usage seconds are the only field that differs.
    ///
    /// Asked by rebasing rather than by comparing field by field: a field added to `EngineState`
    /// later is covered without anybody remembering to come back here, and getting it wrong in
    /// that direction would mean silently not saving something that matters.
    private func isUsageOnlyChange(from saved: EngineState, to candidate: EngineState) -> Bool {
        var rebased = saved
        rebased.usageSecondsToday = candidate.usageSecondsToday
        return rebased == candidate
    }

    private func write(_ state: EngineState, at now: Date) -> Bool {
        do {
            try store.saveState(state)
            lastSavedState = state
            lastStateSaveAt = now
            return clearDegraded(withPrefix: Self.stateSavePrefix)
        } catch {
            // Never swallowed and never fatal: the app keeps blocking, the user is told, and the
            // next tick tries again because `lastSavedState` was not advanced. `lastStateSaveAt`
            // is not advanced either, so a failed write cannot start a coalescing window.
            return addDegraded(Self.stateSavePrefix + Self.shortReason(error))
        }
    }

    /// Writes the configuration, unless the file it would replace could not be read.
    ///
    /// `nil` means it is on disk. Anything else is why it is not, in the words a screen can show
    /// — the same sentence the degraded line carries, because they are the same fact. Answering
    /// with the reason rather than with "the warning list changed" is what lets the caller put
    /// the configuration back: an engine running a rule no file holds is a rule that disappears
    /// at the next launch, and until then the editor is showing it as saved.
    func saveConfig(_ config: Config) -> String? {
        // The backstop behind the callers' own `canSaveConfig` guard. The degraded line saying
        // so is already on screen from the load, so this one adds none of its own.
        guard !configSavesSuspended else { return "Settings file can't be read" }
        do {
            try store.saveConfig(config)
            clearDegraded(withPrefix: Self.configSavePrefix)
            return nil
        } catch {
            let line = Self.configSavePrefix + Self.shortReason(error)
            addDegraded(line)
            return line
        }
    }

    // MARK: - The event log

    /// Best-effort by design: `Store.appendEvent` cannot fail loudly, because no statistic is
    /// worth failing an open over.
    func appendEvent(_ event: Event) {
        store.appendEvent(event)
    }

    /// Opens per group since 03:00 last Monday, and whether the log could be read at all.
    func weeklyOpens(
        now: Date,
        calendar: Calendar,
        dayStartMinutes: Int = EngineState.defaultDayStartMinutes
    ) -> (counts: [String: Int], complete: Bool) {
        store.weeklyOpens(now: now, calendar: calendar, dayStartMinutes: dayStartMinutes)
    }

    // MARK: - Degraded lines

    @discardableResult
    private func addDegraded(_ line: String) -> Bool {
        guard !degradedLines.contains(line) else { return false }
        degradedLines.append(line)
        return true
    }

    @discardableResult
    private func clearDegraded(withPrefix prefix: String) -> Bool {
        let remaining = degradedLines.filter { !$0.hasPrefix(prefix) }
        guard remaining.count != degradedLines.count else { return false }
        degradedLines = remaining
        return true
    }

    /// A short sentence a user can read, not a decoder's internals.
    private static func shortReason(_ error: Error) -> String {
        let text: String
        switch error {
        case StoreError.renameFailed(let code): text = "could not replace the file (errno \(code))"
        case StoreError.writeFailed(let underlying): text = underlying
        case StoreError.invalidDocument(let reason): text = reason
        default: text = error.localizedDescription
        }
        return text.count <= 80 ? text : text.prefix(79) + "…"
    }
}
