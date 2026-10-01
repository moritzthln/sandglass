import SandglassCore
import Foundation

/// Why something is blocked, in words rather than in a case name.
///
/// The menu bar used to show "Blocked until 11:00" and stop there. That is a fact with no cause
/// attached, and the causes are not interchangeable: a time window is something the user drew and
/// can redraw, a spent budget is something they used up and gets handed back tomorrow, a focus
/// session is something they started and cannot end short of the week's pass, and a cooldown is
/// over in a few minutes whatever they do. Four different things to do about it, and the popover was
/// showing the same six words for all of them.
///
/// Lowercase and short, because every one of these is read **after** the engine's own sentence:
/// "Blocked until 11:00 · time window".
public enum BlockCopy {

    public static func why(_ reason: BlockReason) -> String {
        switch reason {
        case .schedule: return "time window"
        // Said as what it is rather than as what it does, because the sentence in front of it has
        // already said what it does: "Blocked until Mon 24 Aug · a date you set". A window is
        // redrawn and a date is removed, which is why the two do not share a word.
        case .datedBlock: return "a date you set"
        case .budgetExhausted: return "today's opens are spent"
        case .cooldown: return "cooldown between opens"
        case .focusSession: return "everything is blocked"
        case .timeLimit: return "today's time is up"
        // Not a reason that ends at a time, which is why it is the one that names a condition:
        // it is over when the clock agrees again. See `BlockReason.clockTampered`.
        case .clockTampered: return "the system clock moved"
        }
    }

    /// The headline when groups are blocked and nothing larger is going on — the one fact worth
    /// putting above everything else in the popover.
    ///
    /// It counts rather than lists. Naming them reads well for two and falls apart at six, and
    /// the rows underneath name every one of them anyway, each with its own reason: what the
    /// headline is for is knowing, without reading a list, whether anything is blocked at all.
    public static func blockedNow(_ blocked: Int, of total: Int) -> String? {
        guard blocked > 0 else { return nil }
        guard blocked < total else {
            return total == 1 ? "Blocked right now" : "All \(total) groups are blocked right now"
        }
        return "\(blocked) of \(total) groups blocked right now"
    }

    /// Whether the protection is doing anything this second, in one sentence.
    ///
    /// The order is the order the facts outrank each other: the app being unable to do its job,
    /// then everything being lifted, then everything being blocked, then how much of it is.
    ///
    /// Shared by the popover and the settings page's Protection card. Two screens that both
    /// answer "is this on right now" and worded it two ways is how one of them ends up wrong —
    /// the settings page answered it not at all, which is worse.
    public static func headline(
        status: StatusKind,
        focusSessionLine: String?,
        blockedGroups: Int,
        groups: Int,
        clockText: (Date) -> String
    ) -> String {
        switch status {
        case .degraded(let line):
            return line
        case .paused(let until):
            guard let rest = stillBlocked(blockedGroups) else {
                return "Nothing is blocked until \(clockText(until))"
            }
            return "Unblocked until \(clockText(until)) · \(rest)"
        case .emergencyPass(let until):
            guard let rest = stillBlocked(blockedGroups) else {
                return "Emergency pass — nothing is blocked until \(clockText(until))"
            }
            return "Emergency pass — unblocked until \(clockText(until)) · \(rest)"
        case .active(let targets):
            if let focusSessionLine { return focusSessionLine }
            if let blocked = blockedNow(blockedGroups, of: groups) { return blocked }
            if targets > 0 { return "Protecting \(targets) \(targets == 1 ? "target" : "targets")" }
            // A group whose scope is advanced rules or the adult list has nothing
            // countable in it — `EngineReadout.managedTargetCount` counts targets and the domains
            // a category carries, and a rule is neither. Reading that zero as "nothing" told
            // somebody blocking the entire web that nothing was being blocked.
            guard groups == 0 else {
                return "Protecting \(groups) \(groups == 1 ? "group" : "groups")"
            }
            return nothingYet
        }
    }

    /// What an app-wide unblock leaves behind, or `nil` when it leaves nothing.
    ///
    /// "Nothing is blocked" is what a break and the week's pass both said flatly, and a group may
    /// now ignore both of them (`GroupSettings.ignoresAppWideUnblocks`) — so the flat version is a
    /// claim the app cannot make while one of those groups is standing there blocked. That is the
    /// same fault as an icon claiming protection that is not there, read from the other end, and it
    /// is the one kind of lie this app cannot afford.
    ///
    /// It counts rather than lists, like `blockedNow` above: naming them reads well for two and
    /// falls apart at six, and the rows underneath name every one of them anyway.
    ///
    /// **A count rather than a cause, deliberately.** Ignoring the unblocks is the ordinary reason
    /// a group is still blocked under one, and it is not the only one — a system clock that has
    /// been moved outranks both doors — so this says what is true and leaves the why to the rows.
    public static func stillBlocked(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 group still blocked" : "\(count) groups still blocked"
    }

    /// What the app says when there is genuinely nothing to block.
    ///
    /// Named because two things say it: this, and the popover's own empty-list row. The popover
    /// shows both, one under the other, so it needs to be able to tell when the headline has
    /// already said it — a 320-point column cannot afford the same sentence twice.
    public static let nothingYet = "Nothing is being blocked yet"
    // Three pieces of copy stood here and all three are gone with the refusal they spoke for.
    // `engineLock` was what a refused edit answered, `undoLockCaption` the short line under the
    // three controls a focus session held, and `waysOutOfAnUndoLock` the door named in their info
    // popovers. Nothing refuses a configuration edit any more — a block blocks and the settings
    // lock decides what may change — so there is nothing left for any of them to explain. See
    // `RulesEngine.updateConfig`.
}
