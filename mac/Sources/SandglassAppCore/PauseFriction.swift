import Foundation

/// What the Unblock card says when it cannot be used, as a value.
///
/// "Unblock everything" is the one control in the app that turns protection off, so it is the
/// one control that has to behave under pressure: a focus session can start underneath it, and
/// it has to say what happened instead of going quiet. That is two pieces of state — a reason
/// the control is dead right now, and a short-lived note about the last attempt — and they only
/// make sense together.
///
/// A scheduled block used to be the other reason, and the commoner one by far. It is not one any
/// more: a break overrides windows. What is left here is narrower than what the type was built
/// for, and it stays because the one case it still carries needs saying in exactly the two
/// places it always did.
///
/// **The wait in front of a break is not here.** It used to be: a countdown this type began on
/// a button press, advanced a second at a time and dropped when a block made it pointless. The
/// wait is `BreakWaitGate`'s now — measured from the settings window opening rather than from a
/// press, so there is no countdown here to begin, to advance or to interrupt. What is left is
/// the two sentences, and `lengths`.
///
/// Two properties of this type are what the app depends on:
///
/// - **Nothing about a refusal is remembered.** `blockedReason` is re-derived from the blocks
///   that are true this second, every second. An earlier version kept a flag that survived
///   the block that set it, and it could only be cleared by the very button it disabled.
/// - **The note expires.** "Protection couldn't be paused" explains something that just
///   happened; an hour later it would only puzzle whoever reads it.
///
/// It knows nothing about the engine, the clock or a calendar: the caller passes in the block
/// that is true and the time it is asking about. That is what makes every rule here reachable
/// from a test without building an app around it.
public struct PauseFriction: Equatable {

    /// The kind of block that makes the engine refuse a break.
    ///
    /// One case, and it was two: `schedule` said "A scheduled block is active", which was the
    /// answer while a strict window refused a break. A break overrides windows now, so nothing
    /// is left for that case to describe — an enum with an unreachable case is a refusal the
    /// screens must still be written to show.
    ///
    /// The focus session carries text rather than a date because formatting wall-clock time
    /// is `AppState`'s job — one formatter, used for every "until 17:00" in the app.
    public enum Block: Equatable {
        case focusSession(untilText: String)
    }

    /// Why a pause cannot be asked for right now, or `nil` when it can.
    public private(set) var blockedReason: String?
    /// Why the last attempt ended without a pause. A short-lived note, not a state.
    public private(set) var stoppedReason: String?

    /// When the note was written, so it can be retired. Private: outside this type the note
    /// is either on screen or it is not.
    private var noteWrittenAt: Date?

    public init() {}

    /// The break lengths on offer, in minutes.
    ///
    /// A menu rather than one number because a break is not one thing: a minute to answer a
    /// message, ten over coffee and an hour over lunch are all breaks, and taking the longest one
    /// because it was the only one offered is how a break turns into an afternoon. Every length
    /// costs the same wait — `Config.breakWaitSeconds`, anything from nought to ten minutes and
    /// thirty seconds by default — because the friction is about the decision, not its size.
    ///
    /// One menu shows these, the Unblock card's. They are here rather than on it because the value
    /// is what the wait is about and the card is only where it is drawn — the same split every
    /// other rule on these screens follows.
    public static let lengths = [1, 5, 10, 15, 30, 60]

    // MARK: - What the blocks do to it

    /// Publishes the refusal. Called on every recompute with whatever is true at that moment,
    /// `nil` included: that is what retires a refusal the instant its cause ends.
    ///
    /// It takes no time, and did until the wait left: a block that opened during a countdown had
    /// to stop it and say so, which was the one thing here that wrote a note by itself. Nothing
    /// this publishes outlives its cause, so there is nothing left to time.
    public mutating func applyBlock(_ block: Block?) {
        blockedReason = block.map(Self.refusalText)
    }

    // MARK: - The note

    public mutating func note(_ reason: String, at now: Date) {
        stoppedReason = reason
        noteWrittenAt = now
    }

    public mutating func clearNote() {
        stoppedReason = nil
        noteWrittenAt = nil
    }

    /// Retires a note that has been on screen for `lifetime`.
    public mutating func expireNote(at now: Date, lifetime: TimeInterval) {
        guard let writtenAt = noteWrittenAt, now.timeIntervalSince(writtenAt) >= lifetime
        else { return }
        clearNote()
    }

    // MARK: - Copy

    /// Copy for a control that cannot be used right now. Said in both places a refusal is said:
    /// on the dead control, and as the note when one was asked for anyway.
    public static func refusalText(_ block: Block) -> String {
        switch block {
        case .focusSession(let untilText): return "Everything is blocked until \(untilText)"
        }
    }
}
