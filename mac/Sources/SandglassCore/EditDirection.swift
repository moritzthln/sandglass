import Foundation

/// Which way an edit moves — the one question every lock in the app is asked.
///
/// **A lock holds loosening, and only loosening.** This is the lock rule the rest of the code
/// refers to: making things stricter must always work, only making them looser is held — apps and
/// websites can be added, a passcode can be added, and so on. Every setting is always editable
/// unless a lock or a passcode stands in front of it. A settings lock is a commitment device against
/// the weaker self, not against the stronger one — so a wait that stood in the way of somebody
/// adding a site, raising a pause or setting a passcode was the app arguing with the only wish it
/// exists to serve.
///
/// This is the direction table the strict windows carried until `ConfigSwap.checkLocks` went with
/// the freeze, resurrected at the point the locks are actually enforced. It reads no clock, no
/// gate and no passcode, and it decides nothing about blocking: it is a rule about **a pair of
/// configurations**, and everything about *whether* a lock is standing is `SettingsLockGate`'s and
/// `GroupLockGate`'s. Which is why it can live here while the engine stays ignorant of locks —
/// `RulesEngine` never asks it anything.
///
/// One question, asked of each field in turn: **can this value, moved this way, get you more than
/// you have this second?** If it can, the lock refuses it; if it cannot, it is a promise the user
/// is making to themselves, and it goes through.
public enum EditDirection {

    // MARK: - The whole configuration

    /// Whether this edit hands anything back **anywhere** — what the app-wide lock is asked.
    ///
    /// The globals first, because they are the cheap half and because a switch that reaches every
    /// group at once is the one worth refusing before any group is looked at. Then every group the
    /// current configuration knows: a group that exists only in `proposed` was not there a moment
    /// ago, so there is nothing it could be handing back.
    ///
    /// `today` is the day this moment is in, as `DatedBlock` spells one. The **one** thing here
    /// that depends on when it is asked: every other field means the same thing whenever it is
    /// read, while a dated block whose day has arrived has stopped being a block and must not be
    /// defended as one. It is handed in rather than read off a clock so that this stays a rule
    /// about a pair of configurations — see the note on the type.
    public static func loosens(from current: Config, to proposed: Config, onDay today: String) -> Bool {
        if loosensGlobals(from: current, to: proposed) { return true }
        return current.groupSettings.keys.contains {
            loosens(group: $0, from: current, to: proposed, onDay: today)
        }
    }

    /// Whether this edit hands anything back about **one group** — what that group's own lock is
    /// asked.
    ///
    /// Three comparisons, and the third is the one that is easy to miss. The settings themselves;
    /// the targets that name the group, where a **superset** passes because one more site inside a
    /// locked group is one more thing blocked; and what the group's live categories actually
    /// carry, with its own exceptions applied — a membership is an id, and comparing ids says
    /// nothing about what they point at, so emptying a list the group has ticked would otherwise
    /// lift every block it held through one.
    ///
    /// A group the edit **deletes** loosens by definition: a missing group is not a stricter one.
    public static func loosens(
        group groupID: String, from current: Config, to proposed: Config, onDay today: String
    ) -> Bool {
        guard let before = current.settings(forGroup: groupID) else { return false }
        guard let after = proposed.settings(forGroup: groupID) else { return true }
        return !(settingsHold(after, against: before, onDay: today)
            && targetIDs(inGroup: groupID, of: proposed)
                .isSuperset(of: targetIDs(inGroup: groupID, of: current))
            && GroupLocks.carried(by: after, in: proposed)
                .isSuperset(of: GroupLocks.carried(by: before, in: current)))
    }

    // MARK: - One group's settings

    /// Whether every field of `after` blocks at least as hard as `before` does.
    ///
    /// Four fields are not asked at all, and each absence is load-bearing. `name` is what the
    /// group is called, which blocks nothing. `presetID` is a **label re-derived after every
    /// edit** — see `ConfigBuilder.presetID(matching:in:)` — so comparing it would refuse every
    /// tightening there is: raising the pause detaches the group from Standard, and a lock reading
    /// that as a changed field would hand back exactly the refusal this exists to stop.
    /// `categoryExceptions` has no direction of its own and needs none: striking a member off
    /// shrinks what the group carries, which the caller's superset check catches.
    /// `passcodeForgotStartedAt` is the lock's own way out, and a lock that guarded its escape
    /// would be a trap — the hour is written through `AppState.saveEdit`, which asks nothing here.
    private static func settingsHold(
        _ after: GroupSettings, against before: GroupSettings, onDay today: String
    ) -> Bool {
        numbersHold(after, against: before)
            && switchesHold(after, against: before)
            && lockHolds(after, against: before)
            && after.categories.isSuperset(of: before.categories)
            && rulesHold(after.rules, against: before.rules)
            && windowsHold(after.timeWindows, against: before.timeWindows)
            && datedBlockHolds(after, against: before, onDay: today)
    }

