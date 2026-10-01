import SandglassAppCore
import SandglassCore
import SwiftUI

/// The category picker, and what a ticked category looks like in the list underneath it.
///
/// Same categories setup offers, now where a group is actually built. Ticking one used to be
/// possible in the wizard and nowhere else, which meant every group made afterwards was typed out
/// site by site — the shortcut existed for the five minutes the user knew least about what they
/// wanted, and was gone by the time they did.
///
/// A ticked category is a **membership**, so it is one row in the list rather than nineteen: the
/// group holds the word, `CategoryMembership` reads the list, and a site added to the list in a
/// later build arrives on its own. The row expands because a membership the user cannot see
/// inside is a group that blocks things for reasons nobody can look up.

// MARK: - The picker

/// The categories, as a multi-select bound to one group's memberships.
///
/// A dropdown rather than the six chips it was. The lists carry about twenty entries each, and
/// the question in front of this control is not "which of these words do I want" but "is Netflix
/// already covered" — which six buttons cannot answer and a search over their contents can.
/// Ticking takes effect at once: there is nothing to confirm, and an Apply step would have to
/// answer for unticking too.
///
/// **Every row opens.** A search says whether one particular thing is in a list; it does not say
/// what the list *is*, and ticking a word whose contents nobody can read is the leap of faith this
/// whole wave exists to end. What a row shows expanded is the category as it stands — not this
/// group's copy of it, which is the list further down the card, with the exceptions this group has
/// made already taken out.
@MainActor
struct CategoryPickerButton: View {
    /// Every category the configuration carries. Handed in rather than read from a global list,
    /// because there is no global list any more — they are the user's, and they live in the
    /// document this group lives in.
    let catalogue: [DistractionCategory]
    let picked: Set<String>
    /// What `AppScanner` found, so an app in a list can be named rather than left as a bundle id.
    /// One that is not installed here is still shown: it is in the list, and a row nobody can see
    /// is the thing this control was fixed to stop.
    let installed: [String: String]
    /// Answers with the reason the write did not happen, or `nil` when it did. Shown inside the
    /// popover for the reason the two sheets show their own: the page that carries refusals is
    /// the one this popover is covering, and a tick that silently springs back explains nothing.
    let onToggle: (DistractionCategory, Bool) -> String?
    @State private var open = false
    @State private var search = ""
    @State private var refusal: String?
    /// Which rows are open, by id. A set rather than one id, because "is Netflix in Video or in
    /// Social" is a question about two of them at once.
    @State private var expanded: Set<String> = []

