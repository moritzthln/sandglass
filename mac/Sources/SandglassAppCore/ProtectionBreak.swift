import SandglassCore
import Foundation

/// One break, from the menu that asks for it to the engine that grants it.
///
/// `PauseFriction` is the two-part state a break is *watched* through — a reason the control is
/// dead, and a short-lived note about the last attempt. What is here is everything around it: how
/// long the break will be, and what to say when the engine refuses it.
///
/// **The wait in front of a break is not here any more.** It used to be thirty hard-coded seconds
/// that started on a button press, with the length chosen before them; it is `BreakWaitGate` now,
/// measured from the settings window opening, and a length is only offered on the far side of it.
/// So what arrives here has already waited, and the only question left is the engine's.
///
/// Split out of `AppState` for the reason `OpenLedger` was: a refusal has to leave a note rather
/// than go quiet, and a break that another feature has just made moot has to drop the note rather
/// than explain something that never happened. Six call sites doing that themselves is six
/// chances for one of them to leave a stale sentence on screen.
///
/// **A struct, and stored on `AppState` as an ordinary property**, which is what keeps the
/// screens' countdown alive: `@Observable` instruments stored properties, so a mutation here is
/// a mutation observers see. Held as a class it would have to be `@ObservationIgnored`, and the
/// popover would stop redrawing the seconds.
///
/// `@MainActor` and `internal` for the reason `EngineReadout` is: the engine is confined to the
/// actor that owns it, and `AppState` is that actor.
@MainActor
struct ProtectionBreak {
    private let engine: RulesEngine
    /// Asked one question only, and only after a refusal: which block it was. See `grant`.
    private let readout: EngineReadout
    /// The app's own clock rather than the engine's, so the note's lifetime is measured on the
    /// same timeline as everything else the loop does.
    private let clock: Clock

    private var friction = PauseFriction()

    /// The break length the card offers first, and what an unspecified request means.
    ///
    /// `nonisolated` because it is read where no actor is: `startBreak` uses it as a default
    /// argument, and those are evaluated at the call site rather than inside the callee.
    nonisolated static let defaultMinutes = 10
    /// How long a refusal stays on screen. It explains something that just happened; an hour
    /// later it would only puzzle whoever reads it.
    private static let noteLifetimeSeconds: TimeInterval = 60

    init(engine: RulesEngine, readout: EngineReadout, clock: Clock) {
        self.engine = engine
        self.readout = readout
        self.clock = clock
    }

    // MARK: - What the screens read

    /// Why a break cannot be asked for right now, or `nil` when it can.
    var blockedReason: String? { friction.blockedReason }
    /// Why the last attempt ended without a break. A short-lived note, not a state.
    var stoppedReason: String? { friction.stoppedReason }

    // MARK: - Asking for one

    /// A length has been chosen. `nil` means protection is off now; anything else is why it is not.
    ///
    /// The last attempt's note is spent first — the user is asking again — and the engine still
    /// has the last word. It is a much shorter word than it was: a strict window used to refuse a
    /// break however long anybody had waited for it, and it does not any more. What is left is a
    /// running "Block everything", and the refusal still has to say which block it was rather
    /// than go unexplained.
    ///
    /// The reason is both left on the card and handed back, because they answer to different
    /// people: the note is for whoever is looking at the card, and the return value is for
    /// whichever caller has to decide what happened.
    @discardableResult
    mutating func start(minutes: Int) -> String? {
        friction.clearNote()
        guard engine.pauseProtection(minutes: minutes) else {
            let reason = readout.pauseBlock.map(PauseFriction.refusalText)
                ?? "Protection couldn't be paused"
            friction.note(reason, at: clock.now)
            return reason
        }
        return nil
    }

    /// Everything about a break the caller is about to make moot — a focus session starting, an
    /// emergency pass being spent. It goes silently: the note would explain a break that never
    /// happened.
    ///
    /// Only the note, now that the wait is `BreakWaitGate`'s: there is nothing here left to call
    /// off, and the wait itself is the settings window's to reset. Kept apart from `clearNote`
    /// because the two are asked for different reasons, and this one may grow again.
    mutating func abandon() {
        friction.clearNote()
    }

    /// The user wants their blocks back before the break is over. Never refused — a passcode here
    /// would be a lock on the way *in* to protection.
    mutating func endEarly() {
        engine.endPauseEarly()
        friction.clearNote()
    }

    // MARK: - What the recompute tells it

    /// Retires a note that has been on screen long enough.
    mutating func expireNote() {
        friction.expireNote(at: clock.now, lifetime: Self.noteLifetimeSeconds)
    }

    /// Publishes the block that is true this second. Called with whatever the projection found,
    /// `nil` included — that is what retires a refusal the instant its cause ends.
    mutating func applyBlock(_ block: PauseFriction.Block?) {
        friction.applyBlock(block)
    }

    /// A refusal from outside the engine — the settings passcode is the only one — said in the
    /// same place every other refusal is said.
    mutating func note(_ reason: String) {
        friction.note(reason, at: clock.now)
    }

    mutating func clearNote() {
        friction.clearNote()
    }
}
