import SandglassAppCore
import SandglassCore
import SwiftUI

/// The card that replaced the earlier Schedule and Strict-block accordions.
///
/// Those two were three concepts pretending to be two controls: an "always active" switch that
/// meant "has no window", a separate "always block" that meant "a window with no end", and one
/// window between them. A group owns a list of windows now, so the card is a picture of the
/// day, the list that made it, and one button.
///
/// The **preset** editor shows this same card rather than one of its own — same strip, same
/// list, same sheet — with one row above it choosing between the three states a preset's week
/// has. What a preset can prepare and what a group runs are the same thing, and two cards for it
/// would be two screens drifting apart from the day they were written.
@MainActor
struct TimeWindowsCard: View {
    @Binding var settings: GroupSettings
    /// Where the write behind `settings` reports its refusals. Read straight after a write, so
    /// the sheet can show the reason rather than leave it on the page it is covering — the other
    /// cards in this column write inline, where the page banner is the right place for it.
    var problem: Binding<String?> = .constant(nil)
    /// The three answers a **preset** gives about the week, or `nil` for a group — which has a
    /// week rather than an opinion about one, and therefore nothing to choose between. See
    /// `PresetWindowsRule`.
    var rule: Binding<PresetWindowsRule>?
    /// The day this moment is in, or `nil` in the **preset** editor.
    ///
    /// Two jobs in one value, and they agree by construction. It is what the quick spans are
    /// counted from and what tells a day still ahead from one already past; and `nil` is what takes
    /// the dated-block row off the card altogether, which is exactly right for a preset — a preset
    /// is a template and a dated block is a one-shot commitment, so no preset carries one (see
    /// `ConfigBuilder.settings(forPreset:current:)`). A row that could be set on a preset would
    /// write a date nothing would ever read.
    var today: String?
    /// Whether a lock is standing over the group, in which case the date may be pushed out and not
    /// pulled in — so the remove control goes dead and says why. Drawn per control for the reason
    /// `GroupDetailColumn.tighteningOnly` is: a wait holds a direction, not the page.
    var tighteningOnly = false

    @State private var sheet: Sheet?
    /// The window whose deletion would close the last gap in the week, while that is being
    /// confirmed. Deleting is otherwise immediate — there is nothing else on this card to undo.
    @State private var confirmingDelete: TimeWindow?
    /// Whether the date picker is up. Its own flag rather than a third `Sheet` case: it is about
    /// the group's one-shot block rather than about a window, and the sheet below is the window
    /// editor.
    @State private var pickingDate = false

    /// Adding starts with the kind, changing starts with the shape — the sheet decides which,
    /// and this only has to say whether there is an existing window behind it.
    private enum Sheet: Identifiable {
        case adding
        case editing(String)

        var id: String {
            switch self {
            case .adding: return "adding"
            case .editing(let windowID): return windowID
            }
        }
    }

