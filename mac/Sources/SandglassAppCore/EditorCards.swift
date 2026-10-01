import SandglassCore
import Foundation

/// Which of the group editor's two shared cards are on the page at all.
///
/// `GroupDetailColumn` draws Time windows and Settings, in that order and always in that order —
/// a column that reshuffled itself as a week changed would move the row somebody was reaching for.
/// The week comes first because it is the first thing to read about a group, and because the card
/// under it is the one that can be absent.
///
/// **A week with no gap in it takes the Settings card away entirely.** `RulesEngine
/// .decision(for:)` answers `.notManaged` inside a break window and `.blocked` inside a strict
/// one, and only reaches the pause countdown, the budget, the cooldown and the session when
/// neither is open. So a week its windows cover end to end runs on none of them, whatever they
/// say — and the honest way to show a card holding seven settings nothing will ever read is not
/// to show it: then it is clear at a glance that there is nothing to set, because the group is
/// fully blocked or fully free. The absence is the message, and the windows card sitting on
/// top is the whole story of such a group.
///
/// What it replaced was the same card dimmed to 0.55 under a line reading "None of this is ever
/// reached" — a card whose entire content was an apology for being there. The dimmed version was
/// kept for one wave so the knobs could be arranged *before* a window was removed; that trade is
/// knowingly overridden. The order is fixed now: make a gap, and the card comes back with it.
///
/// Here rather than in the view for the reason `EditorFreeze` and `EditorState` are: it is a
/// rule, and a rule written inside a `View` is a rule no test can read.
public enum EditorCards {

    /// Whether the Settings card is drawn.
    ///
    /// `presetRule` is `nil` in the group editor, which has a week rather than an opinion about
    /// one; the preset editor passes its answer. See `windowsInForce`.
    public static func showsSettings(
        windows: [TimeWindow], presetRule: PresetWindowsRule?
    ) -> Bool {
        !TimeWindow.coversEveryMinute(of: windowsInForce(windows, presetRule: presetRule))
    }

    /// The week these knobs would actually run in.
    ///
    /// A group's is its own list. A preset's counts only under `.use`: the card keeps the drawn
    /// windows as a working list whichever answer is selected, and a week no group will ever be
    /// given must not take away the settings every group *will* get. Under `.leaveAlone` the
    /// preset says nothing about the week, and under `.clear` it hands out a week of pure gap —
    /// both of which are groups that reach every one of these knobs.
    public static func windowsInForce(
        _ windows: [TimeWindow], presetRule: PresetWindowsRule?
    ) -> [TimeWindow] {
        guard let presetRule else { return windows }
        return presetRule == .use ? windows : []
    }
}
