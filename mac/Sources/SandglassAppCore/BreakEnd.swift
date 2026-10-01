import Foundation

/// When a running break actually ends, and what that makes the button underneath it.
///
/// The Unblock card read `breakEndsAt` and nothing else, so a break taken under an emergency pass
/// said "Nothing is blocked until 12:30" while the pass ran to 13:00 — and its "Block again now"
/// then blocked nothing at all, because ending a break leaves the pass standing. Two ways of being
/// wrong about one fact: naming an end the app does not have, and offering an action it cannot
/// perform.
///
/// So the end is the later of the two. When the pass is what holds it, the line says so: the pass
/// is the thing being spent, and somebody who believes a quarter of an hour is what is running has
/// no idea they have an hour of their week's escape left on the table.
///
/// Here rather than in either view because two screens show it — the settings card and the
/// popover — and a rule written inside a `View` is a rule no test can read.
public struct BreakEnd: Equatable, Sendable {
    /// The moment blocking actually comes back.
    public let endsAt: Date
    /// Whether the emergency pass is what holds it open past the break.
    public let heldByPass: Bool
    /// How many groups are blocked anyway, which is normally none.
    ///
    /// A group may ignore both of the app's unblocks (`GroupSettings.ignoresAppWideUnblocks`), and
    /// a card that says "Nothing is blocked" over one of them is wrong on the screen the user came
    /// to in order to be told what is happening. Carried rather than derived here because this type
    /// has no engine to ask — `AppState` counts the rows it has just projected.
    public let stillBlocked: Int

    public init(breakEndsAt: Date, emergencyPassEndsAt: Date?, stillBlocked: Int = 0) {
        if let pass = emergencyPassEndsAt, pass > breakEndsAt {
            endsAt = pass
            heldByPass = true
        } else {
            endsAt = breakEndsAt
            heldByPass = false
        }
        self.stillBlocked = stillBlocked
    }

    /// The sentence above the button. The same words the headline uses, because they are the same
    /// fact — see `BlockCopy.headline`, which is also where the exception clause is spelled.
    public func line(clockText: (Date) -> String) -> String {
        let until = BlockCopy.stillBlocked(stillBlocked).map {
            "Unblocked until \(clockText(endsAt)) · \($0)"
        } ?? "Nothing is blocked until \(clockText(endsAt))"
        guard heldByPass else { return until }
        return "\(until) — this week's emergency pass, which outlasts your break."
    }

    /// What the button honestly does. Under a pass it ends the break and nothing else; blocking
    /// comes back when the pass does.
    public var buttonTitle: String { heldByPass ? "End the break" : "Block again now" }
}
