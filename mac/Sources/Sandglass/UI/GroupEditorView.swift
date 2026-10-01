import SandglassAppCore
import SandglassCore
import SwiftUI

/// One group, edited. The sidebar selects; this is the other half of the master–detail.
///
/// Four concepts live on this screen and must not be conflated:
///
/// | Control | Means |
/// |---|---|
/// | Header toggle | The group exists but does nothing when off. |
/// | Preset | A prepared set of settings, put on in one decision. Not its week. |
/// | Time windows | *When* it behaves differently from the rest of the week. |
/// | Window kind | *How hard* it blocks in there, not *whether* the group is on. |
///
/// Every edit goes straight through `AppState.applyConfigEdit`. There is no Apply button and
/// nothing is held back: a settings screen with unsaved state is a settings screen that can
/// disagree with what is actually blocking.
@MainActor
struct GroupEditorView: View {
    let appState: AppState
    let group: ConfigGroup
    @Binding var problem: String?
    /// Called with the id of the copy the header's duplicate button has just made, so that the
    /// thing holding the selection can move to it — a copy the user has to go and find in the
    /// sidebar is a copy they cannot tell was made.
    ///
    /// Declared **before** `onDeleted` and defaulted, so a call site passing one unlabelled
    /// trailing closure still binds it to `onDeleted`: the match is made by scanning the parameter
    /// list backwards, and the first function-typed parameter it meets wins.
    var onDuplicated: (String) -> Void = { _ in }
    /// Called when the group this editor is about has just been deleted.
    let onDeleted: () -> Void

    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmingDelete = false

    /// The door comes first, and it is the whole page rather than a sheet over it: with a
    /// passcode set on this group and this visit unanswered, nothing here is readable — not the
    /// knobs, not the week, and not what is in it. What decides it is `GroupDoor`, and only the
    /// passcode holds it: the group's own timer goes on refusing *changes* on the far side,
    /// because "have you sat with this for ten minutes" is not a question worth asking of somebody
    /// who came to read. The sidebar stays where it is either way — this is one page of a window
    /// that is otherwise open.
    var body: some View {
        Group {
            if door.isClosed {
                GroupDoorView(appState: appState, group: group)
            } else {
                page
            }
        }
    }

