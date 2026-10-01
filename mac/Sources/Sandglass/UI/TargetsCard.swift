import SandglassAppCore
import SandglassCore
import SwiftUI

/// What the group is about: the categories it is a member of, the websites and apps in it, and
/// the advanced rules layered over them.
///
/// **Everything a group blocks is on screen at once.** There used to be a `Sites | Apps` segment
/// here, which hid half of it behind a click — on the one card whose whole job is to say what a
/// group blocks. The three lists are sections instead, each with its count, each gone entirely
/// when it is empty, so a group of websites is not three-quarters empty headings.
///
/// **The two adds lead**, because they are what somebody came here to do. `Add website` and
/// `Add apps` are two buttons and two sheets because they are two different questions — see
/// `AddWebsiteSheet` and `AddAppsSheet`, and note that the advanced rule is a mode of the first
/// of them rather than a button of its own: a rule is only ever about a URL.
///
/// Under them the **category picker**, which is the fastest way in and the only one that keeps
/// working on its own: ticking Social makes the group a live member of that list, so a site added
/// to the list next month is blocked here without anybody touching this screen. It sits directly
/// above the list it fills.
///
/// Then the lists, in the order of how much each one covers: **Categories**, **Websites**,
/// **Apps**, **Rules**. The card used to open on two switches — whitelist mode and adult
/// websites — and it opens on its buttons now that both are gone.
///
/// Targets remain one `[Target]` on `Config` with a `kind`. The sections are a view over that
/// list and nothing in the engine knows about them.
@MainActor
struct TargetsCard: View {
    let appState: AppState
    let group: ConfigGroup
    @Binding var problem: String?
    /// What the last add could not do — a site or an app that turned out to be blocked elsewhere.
    /// A note about one click rather than a state of the group.
    @State private var addProblem: String?
    /// Which rule the editor is open over, or `nil` while it is closed.
    ///
    /// A plain `Rule?` since making a new one moved into the website sheet. It used to be a
    /// two-case enum whose `.new` had no rule to carry, which meant a sheet taking an optional and
    /// a title with two readings — all of it to express "this one, or none".
    @State private var editing: Rule?
    /// Read once per open, from the cache `AppScanner` keeps for the life of the process — the
    /// category rows need it to name their apps and to leave out the ones nobody has installed.
    @State private var installed: [String: String] = [:]

