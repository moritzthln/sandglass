import SandglassAppCore
import SwiftUI

/// One entry in a `SettingsSelect` or a `SegmentedControl`.
///
/// A struct rather than the `(value:label:)` tuple it wants to be, for the reason `BudgetRow`
/// is one: Swift has no key paths into tuple elements, and `ForEach` needs one.
struct SelectOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }

    init(_ value: Value, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// The switch at the right-hand end of a settings row.
///
/// A type of its own rather than `Toggle("", isOn:).labelsHidden().toggleStyle(.switch)` at nine
/// call sites: the label belongs to `SettingsRow`, and the one place that decides a toggle looks
/// like a switch rather than a checkbox should be one place.
struct SettingsToggle: View {
    @Binding var isOn: Bool
    /// What a screen reader calls it. The visible label is the row's.
    let label: String

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// A compact dropdown, sized to its content and right-aligned by whatever row holds it.
///
/// **The stored value is always on the menu**, whether or not the caller put it there. A `Picker`
/// whose selection matches no tag draws blank and then writes back whichever row is touched next,
/// so a value a hand-edited `config.json` happens to hold — or one this build has stopped
/// offering — would be shown as nothing and silently rewritten. Three call sites had spotted
/// that and injected the current value themselves; the fourth had not, which is why the guard is
/// here instead of in each of them.
struct SettingsSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SelectOption<Value>]
    /// How a value missing from `options` is labelled. The default prints it, which is plain but
    /// true; a caller with better words for it — "01:30" rather than "90" — passes them in.
    var fallbackLabel: (Value) -> String = { "\($0)" }

    private var resolved: [SelectOption<Value>] {
        let values = ControlRules.menu(options.map(\.value), containing: selection)
        return values.map { value in
            options.first { $0.value == value } ?? SelectOption(value, fallbackLabel(value))
        }
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(resolved) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

/// The `Sites | Apps` switch, and every other two-or-three-way choice.
///
/// Same guard as `SettingsSelect`, and it matters more here: a segmented control with no matching
/// tag shows every segment unselected, which reads as a broken control rather than an empty one.
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SelectOption<Value>]
    var fallbackLabel: (Value) -> String = { "\($0)" }

    private var resolved: [SelectOption<Value>] {
        let values = ControlRules.menu(options.map(\.value), containing: selection)
        return values.map { value in
            options.first { $0.value == value } ?? SelectOption(value, fallbackLabel(value))
        }
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(resolved) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
}

/// A number you can step or type — the direct control that replaces the reference's
/// select → field → submit detour. Saves on every press; there is nothing to confirm.
///
/// A value outside `range` **stretches the range rather than being snapped into it**, which is
/// the rule the selects follow when a stored value is missing from their menu. `Stepper(in:)`
/// disables the arrow that would leave the bounds, so an out-of-range starting value — a
/// hand-edited `config.json`, or a range this build has since narrowed — would otherwise show a
/// number with one dead arrow beside it and no way back into the ordinary span. Shown truthfully
/// and steppable towards the range is the honest reading; silently clamping the display would
/// have the control claim a number the file does not hold.
///
/// **The number is a field, and the field is here rather than in a second control.** Four hours in
/// one-minute presses is 240 of them, and the arrows were the only way in. One control, because
/// the alternative was a typed variant beside the stepped one and two ways for the same row to be
/// wrong: the field is read into exactly the span the arrows may reach, so the keyboard can never
/// reach a number the arrows will not.
struct StepperControl: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    /// Where one press lands, when that depends on where the value already is — the arguments are
    /// the current value and whether the press was the up arrow. `nil` is the even `step` above.
    ///
    /// One control rather than two, because a stepper whose step grows with the number is still a
    /// stepper: the row it sits in cannot tell, and neither can the user until they hold the arrow
    /// down. What it buys is a span too wide for one step size — a minute to four hours, where 1
    /// would make an hour sixty presses and 15 would put five minutes out of reach.
    ///
    /// A destination rather than a step size, so the caller can also decide what an off-grid value
    /// does: see `SettingsLock.timerMinutes(after:goingUp:)`, which walks one onto the grid.
    ///
    /// It shapes the arrows only. A typed number need not sit on the grid at all — the grid is
    /// what makes one press feel right, not a rule about which numbers are allowed.
    var nextValue: ((Int, Bool) -> Int)?
    /// How the number is written for the keyboard and read back off it — a bare quantity, or a
    /// clock face for the two rows whose stored number is minutes since midnight.
    ///
    /// This was `acceptsTyping: Bool`, off in one place: the time-window editor, whose field would
    /// have taken "9" for nine minutes past twelve while the row read 9 AM. A field whose notation
    /// disagrees with its label is worse than no field — but the answer to that is a second way of
    /// writing a number down, not a row with no way in. See `FieldNotation`.
    var notation: FieldNotation = .number
    /// How the number reads: "45s", "20 min", "5". The stepper edits the number, this names it —
    /// and it names the bound in the note below, so a limit is stated in the row's own units.
    let format: (Int) -> String

    /// What is in the field while it is being typed into. Ignored at rest, where the field reads
    /// straight off `value`.
    @State private var draft = ""
    /// The bound a typed number was held to, said out loud for a few seconds.
    @State private var limitNote: String?
    /// Bumped with every note, so a second clamp restarts the wait rather than inheriting the
    /// remains of the first one's.
    @State private var noteToken = 0
    @FocusState private var editing: Bool

    private var reachable: ClosedRange<Int> {
        ControlRules.reachableRange(range, holding: value)
    }

    /// **The note goes under the control, never beside it.** It used to sit in this same `HStack`,
    /// which meant that for the four seconds it was up it was taking its width out of the row's
    /// budget — and the row is a `SettingsRow`, whose label gets whatever the control leaves. In
    /// the right-hand column at the window minimum that was ruinous: "Wait before unblocking"
    /// broke into four lines and hyphenated mid-word, and a row carrying a toggle as well lost its
    /// label outright, leaving an `i`, a switch, a note and a field with nothing to say what any
    /// of them were for.
    ///
    /// Under it, the note costs the row four seconds of height instead. The label keeps its width,
    /// and `SettingsRow` aligns on `.firstTextBaseline`, so the field the note is about does not
    /// move either — the note simply appears beneath it and goes again.
    ///
    /// `lineLimit(1)` and `fixedSize()` because it must not wrap: everything `note(_:)` writes is
    /// "Most is" or "Least is" and one short number in the row's own units, which is narrower than
    /// the field and arrows it sits under, so it asks for no width the control did not already
    /// take.
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                number
                arrows
            }
            if let limitNote {
                Text(limitNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .task(id: noteToken) { await clearNote() }
    }

    // MARK: - The number

    private var number: some View {
        TextField("", text: shown)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
            .focused($editing)
            .onSubmit { commit() }
            .onExitCommand { abandon() }
            .onChange(of: editing) { _, isEditing in
                if isEditing { draft = notation.draft(value) } else { commit() }
            }
            // An arrow pressed while the field has focus changes the value under the draft.
            .onChange(of: value) { _, updated in
                if editing { draft = notation.draft(updated) }
            }
    }

    /// Formatted at rest, in the notation's own spelling while it is being typed into: "20 min" is
    /// what the row means and "20" is what a keyboard can add a digit to; "9:30 AM" and "09:30" are
    /// the same pair for a clock.
    ///
    /// The rest state is read straight off `value` rather than kept in a copy, which is what makes
    /// an arrow press, an edit made in another window and a save the settings lock refused all
    /// show the truth without any of them being wired to this field.
    private var shown: Binding<String> {
        Binding(get: { editing ? draft : format(value) }, set: { draft = $0 })
    }

    @ViewBuilder
    private var arrows: some View {
        if let nextValue {
            // `onIncrement:`/`onDecrement:` rather than `value:in:step:`, which takes one
            // number. Passing `nil` for a closure is what disables that arrow, so the bounds
            // are held the same way the even stepper holds them.
            Stepper(
                "",
                onIncrement: value < reachable.upperBound ? { move(up: true, nextValue) } : nil,
                onDecrement: value > reachable.lowerBound ? { move(up: false, nextValue) } : nil
            )
            .labelsHidden()
        } else {
            Stepper("", value: $value, in: reachable, step: step)
                .labelsHidden()
        }
    }

    // MARK: - Editing

    /// One press, held inside the span the arrows are allowed to reach. The clamp is what keeps an
    /// uneven step from overshooting a bound it was never meant to cross.
    private func move(up: Bool, _ nextValue: (Int, Bool) -> Int) {
        let moved = nextValue(value, up)
        value = min(reachable.upperBound, max(reachable.lowerBound, moved))
    }

    /// Return, or the field losing focus. **Not every keystroke**: 60 is typed as a 6 and then a
    /// 0, and every write from here goes through `AppState.applyConfigEdit` and the settings lock
    /// behind it — so a control that saved per character would save the 6.
    ///
    /// A value that is already what is stored is not written at all, which is what makes clicking
    /// into a field and out of it again cost nothing, and what lets Escape restore the number by
    /// putting it back in the draft.
    private func commit() {
        guard let typed = notation.read(draft, reachable) else {
            draft = notation.draft(value)
            return
        }
        draft = notation.draft(typed.value)
        // Before the guard below, deliberately: a clamp can land on the value already there —
        // typing 700 into a row whose top is 600 that already reads 600 — and then the note is
        // the only thing that happens at all.
        if typed.wasClamped { note(typed.value) }
        guard typed.value != value else { return }
        value = typed.value
    }

    /// Escape drops the edit. Restoring the draft first is what makes the commit that follows the
    /// focus loss a write of the number already there, which `commit` declines to make.
    private func abandon() {
        draft = notation.draft(value)
        limitNote = nil
        editing = false
    }

    /// What the field says when it held a typed number back, in the row's own units rather than as
    /// a bare number: "Most is 600 min", not "600".
    ///
    /// The top is checked first, so a span of a single value reads as a ceiling. Which of the two
    /// bounds it is hardly matters there; that there is one does.
    private func note(_ bound: Int) {
        limitNote = bound == reachable.upperBound
            ? "Most is \(format(bound))"
            : "Least is \(format(bound))"
        noteToken += 1
    }

    /// The note goes by itself. It answers one keystroke, and a line that has to be dismissed is
    /// the error state this field was built not to have.
    private func clearNote() async {
        guard limitNote != nil else { return }
        do { try await Task.sleep(for: .seconds(4)) } catch { return }
        limitNote = nil
    }
}

