import SandglassAppCore
import SandglassCore
import Foundation

/// What a preset dropdown offers, and what each row says about itself.
///
/// The rows carry their settings because picking blind was the complaint: a list of three names
/// asks the user to remember what Gentle means, and nobody does. Every row is its own summary,
/// so the menu answers "what is in this" without being opened twice.
func runPresetChoiceTests() {
    testEveryRowSaysWhatItHolds()
    testTheCurrentRowIsReadFromTheValues()
    testCustomIsOnlyOfferedWhileYouAreInIt()
    testAGroupWithNoPresetsLeftIsStillCustom()
    testANewGroupIsNeverOfferedCustom()
    testARowIsIdentifiedApartFromAPresetCalledCustom()
    testARowSaysWhatThePresetDoesToTheWeek()
    testTheThreeAnswersAboutTheWeekRoundTrip()
    testASummaryNamesAPauseOfNoSecondsRatherThanCountingIt()
}

// MARK: - What a preset says about the week

/// Applying a preset overwrites without asking, so the row somebody picks from is the only place
/// a preset that would clear or replace their week can warn them. One that says nothing about the
/// week adds nothing, which is every preset a fresh install ships with.
private func testARowSaysWhatThePresetDoesToTheWeek() {
    let quiet = NamedPreset(name: "Quiet", settings: .gentle)
    let always = NamedPreset(name: "Always on", settings: .gentle, timeWindows: [])
    let office = NamedPreset(
        name: "Office", settings: .gentle,
        timeWindows: [TimeWindow.make(.workDay, kind: .strictBlock)]
    )
    let both = NamedPreset(
        name: "Two", settings: .gentle,
        timeWindows: [
            TimeWindow.make(.workDay, kind: .strictBlock),
            TimeWindow.make(.bedtime, kind: .strictBlock),
        ]
    )
    expectEqual(
        PresetCopy.detail(of: quiet), PresetCopy.summary(of: .gentle),
        "a preset with no opinion about the week says nothing about it"
    )
    expectEqual(
        PresetCopy.detail(of: always), "\(PresetCopy.summary(of: .gentle)) · clears the week",
        "one that carries none says so, because applying it takes the group's away"
    )
    expectEqual(
        PresetCopy.detail(of: office), "\(PresetCopy.summary(of: .gentle)) · carries 1 time window",
        "and one that carries a week counts it"
    )
    expectEqual(
        PresetCopy.detail(of: both), "\(PresetCopy.summary(of: .gentle)) · carries 2 time windows",
        "in the plural where there is more than one"
    )
}

/// The control writes one of three answers and reads the same three back. `.use` with nothing
/// drawn is `.clear`'s value on purpose: a preset carrying no windows carries no windows, and the
/// two would do the identical thing to a group.
private func testTheThreeAnswersAboutTheWeekRoundTrip() {
    let drawn = [TimeWindow.make(.bedtime, kind: .strictBlock)]
    expectNil(PresetWindowsRule.leaveAlone.windows(drawn), "leaving them alone stores no opinion")
    expectEqual(PresetWindowsRule.clear.windows(drawn), [], "clearing stores an empty week")
    expectEqual(PresetWindowsRule.use.windows(drawn), drawn, "and using them stores the week")

    expectEqual(PresetWindowsRule.rule(for: nil), .leaveAlone, "no opinion reads back as leave alone")
    expectEqual(PresetWindowsRule.rule(for: []), .clear, "an empty week reads back as clear")
    expectEqual(PresetWindowsRule.rule(for: drawn), .use, "and a week reads back as use these")
    expectEqual(
        PresetWindowsRule.rule(for: PresetWindowsRule.use.windows([])), .clear,
        "using a week nobody drew is clearing it, and the file says the same thing the app does"
    )

    expect(
        Set(PresetWindowsRule.allCases.map(\.title)).count == 3,
        "three answers, told apart by what each does to the group"
    )
    expect(
        PresetWindowsRule.allCases.allSatisfy { !$0.detail.isEmpty },
        "and each spells its consequence out under the control"
    )
}

/// The whole point of the two-line row: the second line is the preset's own settings, in the
/// same words the Presets card uses for them.
private func testEveryRowSaysWhatItHolds() {
    let rows = PresetChoices.forGroup(NamedPreset.builtIns, settings: .standard)
    expectEqual(rows.map(\.name), ["Gentle", "Standard", "Strict"], "one row per preset, in order")
    expectEqual(
        rows[0].detail, "10s pause · no opens budget · no relock",
        "Gentle says it has no budget and no relock rather than saying nothing"
    )
    expectEqual(
        rows[1].detail,
        "10s pause · 5 opens a day · 5 min per open · 10 min cooldown · +5s each open · earn-back on",
        "Standard's row is every knob it sets"
    )
    expectEqual(
        rows[2].detail, "30s pause · 2 opens a day · 5 min per open · 60 min cooldown · +15s each open",
        "and Strict's is the same sentence with its own numbers"
    )
    expectEqual(
        rows[1].detail, PresetCopy.summary(of: GroupSettings.standard),
        "the row and the Presets card describe a preset with one function, not two"
    )
}