    var body: some View {
        SettingsCard(
            "Targets",
            help: "What this group is about, in three layers. Add website and Add apps put in one thing at a time, and a website covers everything under it. A category is a live membership: ticking one blocks whatever is in that list, including anything added to it later. An advanced rule is the exact layer — allow or block, a text match or one page, and a priority for when two of them disagree; it is a mode of the Add website sheet, because a rule is only ever about a URL."
        ) {
            // The card reads top to bottom the way it is used: what you came to do, then the way
            // into the first list, then the lists themselves.
            addControls
            CategoryPickerButton(
                catalogue: appState.config.categories,
                picked: settings.categories,
                installed: installed,
                onToggle: toggle
            )
            .padding(.top, 10)
            Divider().overlay(Palette.hairline).padding(.top, 12)
            sections
        }
        .onAppear {
            installed = Dictionary(
                AppScanner.scan().map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first }
            )
        }
        .sheet(item: $editing) { edited in
            AdvancedRuleSheet(existing: edited) { rule in
                // Only closed when it landed. `settings` reads the running configuration back, so
                // a refused write leaves the rules as they were — and closing on that would lose a
                // pattern, a match type, an action and a priority. The reason is handed back for
                // the sheet to say itself: the page that normally carries it is behind the sheet,
                // so a Save that stayed open and silent read as a dead button.
                let refusal = save(rule)
                if self.settings.rules.contains(rule) { self.editing = nil }
                return refusal
            } onCancel: {
                self.editing = nil
            }
        }
    }

    // MARK: - The ways in

    /// Two buttons, one per kind of thing a group is made of.
    ///
    /// Two adds rather than one picker, because a website and an app are picked in opposite ways:
    /// the set of apps is closed and gets recognised in a list, and the set of websites is open
    /// and gets typed. Neither is filled, since neither is *the* main action of the card.
    ///
    /// **`Add advanced rule` used to be a third button here and is not any more.** A rule is only
    /// ever about a URL — `RuleMatcher` never asks one about anything else — so making one is the
    /// exact form of adding a website, and it lives in that sheet as a second mode. The rules
    /// themselves are still listed on this card, and still edited from it.
    ///
    /// Nothing on this card is drawn dead any more. A strict window used to freeze the group's
    /// scope against shrinking and its rules whole, so `onAddRule` was withheld and every button
    /// that takes something away was disabled. A window blocks and freezes nothing; what closes
    /// this card is the group's own lock, and that closes the whole page rather than one control.
    private var addControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AddWebsiteButton(
                    config: appState.config,
                    onAddRule: { save($0) }
                ) { add([$0]) }
                AddAppsButton(config: appState.config, onAdd: add)
                Spacer(minLength: 8)
            }
            if let addProblem {
                Text(addProblem).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Straight into *this* group, whatever it is called.
    ///
    /// What the selection comes to is `TargetAdd`, which is arithmetic on values and checked as
    /// such; this half is the two places the answer goes. Answers with the reason nothing
    /// happened, so the sheet can keep its selection and say why rather than closing over it —
    /// **including a selection that resolved to nothing**, which used to answer `nil` and read as
    /// a successful add. **A selection that landed only in part still closes**, with its note
    /// left on the card: something did happen, and holding a sheet open over a list that has
    /// changed underneath is worse than showing the sentence where the list is.
    @discardableResult
    private func add(_ targets: [Target]) -> String? {
        problem = nil
        let outcome = TargetAdd.adding(targets, toGroup: group.id, in: appState.config)
        addProblem = outcome.problem
        guard !outcome.added.isEmpty else { return outcome.problem }
        problem = appState.applyConfigEdit(outcome.config)
        // A refused write replaces the note rather than joining it. Both sentences are true —
        // one site was already blocked, and the lock then turned the whole edit down — but the
        // second makes the first a report on an edit that did not happen, and one click leaving
        // two orange lines on the card reads as two things having gone wrong.
        if problem != nil { addProblem = nil }
        return problem
    }

    // MARK: - What is in the group

    /// The four lists, in the order the group was filled: the general before the specific, and the
    /// exceptions last.
    ///
    /// A section with nothing in it is not drawn at all — heading included. A card of empty
    /// headings would be four labels saying what the group does not block.
    @ViewBuilder
    private var sections: some View {
        let sites = group.siteTargets
        let apps = group.appTargets
        let rules = settings.rules
        if sites.isEmpty, apps.isEmpty, rules.isEmpty, pickedCategories.isEmpty {
            SettingsStateRow(text: emptyText, tone: .secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                section("Categories", rows: pickedCategories) { categoryRow($0) }
                section("Websites", rows: sites) { targetRow($0) }
                section("Apps", rows: apps) { targetRow($0) }
                section("Rules", rows: rules) { ruleRow($0) }
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private func section<Item: Identifiable, Row: View>(
        _ title: String, rows: [Item], @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                heading(title, count: rows.count)
                ForEach(rows) { row($0) }
            }
        }
    }

    private func heading(_ title: String, count: Int) -> some View {
        Text(RuleCopy.sectionHeading(title, count: count))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// The categories this group is a live member of, in the order the picker offers them — so
    /// the row order matches the picker's and neither reshuffles itself between redraws.
    ///
    /// **`group` is not a snapshot**, whatever this used to say. `MainWindowView` recomputes
    /// `ConfigBuilder.groups(in: appState.config)` on every body pass and hands a fresh
    /// `ConfigGroup` down, so ticking a category redraws this card with the new value — which is
    /// just as well, because the sections below read their websites and apps straight off it.
    ///
    /// This one still goes through `settings`, which answers the same list `group.categories`
    /// carries: everything that writes on this card reads a group's settings that way, and one
    /// route in is worth more than saving a lookup.
    private var pickedCategories: [DistractionCategory] {
        ConfigBuilder.categories(of: settings, in: appState.config)
    }

    private func categoryRow(_ category: DistractionCategory) -> some View {
        CategoryTargetRow(
            category: category,
            settings: settings,
            installed: installed,
            onRemoveMember: { targetID in edit { $0.categoryExceptions.insert(targetID) } },
            onUntick: { toggle(category, isOn: false) }
        )
    }

    private var emptyText: String { "Nothing in this group yet." }

    // MARK: - The rows

    /// A plain target: what it is, and a way to take it away.
    ///
    /// No second line. It used to read `Block · Website or text match` under every website and
    /// `Block · App` under every app, which is the section heading said again in a smaller font on
    /// every row. No edit either — one line is quicker to retype than a form is to open.
    ///
    /// Taking a target out of a group that is blocking is refused, so inside the window the trash
    /// is dead. Adding one is not refused and both buttons above stay live: it lands inside the
    /// window and is blocked by it from that second.
    private func targetRow(_ target: Target) -> some View {
        row(icon: nil, title: RuleCopy.rowTitle(target), subtitle: nil, edit: nil) {
            problem = appState.applyConfigEdit(
                ConfigBuilder.removing(targetID: target.id, from: appState.config)
            )
        }
    }

    /// A rule, which is the only thing on this card that can **allow**.
    ///
    /// So the allow rules are the ones drawn to stand out — the tick in the accent colour, the
    /// cross left in secondary text. Blocking is the normal case and does not need to shout; an
    /// exception does, because an exception is what somebody comes looking for when a thing they
    /// expected to be blocked is not.
    ///
    private func ruleRow(_ rule: Rule) -> some View {
        row(
            icon: rule.action,
            title: rule.pattern,
            subtitle: RuleCopy.summary(rule),
            edit: { editing = rule }
        ) {
            edit { $0.rules.removeAll { $0.id == rule.id } }
        }
    }

    private func row(
        icon: Rule.Action?,
        title: String,
        subtitle: String?,
        edit: (() -> Void)?,
        delete: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon { glyph(icon) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).textSelection(.enabled)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let edit {
                iconButton("pencil", label: "Edit \(title)", action: edit)
            }
            iconButton("trash", label: "Remove \(title)", action: delete)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.page, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
    }

    private func glyph(_ action: Rule.Action) -> some View {
        let allows = action == .allow
        return Image(systemName: allows ? "checkmark" : "xmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(allows ? Color.accentColor : Color.secondary)
            .padding(.top, 3)
            .accessibilityLabel(allows ? "Allows" : "Blocks")
    }

    private func iconButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }

    // MARK: - Writing

    private var settings: GroupSettings {
        appState.config.settings(forGroup: group.id) ?? .standard
    }

    /// An edit keeps the rule's place in the list when it already has one, because declaration
    /// order is the matcher's last tie-break: a correction must not silently reorder the rules.
    @discardableResult
    private func save(_ rule: Rule) -> String? {
        edit { settings in
            guard let index = settings.rules.firstIndex(where: { $0.id == rule.id }) else {
                settings.rules.append(rule)
                return
            }
            settings.rules[index] = rule
        }
    }

    /// The refusal is answered *and* posted to the page. Both callers need one of the two: the
    /// category picker is a popover over the page and shows it itself; the row's own trash button
    /// is on the page, where the banner is already the right place for it.
    @discardableResult
    private func toggle(_ category: DistractionCategory, isOn: Bool) -> String? {
        edit { ConfigBuilder.toggle(category, on: isOn, in: &$0) }
    }

    /// The preset marker is re-derived like everywhere else, even though none of this changes
    /// it: rules say what is in scope, not what the group blocks it with. Doing it anyway keeps
    /// one rule about how settings are written rather than two.
    ///
    /// Answers with the refusal as well as posting it, for the callers that are covering the page
    /// it would otherwise be the only copy of.
    @discardableResult
    private func edit(_ transform: (inout GroupSettings) -> Void) -> String? {
        guard var updated = appState.config.settings(forGroup: group.id) else { return nil }
        transform(&updated)
        updated.presetID = ConfigBuilder.presetID(matching: updated, in: appState.config.presets)
        var config = appState.config
        config.groupSettings[group.id] = updated
        problem = appState.applyConfigEdit(config)
        return problem
    }
}
