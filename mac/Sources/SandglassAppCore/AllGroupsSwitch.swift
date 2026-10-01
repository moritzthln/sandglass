import SandglassCore
import Foundation

/// One control that switches every group off, and back on again.
///
/// Seven groups is seven trips into the sidebar, and the switch that saves those trips is only
/// worth having if the way back is exact. **Switching them all on must not switch on the ones
/// that were already off.** A group deliberately disabled last week is not the same as one this
/// turned off a minute ago, and a control that cannot tell them apart destroys that distinction
/// the first time it is used — which is the whole reason `Config.switchedOffTogether` exists and
/// records what was *changed* rather than what happens to be off.
///
/// **The memory decides which way one press goes**, so there is one control rather than two: an
/// empty list means nothing is off from here and the press switches off; a list with anything in
/// it means the press puts those back. Going back leaves the list empty either way, including
/// when every id in it has already been switched on by hand — otherwise the button would be stuck
/// offering a way back from a place nobody is any more.
///
/// **The world moves while everything is off, and none of it may make the way back wrong.**
///
/// - A group is **deleted**: its id names nothing, so the way back walks past it and the rest
///   still go on. `ConfigBuilder.removingGroup` takes the id out as well, but the walking past is
///   what a hand-edited `config.json` is safe by.
/// - A group is **added**: it is not in the list, so the way back does not touch it. It was made
///   switched on and it stays switched on.
/// - A group is **switched on by hand** from the sidebar: its id is still in the list, and putting
///   it back means setting a switch that is already set. The way back only ever switches things
///   **on**, never off — which is what makes every one of these three cases a no-op rather than a
///   correction, and what makes a stale id harmless instead of dangerous.
///
/// **Switching a group off is an edit to that group, and the group's own lock refuses those.** The
/// held groups are handed in rather than worked out here — see `SettingsVisit.heldGroups` —
/// because a second opinion about what a lock forbids is a second opinion that will one day
/// disagree with the first. They are left where they are, the rest move, and the memory records
/// only the ones that actually went: pressing the way back later puts back exactly those. The edit
/// still goes through `AppState.applyConfigEdit` like every other edit, so the plan is that answer
/// asked twice rather than a way around it.
///
/// **A lock holds the direction that loosens, and only that one.** Switching a group off ends
/// everything it was doing, so a locked group is left out of that press and the sentence says so;
/// switching one back **on** puts a block back, which is the direction no lock has ever existed to
/// stop — so the way back sweeps up every group it remembers, locked or not. Which is why the
/// held count is only ever about the off press: see `AppState.heldGroups`, where the direction
/// decides whether there is a held set at all. A strict window used to hold both directions; a
/// window blocks and freezes no settings, so the only thing that leaves a group behind now is a
/// lock about to be loosened.
public enum AllGroupsSwitch {

    /// Which way one press goes. There is only ever one, and the memory decides it.
    public enum Direction: Equatable, Sendable { case off, on }

    /// What one press would do — worked out before it is pressed, and the value the sentence
    /// afterwards is written from too, so what was promised and what is reported cannot drift.
    ///
    /// Counts rather than ids, because counts are all the row says out loud, and because this is
    /// published on every tick: a value carrying a whole edited `Config` would be compared against
    /// its predecessor once a second for ever.
    public struct Plan: Equatable, Sendable {
        public let direction: Direction
        /// How many groups the press actually moves.
        public let moving: Int
        /// Groups their own lock is holding where they are. The only reason a press is ever
        /// partial, and only the off press can ever be one: a lock refuses the direction that
        /// loosens, and switching a group back on is the other one.
        public let locked: Int
        /// Groups that are off and that this switch is not responsible for — the ones the way back
        /// leaves alone, and the number that proves it does.
        public let untouched: Int
        /// How many groups there are at all, so "nothing to do" can tell an app with no groups
        /// from one where every group is already off.
        public let groups: Int

