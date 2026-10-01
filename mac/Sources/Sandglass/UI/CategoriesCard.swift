import SandglassAppCore
import SandglassCore
import SwiftUI

/// The categories, as a list the user owns.
///
/// Social, Video, News, Shopping, Games and Messaging are seeded on first load and are ordinary
/// rows here: rename them, edit what is in them, throw them away. What they were before was a
/// `static let` in the code — six words a group could be ticked into, with no screen anywhere that
/// said what a word carried. Ticking "Social" was a leap of faith, and the only way to find out
/// what it had taken was to be blocked by something.
///
/// Deleting takes nothing from a group but the membership. A group keeps its own targets, its
/// rules and its exceptions; the confirmation says how many groups are about to stop claiming the
/// list, because that is the fact somebody needs before they press the button rather than after.
@MainActor
struct CategoriesCard: View {
    let appState: AppState

    /// Why the last write did not take, shown at the foot of this card rather than in the page's
    /// banner at the top of a scroll view. See `PresetsPageView`.
    @State private var problem: String?

    /// Which category the contents sheet is about, or `nil` while it is closed. The id rather than
    /// the value, so a sheet left open across an edit from somewhere else re-reads rather than
    /// writing back what it was opened with.
    @State private var editing: EditingCategory?
    @State private var renaming: String?
    @State private var draftName = ""
    @State private var deleting: DistractionCategory?

    private var categories: [DistractionCategory] { appState.config.categories }