/// The values are the truth, the stored marker is a label — the same rule
/// `ConfigBuilder.presetID(matching:in:)` exists for. A group carrying Standard's marker over
/// Strict's numbers is on Strict, and the tick has to say so.
private func testTheCurrentRowIsReadFromTheValues() {
    var settings = GroupSettings.strict
    settings.presetID = NamedPreset.standardID
    let rows = PresetChoices.forGroup(NamedPreset.builtIns, settings: settings)
    expectEqual(rows.filter(\.isCurrent).map(\.name), ["Strict"], "the values win over the marker")
    expectEqual(rows.count, 3, "and nothing is Custom, because the values are a preset")
}

/// Custom is a state to be in rather than one to choose, so it is on the menu only while it is
/// where you already are — and its line describes the group in front of you, which is the one
/// thing no preset's row can say.
private func testCustomIsOnlyOfferedWhileYouAreInIt() {
    var settings = GroupSettings.standard
    settings.pauseSeconds = 45
    let rows = PresetChoices.forGroup(NamedPreset.builtIns, settings: settings)
    expectEqual(rows.count, 4, "a knob moved by hand adds the row")
    expectEqual(rows.last?.name, PresetCopy.custom, "at the end, under the presets")
    expectEqual(rows.last?.presetID, nil, "and it picks no preset")
    expect(rows.last?.isCurrent == true, "it is where the group is")
    expectEqual(
        rows.last?.detail,
        "45s pause · 5 opens a day · 5 min per open · 10 min cooldown · +5s each open · earn-back on",
        "and it says what the group holds this second"
    )
    expect(
        PresetChoices.forGroup(NamedPreset.builtIns, settings: .gentle).allSatisfy { $0.presetID != nil },
        "a group that is on a preset is not offered Custom at all"
    )
}

/// Deleting every preset leaves the control with one true thing to say. The group's settings did
/// not move, so it is Custom — and a dropdown of nothing at all would be a control that has
/// stopped answering.
private func testAGroupWithNoPresetsLeftIsStillCustom() {
    let rows = PresetChoices.forGroup([], settings: .standard)
    expectEqual(rows.map(\.name), [PresetCopy.custom], "one row, and it is Custom")
    expect(rows[0].isCurrent, "which is where the group is")
}

/// The sidebar's dropdown makes a group out of a preset. Custom is not something a group can be
/// made out of — it is the name for values that match none — so it is not on that menu.
private func testANewGroupIsNeverOfferedCustom() {
    let rows = PresetChoices.forNewGroup(NamedPreset.builtIns)
    expectEqual(rows.map(\.name), ["Gentle", "Standard", "Strict"], "the presets and nothing else")
    expect(rows.allSatisfy { !$0.isCurrent }, "nothing is ticked: there is no group yet to be on one")
    expectEqual(rows[1].detail, PresetCopy.summary(of: GroupSettings.standard), "with the same lines")
    expect(PresetChoices.forNewGroup([]).isEmpty, "and no presets means no menu rather than an empty one")
}

/// `id` is what `ForEach` draws rows by, and a duplicate id draws one row where there are two.
/// The Custom row has no preset behind it, so it needs an id of its own — and a hand-written
/// `config.json` may perfectly well hold a preset whose id is the word this test is named after.
private func testARowIsIdentifiedApartFromAPresetCalledCustom() {
    let odd = NamedPreset(id: "custom", name: "Mine", settings: .gentle)
    let rows = PresetChoices.forGroup([odd], settings: .strict)
    expectEqual(rows.count, 2, "the preset, and Custom for the values that match nothing")
    expectEqual(Set(rows.map(\.id)).count, 2, "and the two rows are told apart")
}

/// Every line the app prints about a pause of no seconds has to say what it is. "0s pause" reads
/// as a countdown that finishes instantly; there is no countdown, and the app must not describe
/// a screen it will never show. See `Decision.opensByItself`.
private func testASummaryNamesAPauseOfNoSecondsRatherThanCountingIt() {
    var settings = GroupSettings.standard
    settings.pauseSeconds = 0
    let line = PresetCopy.summary(of: settings)
    expect(line.hasPrefix("no pause · "), "the clause names the state: \(line)")
    expect(!line.contains("0s"), "and never counts it as seconds")
    expect(
        PresetCopy.summary(of: .standard).hasPrefix("10s pause · "),
        "a group with a wait still says how long it is"
    )
}
