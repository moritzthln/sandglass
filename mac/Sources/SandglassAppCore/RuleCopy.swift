import SandglassCore
import Foundation

/// How an advanced rule is written down for a person to read.
///
/// In the shared module rather than in a view for the reason `TimeWindowCopy` is: the targets
/// card and the rule sheet name the same three properties, and a rule that reads
/// "Block · Specific page" in the list must not read "block a page" in the sheet.
public enum RuleCopy {

    // MARK: - The three properties

    public static func action(_ action: Rule.Action) -> String {
        switch action {
        case .allow: return "Allow"
        case .block: return "Block"
        }
    }

    /// What a match type is called on a rule's own row, where it is one clause of a sentence
    /// rather than the label of a control.
    ///
    /// "Website or text match" is what the control says, because there it names a choice. Under a
    /// pattern it read as a badge — a noun phrase in title case, present on every row, saying the
    /// same thing about all of them. These say what the rule *does*, which is the only reason the
    /// line is there.
    ///
    /// **The action is part of the answer**, because one rule type reads two ways: a block matches
    /// its text anywhere in an address and an allow names a place, so a single "address contains"
    /// on every row would describe half of them wrongly. See `RuleMatcher.covers(place:_:)`.
    public static func matchTypeShort(_ matchType: Rule.MatchType, action: Rule.Action) -> String {
        switch matchType {
        case .websiteOrText: return action == .allow ? "site or page" : "address contains"
        case .specificPage: return "exact page"
        }
    }

    /// The sentence under the rule-type control, which changes with both selections above it.
    public static func matchTypeDetail(_ matchType: Rule.MatchType, action: Rule.Action) -> String {
        switch matchType {
        case .websiteOrText where action == .allow:
            return "Matches this site and its subdomains, or this page and anything under it. An exception names a place, so it is not matched inside another address."
        case .websiteOrText:
            return "Matches any address containing this website or text."
        case .specificPage:
            return "Matches only this exact page, and nothing under it."
        }
    }

    /// The second line of a rule card: what it does, how it decides, and whether it outranks the
    /// rest.
    ///
    /// One line that reads as a sentence rather than a row of badges. `priority` is only there
    /// when it is set — a marker present on every row is decoration, and this one is worth
    /// noticing precisely because most rules do not carry it.
    public static func summary(_ rule: Rule) -> String {
        var parts = [action(rule.action), matchTypeShort(rule.matchType, action: rule.action)]
        if rule.highPriority { parts.append("priority") }
        return parts.joined(separator: " · ")
    }

    // MARK: - The card's three sections

    /// `Websites (2)`. The count belongs in the heading because that is the question somebody
    /// scanning the card has — how much is in this group — and a section carrying its own count
    /// answers it without anything underneath being read.
    public static func sectionHeading(_ title: String, count: Int) -> String {
        "\(title) (\(count))"
    }

    /// What a target's row reads.
    ///
    /// A website is its address, which is the thing being blocked and the thing somebody typed. An
    /// app is what the Finder calls it: the row used to show the bundle id, so the Apps list was a
    /// column of `com.tinyspeck.slackmacgap` under a heading saying these were apps. The value is
    /// the fallback for a target hand-written into `config.json` with no name on it.
    public static func rowTitle(_ target: Target) -> String {
        guard target.kind == .app else { return target.value }
        let name = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? target.value : name
    }

    /// Why an add did nothing: the thing is in a group already, and **which** group.
    ///
    /// "already blocked, in this group or another" was true and useless — the one question
    /// somebody has at that moment is where it went, and answering "somewhere" leaves them to
    /// open every group in the sidebar to find out.
    public static func alreadyBlocked(_ items: [(name: String, group: String?)]) -> String? {
        guard !items.isEmpty else { return nil }
        let parts = items.map { item in
            item.group.map { "\(item.name) in “\($0)”" } ?? "\(item.name) in another group"
        }
        return "Already blocked: \(parts.joined(separator: ", "))."
    }

    /// Why an add did nothing when it was handed nothing to do.
    ///
    /// The sibling of `alreadyBlocked(_:)`, for the case that can name no target at all: a
    /// selection is resolved against the list as it stands now, so every ticked row can have
    /// become already blocked since it was ticked, and the sheet hands over an empty list.
    ///
    /// Said rather than answered with silence. Silence is what the sheets read as a successful
    /// add — it is the whole protocol between them and the card — so a quiet `nil` here closed a
    /// sheet over a selection it had just dropped.
    public static let nothingToAdd =
        "Nothing was added — everything picked is already blocked, or is no longer on the list."

    // MARK: - What each control is for

    /// The sheet's whole explanation, behind the `i` next to its title.
    ///
    /// There was an `intro` line above it — "Advanced rules let you layer rules to handle complex
    /// blocking scenarios" — which is a sentence about a feature rather than about anything the
    /// reader is deciding. It said "rules" three times and nothing at all. Gone; this is what a
    /// reader actually needs, and it is one click away rather than in the way every time.
    public static let introHelp = """
        Rules are read high priority first, then the most specific, then allow before block, \
        then the order you wrote them in. The first rule that matches decides.
        """

    public static let priorityHelp = """
        This rule is read before every rule that is not high priority, whichever of them also \
        matches the address. It is how one exception beats a whole list.
        """
}