/// Full width, filled, one to a card: the thing this card is for.
struct PrimaryWideButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// `PrimaryWideButton`'s shape with a menu behind it: a card whose main action is a choice of
/// lengths rather than a single verb.
///
/// It exists because the alternative was a `.borderlessButton` menu on a hand-built hairline
/// background, which is a fifth button shape on a page that already had four — and which made
/// the main action of its card look secondary until a break started, at which point the same
/// action became a filled `PrimaryWideButton`. An action that changes weight by state reads as
/// two different controls.
///
/// `.menuStyle(.button)` is what lets a `Menu` take a `ButtonStyle` at all — without it the
/// prominent fill is ignored and the control stays borderless, which is the bug this type
/// replaces rather than a smaller version of it.
struct PrimaryWideMenu<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }
}

/// The small bordered button that sits at the right-hand end of a row.
///
/// No tint, and no way to pass one. "Use pass" was the page's only red-tinted button, which read
/// as a punishment for taking the escape hatch this app deliberately provides — and the
/// confirmation behind it already carries the weight. A destructive alert button is where that
/// colour belongs; a row control is not.
///
/// **It takes a label as well as a title**, so a control that is this shape with something extra
/// in it — the Targets card's categories dropdown, which carries a chevron and hangs a popover
/// off itself — is the same type rather than the same three modifiers written out again. That
/// one used to be a bare `.bordered` `Button` at the default control size with a `.callout`
/// label, which is taller and wider than the two adds standing beside it; congruence by
/// construction is what keeps the three of them one family through the next edit.
struct SecondaryPillButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