    /// The one-shot block, and it moves under the rule everything above it moves under: **later is
    /// stricter.**
    ///
    /// Setting a date where there was none is a tightening and goes through whatever is standing;
    /// moving it further out is more of the same. Moving it nearer or taking it away is the
    /// loosening, and that is what a lock holds. Which is the whole of the commitment machinery a
    /// dated block needed — it already existed, and the date joins it rather than bringing its own.
    ///
    /// **A day already past is no block, on either side.** A group whose block ended on Sunday is
    /// not being made stricter by still carrying the key on Monday, and taking the dead key out is
    /// not a way back out of anything — a lock that refused that would be defending a block that is
    /// already over. `DatedBlock.standing` is that reading, and it is the same one the engine and
    /// every screen take.
    private static func datedBlockHolds(
        _ after: GroupSettings, against before: GroupSettings, onDay today: String
    ) -> Bool {
        guard let standing = DatedBlock.standing(before.blockedUntilDay, onDay: today) else {
            return true
        }
        guard let proposed = DatedBlock.standing(after.blockedUntilDay, onDay: today) else {
            return false
        }
        return proposed >= standing
    }

    /// The six numbers, and which way each of them has to move.
    ///
    /// - `pauseSeconds` — the wait in front of every open. **Longer** is stricter, and **nought is
    ///   the loosest value on the dial**: it is not a countdown that is already over but the
    ///   absence of a screen, so the page opens by itself and spends the open (see
    ///   `Decision.opensByItself`). Plain `>=` reads it that way already, which is the whole
    ///   reason it needs no case of its own.
    /// - `escalationSeconds` — what each open already spent today adds to the next wait, `0` for
    ///   off. **Larger** is stricter; see `GroupBudget.countdownSeconds`.
    /// - `cooldownMinutes` — the wait between one open and the next. **Longer** is stricter.
    /// - `opensPerDay` — how many times a day the group may be opened. **Fewer** is stricter.
    /// - `sessionMinutes` — how long one open lasts before it relocks. **Shorter** is stricter.
    /// - `dailyMinutes` — minutes the group may be used for in a day. **Lower** is stricter.
    private static func numbersHold(
        _ after: GroupSettings, against before: GroupSettings
    ) -> Bool {
        after.pauseSeconds >= before.pauseSeconds
            && after.escalationSeconds >= before.escalationSeconds
            && after.cooldownMinutes >= before.cooldownMinutes
            && allowance(after.opensPerDay, isNoGreaterThan: before.opensPerDay)
            && allowance(after.sessionMinutes, isNoGreaterThan: before.sessionMinutes)
            && allowance(after.dailyMinutes, isNoGreaterThan: before.dailyMinutes)
    }

    /// An allowance whose `nil` means "no limit at all": unlimited opens, an open that never
    /// relocks, a day with no ceiling on it.
    ///
    /// `nil` is therefore not a missing value to be skipped over but the **loosest value there
    /// is**, and it has to sort above every number somebody could type — which is what `.max`
    /// stands in for. Read the other way round, an off switch would look stricter than the
    /// tightest limit on the dial.
    private static func allowance(_ after: Int?, isNoGreaterThan before: Int?) -> Bool {
        (after ?? .max) <= (before ?? .max)
    }

    /// The three switches, and which side of each is the strict one.
    ///
    /// - `enabled` — **on**. Off is `.notManaged` everywhere the engine looks, which is the whole
    ///   group undone in one click.
    /// - `earnBackEnabled` — **off**. Ending an open early hands half of it back, which is budget
    ///   returning in the middle of a day that was meant to spend it. Turning it on is the
    ///   loosening; turning it off is the user taking their own escape hatch away.
    /// - `ignoresAppWideUnblocks` — **on**. It takes both of the app's ways out away from this
    ///   group — the week's pass and "Unblock everything" — so switching it on is somebody making
    ///   their own commitment harder and goes through whatever is standing; switching it off hands
    ///   the escapes back, which is what a lock is for. The rename widened what the switch covers
    ///   and moved neither side of it: on is still the strict one.
    private static func switchesHold(
        _ after: GroupSettings, against before: GroupSettings
    ) -> Bool {
        (after.enabled || !before.enabled)
            && (!after.earnBackEnabled || before.earnBackEnabled)
            && (after.ignoresAppWideUnblocks || !before.ignoresAppWideUnblocks)
    }