        /// An app with no groups in it: what the published value is before the first pass over
        /// the engine, and the one state where every field is honestly zero.
        public static let noGroups = Plan(
            direction: .off, moving: 0, locked: 0, untouched: 0, groups: 0
        )
    }

    /// What a press did, and whether it was turned away — the row shows the first and takes its
    /// tone from the second.
    ///
    /// Two things end up in `text` and only one of them is written here: a press that went
    /// through reports `result(_:)`, and a press the settings lock, a focus session or the disk
    /// refused reports that refusal in its own words. They are the same row either way, because a
    /// user who pressed a button wants to read one sentence about what happened.
    public struct Outcome: Equatable, Sendable {
        public let text: String
        public let refused: Bool
    }

    // MARK: - What a press would do

    public static func direction(in config: Config) -> Direction {
        config.switchedOffTogether.isEmpty ? .off : .on
    }

    /// What one press would do right now. `locked` is the groups their own lock is holding, handed
    /// in from the visit.
    public static func plan(for config: Config, locked: Set<String> = []) -> Plan {
        let direction = direction(in: config)
        let remembered = Set(config.switchedOffTogether)
        return Plan(
            direction: direction,
            moving: moving(in: config, locked: locked).count,
            // A lock holds both directions, so this counts whichever of them the press was about
            // — and only groups the press would otherwise have moved.
            locked: wouldMove(in: config, direction: direction).filter(locked.contains).count,
            untouched: config.groupSettings
                .filter { !$0.value.enabled && !remembered.contains($0.key) }.count,
            groups: config.groupSettings.count
        )
    }

    /// The plan, and the configuration to submit for it — `nil` when there is nothing to submit.
    ///
    /// Going off, `nil` means no group can move: they are all off already, all held by a lock of
    /// their own, or there are none. Going back, there is always something to submit even when every id has
    /// been switched on by hand, because emptying the list is itself the change.
    public static func edit(
        for config: Config, locked: Set<String> = []
    ) -> (plan: Plan, config: Config?) {
        let plan = plan(for: config, locked: locked)
        let ids = moving(in: config, locked: locked)
        guard plan.direction == .on || !ids.isEmpty else { return (plan, nil) }
        var edited = config
        for id in ids { edited.groupSettings[id]?.enabled = plan.direction == .on }
        edited.switchedOffTogether = plan.direction == .off ? ids : []
        return (plan, edited)
    }

    /// The ids one press moves, sorted — which is also the order they are written down in, so two
    /// runs that switch the same groups off write the same bytes.
    ///
    /// Going back, an id naming a group that is gone is walked past and one naming a group that is
    /// already on is left out: both would be no-ops, and leaving them out is what keeps the count
    /// the row reports honest.
    private static func moving(in config: Config, locked: Set<String>) -> [String] {
        wouldMove(in: config, direction: direction(in: config))
            .filter { !locked.contains($0) }
            .sorted()
    }

    /// The ids one press would move if nothing were holding any of them — which is what both the
    /// count of the held ones and the list of the moving ones are worked out from, so the two can
    /// never be about different groups.
    ///
    /// Going back, an id naming a group that is gone is walked past and one naming a group that is
    /// already on is left out: both would be no-ops, and leaving them out is what keeps the count
    /// the row reports honest.
    private static func wouldMove(in config: Config, direction: Direction) -> [String] {
        guard direction == .on else { return on(in: config) }
        return config.switchedOffTogether.filter { config.groupSettings[$0]?.enabled == false }
    }

    /// Every group that is switched on right now.
    private static func on(in config: Config) -> [String] {
        config.groupSettings.filter(\.value.enabled).map(\.key)
    }

    // MARK: - What the row says

    /// Whether the button can be pressed at all. Going back it always can — there is always the
    /// list to empty.
    public static func isPressable(_ plan: Plan) -> Bool {
        plan.direction == .on || plan.moving > 0
    }

