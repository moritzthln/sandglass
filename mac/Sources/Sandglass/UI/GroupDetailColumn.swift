import SandglassAppCore
import SandglassCore
import SwiftUI

/// The settings a preset stands for, and — for a group — the week it runs them in.
///
/// The right-hand column of the group editor, and — bound to a draft instead of to a group — the
/// whole of the preset editor. Everything it touches is `GroupSettings` and nothing else, which
/// is what lets one set of cards answer both. Where the writes go is the binding's business; see
/// `GroupSettingsEditing`.
///
/// The preset dropdown is **not** here. It writes every row of the first card, which is why it
/// spent a wave in that card's title bar, but a preset belongs to the group the way its name
/// does — so it lives in the editor's header, beside the name. See `GroupPresetPicker`. That
/// also settles the preset editor, which shows these very cards over a draft: a preset cannot be
/// put on a preset, and there is now nothing to hide.
///
/// `windowsRule` is what the two callers disagree about, and the disagreement is the point: a
/// group **has** a week, while a preset may or may not have an opinion about one. The group
/// editor passes nothing and gets the plain windows card; the preset editor passes the binding
/// and the same card grows the row that chooses between the three states of
/// `NamedPreset.timeWindows`. The card used to be hidden here altogether, back when a preset
/// could not carry a week at all.
@MainActor
struct GroupDetailColumn: View {
    @Binding var settings: GroupSettings
    /// The three answers a preset may give about the week, or `nil` in the group editor, where
    /// there is no such question to ask. See `PresetWindowsRule`.
    var windowsRule: Binding<PresetWindowsRule>?
    /// Where the write behind `settings` reports its refusals — the Time windows card opens a
    /// sheet over the page that shows them, so it has to be able to say them itself. Defaulted,
    /// because the preset editor shows no windows and reports its own refusals already.
    var problem: Binding<String?> = .constant(nil)
    /// Whether a lock is standing over the group these knobs belong to, in which case every one of
    /// them may still be turned towards more friction and none of them back.
    ///
    /// A wait holds a **direction**, not the page (`EditDirection`), so the honest drawing of it is
    /// per control: a stepper keeps the arrow that tightens and loses the one that does not, and a
    /// switch whose only remaining move would hand something back goes dead. Nothing here decides
    /// anything — `AppState.applyConfigEdit` refuses either way — this only stops a control
    /// claiming it can do something the save behind it will turn down.
    ///
    /// Defaulted off for the preset editor, which edits a draft: a preset is a template nothing is
    /// living off this second, so no lock is standing over it.
    var tighteningOnly = false
    /// The day this moment is in, or `nil` in the preset editor — which is also what takes the
    /// dated-block row off the windows card there. See `TimeWindowsCard.today`.
    var today: String?
    // What each of the three switches was turned off with, so turning it back on does not hand
    // out the default over the top of a number the user chose. See `RememberedNumber`.
    @State private var sessionMemory = RememberedNumber(fallback: 5)
    @State private var opensMemory = RememberedNumber(fallback: 5)
    /// An hour is where a limit starts when one is turned on: long enough not to be a
    /// punishment, short enough to be a limit.
    @State private var dailyMemory = RememberedNumber(fallback: 60)

    /// **The week is read first.** Time windows sits above Settings, for every group and every
    /// preset, always — not conditionally, and nothing here reorders itself as a week changes. A
    /// column that rearranged under an edit would move the row somebody was reaching for.
    ///
    /// It is the right way round on the merits as well: which hours a group applies in decides
    /// whether the knobs below it are ever consulted, so the answer belongs above the question.
    /// The two spent a wave the other way round, from when the knobs card was the one thing in
    /// this column.
    ///
    /// The order is a swap inside one column and therefore costs the page nothing: the same two
    /// cards, the same widths, the same spacing. What does change the balance is the card below
    /// being able to go away; see `EditorCards` and the numbers at `GroupEditorView.cards`.
    var body: some View {
        VStack(spacing: Metrics.cardSpacing) {
            TimeWindowsCard(
                settings: $settings, problem: problem, rule: windowsRule,
                today: today, tighteningOnly: tighteningOnly
            )
            if showsKnobs { knobsCard }
        }
    }

