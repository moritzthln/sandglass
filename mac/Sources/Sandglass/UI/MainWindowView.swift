import SandglassAppCore
import SandglassCore
import SwiftUI

/// The whole main window: a fixed sidebar that selects, and a scrolling page that edits.
///
/// It replaces the two-tab settings window. The sidebar's three zones are the part worth
/// copying exactly from the reference — fixed top, scrolling middle, pinned bottom — because a
/// group list that grows must never be able to push navigation off the screen.
///
/// Which page is showing is `@State` here rather than anything published: it is a fact about
/// this window, not about the app, and a second window (there is never one) would rightly have
/// its own. Every edit still goes through `AppState.applyConfigEdit`, whose refusals land in
/// `problem` and are shown above whatever page raised them — except on the two pages made of
/// cards, where each card says its own, because this banner is at the top of a scroll view.
///
/// **Two banners, and they are not the same thing.** `problem` is one click's answer, inside the
/// page, scrolling with it; `lockBanner` is a standing condition, over the page, ticking.
/// The one is why that press did nothing and the other is for how much longer — which is why the
/// refusal no longer carries a number of its own. See `lockBanner`.
@MainActor
struct MainWindowView: View {
    let appState: AppState

    @State private var selection: Selection
    @State private var problem: String?
    /// The group a card is being dragged over, or `nil` when nothing is. Only the dashed marker
    /// reads it; where the groups actually sit is `Config.groupOrder`.
    @State private var dropTarget: String?

    enum Selection: Hashable {
        case settings
        case presets
        case stats
        case group(String)
    }

    /// Shuts the window. Only the door uses it, and only for Escape — see `SettingsDoorView`.
    private let close: () -> Void

    /// `initialSelection` exists for the manual test harness — `SANDGLASS_OPEN=group` opens the
    /// window straight into the editor, because a sidebar card cannot be clicked from a script.
    /// Everything else opens on Settings.
    init(
        appState: AppState, initialSelection: Selection = .settings, close: @escaping () -> Void
    ) {
        self.appState = appState
        self.close = close
        _selection = State(initialValue: initialSelection)
    }

    /// The door comes first, and it is the whole window rather than a sheet over it: with a
    /// passcode set and this visit unanswered, nothing here is readable — not how a group is
    /// configured, and not the numbers screen either. What decides it is `SettingsDoor`, and only
    /// the passcode holds it: the timer goes on refusing *changes* on the far side, because "have
    /// you sat with this for ten minutes" is not a question worth asking of somebody who came to
    /// read. The window keeps its own size and its own traffic lights either way.
    var body: some View {
        Group {
            if door.isClosed {
                SettingsDoorView(appState: appState, close: close)
            } else {
                shell
            }
        }
        .frame(
            minWidth: Metrics.minWindowWidth, maxWidth: .infinity,
            minHeight: Metrics.minWindowHeight, maxHeight: .infinity
        )
    }

    private var door: SettingsDoor {
        SettingsDoor(lock: appState.config.settingsLock, state: appState.settingsLockState)
    }

