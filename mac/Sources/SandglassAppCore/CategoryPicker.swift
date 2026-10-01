import SandglassCore
import Foundation

/// What the categories multi-select offers, and what it says when it is closed.
///
/// The chips it replaced were six buttons in a grid, which was fine when a category was a handful
/// of sites. They carry about twenty each now, and the question somebody actually has in front of
/// this control is not "which of these six words do I want" but "is Netflix already covered" —
/// which six words cannot answer and a search over their contents can.
public enum CategoryPicker {

    /// The categories a search matches: by their own name, or by something they carry.
    ///
    /// Searching the members is the whole reason this is a search rather than six buttons.
    /// Domains match on the host and apps on the bundle id, because those are what the lists hold
    /// — an app's Finder name is not knowable here, and a category is found by its sites far more
    /// often than by an app in it.
    public static func matching(
        _ query: String, in categories: [DistractionCategory]
    ) -> [DistractionCategory] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return categories }
        return categories.filter { category in
            category.name.localizedCaseInsensitiveContains(trimmed)
                || category.domains.contains { $0.localizedCaseInsensitiveContains(trimmed) }
                || category.bundleIDs.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    /// What the closed control reads.
    ///
    /// Names while they fit, a count once they do not: "Social, Video" says more than "2
    /// categories", and "Social, Video, News, Shopping, Games" says less than "5 categories".
    /// Ids this configuration does not carry are left out rather than printed raw — see
    /// `Config.category(id:)` for why one can be there at all.
    public static func summary(
        of picked: Set<String>, in categories: [DistractionCategory]
    ) -> String {
        let names = categories.filter { picked.contains($0.id) }.map(\.name)
        switch names.count {
        case 0: return "No categories"
        case 1, 2, 3: return names.joined(separator: ", ")
        default: return "\(names.count) categories"
        }
    }
}