    /// Whether the Settings card is on the page at all. See `EditorCards`, which is where the rule
    /// lives and where it is tested — including the half of it only the preset editor meets.
    ///
    /// Computed off the binding every pass rather than remembered, which is what makes the way
    /// back immediate: deleting a window, or shortening one by a minute, redraws this column with
    /// the card in it.
    private var showsKnobs: Bool {
        EditorCards.showsSettings(
            windows: settings.timeWindows, presetRule: windowsRule?.wrappedValue
        )
    }

    // MARK: - Settings

    /// Seven knobs, and they answer two different questions.
    ///
    /// The card was called "Basic", which is a name for nothing — it said where the knobs were
    /// filed rather than what they do, and the order interleaved the two topics: the wait, the
    /// session, the budget, the cooldown, the escalation, the earn-back, the time limit. **Getting
    /// in** is the friction in front of one open; **the day's budget** is how much there is of
    /// them. Reading either one used to mean skipping every other row.
    ///
    /// Then it was called "How hard it blocks", which is a name for the wrong thing: it turned
    /// the preset dropdown that used to sit in its title bar into a strictness dial, when a
    /// preset is a set of prepared settings and these are the settings. The two subheadings
    /// carry the meaning the title was reaching for, so the title says what the card is.
    ///
    /// **Every span below is wider than it was**, because the arrows are no longer the only way in
    /// and a span was partly a budget for presses: 480 minutes at five a press is 96 of them, so
    /// the top of each row was set where holding an arrow down stopped being reasonable rather
    /// than where the setting stopped making sense. Typed, the top is only a limit — the pause
    /// countdown reaches three minutes, an open two hours, the day ten. The countdown's floor has
    /// moved twice, and it is nought: three seconds replaced somebody's five, and nought is not a
    /// shorter pause but the absence of one — see `Decision.opensByItself`.
    ///
    /// They are still bounded, and the bound is the point. An unbounded field here once bought a
    /// ten-hour lockout with a slipped keystroke — 600 typed where 60 was meant — and the only way
    /// out was the week's emergency pass. A ceiling costs the one person who genuinely wanted
    /// eleven hours a hand-edited `config.json`; no ceiling costs everyone else an afternoon.
    ///
    /// **The card is not drawn at all when the week above it has no gap in it.** It used to be
    /// drawn dimmed to 0.55 under a line reading "None of this is ever reached", which is a card
    /// whose entire content is an apology for being there. Its absence says it better: there is
    /// nothing to set, because the group is either fully blocked or fully free. The dimmed version
    /// bought one thing — the knobs could be arranged *before* the window was taken out — and that
    /// trade is knowingly given up: make the gap first, and the card comes back with it. See
    /// `EditorCards`.
    private var knobsCard: some View {
        SettingsCard("Settings") {
            SettingsSubheading("Getting in", separated: false)
            gettingInRows
            SettingsSubheading("The day's budget")
            budgetRows
        }
    }

    /// The row's own words for a pause of no seconds, said twice because the two say different
    /// things: the field has to name the state it is in, and the caption has to say what that
    /// state does. Neither of them is "0s", which reads as a countdown that is already over —
    /// and it is not one, because there is no screen for it to be over on.
    ///
    /// Short in the field, which is 84 points wide and holds "180s" the rest of the time.
    private static let noPause = "No pause"
    private static let noPauseCaption = "No pause — opens by itself"

    private static func pauseLabel(_ seconds: Int) -> String {
        seconds == 0 ? noPause : "\(seconds)s"
    }