    /// The group's own lock, which is as much a setting as the rest of the page and moves under
    /// the same rule: **raising the wait passes, lowering it or switching it off is held**, and a
    /// passcode may be **set** but never removed or changed.
    ///
    /// That last one is the rule's own example — a passcode can be added — and it is
    /// the one that reads oddest at first: a passcode is friction, so adding it to a group already
    /// held by a running wait is somebody making their own commitment harder, and there has never
    /// been a reason to stand in the way of that. Changing one is not the same act: it is a
    /// removal and a setting in one edit, and the removal half is the way out of the lock.
    private static func lockHolds(
        _ after: GroupSettings, against before: GroupSettings
    ) -> Bool {
        after.lockMinutes >= before.lockMinutes
            && passcodeHolds(after.passcode, against: before.passcode)
    }

    /// A passcode that was not there may be set; one that was there has to survive untouched.
    /// Shared by both scopes, because the rule is the same one scope up.
    private static func passcodeHolds(
        _ after: PasscodeHash?, against before: PasscodeHash?
    ) -> Bool {
        guard let before else { return true }
        return after == before
    }

    // MARK: - Advanced rules

    /// The rule list, split by what each rule does: **block rules may only be added, allow rules
    /// only taken away.**
    ///
    /// The old table froze the list whole, on the argument that which rule a URL runs into is
    /// decided by priority, by match type and, at the last tie-break, by the order the list
    /// happens to be in — so two lists cannot be compared for strictness without deciding every
    /// URL against both. That argument is about the *interaction* between rules; the two
    /// directions above are true whatever the ordering does, because a list that has gained a
    /// block and lost no allow cannot let through a URL the old list caught.
    ///
    /// Compared by shape rather than by `Rule`, because every rule carries a `UUID` of its own:
    /// applying a preset copies rules onto a group, so identical lists compare unequal.
    private static func rulesHold(_ after: [Rule], against before: [Rule]) -> Bool {
        shapes(of: after, doing: .block).isSuperset(of: shapes(of: before, doing: .block))
            && shapes(of: after, doing: .allow).isSubset(of: shapes(of: before, doing: .allow))
    }

    /// One rule with its identity left out: what it matches, how, and whether it is read first.
    private struct RuleShape: Hashable {
        let pattern: String
        let matchType: Rule.MatchType
        let highPriority: Bool
    }

    private static func shapes(of rules: [Rule], doing action: Rule.Action) -> Set<RuleShape> {
        Set(
            rules.filter { $0.action == action }.map {
                RuleShape(
                    pattern: $0.pattern, matchType: $0.matchType, highPriority: $0.highPriority
                )
            }
        )
    }

    // MARK: - The week

    /// The two kinds of window, and they move in opposite directions.
    ///
    /// Derived from the rule: a `strictBlock` window shuts hours, so
    /// **adding or extending one passes** and shortening or deleting one is held. A `break` window
    /// **opens** hours — it is the one shape in the app that hands time back — so adding or
    /// extending one is held and shortening or deleting one passes.
    ///
    /// Compared as the minutes of the week each kind covers rather than window by window, because
    /// every one of the four verbs above is the same fact about coverage: a window drawn on one
    /// more day, a window whose end moved later, two windows merged into one, a window whose kind
    /// was switched. Ids and list order are no part of it, for the reason `TimeWindow.Shape`
    /// exists.
    ///
    /// The two kinds are counted separately rather than as one effective week, and deliberately:
    /// a break outranks a block where they overlap (`RulesEngine.activeStrictWindow`), so a break
    /// laid over a block hands those hours back without either kind's own coverage saying so.
    /// Asked per kind, that edit is a break that grew, and it is held.
    ///
    /// Short-circuited on the shapes, which is what keeps the ordinary edit — anything at all that
    /// is not the week — from walking ten thousand minutes twice.
    private static func windowsHold(_ after: [TimeWindow], against before: [TimeWindow]) -> Bool {
        guard TimeWindow.shapes(of: after) != TimeWindow.shapes(of: before) else { return true }
        return coverage(of: after, kind: .strictBlock)
            .isSuperset(of: coverage(of: before, kind: .strictBlock))
            && coverage(of: after, kind: .break).isSubset(of: coverage(of: before, kind: .break))
    }