    var body: some View {
        // The note is on the title rather than a first row under it. The row said "When this group
        // behaves differently", which is what "Time windows" already says two lines above it.
        SettingsCard("Time windows", help: helpText) {
            VStack(alignment: .leading, spacing: 12) {
                // Above the week, because it outranks the week: while a date stands, nothing the
                // rows underneath say about this group is reached at all.
                if let today { datedBlockRow(today) }
                if let rule { ruleRow(rule) }
                if showsWindows { windowList }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $pickingDate) {
            DatedBlockSheet(
                today: today ?? "",
                current: settings.blockedUntilDay,
                onDone: { settings.blockedUntilDay = $0; pickingDate = false },
                onCancel: { pickingDate = false }
            )
        }
        .sheet(item: $sheet) { which in
            TimeWindowSheet(
                existing: existing(for: which),
                closesTheWeek: closesTheWeek,
                onDone: { save($0) },
                onCancel: { sheet = nil }
            )
        }
        // The same question the sheet asks on the way in, in the same words: taking the one break
        // out of a seven-day block leaves exactly the state that dialogue exists to warn about.
        //
        // `presenting:` rather than reading `confirmingDelete` back inside the action. Pressing a
        // button both runs it and dismisses the alert, and the dismissal is what clears that
        // state — so an action reaching for it afterwards is a race with an empty answer, and a
        // Delete button that sometimes deletes nothing. This hands the window in.
        .alert(
            TimeWindowCopy.aroundTheClockTitle,
            isPresented: .init(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            presenting: confirmingDelete
        ) { window in
            Button("Cancel", role: .cancel) {}
            Button("Delete anyway", role: .destructive) { remove(window) }
        } message: { _ in
            Text(TimeWindowCopy.aroundTheClockMessage)
        }
    }

    // MARK: - Blocked until a day

    /// The group's one-shot block: unset, one control that offers the lengths; set, the day it
    /// reaches and a way out of it.
    ///
    /// One row in two states rather than two rows, because it is one fact. The card underneath is a
    /// picture of a repeating week and this is the sentence that suspends it, so it sits on top and
    /// says its whole self in a line.
    @ViewBuilder
    private func datedBlockRow(_ today: String) -> some View {
        if let day = DatedBlock.standing(settings.blockedUntilDay, onDay: today) {
            SettingsRow(DatedBlock.rowText(day), help: Self.datedHelp) {
                SecondaryPillButton(title: "Remove") { settings.blockedUntilDay = nil }
                    .disabled(tighteningOnly)
                    .help(tighteningOnly ? Self.heldHelp : "End this block now")
            }
        } else {
            SettingsRow("Block until a day", help: Self.datedHelp) {
                Menu {
                    // Each length carries the day it reaches, so what is being bought is read
                    // before it is bought rather than worked out afterwards. See `DatedBlock.Span`.
                    ForEach(DatedBlock.Span.allCases, id: \.self) { span in
                        Button(DatedBlock.spanTitle(span, from: today)) {
                            settings.blockedUntilDay = DatedBlock.day(span, from: today)
                        }
                    }
                    Divider()
                    Button("A date…") { pickingDate = true }
                } label: {
                    Text("Block until…")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private static let datedHelp =
        "Shuts everything in this group until the day you choose begins — once, rather than every"
        + " week. It outranks the windows below while it stands, break windows included, and the"
        + " ordinary week takes over again the moment the day arrives.\n\nThe day begins when this"
        + " app's day does, which is the same moment a daily budget comes back; move that in"
        + " Settings and this moves with it.\n\nSetting one, or pushing it further out, always goes"
        + " through. Pulling it in or removing it is a loosening, so a lock on this group holds it"
        + " — and the week's emergency pass lifts it for the hour unless this group ignores the"
        + " pass."

    /// The same sentence the group editor's held controls say: this control's only remaining move
    /// would hand something back, and a lock is there to refuse exactly that.
    private static let heldHelp = "A lock is running — this would make the group easier"

    // MARK: - Rows

    /// A group's windows are its own week; a preset's are a week it may hand to one, so the same
    /// sentence would name a group that is not on the screen. The half about overlapping is the
    /// same either way — it is a fact about windows rather than about who holds them.
    private var helpText: String {
        let overlap = "Where two windows overlap, a break wins over a strict block; outside every window the group runs its ordinary budget."
        return rule == nil
            ? "When this group behaves differently from the rest of its week. \(overlap)"
            : "The week a group put on this preset gets. \(overlap)"
    }

    /// A group always shows its week. A preset shows one only where it has one to show: the other
    /// two answers hand out no windows, so a strip and a list under them would be a picture of
    /// something the preset never gives anybody.
    private var showsWindows: Bool {
        guard let rule else { return true }
        return rule.wrappedValue == .use
    }

    @ViewBuilder
    private var windowList: some View {
        TimelineStripView(windows: windows)
        if windows.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 6) {
                ForEach(windows) { row($0) }
            }
        }
        PrimaryWideButton(title: "Add time window") { sheet = .adding }
    }

    /// The empty list says something different to a preset: a preset with no windows drawn hands
    /// out no windows, which is what the answer beside it already means — so the sentence names
    /// what to do about it rather than describing a group that is not there.
    private var emptyText: String {
        rule == nil
            ? "No windows yet, so this group behaves the same way all week."
            : "No windows yet. Add the ones a group put on this preset should get."
    }

    private func row(_ window: TimeWindow) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.windowTint(window.kind)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(TimeWindowCopy.kind(window.kind)).font(.callout)
                Text(TimeWindowCopy.schedule(window)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { delete(window) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete this time window")
            .accessibilityLabel("Delete this time window")
            Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.page, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .contentShape(Rectangle())
        .onTapGesture { sheet = .editing(window.id) }
        .contextMenu {
            Button("Delete", role: .destructive) { delete(window) }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - What a preset does to a group's week

    /// One control with three answers, above the card it governs.
    ///
    /// A switch and a list would be the same thing said twice, and would leave "carries windows,
    /// but none drawn" as a fourth state nobody meant. The caption spells the consequence out,
    /// because a menu row has to be short and this is the only screen where the difference
    /// between the three can be read before it happens.
    private func ruleRow(_ rule: Binding<PresetWindowsRule>) -> some View {
        SettingsRow(
            "What it does to a group's week",
            help: "A preset can leave a group's time windows alone, clear them, or replace them. Picking a preset applies whichever of the three this is, without asking again.",
            caption: rule.wrappedValue.detail
        ) {
            SettingsSelect(
                selection: rule,
                options: PresetWindowsRule.allCases.map { SelectOption($0, $0.title) }
            )
        }
    }

    // MARK: - Reading and writing

    private var windows: [TimeWindow] { settings.timeWindows }

    private func existing(for sheet: Sheet) -> TimeWindow? {
        guard case .editing(let windowID) = sheet else { return nil }
        return windows.first { $0.id == windowID }
    }

    /// One path for both adding and changing.
    ///
    /// The sheet closes only when the write actually landed. `settings` reads back the running
    /// configuration, so a refusal — the settings lock's passcode or timer — leaves the list
    /// exactly as it was, and closing on that would throw away the window the user had just drawn.
    /// The reason is handed back for the sheet to say itself, because the page that carries it is
    /// the one this sheet is covering.
    private func save(_ window: TimeWindow) -> String? {
        let updated = TimeWindowList.merging(window, into: windows)
        write(updated)
        if windows == updated { sheet = nil }
        return problem.wrappedValue
    }

    /// Whether saving this window would leave the group's week without one uncovered minute —
    /// the question the sheet asks before it closes.
    ///
    /// Not a trap, and the warning is not a refusal: a week with no gap in it blocks the group
    /// every minute of the week, which is a real thing to walk into by nudging a stepper and a
    /// perfectly reasonable thing to want. It freezes nothing — the knobs, the switch, the delete
    /// button and this card all go on working. The rule is `TimeWindowList`'s; what is here is
    /// asking it about this group's list.
    private func closesTheWeek(_ window: TimeWindow) -> Bool {
        TimeWindowList.closesTheWeek(
            TimeWindowList.merging(window, into: windows), replacing: windows
        )
    }

    /// The trash button, which asks first when the week would close behind it.
    private func delete(_ window: TimeWindow) {
        let remaining = TimeWindowList.removing(window.id, from: windows)
        guard TimeWindowList.closesTheWeek(remaining, replacing: windows) else {
            write(remaining)
            return
        }
        confirmingDelete = window
    }

    private func remove(_ window: TimeWindow) {
        confirmingDelete = nil
        write(TimeWindowList.removing(window.id, from: windows))
    }

    /// Straight through the binding, like every other control in this editor — which for a group
    /// means `applyConfigEdit`.
    ///
    /// This used to be the one card in the editor a strict window did not freeze — everything
    /// else about a blocked group was held. Nothing is: a window blocks, and what may be changed
    /// is the settings lock's question. The settings lock, app-wide or this group's own, applies
    /// here as it does everywhere.
    private func write(_ updated: [TimeWindow]) {
        settings.timeWindows = updated
    }
}