    /// What stands between wanting the group and having it: the wait, and how it grows.
    @ViewBuilder
    private var gettingInRows: some View {
        SettingsRow(
            "Pause countdown",
            help: "How long the pause screen waits before the way through appears.\n\nSet to none, there is no pause screen at all: the app or the page opens the moment you reach for it, and the open is counted straight away — an accidental one too. Everything else still holds, so the open ends, the budget empties, and an empty budget is still a block.",
            caption: settings.pauseSeconds == 0 ? Self.noPauseCaption : nil
        ) {
            StepperControl(
                value: field(\.pauseSeconds),
                range: upwards(0...180, from: settings.pauseSeconds),
                format: Self.pauseLabel
            )
        }
        Divider().overlay(Palette.hairline)
        SettingsRow(
            "Escalate the countdown",
            help: "Every open already taken today makes the next pause screen this much longer."
        ) {
            SettingsSelect(
                selection: field(\.escalationSeconds),
                options: escalationOptions,
                fallbackLabel: Self.escalationLabel(_:)
            )
        }
    }

    /// How much of the group there is in a day: the two budgets, what they add up to, and the two
    /// knobs that spend from them.
    @ViewBuilder
    private var budgetRows: some View {
        SettingsRow(
            "Daily opens goal",
            help: "How many times a day this group may be opened. Once they are spent, it is blocked until the day resets.",
            caption: settings.opensPerDay == nil ? "Unlimited" : nil
        ) {
            HStack(spacing: 10) {
                // Off is unlimited, so a goal that is on can only be switched off towards a
                // looser group — and the number behind it only cut. Both are drawn that way.
                SettingsToggle(isOn: hasOpensGoal, label: "Daily opens goal")
                    .disabled(tighteningOnly && settings.opensPerDay != nil)
                if let opens = settings.opensPerDay {
                    StepperControl(value: opensPerDay, range: downwards(1...30, to: opens)) { "\($0)" }
                }
            }
        }
        Divider().overlay(Palette.hairline)
        SettingsRow(
            "Open length",
            help: "How long one open lasts before the group locks again.",
            caption: settings.sessionMinutes == nil ? "No relock — an open lasts until you end it" : nil
        ) {
            HStack(spacing: 10) {
                SettingsToggle(isOn: hasSessionLength, label: "Open length")
                    .disabled(tighteningOnly && settings.sessionMinutes != nil)
                if let minutes = settings.sessionMinutes {
                    StepperControl(value: sessionMinutes, range: downwards(1...120, to: minutes)) { "\($0) min" }
                }
            }
        }
        Divider().overlay(Palette.hairline)
        SettingsRow("Daily time limit", help: "Minutes this group may be used for in a day, counted whether or not an open is running. It sits beside the opens goal rather than instead of it: opens count how often you go in, minutes count how long you stay. Whichever runs out first blocks, and says which one it was.") {
            HStack(spacing: 10) {
                SettingsToggle(isOn: dailyLimitOn, label: "Daily time limit")
                    .disabled(tighteningOnly && settings.dailyMinutes != nil)
                if let minutes = settings.dailyMinutes {
                    StepperControl(value: dailyMinutes, range: downwards(5...600, to: minutes), step: 5) { "\($0) min" }
                }
            }
        }
        // Under all three of the numbers it is the product of, rather than under the first of
        // them: the time limit is the ceiling, so a total stated above it would be a total the
        // next row contradicts.
        SettingsStateRow(
            text: GroupSummary.dailyTotal(
                opensPerDay: settings.opensPerDay,
                sessionMinutes: settings.sessionMinutes,
                dailyMinutes: settings.dailyMinutes
            ),
            tone: .secondary
        )
        Divider().overlay(Palette.hairline)
        SettingsRow("Cooldown", help: "A wait before the next open, counted from the moment the last one ended.") {
            StepperControl(
                value: field(\.cooldownMinutes),
                range: upwards(0...240, from: settings.cooldownMinutes)
            ) { "\($0) min" }
        }
        Divider().overlay(Palette.hairline)
        SettingsRow("Earn back half an open", help: "Ending an open in its first half gives half an open back.") {
            // The one switch whose *off* is the strict side: earn-back hands half a spent open
            // back, so giving it up is always allowed and asking for it back is not.
            SettingsToggle(isOn: field(\.earnBackEnabled), label: "Earn back half an open")
                .disabled(tighteningOnly && !settings.earnBackEnabled)
        }
    }

    // MARK: - The span a held number may still reach