    /// Every minute of the week these windows cover, of one kind — as an index into the week, so
    /// two lists are compared as sets rather than as intervals.
    ///
    /// Every minute is walked through `contains(weekday:minutes:)` rather than the intervals
    /// merged, for the reason `TimeWindow.coversEveryMinute` walks them: windows cross midnight,
    /// name the day they *start* on, and may be listed in any order, and a second reading of that
    /// rule is one that could quietly disagree with the engine's.
    private static func coverage(of windows: [TimeWindow], kind: TimeWindow.Kind) -> Set<Int> {
        let ofKind = windows.filter { $0.kind == kind }
        guard !ofKind.isEmpty else { return [] }
        var minutes: Set<Int> = []
        for weekday in 1...7 {
            for minute in 0..<TimeWindow.minutesInDay
            where ofKind.contains(where: { $0.contains(weekday: weekday, minutes: minute) }) {
                minutes.insert(weekday * TimeWindow.minutesInDay + minute)
            }
        }
        return minutes
    }

    // MARK: - The app's own settings

    /// The app-wide settings, and which way each of them may move.
    ///
    /// The test for membership is narrow and it is the only one: **can turning this knob weaken
    /// what is being enforced right now?** Each of these can, and each of them reaches past any
    /// one group, which is why the per-group comparison never sees them.
    ///
    /// - `dayStartMinutes` is **frozen in both directions, because it has no strict one.** It
    ///   decides which logical day this moment belongs to, and therefore when a spent budget is
    ///   handed back. Moved later, it can put this moment into yesterday and bring the next
    ///   rollover forward to this afternoon — two fresh budgets inside one calendar day. Moved
    ///   earlier, the same arithmetic on the other side of the boundary. A number that hands
    ///   something back whichever way it is turned is a number that stays where it is.
    /// - `preventTimeChange` is what stops a changed clock from being carried on with, so **on is
    ///   the strict side**.
    /// - `breakWaitSeconds` is the wait in front of the Unblock card. **Longer** is stricter;
    ///   cutting it is a break arriving sooner.
    /// - `settingsLock` moves under the rule its per-group twin does — see `lockHolds`.
    ///
    /// What is deliberately **not** here is everything that cannot loosen anything: the menu-bar
    /// countdown, the relock warning, the presets (a template a group was copied from, never a
    /// live link), the seeds, and `groupOrder`, which decides which card is above which and
    /// nothing about what is blocked. A lock that would not let its own sidebar be tidied is
    /// friction that protects nothing. `switchedOffTogether` is on that list too: it is the memory
    /// of what the all-at-once switch turned off, and every group it names is compared as a group.
    public static func loosensGlobals(from current: Config, to proposed: Config) -> Bool {
        !(proposed.dayStartMinutes == current.dayStartMinutes
            && (proposed.preventTimeChange || !current.preventTimeChange)
            && proposed.breakWaitSeconds >= current.breakWaitSeconds
            && settingsLockHolds(proposed.settingsLock, against: current.settingsLock))
    }

    /// The app-wide lock, field by field.
    ///
    /// - `timerMinutes` — raising the wait passes, lowering it or switching it off is held. `nil`
    ///   is the off state and sorts as nought, which is where the dial's own bottom is.
    /// - `passcode` — may be set, never removed or changed. See `passcodeHolds`.
    /// - `coversQuickDisable` — whether starting a break asks for the passcode too. **On** is the
    ///   strict side: switching it off takes a question away from the largest loosening the app
    ///   offers short of quitting.
    /// - `allowForgot` — whether a forgotten passcode can be cleared from inside the app at all.
    ///   **Off** is the strict side, because on is a way out that was not there a moment ago. It
    ///   is not a trap either way: the week's emergency pass lifts every lock in the app, which is
    ///   what keeps this from being the one field that could shut the door for good.
    private static func settingsLockHolds(
        _ after: SettingsLock, against before: SettingsLock
    ) -> Bool {
        (after.timerMinutes ?? 0) >= (before.timerMinutes ?? 0)
            && passcodeHolds(after.passcode, against: before.passcode)
            && (after.coversQuickDisable || !before.coversQuickDisable)
            && (!after.allowForgot || before.allowForgot)
    }

    // MARK: - Scope

    private static func targetIDs(inGroup groupID: String, of config: Config) -> Set<String> {
        Set(config.targets.filter { $0.groupID == groupID }.map(\.id))
    }
}
