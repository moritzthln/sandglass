import SandglassAppCore
import SandglassCore
import SwiftUI

/// The button that opens the website sheet, and the sheet itself.
///
/// **Typing is the way in**, so the field has focus the moment the sheet opens and nothing stands
/// above it. The set of websites is open — every address there is — and no list anybody could
/// write covers it, which is why the field is the path and the history underneath is help.
///
/// The browsers on this Mac know what the week actually goes on, and that is a better suggestion
/// than a curated list: `Most visited` is the user's own history read back to them, filtering as
/// they type, and picking one is a single click. What it is not is the menu — a Mac whose browsers
/// have nothing to say leaves the field alone on the sheet, working exactly as well.
@MainActor
struct AddWebsiteButton: View {
    let config: Config
    /// What counts as already there, and what the sheet calls it. The group editor asks the
    /// configuration; the category editor hands over the list it is filling.
    var alreadyThere: AlreadyThere = .configuration
    /// Called with a new advanced rule, or `nil` to take that mode off the sheet entirely.
    ///
    /// The category editor never offers it: a category is a list of sites and apps, and a rule is
    /// something a *group* layers over one. A group used to withhold it inside a strict window,
    /// where the rules were frozen whole; nothing is frozen there any more.
    var onAddRule: ((Rule) -> String?)?
    /// Called with the website. Answers with the reason the write did not happen, or `nil` when it
    /// did — and only then does the sheet close.
    let onAdd: (Target) -> String?

    @State private var open = false

    /// Never the filled button. Both places that hold it offer two adds side by side, so neither
    /// is the main action of what it sits in — which is what a filled button would claim.
    var body: some View {
        SecondaryPillButton(title: "Add website") { open = true }
            .sheet(isPresented: $open) {
                AddWebsiteSheet(
                    config: config, alreadyThere: alreadyThere, onAddRule: onAddRule
                ) { target in
                    // Closing on a refusal would throw away what was typed and leave the reason
                    // on a page this sheet is covering. The same rule the rule sheet follows.
                    let refusal = onAdd(target)
                    if refusal == nil { open = false }
                    return refusal
                } onCancel: {
                    open = false
                }
            }
    }
}

/// One address, typed or recognised — **or the exact form of the same act**, which is a rule.
///
/// `Add advanced rule` used to be a third button on the targets card, beside two adds it had
/// nothing structurally to do with. It belongs here: `RuleMatcher` only ever asks a rule about a
/// URL, so a rule is a website written precisely, and this is the sheet where a website is added.
///
/// **A second mode rather than a second sheet.** The alternatives were both worse. Presenting the
/// rule editor *from* this sheet stacks two modals, which macOS draws as a sheet growing out of a
/// sheet and which no other part of this app does. Closing this one and asking the card to open
/// the other trades that for a dismiss-then-present in the same turn, which SwiftUI drops often
/// enough to be a bug report. One sheet with a segment at the top is the honest shape anyway: the
/// two forms are two ways of saying one thing, and the segment says which one is being used.
///
/// Nothing here removes anything: a website added to a group that is blocking is one more thing
/// blocked, and the rule mode writes a rule the same way.
@MainActor
struct AddWebsiteSheet: View {
    let config: Config
    var alreadyThere: AlreadyThere = .configuration
    /// Called with a new advanced rule, or `nil` when this sheet does not offer that mode.
    var onAddRule: ((Rule) -> String?)?
    /// Answers with the reason the write did not happen, which this sheet shows itself: the page
    /// that normally carries it is behind this sheet.
    let onAdd: (Target) -> String?
    let onCancel: () -> Void

    /// Which of the two forms is showing. Only ever `.rule` when `onAddRule` is there to take it.
    private enum Mode: Hashable { case address, rule }

    @State private var mode: Mode = .address

