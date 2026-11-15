import SandglassCore
import Foundation

/// Which single controls a running wait draws dead: the ones whose one move would loosen.
///
/// **Dead rather than lying.** Under a wait the editor's knobs keep the arrow that tightens and
/// lose the one that does not (`EditorFreeze.tighteningOnly`), but the targets card, the
/// category rows and the time-window rows were never told: their trash and minus buttons looked
/// exactly as they do when they work, and every press was refused. A remove button has one move,
/// so whether it may be pressed is the direction of that move, asked of the same table
/// `AppState.applyConfigEdit` asks — removing a block rule or a strict window loosens and goes
/// dead, removing an allow rule or a break window tightens and stays live.
///
/// Controls that open an editor stay live: an edit can go either way, and the editor's own Save
/// is refused on a loosening, in the editor, where what was drawn is still on screen.
public enum HeldControl {

    /// Whether a control that would turn `current` into `proposed` is held.
    public static func isHeld(
        tighteningOnly: Bool, from current: Config, to proposed: Config, onDay today: String
    ) -> Bool {
        tighteningOnly && EditDirection.loosens(from: current, to: proposed, onDay: today)
    }

    /// The same question for a card that holds one group's settings and nothing around them —
    /// the time-window card, which a preset's editor shares with a group's.
    public static func isHeld(
        tighteningOnly: Bool, from before: GroupSettings, to after: GroupSettings,
        onDay today: String
    ) -> Bool {
        guard tighteningOnly else { return false }
        let groupID = "held-control"
        let current = Config(version: 1, targets: [], groupSettings: [groupID: before])
        var proposed = current
        proposed.groupSettings[groupID] = after
        return EditDirection.loosens(group: groupID, from: current, to: proposed, onDay: today)
    }
}

/// The date sheet behind "Block until a day", and the one choice it makes for itself.
public enum DatedBlockPick {

    /// The earliest day the sheet lets a block be set to.
    ///
    /// Tomorrow, ordinarily: a block that ends today is no block. **Under a wait, the day after the
    /// one standing**, because pushing a block further out is a tightening and always goes
    /// through, while pulling it in is a loosening the wait holds — a calendar that offered the
    /// earlier days would offer only refusals.
    public static func earliest(today: String, standing: String?, tighteningOnly: Bool) -> String? {
        guard tighteningOnly, let standing else { return DatedBlock.day(.day, from: today) }
        return DatedBlock.day(.day, from: standing)
    }
}

/// Writing one edited item back into the list it came from.
///
/// Shared by the cards that edit a list in a sheet — rules, presets, categories — because the
/// two ways it goes wrong are the same everywhere: an item saved twice must not be in the list
/// twice, and an item deleted somewhere else while its sheet was open must not quietly come back.
public enum ListUpsert {

    /// The list with `element` in it: in its old place when it is there, so declaration order
    /// survives a correction, and appended when it is not and `appendsWhenMissing` says it is
    /// new. `nil` when it is neither — the item was deleted while it was being edited, and
    /// writing it back would resurrect what the user threw away.
    public static func upserting<Element: Identifiable>(
        _ element: Element, into list: [Element], appendsWhenMissing: Bool
    ) -> [Element]? {
        var list = list
        if let index = list.firstIndex(where: { $0.id == element.id }) {
            list[index] = element
            return list
        }
        guard appendsWhenMissing else { return nil }
        list.append(element)
        return list
    }

    /// What a card says when that happens. Answering `nil` there read as "saved" and threw the
    /// edits away in silence.
    public static func deletedWhileOpen(_ name: String) -> String {
        "“\(name)” was deleted while it was open. Nothing was written."
    }
}

/// The hours under the week strip, in the reader's own clock.
public enum TimelineAxis {

    /// Midnight, 6, noon, 18 and midnight again, the way the locale writes an hour: `12 AM` in a
    /// twelve-hour locale, `00 Uhr` in German. It used to be the English five hard-coded.
    public static func labels(locale: Locale = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("j")
        let midnight = Date(timeIntervalSince1970: 0)
        return [0, 6, 12, 18, 24].map { hour in
            formatter.string(from: midnight.addingTimeInterval(TimeInterval(hour * 3_600)))
        }
    }
}