    private var shell: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Palette.hairline)
            VStack(spacing: 0) {
                lockBanner
                page
            }
        }
        // A refusal describes the edit that was refused. Moving to another page is the user
        // doing something else, and the reason comes straight back if they try again.
        //
        // And the group being left is told to the visit, because a wait switched on for it during
        // this visit arms here rather than at the next window open: the exemption exists so nobody
        // is locked out of the stepper they are standing at, and stepping away is the end of it.
        // See `AppState.settingsGroupLeft`.
        .onChange(of: selection) { previous, _ in
            problem = nil
            if case .group(let groupID) = previous { appState.settingsGroupLeft(groupID) }
        }
    }

    /// The lock countdown — the whole app's one copy of it, ticking.
    ///
    /// **Over the page only, and not in the `problem` slot.** It first spanned the whole window,
    /// sidebar included, on the argument that the lock holds the sidebar's `+` too; the page
    /// alone is the better trade, and a fair one — the sidebar keeps its calm and its eighth group
    /// card, and somebody pressing `+` under the lock still gets the refusal as the page's own
    /// line, just on the press rather than before it. Not the `problem` slot, because that is the
    /// answer to one click, sits inside the scroll view, and may be scrolled away; this is a
    /// standing condition and must not be. With the number gone from the refusals, "Held by the
    /// settings lock" below and the count up here are one sentence in two halves.
    ///
    /// **On a group's page it counts the group's own wait too — and never two numbers.** What is
    /// shown is the effective wait over the page in front of the user, which is the longer of the
    /// two; the rule and the reasoning behind it are `LockBanner`'s. A group's own wait had
    /// no live copy anywhere before this, so the one lock with a lifecycle worth watching — it
    /// starts at a code, or at a page being left — was the one nobody could see.
    ///
    /// It is drawn from `settingsLockState` and `groupLockStates`, which the 1 Hz loop republishes,
    /// so it counts rather than reporting the second it was built in — which is the whole
    /// complaint. It goes away with the waits, and it is inside `shell` rather than `body`: with
    /// the app-wide passcode owed the window is `SettingsDoorView`, and a countdown over that door
    /// would be a fact about a room nobody has been let into. A *group's* door is a page inside a
    /// window somebody has been let into, so the band stands over it — and says nothing new there,
    /// because a wait behind an unanswered code has not started.
    @ViewBuilder
    private var lockBanner: some View {
        if let seconds = bannerSeconds {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .imageScale(.small)
                Text(LockBanner.text(seconds))
                    .font(.callout)
                    // Or the whole line shifts under itself once a second as the digits change
                    // width, which is exactly the sort of movement a slim band must not have.
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.sidebar)
            Divider().overlay(Palette.hairline)
        }
    }

    /// What the band counts down over the page that is showing. See `LockBanner`.
    private var bannerSeconds: Int? {
        LockBanner.secondsLeft(
            global: appState.settingsLockState.unlockSeconds, group: shownGroupLockSeconds
        )
    }

    /// The wait belonging to the group whose page is up, or `nil` on every other page — where
    /// there is no group for a second number to be about.
    ///
    /// `resolved` rather than `selection`, so a group deleted from its own editor cannot leave the
    /// band counting down a lock nobody can reach any more.
    private var shownGroupLockSeconds: Int? {
        guard case .group(let groupID) = resolved else { return nil }
        return appState.groupLockStates[groupID]?.unlockSeconds
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            Divider().overlay(Palette.hairline)
            VStack(alignment: .leading, spacing: 2) {
                SidebarNavRow(
                    icon: "gearshape", title: "Settings", isActive: resolved == .settings
                ) { selection = .settings }
                // Under Settings rather than beside Stats at the bottom: what is pinned down
                // there is the one page that reports rather than configures, and presets and
                // categories are configuration — the parts a group is assembled from.
                SidebarNavRow(
                    icon: "square.grid.2x2", title: "Presets", isActive: resolved == .presets
                ) { selection = .presets }
                groupsHeader
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            groupList

            Divider().overlay(Palette.hairline)
            bottomNav
        }
        .frame(width: Metrics.sidebarWidth)
        .background(Palette.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            Image(systemName: "hourglass")
                .foregroundStyle(Color.accentColor)
            Text("Sandglass").font(.headline)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var groupsHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            // What a group *is* was the second half of the empty-list sentence, which meant it was
            // on screen exactly until somebody made their first group and never again after that.
            // Here it is readable at any point, and the empty list is left saying what to press.
            LabelWithInfo(
                "Groups",
                help: "A group is a handful of apps and websites that share one budget: one pause screen, one opens-per-day, one schedule. Splitting what you block into a few groups is how a strict evening and a loose lunchtime live in the same app."
            )
            Spacer(minLength: 0)
            presetPicker
            Button { addGroup(preset: defaultPreset) } label: {
                Image(systemName: "plus")
                    .imageScale(.small)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a group")
            .accessibilityLabel("Add a group")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// The only part of the sidebar that scrolls.
    ///
    /// **What it has to fit, and how much room it has to do it in.** Everything above and below
    /// is fixed — the brand, the two nav rows, the Groups header, the pinned Stats row — and what
    /// they leave at the 700-point window floor is 496 points. A card is 51 and the gap 8, so
    /// eight groups are visible without scrolling and the ninth is what starts it. That number is
    /// the budget any change to `GroupCard` is spending: measured, not guessed, by hanging this
    /// view in an off-screen window at 1000×700 and reading the scroll view's clip height.
    ///
    /// `lockBanner` spends 34 of those points — 33 of band and the hairline under it, measured the
    /// same way — for as long as a wait runs, which costs the eighth card. A list under a lock
    /// therefore starts scrolling one group sooner. Accepted: the banner is up for minutes at a
    /// time and a scroll view is what the extra card would land in anyway. It is the same 34
    /// whichever lock raised it, because there is only ever one band — see `LockBanner`.
    private var groupList: some View {
        ScrollView {
            VStack(spacing: 8) {
                if groups.isEmpty {
                    Text("No groups yet. Press + to make one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                ForEach(groups) { group in
                    card(for: group)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity)
    }

    /// One card, with both things it can be the subject of: a click that selects it, and a drag
    /// that moves it.
    ///
    /// **Every card is a drop target, and that is the point.** `.onMove` is a `List`'s, and this
    /// is a `ForEach` in a scrolling stack — so the drop has to be written, and a single zone
    /// around the whole list could only ever tell top from bottom. A row each means every slot in
    /// the order is somewhere a card can be let go of, which is what makes dropping *between* two
    /// groups possible; what a drop on a row means is `ConfigBuilder.movingGroup(_:onto:in:)`.
    ///
    /// The drag does not take the click with it — but only because `GroupCard` is built on a tap
    /// gesture rather than a `Button`. It was a button first, and on macOS that meant the card
    /// could not be dragged at all: the button holds the mouse down and `.draggable` never sees
    /// the movement it starts on. See the note on `GroupCard.body`.
    private func card(for group: ConfigGroup) -> some View {
        let row = appState.budgetsByGroup.first { $0.id == group.id }
        return GroupCard(
            group: group,
            todayLine: todayLine(for: group, row: row),
            isBlocked: row?.reason != nil,
            isOpen: row?.isOpen ?? false,
            isSelected: resolved == .group(group.id),
            isDropTarget: dropTarget == group.id
        ) {
            selection = .group(group.id)
        }
        .draggable(DraggedGroup(groupID: group.id))
        .dropDestination(for: DraggedGroup.self) { dropped, _ in
            move(dropped.first, onto: group.id)
        } isTargeted: { isOver in
            // Only this row may put the marker out, and only this row may take it back: leaving
            // one card and entering the next arrive in whichever order they arrive in, and a
            // plain `nil` on the way out can land after the next row has already claimed it.
            if isOver { dropTarget = group.id } else if dropTarget == group.id { dropTarget = nil }
        }
    }

    /// Where the drop would land, and nothing else — the arrangement itself is in the
    /// configuration, so this is the one piece of the drag that is state.
    private func move(_ dragged: DraggedGroup?, onto groupID: String) -> Bool {
        dropTarget = nil
        guard let dragged else { return false }
        let updated = ConfigBuilder.movingGroup(
            dragged.groupID, onto: groupID, in: appState.config
        )
        // A card dropped on itself, or one carrying an id this configuration no longer holds.
        // Nothing to save, and nothing to refuse: `false` puts the card back where it came from.
        guard updated != appState.config else { return false }
        problem = appState.applyConfigEdit(updated)
        return problem == nil
    }

    /// Pinned, so the group list can never push it away. The reference's browser-permission
    /// entry became a section inside Settings → Protection, and its URL tester was built and
    /// then taken out again. What is left is the numbers screen, which the two-tab window used
    /// to hold and which nothing else shows.
    private var bottomNav: some View {
        SidebarNavRow(icon: "chart.bar", title: "Stats", isActive: resolved == .stats) {
            selection = .stats
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: - Page

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                content
            }
            .padding(Metrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }

    @ViewBuilder
    private var content: some View {
        switch resolved {
        case .settings:
            SettingsPageView(appState: appState)
        case .presets:
            PresetsPageView(appState: appState)
        case .stats:
            StatsPageView(appState: appState)
        case .group(let groupID):
            if let group = groups.first(where: { $0.id == groupID }) {
                GroupEditorView(
                    appState: appState, group: group, problem: $problem,
                    // A copy is made to be edited, so the window moves to it the moment it
                    // exists — the source's page staying up would leave the button looking
                    // like it did nothing.
                    onDuplicated: { selection = .group($0) }
                ) {
                    selection = .settings
                }
                // Rebuilds the editor's own local state — the rename field, which segment is
                // showing — when the sidebar moves to another group.
                .id(groupID)
            }
        }
    }

    // MARK: - Reading the configuration

    private var groups: [ConfigGroup] { ConfigBuilder.groups(in: appState.config) }

    /// The selection, corrected for a group that no longer exists. A group deleted from its own
    /// editor leaves the selection pointing at nothing, and the honest answer is the page that
    /// is always there rather than an empty right-hand side.
    private var resolved: Selection {
        if case .group(let id) = selection, !groups.contains(where: { $0.id == id }) {
            return .settings
        }
        return selection
    }

    /// Where the day stands — unless the group is blocked, in which case where the day stands is
    /// not the question. "2 of 5 opens" over a group nobody can open until 08:00 is a true number
    /// answering something nobody asked; the engine's own "Blocked until 08:00" is the answer.
    ///
    /// The same reasoning reaches one case further: a group whose windows cover the whole week is
    /// never on a budget at any moment, so it has no day to report even when nothing is blocking it
    /// this second. `GroupSummary.today` is where that is decided, off the week handed to it —
    /// which is why the block line above is not passed on, it has already won by then.
    private func todayLine(for group: ConfigGroup, row: BudgetRow?) -> String {
        if let row, row.reason != nil { return row.line }
        // No row at all is the engine having nothing to say about this group: it holds neither a
        // target, nor a live category, nor a rule. Such a group cannot spend an open, so a budget
        // beside it is an advertisement for something that cannot happen — the card read "Nothing
        // in it yet" on the left and "5 of 5 opens left" on the right, at once. The pill in the
        // editor has always known to say one thing there; see `EditorState.pill`.
        guard row != nil else { return "" }
        return GroupSummary.today(
            opensUsed: appState.stats.opensUsedToday[group.id] ?? 0,
            opensPerDay: group.settings?.opensPerDay,
            usageSeconds: appState.stats.usageSecondsToday[group.id] ?? 0,
            dailyMinutes: group.settings?.dailyMinutes,
            windows: group.settings?.timeWindows ?? []
        )
    }

    /// The same button, with the settings chosen up front.
    ///
    /// `+` makes a group and then you set it up; this makes the one you already know you want.
    /// Beside the button rather than inside it, because the plain `+` is still the answer nine
    /// times out of ten and burying it one menu deep would cost every one of them a click.
    ///
    /// Every row says what its preset holds, and it matters more here than in the editor: the
    /// group being chosen for does not exist yet, so there is nothing else on the screen to read
    /// the choice against. See `PresetPicker` for why this is a popover and not a `Menu`.
    @ViewBuilder
    private var presetPicker: some View {
        if !appState.config.presets.isEmpty {
            PresetPicker(rows: PresetChoices.forNewGroup(appState.config.presets)) { presetID in
                addGroup(preset: appState.config.presets.first { $0.id == presetID })
            } trigger: {
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a group on a preset")
            .accessibilityLabel("Add a group on a preset")
        }
    }

    /// What `+` on its own means: the first preset in the list, or plain Standard values when the
    /// user has deleted every last one of them.
    private var defaultPreset: NamedPreset? { appState.config.presets.first }

    /// Made straight away rather than behind a naming dialog: the editor's own header renames
    /// it, and one click that produces an empty group beats two that produce the same thing.
    private func addGroup(preset: NamedPreset?) {
        var settings = ConfigBuilder.settings(forPreset: preset, current: .standard)
        // With no presets left at all, `.standard`'s own marker names one that is not there. The
        // group is Custom, and saying so on disk beats writing an id nothing answers to.
        if preset == nil { settings.presetID = nil }
        let (updated, groupID) = ConfigBuilder.addingGroup(
            named: "New group", to: appState.config, settings: settings
        )
        problem = appState.applyConfigEdit(updated)
        guard problem == nil else { return }
        selection = .group(groupID)
    }
}