    private var door: GroupDoor {
        GroupDoor(name: group.name, state: appState.groupLockStates[group.id] ?? GroupLockState())
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            header
            frozenNotice
            // Everything below the banner writes `Config`, so everything below the banner goes
            // dead when the banner says nothing can be written. See `frozenOutright`.
            cards.disabled(frozenOutright)
        }
        .alert("Delete “\(group.name)”?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("Everything in the group goes with it. Nothing in it will be blocked any more.")
        }
    }

    // MARK: - Header

    /// Two rows: `[name] [pencil] [Preset ▾]  ···  [state pill] [switch] [copy] [trash]`, and
    /// under it the open that is running, when one is.
    ///
    /// **Six things on one row do not fit a 1000-point window, which is the width this window may
    /// be squeezed to.** All six on one line, with an open running and a group called "Social",
    /// left every third item ending in an ellipsis: `Social m…`, `End open (…`, `4 of 5 opens
    /// left to…`. The button was the worst of the three — "End open (earn back)" without its
    /// parenthesis has lost the whole reason to press it — and a title that cannot say the name
    /// of the thing the page is about is not far behind.
    ///
    /// The open is what moved, because it is the only part of this that comes and goes. The name,
    /// the preset, the pill, the switch and the trash are true of the group all day; a countdown
    /// and the button that ends it are true for five minutes. A row that appears for those five
    /// minutes costs nothing the rest of the time, and it leaves the top row about 250 points of
    /// slack — enough that an ordinary name never reaches the preset beside it.
    ///
    /// Left, not under the switch: "End open" directly below a delete button is a mis-click
    /// waiting to happen, and the countdown reads as a sentence about the group, which is what
    /// the left edge of this page is for.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The name, the preset, the switch and the trash all write `Config`. The open row
            // below does not — `AppState.endActiveSessionEarly` spends no edit and no lock stands
            // in its way — so it stays live under a freeze that stops everything else.
            titleRow.disabled(frozenOutright)
            openRow
        }
    }

    /// The two cards, or the notice that stands in for them.
    ///
    /// **Time windows stays on the right, and it now sits at the top of it.** The column reads
    /// week, then knobs, then lock, for every group and every preset — see `GroupDetailColumn
    /// .body` for why that order and why it never changes. The swap is inside one column, so it
    /// costs the page nothing: measured off-screen at the 1000-point floor, before and after, a
    /// two-target group with no window ends its left column at 250 points and its right at 940
    /// either way, and an eight-target group at 517 against the same 940.
    ///
    /// **What Time windows must not do is cross to the left**, and that was measured before it was
    /// left alone. Putting the windows card under Targets was built and measured a wave ago: the
    /// small group improved and the large one got worse, they crossed at about six targets, and
    /// neither arrangement won across the range a group can be. What varies is the Targets card
    /// and nothing else — about 44.5 points a target — so as it is the right column is a fixed 940
    /// with no window on the group and the left does not grow past it until about eighteen of
    /// them.
    ///
    /// Those numbers are the arrangement's floor rather than its shape: the right column is fixed
    /// only for a given week. One bedtime window puts it at 982, and a week with no gap in it
    /// takes the Settings card off the page entirely — see `EditorCards`.
    @ViewBuilder
    private var cards: some View {
        if group.settings == nil {
            unmanagedNotice
        } else {
            HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                TargetsCard(appState: appState, group: group, problem: $problem)
                // The Lock card is the group's and not the preset's, so it is added here rather
                // than inside the column: `GroupDetailColumn` is exactly the cards a group and a
                // preset share, and a preset is a template nothing can be locked to.
                VStack(spacing: Metrics.cardSpacing) {
                    GroupDetailColumn(
                        settings: settingsBinding, problem: $problem,
                        tighteningOnly: tighteningOnly, today: appState.today
                    )
                    GroupLockCard(
                        appState: appState, groupID: group.id,
                        settings: settingsBinding, problem: $problem,
                        tighteningOnly: tighteningOnly
                    )
                }
            }
        }
    }

    /// The preset stands on its own beside the name because that is what it is: a property of
    /// the group, like the name, and not a heading for the card of knobs it happens to write. It
    /// spent one wave in that card's title bar, where it read as a label for those seven rows.
    ///
    /// It hides while the name is being renamed, for the reason the pencil does: the field, its
    /// Save and its Cancel are what this row is for until the rename is finished.
    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            if renaming {
                TextField("Group name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                    .frame(maxWidth: 380)
                    .onSubmit(commitRename)
                Button("Save", action: commitRename)
                Button("Cancel") { renaming = false }
            } else {
                // Wraps rather than truncates. A name is the one string on this page that cannot
                // be guessed from what is left of it, and two lines of title cost less than a
                // page whose heading trails off.
                Text(group.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // Both of these edit `GroupSettings`, and a group that has none has nowhere to
                // put what they write: the pencil was offered anyway and the rename it opened
                // saved nothing, silently. The same reasoning as `unmanagedNotice` — no dead
                // controls. The button under that notice is what this group needs first.
                if group.settings != nil {
                    renameButton
                    GroupPresetPicker(
                        settings: settingsBinding, presets: appState.config.presets
                    )
                }
            }
            Spacer(minLength: 12)
            if group.settings != nil {
                statePill
                // The two controls on this page whose direction depends on where they already
                // are. Switching a group **off** ends everything it was doing, so a running lock
                // refuses it; switching one back **on** puts the block back and is free. Dead
                // rather than lying about it — pressing them was the only way to find out.
                SettingsToggle(isOn: enabled, label: "Group enabled")
                    .disabled(tighteningOnly && isOn)
                    .help(switchHelp)
                duplicateButton
            }
            // The trash has no such direction: a group that is gone blocks nothing, whichever
            // state it was in. See `frozenNotice` for the reason and the way out.
            Button { confirmingDelete = true } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(tighteningOnly)
            .help(deleteHelp)
            .accessibilityLabel("Delete this group")
        }
    }

    /// Whether the group's own switch is on, which is what decides which way pressing it points.
    private var isOn: Bool { group.settings?.enabled ?? false }

    private var switchHelp: String {
        guard !frozenOutright else { return Self.pageFrozenHelp }
        guard !(tighteningOnly && isOn) else { return Self.heldHelp }
        return group.isActive ? "This group is on" : "This group is off and blocks nothing"
    }

    private var deleteHelp: String {
        if frozenOutright { return Self.pageFrozenHelp }
        return tighteningOnly ? Self.heldHelp : "Delete this group"
    }

    /// What a control that cannot move says when the pointer rests on it. One sentence for all of
    /// them, and the banner above carries the full reason — a tooltip repeating three lines on
    /// every knob would be the page shouting. Which lock it is, and how long it has to run, is the
    /// banner's to say.
    private static let pageFrozenHelp = "Locked — the notice above says why"

    /// The same idea for the freeze that is a direction rather than a wall: this control's only
    /// remaining move would hand something back, and a lock is there to refuse exactly that.
    private static let heldHelp = "A lock is running — this would make the group easier"

    /// `textformat`, not a pencil. The Presets and Categories pages give every row all three
    /// glyphs at once — `pencil` opens what is in the thing, `textformat` renames it, `trash`
    /// deletes it — so somebody who learned the pencil there and pressed it here got a name field
    /// instead of the contents they were after. This page has no "edit the contents" button at
    /// all; the cards below are that. So the pencil is free to mean nothing here, and the glyph
    /// the rest of the app renames with is the one that belongs on it.
    private var renameButton: some View {
        Button {
            draftName = group.name
            renaming = true
        } label: {
            Image(systemName: "textformat")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Rename this group")
        .accessibilityLabel("Rename this group")
    }

    /// `doc.on.doc`, beside the trash and drawn exactly like it — the two things this header can
    /// do to the group as a whole.
    ///
    /// The page-wide freezes reach it, and correctly: `titleRow` is disabled whole under them, and
    /// a copy is a change made in the very window the settings lock stands in front of. What the
    /// copy does *not* carry is the original's lock — see `ConfigBuilder.duplicatingGroup`.
    ///
    /// Not offered on a group with no settings, for the reason the pencil and the preset picker
    /// are not: there is nothing to copy, and `ConfigBuilder.duplicatingGroup` says so in `nil`.
    private var duplicateButton: some View {
        Button(action: duplicate) {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Duplicate this group, without the apps and websites in it")
        .accessibilityLabel("Duplicate this group")
    }

    // MARK: - Where this group stands right now

    /// The one fact the editor was missing: what this group is doing *this second*.
    ///
    /// `Blocked until 08:00` · `3 of 5 opens left` · `Off`. The projection already works it out
    /// once a tick for the popover and the sidebar, so the editor was the one screen about a group
    /// that could not say what the group was up to. Beside the switch, because the switch is the
    /// other half of the same question.
    ///
    /// **It takes its width before the spacer does.** Without the priority the row hands every
    /// child an equal share and lets this one truncate into the ellipsis its `lineLimit` allows,
    /// while 70-odd points of `Spacer` sit empty beside it: at the 1000-point floor with both of a
    /// group's budgets on, "1 of 2 opens and 45 min left today" lost its last word to nothing. The
    /// name is unaffected either way — it wraps to its two lines at exactly the same point — and it
    /// is one short line against a title that has a whole column.
    private var statePill: some View {
        Text(state.text)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("This group right now: \(state.text)")
            .layoutPriority(1)
    }

    /// The open that is running on this group, and the only way to end it early.
    ///
    /// It was a row in the menu bar popover, which is now two items. Here is where it belongs
    /// anyway: it is a fact about one group, and this is the screen about one group — under the
    /// name, on a row of its own, because it is the one part of this header that comes and goes.
    /// See `header` for what sharing the title's row cost it.
    ///
    /// The button names the earn-back only where there is one. `RulesEngine.end` credits nothing
    /// unless the group asked for it, and two of the three seeded presets have it off — so over a
    /// Strict group the label was promising half an open the engine had no intention of giving.
    ///
    /// **Only the session that relocks first has a row**, which is what `activeSession` is: the
    /// group id is compared so a second group's open cannot be ended from a button standing next
    /// to this one's name. A group whose open ends later shows its pill and waits its turn.
    @ViewBuilder
    private var openRow: some View {
        if let session = appState.activeSession, session.groupID == group.id {
            HStack(spacing: 8) {
                Text(Self.countdown(session.secondsLeft))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                SecondaryPillButton(title: session.earnsBack ? "End open (earn back)" : "End open") {
                    appState.endActiveSessionEarly()
                }
            }
        }
    }

    private static func countdown(_ seconds: Int) -> String {
        String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }

    /// The words and which of the four states they are are `EditorState`'s; what is left here is
    /// the colour, which is the only part of it a test could not read.
    private var state: (text: String, tone: EditorState.Tone) {
        EditorState.pill(
            isActive: group.isActive,
            row: appState.budgetsByGroup.first { $0.id == group.id }
        )
    }

    private var tint: Color {
        switch state.tone {
        case .idle: return .secondary
        case .running: return .accentColor
        // The same colour the sidebar's shield uses for the same fact, because it is the same
        // fact: this group is on and holding nothing back this second.
        case .open: return Palette.windowTint(.break)
        case .blocked: return .red
        }
    }

    /// The two freezes that leave no direction open: an unanswered passcode — app-wide or this
    /// group's — and a focus session. Under either of them nothing on this page can be written at
    /// all, so all of it is drawn dead.
    ///
    /// The two waits are not here: a wait holds loosening and only loosening, so the page under
    /// one is narrowed rather than killed. That is `tighteningOnly`, and `EditorFreeze` is where
    /// the two questions are told apart.
    ///
    /// They were said in the banner and nowhere else, on the argument that there was no direction
    /// to draw. But the argument this file makes at `titleRow` is not about direction: a control
    /// that cannot move should be drawn as one, because pressing it was otherwise the only way to
    /// find out. Under the lock the page said "Nothing can change until then" over seven live-
    /// looking knobs, a switch and a delete button, and every one of them refused on the press.
    /// The sentence has since stopped being true as well — a wait holds only what loosens — which
    /// is why there are two questions here rather than one.
    ///
    /// The rule and the sentence come from the same place — see `EditorFreeze.freezesEverything`,
    /// which reads the same `lockNotice` the banner does.
    private var frozenOutright: Bool {
        EditorFreeze.freezesEverything(
            lock: appState.settingsLockState,
            groupLock: appState.groupLockStates[group.id],
            focusSessionLine: appState.focusSessionLine
        )
    }

    /// Whether a wait is standing over this page, in which case every control on it may still be
    /// turned towards more friction and none of them back.
    ///
    /// Read off the same values the banner is raised from, so a control and the sentence above it
    /// cannot disagree about whether a lock is running — the rule is `EditorFreeze.tighteningOnly`
    /// and the table behind it is `EditDirection`.
    private var tighteningOnly: Bool {
        EditorFreeze.tighteningOnly(
            lock: appState.settingsLockState,
            groupLock: appState.groupLockStates[group.id],
            focusSessionLine: appState.focusSessionLine
        )
    }

    /// What has already refused an edit here, before anything on the page is touched.
    ///
    /// The rule and the words are `EditorFreeze`'s. What is here is that the banner sits under the
    /// header rather than beside the control that would have raised it: every one of these freezes
    /// the whole page, so attaching it to one row would be saying it in the wrong place seven
    /// times over.
    @ViewBuilder
    private var frozenNotice: some View {
        let notices = EditorFreeze.notices(
            lock: appState.settingsLockState,
            groupLock: appState.groupLockStates[group.id],
            focusSessionLine: appState.focusSessionLine
        )
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notices, id: \.self) { notice in
                    Label(notice, systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        }
    }

    /// A group in the targets with no settings behind it is `.notManaged` — the engine will not
    /// touch it. Saying so, and offering the one-click fix, beats showing eight dead knobs.
    private var unmanagedNotice: some View {
        SettingsCard {
            SettingsStateRow(
                text: "This group has no settings, so nothing in it is being blocked.",
                tone: .warning
            )
            PrimaryWideButton(title: "Protect this group") {
                var config = appState.config
                config.groupSettings[group.id] = .standard
                problem = appState.applyConfigEdit(config)
            }
        }
    }

    // MARK: - Writing

    private var settingsBinding: Binding<GroupSettings> {
        GroupSettingsEditing.binding(appState: appState, groupID: group.id, problem: $problem)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { group.settings?.enabled ?? false },
            set: { isOn in
                var config = appState.config
                config.groupSettings[group.id]?.enabled = isOn
                problem = appState.applyConfigEdit(config)
            }
        )
    }

    /// An empty name is not a name: the group falls back to being called after its first target,
    /// which is what it was called before anybody renamed it.
    ///
    /// A refused rename keeps the field open with what was typed still in it. Closing it threw
    /// the name away and left a refusal explaining a change with nothing on screen to show for
    /// it, so the only way to act on the refusal was to type the name again.
    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = appState.config
        config.groupSettings[group.id]?.name = trimmed.isEmpty ? nil : trimmed
        problem = appState.applyConfigEdit(config)
        if problem == nil { renaming = false }
    }

    /// Everything but what is in the group, under a name of its own, and then selected.
    ///
    /// What is carried and what is not is `ConfigBuilder.duplicatingGroup`'s; what is here is that
    /// a refused copy leaves the selection exactly where it is, with the refusal on screen above —
    /// the same shape `delete` has, and for the same reason.
    private func duplicate() {
        guard let copy = ConfigBuilder.duplicatingGroup(group.id, in: appState.config) else {
            return
        }
        problem = appState.applyConfigEdit(copy.config)
        guard problem == nil else { return }
        onDuplicated(copy.groupID)
    }

    private func delete() {
        problem = appState.applyConfigEdit(
            ConfigBuilder.removingGroup(group.id, from: appState.config)
        )
        guard problem == nil else { return }
        onDeleted()
    }
}