extension SecondaryPillButton where Label == Text {
    /// The plain case: a verb and nothing else. No `.font` of its own — the control size decides
    /// the type, which is the whole point of the label variant matching it.
    init(title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}

/// Seven round weekday buttons, Monday first — the way a week is read in this app.
///
/// `Calendar.weekday` counts from Sunday = 1, which is why the order is written out rather
/// than generated: the display order and the stored numbers are two different things.
struct WeekdayCircles: View {
    @Binding var weekdays: Set<Int>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TimeWindowCopy.mondayFirst, id: \.self) { weekday in
                let isOn = weekdays.contains(weekday)
                Button {
                    if isOn { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
                } label: {
                    Text(TimeWindowCopy.letter(weekday))
                        .font(.caption.weight(.medium))
                        .frame(width: 26, height: 26)
                        .background(isOn ? Color.accentColor : Palette.hairline, in: Circle())
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TimeWindowCopy.dayName(weekday))
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}

/// The same seven days, read-only and half the size: the strip on a sidebar group card.
struct WeekdayStrip: View {
    let weekdays: Set<Int>
    /// What a lit day is coloured. The caller's business, because "this group has an opinion on
    /// Saturday" is not the same fact as *which* opinion — see `GroupCard.stripTint`.
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 3) {
            ForEach(TimeWindowCopy.mondayFirst, id: \.self) { weekday in
                Text(TimeWindowCopy.letter(weekday))
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 13, height: 13)
                    .foregroundStyle(weekdays.contains(weekday) ? Color.white : Color.secondary)
                    .background(weekdays.contains(weekday) ? tint : .clear, in: Circle())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scheduled days")
    }
}
