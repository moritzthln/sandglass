import SandglassAppCore
import SandglassCore
import SwiftUI

/// The button that opens the app sheet, and the sheet itself.
///
/// The set of apps is closed — what is installed on this Mac — so this one is a list to tick
/// rather than a field to type in. **Multi-select**, because ticking four apps in one pass is the
/// normal case: websites are singular by nature and apps are not.
///
/// **What is running goes on top.** You usually block the thing that just distracted you, and it
/// is the one app somebody can name without thinking.
@MainActor
struct AddAppsButton: View {
    let config: Config
    /// What counts as already there, and what the sheet calls it. The group editor asks the
    /// configuration; the category editor hands over the list it is filling.
    var alreadyThere: AlreadyThere = .configuration
    /// Called with everything ticked, in the order the list offered it. Answers with the reason
    /// the write did not happen, or `nil` when it did — and only then does the sheet close.
    let onAdd: ([Target]) -> String?

    @State private var open = false

    /// Never the filled button, for the reason `AddWebsiteButton` is not: it stands beside that
    /// one, and two filled buttons side by side name no main action at all.
    var body: some View {
        SecondaryPillButton(title: "Add apps") { open = true }
            .sheet(isPresented: $open) {
                AddAppsSheet(config: config, alreadyThere: alreadyThere) { targets in
                    // Closing on a refusal threw the whole selection away — `picked` is the
                    // sheet's own state and dies with it — and left the reason on a page the sheet
                    // was covering. Ten ticked apps, gone, to act on a refusal nobody saw.
                    let refusal = onAdd(targets)
                    if refusal == nil { open = false }
                    return refusal
                } onCancel: {
                    open = false
                }
            }
    }
}

/// Two sections, one search, and one Add.
///
/// Nothing here removes anything: ticking and unticking change a selection this sheet is holding,
/// and only Add reaches the configuration.
@MainActor
struct AddAppsSheet: View {
    let config: Config
    var alreadyThere: AlreadyThere = .configuration
    /// Answers with the reason the write did not happen, which this sheet shows itself: the page
    /// that normally carries it is behind this sheet.
    let onAdd: ([Target]) -> String?
    let onCancel: () -> Void

    /// Read once per open, from the cache `AppScanner` keeps for the life of the process.
    @State private var installed: [TargetPicker.App] = []
    /// Read once per open and **not** cached: what is running is the one thing on this sheet that
    /// is different every time it opens.
    @State private var running: [TargetPicker.App] = []
    @State private var search = ""
    @State private var picked: Set<String> = []
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextField("Search apps", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    section("Running now", rows: sections.running)
                    section("All apps", rows: sections.all)
                    if sections.isEmpty { nothingFound }
                }
                .padding(.trailing, 4)
            }
            .frame(height: 320)
            Divider().overlay(Palette.hairline)
            footer
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            installed = AppScanner.scan().map {
                TargetPicker.App(bundleID: $0.bundleID, name: $0.name)
            }
            running = AppScanner.running()
        }
        // The refusal names the apps that were ticked when Add was pressed, so changing the
        // selection makes it a sentence about apps that are no longer picked. The search is not
        // watched: it changes what is on screen and not what would be added.
        .onChange(of: picked) { refusal = nil }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Add apps").font(.headline)
            InfoButton(
                "A blocked app cannot be brought to the front while the group is blocking. Browsers are not on this list: blocking one would block the web whole, and websites are blocked one at a time."
            )
            Spacer(minLength: 0)
        }
    }

    // MARK: - The two lists

    /// Both sections, filtered by one search and each keeping its heading. A running app is in
    /// both: it is a shortcut into the list, not a list of its own.
    private var sections: AppChoices.Sections {
        AppChoices.sections(
            running: running, installed: installed, alreadyThere: alreadyThere, config: config,
            search: search
        )
    }

    @ViewBuilder
    private func section(_ title: String, rows: [TargetCandidate]) -> some View {
        if !rows.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows) { row($0) }
        }
    }

    private func row(_ candidate: TargetCandidate) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: binding(candidate)) { Text(candidate.label).font(.callout) }
                .disabled(candidate.alreadyBlocked)
            Spacer(minLength: 8)
            if candidate.alreadyBlocked {
                Text(alreadyThere.label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var nothingFound: some View {
        Text(search.isEmpty ? "No apps found on this Mac." : "No app on this Mac matches.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// An app already in the list reads as ticked and cannot be unticked: the tick is the fact
    /// that it is there, and nothing on this sheet takes anything away.
    private func binding(_ candidate: TargetCandidate) -> Binding<Bool> {
        Binding(
            get: { candidate.alreadyBlocked || picked.contains(candidate.id) },
            set: { isOn in
                if isOn { picked.insert(candidate.id) } else { picked.remove(candidate.id) }
            }
        )
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
            Button(resolved.isEmpty ? "Add" : "Add \(resolved.count)", action: add)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
        }
    }

    /// What Add would actually write, resolved once so the count and the action cannot disagree.
    ///
    /// The footer used to count `picked`, which is ticks rather than targets: a row that has
    /// become already blocked since it was ticked is dropped on the way out, so `Add 3` could
    /// write one. Both read this now, and a selection that resolves to nothing is answered by
    /// the card — see `TargetAdd.adding(_:toGroup:in:)`.
    ///
    /// Resolved against every app on offer rather than against what the search currently shows:
    /// a tick survives the field being typed in, and a selection made in three searches is one
    /// decision. `AppChoices.everything` is also what keeps an app that is both running and
    /// installed from being added twice.
    private var resolved: [Target] {
        TargetPicker.targets(
            picked: picked,
            from: AppChoices.everything(
                running: running, installed: installed, alreadyThere: alreadyThere, config: config
            )
        )
    }

    private func add() {
        refusal = onAdd(resolved)
    }
}
