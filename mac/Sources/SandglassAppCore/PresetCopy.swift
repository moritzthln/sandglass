import SandglassCore
import Foundation

/// How a preset is described to the user, and what a dropdown of them offers.
///
/// Every sentence is built from the values that are actually running, never from a table of
/// what a preset is supposed to be. A preset the user has since customised then describes
/// itself correctly instead of repeating the label it no longer deserves.
///
/// Here rather than in a view for the reason `ControlRules` gives: `Sandglass` is an
/// executable and nothing can import it, so a sentence written inside a `View` is a sentence no
/// test can read back. Its siblings — `BlockCopy`, `RuleCopy`, `TimeWindowCopy` — have always
/// lived here.
public enum PresetCopy {

    /// What values that match no preset are called. A state to be in rather than one to choose.
    public static let custom = "Custom"

    /// What to call a preset id: the name the user gave it, or Custom for values that match none
    /// — which is also the honest answer for an id naming a preset that has since been deleted.
    public static func name(ofPreset presetID: String?, in presets: [NamedPreset]) -> String {
        guard let presetID, let preset = presets.first(where: { $0.id == presetID }) else {
            return custom
        }
        return preset.name
    }

    /// One preset's row: its knobs, and what it does to the week when it has anything to say
    /// about one.
    ///
    /// Applying a preset overwrites with no confirmation, so the row somebody picks from is the
    /// only place a preset that would clear or replace their week can warn them. A preset that
    /// says nothing about the week adds nothing here, which is most of them.
    public static func detail(of preset: NamedPreset) -> String {
        [summary(of: preset.settings), windowsClause(preset.timeWindows)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// What a preset's three states about the week are worth in half a clause, or `nil` for the
    /// state that says nothing. See `NamedPreset.timeWindows`.
    public static func windowsClause(_ windows: [TimeWindow]?) -> String? {
        guard let windows else { return nil }
        guard !windows.isEmpty else { return "clears the week" }
        return "carries \(windows.count) time \(windows.count == 1 ? "window" : "windows")"
    }

    /// One line of the settings that matter, in the order they are met: the wait, the day's
    /// budget, the open, what follows it.
    ///
    /// **The friction knobs and nothing else.** It used to append the group's time windows, which
    /// made the line read "…strict block, Weekdays 10 PM – 8 AM" about a schedule the preset does
    /// not own, cannot set and does not hand out. Where this line is shown — a preset's row, the
    /// sheet that edits one, and every row of the two preset dropdowns — the windows are either
    /// empty or none of the preset's business, so the clause was a promise the values behind it
    /// could never keep.
    /// A pause of no seconds opens the clause with what it is rather than with a nought: "0s
    /// pause" reads as a countdown that finishes instantly, and there is no countdown — see
    /// `Decision.opensByItself`. Same words as the group editor's row, because it is the same
    /// state.
    public static func summary(of settings: GroupSettings) -> String {
        var parts = [
            settings.pauseSeconds == 0 ? "no pause" : "\(settings.pauseSeconds)s pause"
        ]
        // "no daily limit" named the wrong knob: a group can have no opens budget and still have
        // a daily time limit, and this clause is only ever about the opens.
        parts.append(settings.opensPerDay.map { "\($0) opens a day" } ?? "no opens budget")
        // Only when it is set: no preset has one, so on most groups there is nothing to say.
        if let dailyMinutes = settings.dailyMinutes { parts.append("\(dailyMinutes) min a day") }
        parts.append(settings.sessionMinutes.map { "\($0) min per open" } ?? "no relock")
        if settings.cooldownMinutes > 0 { parts.append("\(settings.cooldownMinutes) min cooldown") }
        if settings.escalationSeconds > 0 { parts.append("+\(settings.escalationSeconds)s each open") }
        if settings.earnBackEnabled { parts.append("earn-back on") }
        return parts.joined(separator: " · ")
    }
}

/// What a preset says about the week, as the one control that says it.
///
/// **Three answers to one question, not a switch plus a list.** "Does this preset carry windows"
/// and "which windows" are one decision, and two controls would be a lie: they would let the
/// screen show a week that is never handed out, and leave the user to work out which of the two
/// controls the group would actually feel.
///
/// Every answer is worded as what applying the preset does to the *group*, because that is the
/// only moment the difference between them is visible. See `NamedPreset.timeWindows` for the
/// three states these stand for.
public enum PresetWindowsRule: String, CaseIterable, Sendable {
    /// `nil` — applying the preset changes no window.
    case leaveAlone
    /// `[]` — applying the preset takes every window off the group.
    case clear
    /// A week of its own, which applying the preset puts on the group.
    case use

    /// What the row for this answer reads. Short enough for a menu, and each one names what
    /// happens to the group rather than what the preset holds.
    public var title: String {
        switch self {
        case .leaveAlone: return "Leave the group's windows alone"
        case .clear: return "Clear the group's windows"
        case .use: return "Use these windows"
        }
    }

    /// The sentence under the control, which is where the consequence is spelled out — a menu row
    /// has to be short and this does not.
    public var detail: String {
        switch self {
        case .leaveAlone:
            return "This preset says nothing about the week, so a group keeps whatever windows it already had."
        case .clear:
            return "A group put on this preset loses every window, and runs its ordinary budget all week."
        case .use:
            return "A group put on this preset gets exactly these windows, in place of whatever it had."
        }
    }

    /// Which answer a stored value is. The default for a preset that has never been asked is
    /// "leave them alone" — the one state that cannot surprise anybody.
    public static func rule(for windows: [TimeWindow]?) -> PresetWindowsRule {
        guard let windows else { return .leaveAlone }
        return windows.isEmpty ? .clear : .use
    }

    /// What to store for this answer, given the windows the editor is holding.
    ///
    /// `.use` with nothing drawn stores `[]` and therefore reads back as `.clear`. That is not a
    /// state being lost: a preset carrying no windows carries no windows, and the two answers
    /// would do the identical thing to a group. Storing anything else would let the file say one
    /// thing and the behaviour do another.
    public func windows(_ drawn: [TimeWindow]) -> [TimeWindow]? {
        switch self {
        case .leaveAlone: return nil
        case .clear: return []
        case .use: return drawn
        }
    }
}

/// One row of a preset dropdown: what it is called, and what it holds.
///
/// The second line is the whole reason this type exists. A menu of three names asks the user to
/// remember what Gentle means and pick blind, which is exactly what a preset is meant to save
/// them from — so every row carries its own settings in words.
public struct PresetChoice: Identifiable, Equatable, Sendable {
    /// The preset this row puts on the group, or `nil` for Custom.
    public let presetID: String?
    public let name: String
    /// The settings behind the name, as one plain line. See `PresetCopy.summary(of:)`.
    public let detail: String
    /// Whether this is where the group already is — a tick, not a selection to write.
    public let isCurrent: Bool

    /// Namespaced away from the preset ids it sits beside, because `ForEach` draws by this and a
    /// duplicate would draw one row where there are two: a hand-written `config.json` may hold a
    /// preset whose id is the literal word "custom".
    public var id: String { presetID.map { "preset:\($0)" } ?? "custom" }

    public init(presetID: String?, name: String, detail: String, isCurrent: Bool) {
        self.presetID = presetID
        self.name = name
        self.detail = detail
        self.isCurrent = isCurrent
    }
}

/// The rows the two preset dropdowns offer — the group editor's, beside the group's name, and
/// the sidebar's, which makes a group straight into a preset.
///
/// They differ in one thing and it is worth the second function: the editor is changing a group
/// that exists and can therefore be sitting on nothing, while the sidebar is choosing for a
/// group that does not exist yet.
public enum PresetChoices {

    /// What a group may be put on: every preset, plus Custom while that is where it already is.
    ///
    /// Custom is a state rather than a choice — it is the name for values matching no preset —
    /// so offering it to a group that is on one would be offering a destination with no address.
    /// Its line is the group's own settings, which is the one thing no preset's row can say.
    ///
    /// Which row is ticked comes from the values, never from the stored marker: see
    /// `ConfigBuilder.presetID(matching:in:)` for why the two are allowed to disagree.
    public static func forGroup(
        _ presets: [NamedPreset], settings: GroupSettings
    ) -> [PresetChoice] {
        let live = ConfigBuilder.presetID(matching: settings, in: presets)
        var rows = presets.map { preset in
            PresetChoice(
                presetID: preset.id,
                name: preset.name,
                detail: PresetCopy.detail(of: preset),
                isCurrent: preset.id == live
            )
        }
        guard live == nil else { return rows }
        rows.append(
            PresetChoice(
                presetID: nil,
                name: PresetCopy.custom,
                detail: PresetCopy.summary(of: settings),
                isCurrent: true
            )
        )
        return rows
    }

    /// What a group that does not exist yet may be made out of: the presets, and no Custom.
    ///
    /// Nothing is ticked, because there is no group to be on anything. An empty list is an empty
    /// menu, and the sidebar shows no control at all rather than one with nothing in it.
    public static func forNewGroup(_ presets: [NamedPreset]) -> [PresetChoice] {
        presets.map { preset in
            PresetChoice(
                presetID: preset.id,
                name: preset.name,
                detail: PresetCopy.detail(of: preset),
                isCurrent: false
            )
        }
    }
}