    var body: some View {
        SettingsCard(
            "Categories",
            help: "One list of apps and websites that several groups can share. Ticking it in a group is a live membership rather than a copy, so anything added to the list here is blocked in every group that ticked it. A group can still drop single entries of its own."
        ) {
            if categories.isEmpty {
                SettingsStateRow(
                    text: "No categories. A group still blocks whatever it names itself.",
                    tone: .secondary
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(categories) { row($0) }
                }
            }
            PrimaryWideButton(title: "Add category", action: add).padding(.top, 10)
            if let problem {
                SettingsStateRow(text: problem, tone: .warning)
            }
        }
        .sheet(item: $editing) { sheet in
            if let category = sheet.draft ?? categories.first(where: { $0.id == sheet.id }) {
                CategoryEditorSheet(category: category, config: appState.config) { edited in
                    save(edited, isNew: sheet.draft != nil)
                } onCancel: {
                    editing = nil
                }
            } else {
                // Nothing to edit and nothing to write back to. It cannot be reached from this
                // screen — deleting closes the sheet — and a sheet that renders nothing is a sheet
                // with no way out of it, which is worth one line to make impossible.
                VStack(spacing: 12) {
                    Text("That category is no longer there.")
                    Button("Close") { editing = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(24)
            }
        }
        .alert(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { category in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(category) }
        } message: { category in
            Text(deleteMessage(for: category))
        }
    }

    // MARK: - One row

    private func row(_ category: DistractionCategory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if renaming == category.id {
                renameRow(category)
            } else {
                nameRow(category)
            }
            Text(GroupSummary.targets(apps: category.bundleIDs.count, sites: category.domains.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.page, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
    }

    private func nameRow(_ category: DistractionCategory) -> some View {
        HStack(spacing: 10) {
            Text(category.name).font(.callout)
            Spacer(minLength: 8)
            icon("pencil", "Edit what is in \(category.name)") {
                editing = EditingCategory(id: category.id)
            }
            icon("textformat", "Rename \(category.name)") {
                draftName = category.name
                renaming = category.id
            }
            icon("trash", "Delete \(category.name)") { deleting = category }
        }
    }

    private func renameRow(_ category: DistractionCategory) -> some View {
        HStack(spacing: 8) {
            TextField("Category name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename(category) }
            Button("Save") { commitRename(category) }
            Button("Cancel") { renaming = nil }
        }
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }

    // MARK: - Writing

    /// A new category starts empty and opens straight onto its own contents: the list is the
    /// user's to build, and seeding it with somebody else's idea of what belongs would be the app
    /// guessing at the one thing it cannot know.
    ///
    /// **Nothing is written here.** The draft lives in the sheet's item until Save, so a Cancel
    /// leaves no "New category" behind in a list nobody agreed to — the rule `PresetsCard` follows.
    private func add() {
        let draft = ConfigBuilder.newCategory(named: "New category", in: appState.config)
        editing = EditingCategory(id: draft.id, draft: draft)
    }

    /// Save from the sheet, for a category that is in the configuration and for one that is not
    /// yet. The sheet closes only when the write went through: a refusal — the settings lock, or
    /// the lock on a group this list shrinks under — would otherwise throw away every entry that
    /// was added on it.
    private func save(_ edited: DistractionCategory, isNew: Bool) -> String? {
        var config = appState.config
        if isNew {
            config.categories.append(edited)
        } else if let index = config.categories.firstIndex(where: { $0.id == edited.id }) {
            config.categories[index] = edited
        } else {
            // Deleted from somewhere else while the sheet was open. There is nothing to write back
            // to, and re-adding it would resurrect a list the user threw away — so the sheet is
            // closed and the page says what happened to the edits it took. Answering `nil` here
            // read as "saved" and threw them away in silence.
            editing = nil
            problem = "“\(edited.name)” was deleted while it was open. Nothing was written."
            return problem
        }
        // An entry taken out of a list leaves every exception naming it dangling; see
        // `ConfigBuilder.pruningDanglingExceptions(in:)`.
        problem = appState.applyConfigEdit(ConfigBuilder.pruningDanglingExceptions(in: config))
        if problem == nil { editing = nil }
        return problem
    }

    private func commitRename(_ category: DistractionCategory) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != category.name else {
            renaming = nil
            return
        }
        var others = appState.config.categories
        others.removeAll { $0.id == category.id }
        let name = DistractionCategory.freeName(basedOn: trimmed, among: others)
        var config = appState.config
        guard let index = config.categories.firstIndex(where: { $0.id == category.id }) else {
            renaming = nil
            return
        }
        config.categories[index].name = name
        problem = appState.applyConfigEdit(config)
        // A refused write keeps the field open with what was typed still in it, so the only way to
        // act on the refusal is not to type the name again.
        if problem == nil { renaming = nil }
    }

    private func delete(_ category: DistractionCategory) {
        if editing?.id == category.id { editing = nil }
        if renaming == category.id { renaming = nil }
        problem = appState.applyConfigEdit(
            ConfigBuilder.removingCategory(category.id, from: appState.config)
        )
    }

    private func deleteMessage(for category: DistractionCategory) -> String {
        let count = ConfigBuilder.groupCount(usingCategory: category.id, in: appState.config)
        guard count > 0 else { return "No group is a member of it." }
        return "\(count) \(count == 1 ? "group is" : "groups are") a member. They stop claiming what it carries and keep everything of their own."
    }
}

/// A category id, as something a `.sheet(item:)` will accept.
///
/// `draft` is set only while the category is one that does not exist yet — "Add category" holds it
/// here rather than in the configuration. For an existing one it is `nil` and the sheet re-reads
/// by id, which is what keeps a sheet left open across an edit from somewhere else from writing
/// back what it was opened with.
private struct EditingCategory: Identifiable {
    let id: String
    var draft: DistractionCategory?
}

// MARK: - What is in one

/// The contents of one category: its websites and its apps, each removable, each with a way to
/// add more.
///
/// Two lists rather than one, because the two are read differently — a website always applies,
/// while a bundle id only means anything if that app is on this Mac — and because adding to them
/// asks different questions. The controls that add are the group editor's own two sheets, each
/// filling one of these lists: a picker built for this screen would be a second answer to "what
/// counts as a website", and the two would drift.
///
/// Everything happens on a draft and lands on Save. The alternative — writing each removal
/// straight through — would mean a category being edited is a category already changed for every
/// group that ticked it, one entry at a time, with no way back.
@MainActor
struct CategoryEditorSheet: View {
    let category: DistractionCategory
    let config: Config
    /// Answers with the reason the write did not happen, or `nil` when it did — and only in the
    /// second case does the caller close this sheet. The refusals it can come back with are shown
    /// on the page underneath, which this sheet is covering, so it has to say them itself.
    let onSave: (DistractionCategory) -> String?
    let onCancel: () -> Void

    @State private var draft: DistractionCategory
    @State private var refusal: String?
    /// What `AppScanner` found, so an app can be listed under the name the Finder gives it.
    @State private var installed: [String: String] = [:]

    init(
        category: DistractionCategory,
        config: Config,
        onSave: @escaping (DistractionCategory) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.category = category
        self.config = config
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(draft.name).font(.headline)
                InfoButton("Every group that ticked this list blocks what is in it, so an entry added here starts being blocked in all of them at once. Nothing is written until Save.")
                Spacer(minLength: 0)
            }
            Text(GroupSummary.targets(apps: draft.bundleIDs.count, sites: draft.domains.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    websites
                    Divider().overlay(Palette.hairline)
                    apps
                }
                .padding(.trailing, 4)
            }
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(18)
        // Shorter than the window's own minimum height, so the sheet is never the thing that
        // cannot fit: what it holds scrolls, the frame does not grow to meet it.
        .frame(width: 460, height: 600)
        .onAppear {
            installed = Dictionary(
                AppScanner.scan().map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first }
            )
        }
    }

    // MARK: - The two lists

    private var websites: some View {
        list(
            title: "Websites",
            empty: "No websites in it yet.",
            note: "Each covers everything under it: youtube.com is also m.youtube.com.",
            entries: draft.domains.map { Entry(id: $0, label: $0) },
            kind: .domain,
            alreadyThere: siteIDs,
            onRemove: { host in draft.domains.removeAll { $0 == host } },
            onAdd: { targets in
                for target in targets where !draft.domains.contains(target.value) {
                    draft.domains.append(target.value)
                }
            }
        )
    }

    /// Apps are listed whether or not they are installed here, and named by their bundle id when
    /// they are not. The group editor hides the missing ones — nothing can bring an app this Mac
    /// does not have to the front, so counting it would promise something — but this is the list
    /// itself, and an entry nobody can see is an entry nobody can take out.
    private var apps: some View {
        list(
            title: "Apps",
            empty: "No apps in it yet.",
            note: "An app that is not installed here is kept and shown by its bundle id.",
            entries: draft.bundleIDs.map { Entry(id: $0, label: installed[$0] ?? $0) },
            kind: .app,
            alreadyThere: appIDs,
            onRemove: { bundleID in draft.bundleIDs.removeAll { $0 == bundleID } },
            onAdd: { targets in
                for target in targets where !draft.bundleIDs.contains(target.value) {
                    draft.bundleIDs.append(target.value)
                }
            }
        )
    }

    private struct Entry: Identifiable {
        let id: String
        let label: String
    }

    private func list(
        title: String,
        empty: String,
        note: String,
        entries: [Entry],
        kind: TargetKind,
        alreadyThere: Set<String>,
        onRemove: @escaping (String) -> Void,
        onAdd: @escaping ([Target]) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The note is on the heading rather than under the list. It says how an entry is read,
            // which is true of every entry there will ever be — so it belongs where the rest of
            // this app's explanations are, behind the `i`.
            HStack(spacing: 5) {
                Text(title).font(.callout.weight(.medium))
                InfoButton(note)
                Spacer(minLength: 0)
            }
            if entries.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.label).font(.caption).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button { onRemove(entry.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Take \(entry.label) out of this category")
                                .accessibilityLabel("Take \(entry.label) out of this category")
                        }
                    }
                }
            }
            addButton(kind, alreadyThere: alreadyThere, onAdd: onAdd)
        }
    }

    /// The group editor's own add sheets, filling this list instead of a group.
    ///
    /// `AlreadyThere.list` is what makes that difference: a site some group happens to block is
    /// still free to go in a category, so "already there" has to mean *this list* — and the sheet
    /// says "Already there" rather than "Already blocked", which no group has said.
    @ViewBuilder
    private func addButton(
        _ kind: TargetKind, alreadyThere: Set<String>, onAdd: @escaping ([Target]) -> Void
    ) -> some View {
        switch kind {
        case .domain:
            AddWebsiteButton(config: config, alreadyThere: .list(alreadyThere)) { target in
                onAdd([target])
                // Nothing has been written yet — this is a draft — so there is nothing to refuse.
                return nil
            }
        case .app:
            AddAppsButton(config: config, alreadyThere: .list(alreadyThere)) { targets in
                onAdd(targets)
                return nil
            }
        }
    }

    // MARK: - Saving

    private var siteIDs: Set<String> {
        Set(draft.domains.map { Target.id(ofKind: .domain, value: $0) })
    }

    private var appIDs: Set<String> {
        Set(draft.bundleIDs.map { Target.id(ofKind: .app, value: $0) })
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 12)
            Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
            Button("Save") { refusal = onSave(draft) }.keyboardShortcut(.defaultAction)
        }
    }
}
