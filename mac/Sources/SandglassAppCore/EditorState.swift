import SandglassCore
import Foundation

/// Where one group stands right now, in the four words that fit beside its switch.
///
/// The group editor's state pill. Here rather than in the view for the reason `EditorFreeze` is:
/// it is wording plus the rule for which words apply, and a sentence written inside a `View` is a
/// sentence no test can read.
///
/// It decides nothing. The line itself is the engine's — `BudgetRow.line` is either a budget or
/// the block that is over it — and all this picks is *which* fact belongs beside a switch.
public enum EditorState {

    /// How the pill reads at a glance. Colours are the app layer's business; what is decided here
    /// is which of the four states the group is in.
    public enum Tone: Equatable {
        /// Nothing is happening, and nothing is meant to be: switched off, or empty.
        case idle
        /// On and enforcing.
        case running
        /// On, and the engine is standing down over it this second. See `BudgetRow.isOpen`.
        case open
        /// Blocked right now.
        case blocked
    }

    /// `row` is the group's line in the projection, or `nil` when the engine has nothing to say
    /// about it — which is a group holding neither a target, nor a live category, nor a rule.
    ///
    /// **`isOpen` is checked before the line.** A break window over this group, a break over the
    /// whole app or an emergency pass all leave the group on, going to block again, and holding
    /// nothing back at this moment. Printing its budget in the accent colour there was the editor
    /// claiming enforcement while the sidebar's shield, two inches to the left, said the opposite —
    /// the same lie the shield itself was fixed for.
    public static func pill(isActive: Bool, row: BudgetRow?) -> (text: String, tone: Tone) {
        guard isActive else { return ("Off", .idle) }
        // Switched off and empty are two different states, and calling the second one "Off" would
        // be a label disagreeing with the switch right next to it.
        guard let row else { return ("Nothing in it yet", .idle) }
        guard !row.isOpen else { return ("Nothing held back", .open) }
        return (row.line, row.reason == nil ? .running : .blocked)
    }
}
