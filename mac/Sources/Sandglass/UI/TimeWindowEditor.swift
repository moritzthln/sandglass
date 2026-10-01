import SandglassAppCore
import SandglassCore
import SwiftUI

/// Adding or changing one time window, in two phases.
///
/// A new window is a kind first and a shape second, because the kind is the only decision that
/// changes what the other controls *mean*: the same 22:00–08:00 is a bedtime block or an
/// evening off depending on it. An existing window skips straight to the shape — the kind is
/// already answered, and re-asking it every time would make an edit feel like a re-creation.
///
/// Nothing is written until Done. This is the one screen in the app with a Cancel, and it has
/// one because a half-drawn window is a window that blocks the wrong hours.
@MainActor
struct TimeWindowSheet: View {
    /// The window being changed, or `nil` to add one.
    let existing: TimeWindow?
    /// Whether saving this window would leave the group's week with no uncovered minute. The
    /// sheet cannot answer that itself — it is a question about the whole list, which the card
    /// behind it owns.
    let closesTheWeek: (TimeWindow) -> Bool
    /// Answers with the reason the write did not happen, or `nil` when it did. Shown here for the
    /// reason the rule sheet shows its own: the page that carries refusals is behind this sheet.
    let onDone: (TimeWindow) -> String?
    let onCancel: () -> Void

