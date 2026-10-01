import SandglassAppCore
import SandglassCore
import SwiftUI

/// The presets, as a list the user owns.
///
/// Gentle, Standard and Strict are seeded on first load and are ordinary rows here: rename them,
/// move their knobs, throw them away. What they were before was an enum, which meant the three
/// the app shipped with were the three there could ever be — and "block this the way I block
/// everything else" had no answer but moving eight knobs on every group by hand.
///
/// Deleting takes nothing away from a group. A group holds its own copy of the values plus the
/// id it came from, so a deleted preset costs it a label and not one setting; the confirmation
/// says how many groups that is, because "3 groups use this" is the fact somebody needs before
/// they press the button rather than after.
@MainActor
struct PresetsCard: View {
    let appState: AppState

    /// Why the last write did not take, shown at the foot of this card rather than in the page's
    /// banner at the top of a scroll view. See `PresetsPageView`.
    @State private var problem: String?

    /// Which preset the knobs sheet is about, or `nil` while it is closed. The id rather than the
    /// value, so a sheet left open across an edit from somewhere else re-reads rather than
    /// writing back what it was opened with.
    @State private var editing: EditingPreset?
    @State private var renaming: String?
    @State private var draftName = ""
    @State private var deleting: NamedPreset?

    private var presets: [NamedPreset] { appState.config.presets }

    var body: some View {
        SettingsCard(
            "Presets",
            help: "Settings you have prepared, to put on a group in one go. Not levels of strictness: a preset is whatever its own settings say. A group made from one keeps its own copy, so editing or deleting a preset never changes a group that is already on it."
        ) {
            if presets.isEmpty {
                SettingsStateRow(
                    text: "No presets. Every group is Custom until you make one.", tone: .secondary
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(presets) { row($0) }
                }
            }
            PrimaryWideButton(title: "Add preset", action: add).padding(.top, 10)
            if let problem {
                SettingsStateRow(text: problem, tone: .warning)
            }
        }
        .sheet(item: $editing) { sheet in
            if let preset = sheet.draft ?? presets.first(where: { $0.id == sheet.id }) {
                PresetEditorSheet(preset: preset) { edited in
                    save(edited, isNew: sheet.draft != nil)
                } onCancel: {
                    editing = nil
                }
            }
        }
        .alert(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { preset in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(preset) }
        } message: { preset in
            Text(deleteMessage(for: preset))
        }
    }

    // MARK: - One row

    @ViewBuilder
    private func row(_ preset: NamedPreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if renaming == preset.id {
                renameRow(preset)
            } else {
                nameRow(preset)
            }
            Text(PresetCopy.detail(of: preset))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.page, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
    }

    private func nameRow(_ preset: NamedPreset) -> some View {
        HStack(spacing: 10) {
            Text(preset.name).font(.callout)
            Spacer(minLength: 8)
            icon("pencil", "Edit \(preset.name)") { editing = EditingPreset(id: preset.id) }
            icon("textformat", "Rename \(preset.name)") {
                draftName = preset.name
                renaming = preset.id
            }
            icon("trash", "Delete \(preset.name)") { deleting = preset }
        }
    }

