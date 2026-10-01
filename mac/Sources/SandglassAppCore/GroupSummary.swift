import SandglassCore
import Foundation

/// The three short lines a group card in the sidebar is made of.
///
/// Here rather than in the view because they are arithmetic with wording attached, and because
/// "3 of 5 opens · 12 min" is the number the user scans the list for — a card that rounded it the
/// other way, or wrote "0 opens" for a group with no budget, would be the app misreporting the
/// one thing it exists to report. All of it is checked in the suite.
public enum GroupSummary {

    /// What is in the group: `1 app · 2 sites`, and an honest empty state when there is nothing.
    public static func targets(apps: Int, sites: Int) -> String {
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) \(apps == 1 ? "app" : "apps")") }
        if sites > 0 { parts.append("\(sites) \(sites == 1 ? "site" : "sites")") }
        return parts.isEmpty ? "Nothing in it yet" : parts.joined(separator: " · ")
    }

    /// The one line a sidebar card gives a group's standing, from the two facts that used to have
    /// a row each.
    ///
    /// A card reported both, one above the other: `1 site` over `5 of 5 opens left`. Two rows for
    /// a fact you set once and a fact that moves all day — and a row per group is what made seven
    /// groups scroll in a sidebar that has room for eight.
    ///
    /// They fold because they are never both worth reading. A group the engine has something to
    /// say about is a group with targets in it, so the count underneath is the arithmetic nobody
    /// is doing; a group it has nothing to say about has no day to report, and then what is — or
    /// is not — in it is the only honest thing the line can say. `MainWindowView.todayLine` is
    /// what decides which of the two this is, and it hands over an empty string for the second.
    public static func cardStatus(todayLine: String, apps: Int, sites: Int) -> String {
        todayLine.isEmpty ? targets(apps: apps, sites: sites) : todayLine
    }

    /// What a group whose week has no gap in it says when nothing is blocking it this second.
    ///
    /// Which, for such a week, can only mean a break window is open over it — or a break or an
    /// emergency pass over the whole app. The same words the sidebar's shield uses for the same
    /// fact ("On, but nothing is held back right now"), because it is the same fact and two
    /// spellings of one state is how a card and the icon beside it start disagreeing.
    public static let nothingHeldBack = "Nothing held back right now"

    /// Where today stands: what is **left** of each budget the group has, then what has been spent
    /// on anything it has no budget for. `3 of 5 opens · 48 of 60 min left`.
    ///
    /// **A budget counts down, everywhere in this app.** `"N of M opens"` used to mean opens
    /// *spent* here and opens *left* in `GroupBudget.line`, which is the string the pause screen,
    /// the block page, the menu-bar popover and the group editor's own pill are built from — so
    /// the editor showed "0 of 5 opens" in the sidebar and "5 of 5 opens left today" beside the
    /// switch, at the same moment, about the same group. One shape cannot carry two meanings.
    ///
    /// The engine's line is the one that stands, for two reasons. It is where the number is read
    /// under pressure: the pause screen is where somebody decides whether to spend one. And it
    /// cannot be turned round without contradicting itself — its time half already counts down
    /// ("12 min"), and a sentence ending "left today" cannot open with a count of what is gone.
    ///
    /// **`min`, not `m`.** Every control on the settings pages, `dailyTotal` right below this, and
    /// the engine's own budget line all write minutes as "5 min"; this line alone wrote "12m of
    /// 60m", which is a second notation for the one unit the app counts in. The unit is said once
    /// at the end of the pair, the way the opens half says "opens" once.
    ///
    /// **One sentence for two screens.** The sidebar card and the stats page report the same fact
    /// and used to word it differently — `2/5 opens · 12m` against `2 of 5 opens · 12m of 60m` —
    /// which is the app disagreeing with itself about the number it exists to report.
    ///
    /// One rule for both halves: a budget the user set is shown from the moment it exists, so the
    /// line says what they have got left before they have touched it; a number with no budget
    /// behind it has nothing to be left of, so it counts what was spent and is shown only once it
    /// is worth reading. That is why a group with no time limit says nothing about time all
    /// morning — a card that reads "0 min" every morning teaches the reader to stop reading it —
    /// while one with a limit says "60 of 60 min left", where the 60 is the point.
    ///
    /// `left` is said once for the whole run of budgets rather than after each of them, the way
    /// `GroupBudget.line` says "left today" once after both of its halves.
    ///
    /// Both are floored the way the engine floors them: half an open earned back is not an open to
    /// spend, and forty seconds left is not a minute to stay.
    ///
    /// **A group whose week its windows cover end to end reports none of this.** It is blocked or
    /// off at every moment — `RulesEngine.decision(for:)` answers `.blocked` inside a strict window
    /// and `.notManaged` inside a break, and reaches the budget only when neither is open — so it
    /// is never on a budget and no number here is about anything. What stood there instead was the
    /// day's *usage* drawn in the place a budget goes: a late-night group's card read "277 min",
    /// which is how long those seven apps had been in front, on a group that cannot spend an open
    /// at all. `TimeWindow.coversEveryMinute` is the rule, and `EditorCards.showsSettings` is the
    /// same rule taking the knobs off the editor — one answer, so the two screens cannot disagree
    /// about whether a group has settings worth reading.
    ///
    /// What is left is the schedule state, which is the whole story of such a group: `blockLine` is
    /// the engine's own sentence where something is blocking, and where nothing is — which for a
    /// covered week can only be a break window — the honest line is that nothing is held back. The
    /// sidebar prefers a block line before it ever gets here (see `MainWindowView.todayLine`), so
    /// it passes none; the stats page has no such rule of its own and hands one in.
    ///
    /// **A dated block reads the same way, for the same day and a half.** The stats page reports a
    /// day rather than a moment, so an ordinary blocked group still shows its budget here — that is
    /// deliberate, and it is why a strict window standing this second changes nothing below. A
    /// dated block is not about this second: it shuts the group for days, over which no open can be
    /// spent at all, so a budget beside it is the same "277 min" fault read from the other end. It
    /// is handed in as a fact rather than derived, because deciding whether a day is still ahead
    /// takes a clock and nothing here has one — see `DatedBlock.standing`.
    public static func today(
        opensUsed: Double, opensPerDay: Int?, usageSeconds: Int, dailyMinutes: Int? = nil,
        windows: [TimeWindow] = [], datedBlock: Bool = false, blockLine: String? = nil
    ) -> String {
        guard !datedBlock, !TimeWindow.coversEveryMinute(of: windows) else {
            return blockLine ?? nothingHeldBack
        }
        var budgets: [String] = []
        var spent: [String] = []
        let used = Int(opensUsed.rounded(.down))
        if let opensPerDay {
            // The remainder is floored, not the spend: `GroupBudget.line` works it out this way
            // round, and with 1.5 opens gone the two orders differ by a whole open — 5 − ⌊1.5⌋ = 4
            // against ⌊5 − 1.5⌋ = 3. Three is the true one, because the next open has to fit whole.
            let left = Int((Double(opensPerDay) - opensUsed).rounded(.down))
            budgets.append("\(max(0, left)) of \(opensPerDay) opens")
        } else if used > 0 {
            spent.append("\(used) \(used == 1 ? "open" : "opens")")
        }
        let minutes = usageSeconds / 60
        if let dailyMinutes {
            // The same care with the seconds the card never shows: ninety seconds into an hour is
            // 58 minutes left, not 59. Subtract first, then floor — `GroupBudget.secondsLeftToday`.
            let left = max(0, dailyMinutes * 60 - usageSeconds) / 60
            budgets.append("\(left) of \(dailyMinutes) min")
        } else if minutes > 0 {
            spent.append("\(minutes) min")
        }
        var parts: [String] = []
        if !budgets.isEmpty { parts.append("\(budgets.joined(separator: " · ")) left") }
        parts += spent
        return parts.isEmpty ? "Nothing today" : parts.joined(separator: " · ")
    }

    /// What the day's budget adds up to: `5 opens × 7 min = 35 min a day`.
    ///
    /// The numbers were always stored and the product was never said out loud, which left the
    /// user to do the arithmetic that decides whether their budget is generous or absurd.
    ///
    /// **All three knobs, because the ceiling is the lowest of them.** It used to be told only the
    /// opens and the length, so five opens of twenty minutes under a one-hour limit read as "100
    /// min a day" — the one number on the card that was not true.
    ///
    /// **A limit above the product is still said out loud.** It used to be dropped on the argument
    /// that it changed nothing, which would be right if the two counted the same minutes. They do
    /// not: the limit's own help row says it counts time in the group *whether or not an open is
    /// running*, so an emergency pass or a break spends it without spending a single open. A
    /// sixty-minute limit over a twenty-five-minute product can still be the thing that blocks,
    /// and the card was leaving it off the one line that adds the day up.
    ///
    /// So the two are worded as what they are. At or below the product the limit is the ceiling —
    /// "capped at". Above it, it is a second ceiling on a different measure — "under a … limit".
    public static func dailyTotal(
        opensPerDay: Int?, sessionMinutes: Int?, dailyMinutes: Int? = nil
    ) -> String {
        let capped = dailyMinutes.map { "\($0) min a day" }
        guard let opensPerDay else {
            return "Unlimited opens · \(capped ?? "no daily total")"
        }
        guard let sessionMinutes else {
            return capped.map { "\(opensPerDay) opens · no relock · \($0)" }
                ?? "\(opensPerDay) opens · no relock, so no daily total"
        }
        let total = opensPerDay * sessionMinutes
        let product = "\(opensPerDay) opens × \(sessionMinutes) min = \(total) min"
        guard let dailyMinutes else { return "\(product) a day" }
        guard dailyMinutes > total else { return "\(product), capped at \(dailyMinutes) min a day" }
        return "\(product) a day, under a \(dailyMinutes) min limit"
    }
}