    @State private var draft: TimeWindow?
    @State private var confirming = false
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            // `Binding($draft)`, and not `if let draft { Binding(get: { draft }, …) }`, which is
            // what this was and why nothing in the editor stuck. `if let draft` binds a **local
            // constant**, so the getter closed over a snapshot taken when `body` last ran, and
            // every write became get-copy-mutate-set against a frozen value. A preset chip writes
            // three fields in a row and each one reverted the last, so a chip set the weekdays and
            // threw both times away. This overload reads through to the state on every get.
            if let draft = Binding($draft) {
                TimeWindowEditor(window: draft)
            } else {
                kindChoice
            }
            Divider().overlay(Palette.hairline)
            footer
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { draft = existing }
        .alert(TimeWindowCopy.aroundTheClockTitle, isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            // "Save anyway" when the window already exists: the same question now reaches an
            // edit that turns a break into a block, and "Add" would name the wrong act.
            Button(existing == nil ? "Add anyway" : "Save anyway") {
                if let draft { refusal = onDone(draft) }
            }
        } message: {
            Text(TimeWindowCopy.aroundTheClockMessage)
        }
    }

    private var title: String {
        guard let draft else { return "Add a time window" }
        return existing == nil ? "New \(TimeWindowCopy.kind(draft.kind).lowercased())"
                               : TimeWindowCopy.kind(draft.kind)
    }

    // MARK: - Phase one

    /// Three rows rather than a segmented control: each kind needs a sentence, and a segment
    /// with a sentence under it is a row wearing a costume.
    private var kindChoice: some View {
        VStack(spacing: 8) {
            ForEach(TimeWindow.Kind.allCases, id: \.self) { kind in
                // A new window opens on the work day. It always did — `make(.custom, …)` fell
                // back to exactly these values — it just used to say Custom while doing it.
                Button { draft = TimeWindow.make(.workDay, kind: kind) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Palette.windowTint(kind)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(TimeWindowCopy.kind(kind)).font(.callout.weight(.medium))
                            Text(TimeWindowCopy.kindDetail(kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Palette.page, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
            }
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
            if let draft {
                // `commitDraft()` rather than `commit(draft)`, because `draft` here is the local
                // constant `if let` binds — a snapshot of the last time `body` ran, which is the
                // same trap the editor's binding fell into above. It matters as of the two time
                // fields taking a keyboard: Return reaches both the field's `onSubmit` and this
                // button's `.keyboardShortcut(.defaultAction)`, and if the button's turn comes
                // second it would save the window as it stood before the number was typed.
                Button("Done") { commitDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.weekdays.isEmpty)
            }
        }
    }

    /// A block that leaves the week without one free minute is confirmed before it is saved.
    ///
    /// Asked from inside the sheet, so Cancel drops back into the editor with the drawn window
    /// still there. Asking after the sheet has closed would make Cancel mean "throw away what
    /// you just did", which is not what the word says and not what the user wants when the
    /// answer is "no, make it end at 23:00 then".
    private func commit(_ draft: TimeWindow) {
        guard closesTheWeek(draft) else {
            refusal = onDone(draft)
            return
        }
        confirming = true
    }

    /// The window as it stands at the moment of the press. `@State` is read through storage the
    /// view does not own, so this sees an edit made in the same event turn that the press arrived
    /// in; a value captured while `body` ran does not.
    private func commitDraft() {
        guard let draft else { return }
        commit(draft)
    }
}

/// The shape of one window: what it is called, which days, and between which two times.
@MainActor
struct TimeWindowEditor: View {
    @Binding var window: TimeWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetChips
            HStack(alignment: .top, spacing: 14) {
                timeField("Start", minutes: startMinutes, range: TimeWindow.startRange)
                timeField("End", minutes: endMinutes, range: TimeWindow.endRange)
            }
            if window.crossesMidnight {
                Text(TimeWindowCopy.crossesMidnightHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Days").font(.caption).foregroundStyle(.secondary)
                WeekdayCircles(weekdays: weekdays)
                if window.weekdays.isEmpty {
                    Text("No days chosen, so this window never applies.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Presets fill the fields and nothing more. Which chip is lit is read back off the fields, so
    /// nudging a stepper unlights it and typing the work-day hours by hand lights Work day — a
    /// chip that stayed lit over values it no longer describes is a screen telling lies.
    ///
    /// **There is no Custom chip.** It was offered, and pressing it did nothing at all: Custom is
    /// what "no chip is lit" already means, so the button's whole job was to describe the state it
    /// was in. What made that worse was the other end of the same bug — a new window was built
    /// with `make(.custom, …)`, whose fallback is exactly the work-day values, so every window
    /// opened on Mon–Fri 9-to-5 with Custom lit and Work day dark.
    private var presetChips: some View {
        HStack(spacing: 6) {
            ForEach(TimeWindow.Preset.allCases, id: \.self) { preset in
                let isOn = window.livePreset == preset
                Button { apply(preset) } label: {
                    Text(TimeWindowCopy.preset(preset))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isOn ? Color.accentColor : Palette.hairline, in: Capsule())
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }

    private func apply(_ preset: TimeWindow.Preset) {
        let values = TimeWindow.values(for: preset)
        window.weekdays = values.weekdays
        window.startMinutes = values.startMinutes
        window.endMinutes = values.endMinutes
    }

    /// The two ends do not share a range: an end may be 24:00 and a start may not. See
    /// `TimeWindow.startRange`.
    private func timeField(
        _ label: String, minutes: Binding<Int>, range: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            // The one stepper in the app whose number is not the number on screen: it holds
            // minutes since midnight and shows a clock. Which is why it reads and writes its
            // field as a clock face — see `FieldNotation.clock` for the grammar it takes and
            // `ControlRules.clockMinutes(after:goingUp:)` for why the arrows move a quarter-hour
            // rather than the half they used to, which put 9:15 out of reach entirely.
            //
            // The same `endpoint` the notation drafts with, deliberately spelled out here: what
            // the row shows at rest and what a click hands the keyboard are one function, so the
            // notation cannot change under the cursor again.
            StepperControl(
                value: minutes,
                range: range,
                nextValue: ControlRules.clockMinutes(after:goingUp:),
                notation: .clock
            ) {
                TimeWindowCopy.endpoint($0)
            }
        }
    }

    // MARK: - Bindings

    /// Both ends move freely inside the day, and the end is allowed to land before the start —
    /// that is what a window crossing midnight *is*, and refusing it was V1's bug. The only
    /// clamps left are the day itself, and the one minute of it a *start* may not be.
    private var startMinutes: Binding<Int> {
        Binding(
            get: { window.startMinutes },
            set: { window.startMinutes = clamped($0, to: TimeWindow.startRange) }
        )
    }

    private var endMinutes: Binding<Int> {
        Binding(
            get: { window.endMinutes },
            set: { window.endMinutes = clamped($0, to: TimeWindow.endRange) }
        )
    }

    private var weekdays: Binding<Set<Int>> {
        Binding(get: { window.weekdays }, set: { window.weekdays = $0 })
    }

    private func clamped(_ minutes: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, minutes))
    }
}