    private func renameRow(_ preset: NamedPreset) -> some View {
        HStack(spacing: 8) {
            TextField("Preset name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename(preset) }
            Button("Save") { commitRename(preset) }
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

    /// A new preset starts from Standard's values rather than from nothing: an empty settings
    /// object is not a thing anybody wants, and the sheet opens on it straight away.
    ///
    /// **Nothing is written here.** It used to save the preset and then open the sheet on it, so
    /// Cancel left a "New preset" nobody had agreed to behind in the list — and a Cancel that
    /// creates the thing it was cancelling is the one behaviour a Cancel button may not have. The
    /// draft lives in the sheet's item until Save.
    private func add() {
        let draft = ConfigBuilder.newPreset(
            named: "New preset", settings: .standard, in: appState.config
        )
        editing = EditingPreset(id: draft.id, draft: draft)
    }

    /// Save from the sheet, for a preset that is in the configuration and for one that is not yet.
    ///
    /// The sheet closes only when the write went through: a refusal — the settings lock, a strict
    /// window — would otherwise throw away everything that was set on it, and say so on a page
    /// the sheet is covering.
    private func save(_ edited: NamedPreset, isNew: Bool) -> String? {
        var config = appState.config
        if isNew {
            config.presets.append(edited)
        } else if let index = config.presets.firstIndex(where: { $0.id == edited.id }) {
            config.presets[index] = edited
        } else {
            // Deleted from somewhere else while the sheet was open. There is nothing to write
            // back to, and re-adding it would resurrect a preset the user threw away.
            editing = nil
            return nil
        }
        problem = appState.applyConfigEdit(config)
        if problem == nil { editing = nil }
        return problem
    }

    private func commitRename(_ preset: NamedPreset) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != preset.name else {
            renaming = nil
            return
        }
        var others = appState.config.presets
        others.removeAll { $0.id == preset.id }
        let name = NamedPreset.freeName(basedOn: trimmed, among: others)
        write(preset.id) { $0.name = name }
        // A refused write keeps the field open with what was typed still in it. Closing it threw
        // the name away and left a refusal explaining a change with nothing on screen to show
        // for it, so the only way to act on the refusal was to type the name again.
        if problem == nil { renaming = nil }
    }

    private func delete(_ preset: NamedPreset) {
        // A sheet left open on a preset that is no longer there would be a sheet with nothing in
        // it and no way out. It cannot happen from this screen — the sheet covers the row the
        // trash button is on — and it costs one line to make sure it cannot happen at all.
        if editing?.id == preset.id { editing = nil }
        if renaming == preset.id { renaming = nil }
        problem = appState.applyConfigEdit(
            ConfigBuilder.removingPreset(preset.id, from: appState.config)
        )
    }

    private func deleteMessage(for preset: NamedPreset) -> String {
        let count = ConfigBuilder.groupCount(usingPreset: preset.id, in: appState.config)
        guard count > 0 else { return "Nothing is using it." }
        return "\(count) \(count == 1 ? "group is" : "groups are") on it. They keep their settings and show as Custom."
    }

    /// The sheet writes the whole preset back; renaming writes one field. Both go through here so
    /// there is one path to the disk and one place a refusal is reported from.
    private func write(_ presetID: String, _ change: (inout NamedPreset) -> Void) {
        var config = appState.config
        guard let index = config.presets.firstIndex(where: { $0.id == presetID }) else { return }
        change(&config.presets[index])
        problem = appState.applyConfigEdit(config)
    }
}

/// A preset id, as something a `.sheet(item:)` will accept.
///
/// `draft` is set only while the preset is one that does not exist yet — "Add preset" holds it
/// here rather than in the configuration, so cancelling leaves nothing behind. For an existing
/// preset it is `nil` and the sheet re-reads from the configuration by id, which is what keeps a
/// sheet left open across an edit from somewhere else from writing back what it was opened with.
private struct EditingPreset: Identifiable {
    let id: String
    var draft: NamedPreset?
}

/// The settings, over a draft.
///
/// The very same cards the group editor shows, which is the whole point: "what does this block
/// with" is one question, and answering it in two places would be two screens drifting apart
/// from the day they were written. What differs is where the writes land — a draft here, the
/// running configuration there — and that is the binding's business, not the cards'.
///
/// The Time windows card included, with one row above it choosing what the preset does to a
/// group's week: leave it alone, clear it, or replace it with the one drawn here. The card was
/// hidden for a wave, back when a preset could not carry a week at all — and the row is what
/// keeps letting it carry one from being the bug that got it hidden. See
/// `NamedPreset.timeWindows`.
///
/// `onSave` answers with the reason the write did not happen, or `nil` when it did — and only in
/// the second case does the caller close this sheet. The refusals it can come back with are shown
/// on the page underneath, which this sheet is covering, so it has to say them itself.
@MainActor
struct PresetEditorSheet: View {
    let preset: NamedPreset
    let onSave: (NamedPreset) -> String?
    let onCancel: () -> Void

    @State private var draft: GroupSettings
    /// Which of the three states this preset's week is in, held apart from `draft` because
    /// `GroupSettings.timeWindows` has no room for the third — see `PresetWindowsRule`.
    @State private var windowsRule: PresetWindowsRule
    @State private var refusal: String?

    init(
        preset: NamedPreset, onSave: @escaping (NamedPreset) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.preset = preset
        self.onSave = onSave
        self.onCancel = onCancel
        // The draft's own windows are the card's working list, and start as whatever the preset
        // carries — empty for the two answers that carry none, so switching to "use these" opens
        // on a blank week rather than on somebody's leftovers.
        var settings = preset.settings
        settings.timeWindows = preset.timeWindows ?? []
        _draft = State(initialValue: settings)
        _windowsRule = State(initialValue: PresetWindowsRule.rule(for: preset.timeWindows))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(preset.name).font(.headline)
                InfoButton("Groups already on this preset are not changed: a group takes a copy of the settings when it is put on one. What is edited here is what the next group to pick it gets.")
                Spacer(minLength: 0)
            }
            Text(PresetCopy.detail(of: edited))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                // No preset control to hide: it belongs to a group, and lives in the group
                // editor's header. A preset cannot be put on a preset.
                GroupDetailColumn(settings: $draft, windowsRule: $windowsRule)
                    .padding(.trailing, 4)
            }
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        // Shorter than the window's own minimum height, so the sheet is never the thing that
        // cannot fit: what it holds scrolls, the frame does not grow to meet it.
        .frame(width: 460, height: 600)
    }

    /// The preset as this sheet would save it — also what the line under the title describes, so
    /// the summary and the write can never disagree about what is being edited.
    ///
    /// The preset's own settings never carry a group's belongings: a name, a switch, rules and
    /// categories are what a group brings to a preset, not what a preset hands out. Clearing them
    /// is what keeps `ConfigBuilder.settings(forPreset:current:)` honest.
    ///
    /// `settings.timeWindows` is cleared **and** the week is written to `NamedPreset.timeWindows`
    /// instead, which is the only place a preset's opinion about one lives. A preset written by
    /// an earlier build — the seeded Strict carried a Mon–Fri block — would otherwise keep a week
    /// inside its settings that nothing reads and nothing hands out.
    private var edited: NamedPreset {
        var edited = preset
        var settings = draft
        settings.presetID = preset.id
        settings.name = nil
        settings.enabled = true
        settings.rules = []
        settings.categories = []
        settings.categoryExceptions = []
        settings.timeWindows = []
        edited.settings = settings
        edited.timeWindows = windowsRule.windows(draft.timeWindows)
        return edited
    }

    private func save() {
        refusal = onSave(edited)
    }
}
