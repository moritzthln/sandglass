/// What the loop compares from one second to the next to decide whether the front app has to be
/// decided again.
///
/// The blocked set alone used to be the whole comparison, and it misses the edge that matters
/// most after a block: the engine *ending* a stand-down. A break, an emergency pass and a group's
/// break window all run out by themselves, and the group they were holding open lands on its
/// countdown screen — which is not a block, so the blocked set does not move, no engine effect
/// announces it, and the app in front stayed fully usable until the user switched away and back.
///
/// So the groups the engine is standing down over are compared too. It is the coarse half of the
/// decision on purpose: comparing whole decisions would move every second — a session's
/// remaining seconds are part of one — and a 1 Hz loop must not ask `NSWorkspace` about the front
/// app all day. Both sets change only at an edge.
struct BlockEdge: Equatable {
    /// The groups that are hard-blocked — the set the blocker has always been told about.
    var blocked: Set<String>
    /// The groups the engine stands down over this instant: a break window over the group, or a
    /// break or an emergency pass over the whole app. `BudgetRow.isOpen`, collected.
    var standingDown: Set<String>

    static let none = BlockEdge(blocked: [], standingDown: [])

    init(blocked: Set<String>, standingDown: Set<String>) {
        self.blocked = blocked
        self.standingDown = standingDown
    }

    init(blocked: Set<String>, rows: [BudgetRow]) {
        self.init(blocked: blocked, standingDown: Set(rows.filter(\.isOpen).map(\.id)))
    }
}
