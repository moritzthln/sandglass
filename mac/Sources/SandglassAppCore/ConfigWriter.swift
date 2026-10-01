import SandglassCore
import Foundation

/// The one transaction that puts a configuration into the engine and onto the disk — and takes it
/// back out again when the disk refuses it.
///
/// Split out of `AppState` for the reason `StatePersistence` was: none of it is part of the loop.
/// The loop asks what time has made true and republishes it; this is the two-step write that
/// stands between an edited `Config` and the app running on one, and the rollback that keeps the
/// two halves from disagreeing. What is left in `AppState` is the bookkeeping around it — the
/// published flags, the note the break card carries, and the re-derivation every mutation ends in.
///
/// **A configuration that could not be written is not adopted either.** The engine takes the edit
/// first, because refusing it is its business and it must not be asked to write; but a failed
/// write puts the previous one straight back and throws. The alternative — which this app shipped
/// — is an engine enforcing a rule no file holds: the menu bar says the disk failed, the editor
/// says nothing at all, and the rule is gone at the next launch. An edit that visibly does nothing
/// and says why is the honest version of that.
///
/// It refuses nothing of its own, and neither does the engine any more. The user's own locks — the
/// settings lock, and a group's — are asked before anything reaches here; see
/// `AppState.applyConfigEdit`, which is the gated path and the only one anything in `Sandglass`
/// calls.
///
/// `@MainActor` for the reason `AppState` is: `RulesEngine` and `Store` are both documented as
/// "not thread-safe; confine to one thread or actor", and this touches both.
@MainActor
struct ConfigWriter {
    let engine: RulesEngine
    let persistence: StatePersistence

    /// Whether the disk would take a configuration at all.
    ///
    /// A document that could not be **read** is never **written** — the rule is
    /// `StatePersistence`'s and the reason is written there. Asked before the engine is, so a
    /// suspended file cannot leave the engine running on a configuration no file holds.
    var canSave: Bool { persistence.canSaveConfig }

    /// What a caller says when the file is out of reach. A sentence rather than a thrown error:
    /// nothing was attempted, so there is nothing to roll back.
    static let unsavable = "Settings can't be saved while the settings file can't be read"

    /// The line for anything else that came back. Nothing throws one: the engine takes every
    /// configuration it is given, and a disk that will not is the case above. It stays because a
    /// `catch` with nothing to say would be the one place an edit could fail in silence.
    static let unknownRefusal = "Settings couldn't be changed"

    /// Hands the configuration to the engine and then to the disk.
    ///
    /// Throws `ConfigWriteFailure` when the engine took the edit and the disk would not have it —
    /// the engine is back on the previous configuration by then, with the state that went with
    /// it. That is the only way this fails; the engine refuses no configuration.
    func write(_ newConfig: Config) throws {
        // Both halves of what an edit changes, taken before it is asked for: the engine filters
        // the state to the groups the new configuration knows, so a deleted group would come
        // back from a failed write with its day's budget unspent. See `RulesEngine.revertConfig`.
        let previous = engine.config
        let previousState = engine.state
        engine.updateConfig(newConfig)
        guard let problem = persistence.saveConfig(newConfig) else { return }
        engine.revertConfig(to: previous, restoring: previousState)
        throw ConfigWriteFailure(reason: problem)
    }

    /// Why an edit did not go through, in the words the screen shows.
    ///
    /// A failed write is already a sentence about a disk, and the same one the menu bar is
    /// showing, so it is passed through untouched. It is the only error `write` raises; anything
    /// else is a bug, and it says so rather than passing in silence.
    func refusal(_ error: Error) -> String {
        if let failure = error as? ConfigWriteFailure { return failure.reason }
        return Self.unknownRefusal
    }
}