    /// A number the lock lets grow, and the same the other way for the three where less is
    /// stricter. The arithmetic is `ControlRules`'; these two carry `tighteningOnly` to it so the
    /// rows above stay one line each.
    private func upwards(_ full: ClosedRange<Int>, from value: Int) -> ClosedRange<Int> {
        ControlRules.upwards(full, from: value, tighteningOnly: tighteningOnly)
    }

    private func downwards(_ full: ClosedRange<Int>, to value: Int) -> ClosedRange<Int> {
        ControlRules.downwards(full, to: value, tighteningOnly: tighteningOnly)
    }

    /// Escalation is a menu rather than a stepper, so the held direction is drawn by leaving the
    /// shorter waits off it. The current value is always on the menu whatever this returns —
    /// `SettingsSelect` sees to that — so a locked group cannot end up with a blank control.
    private var escalationOptions: [SelectOption<Int>] {
        guard tighteningOnly else { return Self.escalationOptions }
        return Self.escalationOptions.filter { $0.value >= settings.escalationSeconds }
    }

    // MARK: - Bindings

    private func field<V>(_ keyPath: WritableKeyPath<GroupSettings, V>) -> Binding<V> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in edit { $0[keyPath: keyPath] = value } }
        )
    }

    /// Off is "no relock", which is Gentle's doing and a real answer rather than a missing
    /// number — so it gets the switch `opensPerDay` and `dailyMinutes` have. A bare stepper made
    /// it a one-way door: the getter read five, so one nudge turned Gentle's "no relock" into a
    /// five-minute session with nothing on the row that could put it back.
    ///
    /// Turning it off keeps the number for the rest of this visit; see `RememberedNumber`.
    private var hasSessionLength: Binding<Bool> {
        Binding(
            get: { settings.sessionMinutes != nil },
            set: { isOn in
                edit { $0.sessionMinutes = sessionMemory.flipped(to: isOn, from: $0.sessionMinutes) }
            }
        )
    }

    private var sessionMinutes: Binding<Int> {
        Binding(
            get: { settings.sessionMinutes ?? sessionMemory.fallback },
            set: { value in edit { $0.sessionMinutes = value } }
        )
    }

    private var opensPerDay: Binding<Int> {
        Binding(
            get: { settings.opensPerDay ?? opensMemory.fallback },
            set: { value in edit { $0.opensPerDay = value } }
        )
    }

    /// Off is unlimited. The switch is the same shape as the daily time limit's, deliberately:
    /// both answer "is there a budget", and both reveal the number when there is one.
    private var hasOpensGoal: Binding<Bool> {
        Binding(
            get: { settings.opensPerDay != nil },
            set: { isOn in
                edit { $0.opensPerDay = opensMemory.flipped(to: isOn, from: $0.opensPerDay) }
            }
        )
    }

    /// Off, and four steps. Five seconds is what the presets mean by escalation and is where
    /// anybody turning it on lands; the rest are for a habit that has learned to sit through five.
    ///
    /// A hand-edited value that is on none of them is put on the menu by `SettingsSelect` itself,
    /// which is why this list is a constant rather than a function of the current value: a value
    /// missing from a menu leaves the menu blank and then silently rewrites itself on the next
    /// click, and that rule belongs in one place rather than in every caller.
    private static let escalationOptions = [0, 5, 10, 15, 30].map {
        SelectOption($0, escalationLabel($0))
    }

    private static func escalationLabel(_ seconds: Int) -> String {
        seconds == 0 ? "Off" : "+\(seconds)s per open"
    }

    private var dailyLimitOn: Binding<Bool> {
        Binding(
            get: { settings.dailyMinutes != nil },
            set: { isOn in
                edit { $0.dailyMinutes = dailyMemory.flipped(to: isOn, from: $0.dailyMinutes) }
            }
        )
    }

    private var dailyMinutes: Binding<Int> {
        Binding(
            get: { settings.dailyMinutes ?? dailyMemory.fallback },
            set: { value in edit { $0.dailyMinutes = value } }
        )
    }

    // MARK: - Writing

    private func edit(_ transform: (inout GroupSettings) -> Void) {
        var updated = settings
        transform(&updated)
        settings = updated
    }
}