    /// The same pill as `Add website` and `Add apps`, with a chevron in it.
    ///
    /// It was a bare `.bordered` `Button` at the default control size carrying a `.callout` label,
    /// and it rendered visibly taller and heavier than the two adds directly above it — three ways
    /// into the same card in two sizes. `SecondaryPillButton` is the one shape now, so the height,
    /// the type and the padding come from one place. The popover still hangs off this control and
    /// not off the pill's insides: the button is what it is anchored to either way.
    var body: some View {
        HStack(spacing: 6) {
            SecondaryPillButton(action: { open = true }) {
                HStack(spacing: 6) {
                    Text("Categories: \(CategoryPicker.summary(of: picked, in: catalogue))")
                    Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $open, arrowEdge: .bottom) { list }
            InfoButton("A ticked category stays up to date: sites added to it later are blocked here too. Single sites can be dropped from it in the list below, and dropping one changes this group only.")
            Spacer(minLength: 0)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search categories and what is in them", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                let matches = CategoryPicker.matching(search, in: catalogue)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(matches) { row($0) }
                    if matches.isEmpty {
                        // Two different empty states. "Nothing matches" over a list that does not
                        // exist would have somebody searching a catalogue of nothing.
                        Text(
                            catalogue.isEmpty
                                ? "No categories yet. Presets → Categories makes one."
                                : "No category carries that."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(height: 260)
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Done") { open = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ category: DistractionCategory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Toggle(isOn: binding(category)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.name).font(.callout)
                        Text(GroupSummary.targets(
                            apps: category.bundleIDs.count, sites: category.domains.count
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                disclosure(category)
            }
            if expanded.contains(category.id) { entries(category) }
        }
    }

    private func disclosure(_ category: DistractionCategory) -> some View {
        let isOpen = expanded.contains(category.id)
        return Button {
            if isOpen { expanded.remove(category.id) } else { expanded.insert(category.id) }
        } label: {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide what is in \(category.name)" : "Show what is in \(category.name)")
        .accessibilityLabel(
            isOpen ? "Hide what is in \(category.name)" : "Show what is in \(category.name)"
        )
    }

    /// Websites first and apps after, which is the order they are carried in and the order the
    /// count above reads. A category with neither says so rather than opening onto nothing.
    @ViewBuilder
    private func entries(_ category: DistractionCategory) -> some View {
        let apps = category.bundleIDs.map { installed[$0] ?? $0 }
        if category.domains.isEmpty, apps.isEmpty {
            Text("Nothing in it. Add to it in Presets → Categories.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(category.domains + apps, id: \.self) { entry in
                    Text(entry)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 20)
        }
    }

    private func binding(_ category: DistractionCategory) -> Binding<Bool> {
        Binding(
            get: { picked.contains(category.id) },
            set: { isOn in refusal = onToggle(category, isOn) }
        )
    }
}

// MARK: - A ticked category, in the list

/// One live category as a row: what it carries, and a way to look inside and take one out.
///
/// Collapsed by default, because the point of a category is not having to read twenty lines. The
/// count is what the group actually carries — exceptions already subtracted, and apps narrowed
/// to the ones on this Mac, since a bundle id nobody has installed can never be brought to the
/// front and counting it would be the card promising something it cannot do.
@MainActor
struct CategoryTargetRow: View {
    let category: DistractionCategory
    let settings: GroupSettings
    /// What `AppScanner` found, so an app in the list can be named and one that is not installed
    /// can be left out.
    let installed: [String: String]
    let onRemoveMember: (String) -> Void
    let onUntick: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded { members }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.page, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name).font(.callout)
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                expanded ? "Hide what is in \(category.name)" : "Show what is in \(category.name)"
            )
            Spacer(minLength: 8)
            // `minus.circle`, not a trash. This unticks the category for this group; the category
            // itself, and every other group using it, is untouched. A trash on this row means
            // something else everywhere the user has already seen one — on the Presets and
            // Categories pages it deletes the thing outright — so a trash beside a category name
            // read as "delete this category from the app". The two other controls in this app
            // that take an entry out of a list it is only a member of use this glyph already:
            // the rule row below, and the editor sheet in `CategoriesCard`.
            Button(action: onUntick) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove the \(category.name) category from this group")
                .accessibilityLabel("Remove the \(category.name) category from this group")
        }
    }

    /// `18 sites · 2 apps` — the whole of what the group carries through this category.
    private var summary: String {
        let apps = appMembers.count
        let sites = siteMembers.count
        // `GroupSummary` would say "Nothing in it yet", which is the wrong tense for a category
        // the user has just emptied one row at a time.
        guard apps > 0 || sites > 0 else { return "Nothing left in it" }
        return GroupSummary.targets(apps: apps, sites: sites)
    }

    /// Websites first and apps after, which is the order a category is carried in and the order
    /// its count above reads. Both at once, because the card no longer has halves to be in: a row
    /// that showed the websites while the apps were a click away was the segment saying itself
    /// again inside a list.
    @ViewBuilder
    private var members: some View {
        let rows = siteMembers + appMembers
        if rows.isEmpty {
            Text(emptyText).font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows, id: \.targetID) { member in
                    HStack(spacing: 8) {
                        Text(member.label).font(.caption)
                        Spacer(minLength: 8)
                        Button {
                            onRemoveMember(member.targetID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                                .help("Stop blocking \(member.label) in this group")
                        .accessibilityLabel("Stop blocking \(member.label) in this group")
                    }
                }
            }
            .padding(.leading, 20)
        }
    }

    /// The two ways a live category can carry nothing here: every entry has been struck off this
    /// group one at a time, or what is left is apps this Mac does not have — which are left out
    /// because nothing can bring them to the front, so listing them would promise a block that
    /// cannot happen.
    private var emptyText: String {
        "Nothing from this category is left in this group."
    }

    // MARK: - What is in it

    private struct Member {
        let targetID: String
        let label: String
    }

    private var siteMembers: [Member] {
        CategoryMembership.members(of: category, in: settings).domains.map {
            Member(targetID: Target.id(ofKind: .domain, value: $0), label: $0)
        }
    }

    /// Apps narrowed to what this Mac actually has, and named the way the Finder names them —
    /// a bundle id is not something anybody should have to read to decide whether to keep it.
    private var appMembers: [Member] {
        CategoryMembership.members(of: category, in: settings).bundleIDs
            .compactMap { bundleID in
                guard let name = installed[bundleID] else { return nil }
                return Member(targetID: Target.id(ofKind: .app, value: bundleID), label: name)
            }
    }
}