    /// The verb on the button, counting what it will move — because a button that says "all" over
    /// a press that leaves three groups on is a button that lies.
    ///
    /// "all" is kept for the case where it is true, and for the two cases where there is nothing
    /// to count: a press that moves nothing would otherwise read "Switch 0 off".
    public static func buttonTitle(_ plan: Plan) -> String {
        guard plan.direction == .off else {
            return plan.moving == 0
                ? "Switch them back on" : "Switch \(plan.moving) back on"
        }
        return plan.moving == 0 || plan.moving == plan.groups
            ? "Switch all off" : "Switch \(plan.moving) off"
    }

    /// Where things stand, under the label — what the press will do, before it is pressed.
    public static func caption(_ plan: Plan) -> String {
        guard plan.direction == .off else { return backCaption(plan) }
        guard plan.groups > 0 else { return "No groups yet." }
        guard plan.moving > 0 else {
            return plan.locked > 0
                ? "Every group that is on has a lock on it."
                : "Every group is already off."
        }
        return [
            "\(count(plan.moving)) will go off.",
            plan.locked > 0 ? lockedClause(plan.locked, past: false) : nil,
            plan.untouched > 0
                ? "\(count(plan.untouched)) already off \(stays(plan.untouched)) off." : nil,
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// The way back names no held groups, and cannot: putting a block back is the tightening
    /// direction, so every group this switched off comes with it whatever lock it carries.
    private static func backCaption(_ plan: Plan) -> String {
        guard plan.moving > 0 else { return "Every group this switched off is on again." }
        let promise = plan.untouched > 0
            ? " \(count(plan.untouched)) you switched off yourself \(stays(plan.untouched)) off."
            : ""
        return "\(count(plan.moving)) switched off from here.\(promise)"
    }

    /// What just happened, after the press — including the honest version of a partial press,
    /// which must never read as "done" while groups stayed on.
    ///
    /// Only reached when the edit went through: a refusal from the settings lock, a focus session
    /// or the disk is that refusal's own sentence, and it replaces this one.
    public static func result(_ plan: Plan) -> String {
        guard plan.direction == .off else { return backResult(plan) }
        guard plan.groups > 0 else { return "Nothing to switch off: there are no groups yet." }
        guard plan.moving > 0 else {
            return plan.locked > 0
                ? "Nothing switched off: every group that is on has a lock on it."
                : "Nothing to switch off: every group is already off."
        }
        let held = plan.locked > 0 ? " " + lockedClause(plan.locked, past: true) : ""
        return "\(count(plan.moving)) switched off.\(held)"
    }

    /// No held clause here either, for the reason `backCaption` has none.
    private static func backResult(_ plan: Plan) -> String {
        guard plan.moving > 0 else { return "Nothing to switch on: every one of them is already on." }
        let promise = plan.untouched > 0
            ? " \(count(plan.untouched)) you switched off yourself \(were(plan.untouched)) left off."
            : ""
        return "\(count(plan.moving)) switched back on.\(promise)"
    }

    /// What a lock holding a group out of the press is called, before it and after it.
    ///
    /// "Left alone" rather than "stayed on" or "stayed off", because a lock holds a group **where
    /// it is** and the press may have been going either way: the same sentence has to be true of a
    /// locked group the switch would have turned off and of one the way back would have turned on.
    private static func lockedClause(_ groups: Int, past: Bool) -> String {
        let verb = past ? (groups == 1 ? "was" : "were") : (groups == 1 ? "is" : "are")
        let carrying = groups == 1
            ? "1 group with a lock on it" : "\(groups) groups with a lock on them"
        return "\(carrying) \(verb) left alone."
    }

    /// "1 group" / "5 groups", so a number never reads as a fragment.
    private static func count(_ groups: Int) -> String {
        groups == 1 ? "1 group" : "\(groups) groups"
    }

    private static func stays(_ groups: Int) -> String { groups == 1 ? "stays" : "stay" }

    private static func were(_ groups: Int) -> String { groups == 1 ? "was" : "were" }
}
