import SandglassAppCore
import SandglassCore
import SwiftUI

/// Writing one advanced rule: a pattern, how it is matched, what it does, and whether it
/// outranks the rest.
///
/// Four controls, deliberately flat. Priority is a toggle rather than a third value on the
/// action control, and the match type is a control rather than something inferred from whether
/// the pattern looks like a path — a rule the app guessed the meaning of is a rule nobody can
/// debug. Every one of them has its sentence next to it, because a rule list is only readable
/// if each rule was readable while it was written.
///
/// Nothing is written until the button, and it is refused for a pattern that is empty or nothing
/// but spaces — a rule matching every address is not a rule. `Esc` cancels; a sheet does not
/// dismiss on a click outside, which is the behaviour wanted here and the one AppKit
/// already gives.
///
/// **A form rather than a sheet, because the editor is reached two ways.** The pencil on a listed
/// rule opens `AdvancedRuleSheet`; a *new* rule is written in the advanced mode of
/// `AddWebsiteSheet`, where adding a website already lives — `RuleMatcher` only ever asks a rule
/// about a URL, so making one belongs with the other thing that is only ever a URL. Two copies of
/// these four controls would drift into two rules that mean slightly different things.
@MainActor
struct AdvancedRuleForm: View {
    /// The rule being changed, or `nil` to write a new one.
    let existing: Rule?
    /// What the button that writes it says. `Save` over a rule that already exists; `Add` where
    /// one is being made beside websites, which is what everything else on that sheet does.
    var saveTitle = "Save"
    /// Answers with the reason the write did not happen, or `nil` when it did. Shown here rather
    /// than left to the page underneath, which this form's host is covering — a button that stays
    /// open and says nothing reads as broken.
    let onSave: (Rule) -> String?
    let onCancel: () -> Void

    @State private var pattern = ""
    @State private var matchType: Rule.MatchType = .websiteOrText
    @State private var action: Rule.Action = .block
    @State private var highPriority = false
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            patternField
            ruleTypeRow
            actionRow
            priorityRow
            Divider().overlay(Palette.hairline)
            footer
        }
        .onAppear(perform: load)
    }

    // MARK: - The four controls

    private var patternField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Pattern").font(.caption).foregroundStyle(.secondary)
            TextField("Enter pattern (e.g. youtube.com)", text: $pattern)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSave { save() } }
            // Said out loud rather than left as a Save button that will not press: "www." is
            // something somebody types on the way to a rule, and a disabled button with no
            // reason next to it reads as the sheet being broken.
            if !pattern.isEmpty, !canSave {
                Text("A scheme and a “www.” are dropped from every address, so this leaves nothing to match on.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var ruleTypeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Rule type").font(.caption).foregroundStyle(.secondary)
            SegmentedControl(
                selection: $matchType,
                options: [
                    SelectOption(Rule.MatchType.websiteOrText, "Website or text"),
                    SelectOption(Rule.MatchType.specificPage, "Specific page"),
                ]
            )
            Text(RuleCopy.matchTypeDetail(matchType, action: action))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionRow: some View {
        SettingsRow("Action") {
            SegmentedControl(
                selection: $action,
                options: [
                    SelectOption(Rule.Action.allow, "Allow"),
                    SelectOption(Rule.Action.block, "Block"),
                ]
            )
            .frame(width: 160)
        }
    }

    private var priorityRow: some View {
        SettingsRow("High priority", help: RuleCopy.priorityHelp) {
            SettingsToggle(isOn: $highPriority, label: "High priority")
        }
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
            Button(saveTitle, action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    /// Asked of what will actually be **stored**, not of what has been typed. `Rule.init`
    /// normalizes on the way in, and a pattern that survives a whitespace check can still come out
    /// of that as an empty string — see `RuleMatcher.isActionable(pattern:matchType:)`.
    private var canSave: Bool {
        RuleMatcher.isActionable(pattern: pattern, matchType: matchType)
    }

    // MARK: - Reading and writing the draft

    private func load() {
        guard let existing else { return }
        pattern = existing.pattern
        matchType = existing.matchType
        action = existing.action
        highPriority = existing.highPriority
    }

    /// An edit keeps the rule's id, so the list does not reorder itself under the user and the
    /// declaration order — which is the matcher's last tie-break — survives a correction.
    private func save() {
        guard canSave else { return }
        refusal = onSave(Rule(
            id: existing?.id ?? UUID().uuidString,
            pattern: pattern,
            matchType: matchType,
            action: action,
            highPriority: highPriority
        ))
    }
}

/// One rule on its own sheet: what the pencil beside a listed rule opens.
///
/// **Only ever an edit.** Making a new one moved into `AddWebsiteSheet`'s advanced mode, on the
/// grounds that a rule is only ever about a URL — see `AdvancedRuleForm`. So this sheet no longer
/// takes an optional rule, and its title no longer has two readings to choose between.
@MainActor
struct AdvancedRuleSheet: View {
    let existing: Rule
    let onSave: (Rule) -> String?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(Palette.hairline)
            AdvancedRuleForm(existing: existing, onSave: onSave, onCancel: onCancel)
        }
        .padding(18)
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Edit advanced rule").font(.headline)
            InfoButton(RuleCopy.introHelp)
            Spacer(minLength: 0)
        }
    }
}