    @State private var text = ""
    /// What the browsers said, once they have been read. `nil` while that is still happening,
    /// which is a section that is not there yet rather than a spinner in a list.
    @State private var history: BrowserHistory.Ranking?
    @State private var refusal: String?
    /// Whether a press is already on its way out, for the length of this event turn.
    ///
    /// **Return reaches two handlers here**: the field's `onSubmit`, and the Add button's
    /// `.keyboardShortcut(.defaultAction)`. `add()` guards on `state`, which is derived from the
    /// passed-in `config` — and that cannot have changed within one turn, so a second delivery
    /// would find `.ready` again and hand over the same host twice. What that looks like is
    /// `Already blocked: youtube.com in “this group”` landing straight after a successful add:
    /// the sheet accusing the user of something it did itself.
    ///
    /// Whether AppKit actually delivers it twice is not something this file can settle, and a
    /// flag costs nothing either way. Not solved by clearing the field instead, which would throw
    /// away what was typed on a refusal — the one thing this sheet is built not to do.
    ///
    /// Cleared on the next turn rather than at the end of this one, so a refusal can still be
    /// tried again: the sheet stays open on one, and a dead Add is the wrong thing to leave.
    @State private var submitting = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(Palette.hairline)
            if mode == .rule, let onAddRule {
                // Its own Cancel closes the whole sheet, which is what Esc does from either mode:
                // the segment is how you change your mind about the form, not a place to go back
                // to. Nothing typed into the address is lost by it — that field keeps its state.
                AdvancedRuleForm(
                    existing: nil, saveTitle: "Add", onSave: onAddRule, onCancel: onCancel
                )
            } else {
                addressField
                suggestions
                Divider().overlay(Palette.hairline)
                footer
            }
        }
        .padding(18)
        .frame(width: 420)
        // Typing is the way in, so the field is what the sheet opens on. Both ways of saying so:
        // `defaultFocus` is the one that survives the sheet not being key yet when it appears, and
        // the `onAppear` covers a reopen of a sheet that is already on screen.
        .defaultFocus($focused, true)
        .onAppear { focused = true }
        // The refusal is about the address that was pressed Add on, so it stops being true the
        // moment that address changes. Left standing it contradicted the line under the field,
        // which had already moved on to what is being typed now — two sentences about one field,
        // disagreeing, and no way to tell which of them is the current one.
        .onChange(of: text) { refusal = nil }
        // Off the main thread and cached for the life of the process — see `BrowserHistoryCache`.
        // Ranked against what is already held, which nothing can change while this is open except
        // this sheet, and it closes on a successful add.
        .task {
            let answers = await BrowserHistoryCache.read()
            guard !Task.isCancelled else { return }
            history = BrowserHistory.rank(answers, excluding: alreadyThere.hosts(in: config))
        }
    }

    /// The title follows the form, and the segment underneath is how the form is changed.
    ///
    /// The segment is absent wherever the rule mode is — the category editor is the one place
    /// left — which leaves the sheet exactly as it was there.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(mode == .rule ? "Add advanced rule" : "Add a website").font(.headline)
                InfoButton(mode == .rule ? RuleCopy.introHelp : Self.websiteHelp)
                Spacer(minLength: 0)
            }
            if onAddRule != nil {
                SegmentedControl(
                    selection: $mode,
                    options: [
                        SelectOption(Mode.address, "Address"),
                        SelectOption(Mode.rule, "Advanced rule"),
                    ]
                )
            }
        }
    }

    private static let websiteHelp =
        "A website is blocked whole: youtube.com covers m.youtube.com and every page under it. "
        + "One page on its own, or anything that has to allow rather than block, is an advanced rule."

    // MARK: - The field

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Address").font(.caption).foregroundStyle(.secondary)
            TextField("youtube.com", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if state.canAdd { add() } }
            if let note = SiteField.note(for: text, alreadyThere: alreadyThere, config: config) {
                Text(note)
                    .font(.caption)
                    // Orange is for what stands in the way. The normaliser's own line — "adds
                    // youtube.com instead" — is not a problem, it is the sheet saying what it will
                    // do, so it reads as ordinary secondary text.
                    .foregroundStyle(state.canAdd ? Color.secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var state: SiteField.State {
        SiteField.state(of: text, alreadyThere: alreadyThere, config: config)
    }

    // MARK: - The history underneath

    /// The suggestions, and the one line about what could not be read.
    ///
    /// Both are absent when there is nothing to say. A section explaining that a Mac has no
    /// browser history is a paragraph nobody asked for on a sheet whose field works regardless —
    /// but a Safari user looking at a list with no Safari in it would conclude the feature is
    /// broken, and that fix is one sentence and one checkbox away.
    @ViewBuilder
    private var suggestions: some View {
        if let line = history?.line {
            Text(line)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        let sites = SiteField.matching(text, in: history?.sites ?? [])
        if !sites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text.isEmpty ? "Most visited" : "Matches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sites) { row($0) }
                    }
                    .padding(.trailing, 4)
                }
                .frame(height: sites.count > 5 ? 190 : nil)
            }
        }
    }

    /// A suggestion is one click: it adds and closes. The visit count comes with it because it is
    /// the whole argument for the row — "412 visits" is the user's own week, which is not
    /// something this app is in any position to make up.
    private func row(_ site: BrowserHistory.Site) -> some View {
        Button {
            refusal = onAdd(SiteField.target(forHost: site.host))
        } label: {
            HStack(spacing: 8) {
                Text(site.host).font(.callout)
                Spacer(minLength: 8)
                Text("\(site.visits) visits")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not "Block": this sheet also fills a category, and a list nobody has ticked yet blocks
        // nothing. What the row does is add, in both places.
        .help("Add \(site.host)")
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if let refusal {
            Label(refusal, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
            Spacer()
            Button("Add", action: add)
                .keyboardShortcut(.defaultAction)
                .disabled(!state.canAdd)
        }
    }

    private func add() {
        guard !submitting, let host = state.host, state.canAdd else { return }
        submitting = true
        refusal = onAdd(SiteField.target(forHost: host))
        Task { @MainActor in submitting = false }
    }
}
