import SandglassAppCore

// What the overlay puts on each display, whether it steps back for a modal alert, and which
// command keys it lets through. The AppKit half builds what these say; see `OverlaySet`.

func runOverlayPlanTests() {
    testEveryDisplayIsCovered()
    testThePauseScreenFallsBackWhenItsDisplayIsGone()
    testAModalAlertKeepsTheKeyboard()
    testCommandKeysAreRefusedExceptEditingInAField()
}

private func testEveryDisplayIsCovered() {
    let plan = OverlayPlan.plan(displays: [1, 2, 3], target: 2, modalAlertRunning: false)
    expectEqual(
        plan.placements.map(\.display), [1, 2, 3],
        "a window on every display, so a blocked app's second-screen window is covered too"
    )
    expectEqual(
        plan.placements.map(\.role), [.cover, .pauseScreen, .cover],
        "the pause screen where the blocked thing was found, black everywhere else"
    )
    expect(plan.takesKeyboard, "with no alert up the overlay takes the keyboard")
    expect(!plan.liftsModalAlert, "and there is nothing to lift")
}

private func testThePauseScreenFallsBackWhenItsDisplayIsGone() {
    let plan = OverlayPlan.plan(displays: [1, 3], target: 2, modalAlertRunning: false)
    expectEqual(
        plan.placements.map(\.role), [.pauseScreen, .cover], "an unplugged display falls to the first"
    )
    expectEqual(
        OverlayPlan.plan(displays: [], target: nil, modalAlertRunning: false).placements, [],
        "no display, nothing to cover"
    )
}

private func testAModalAlertKeepsTheKeyboard() {
    let plan = OverlayPlan.plan(displays: [1, 2], target: 1, modalAlertRunning: true)
    expectEqual(plan.placements.count, 2, "the overlay still covers everything")
    expect(!plan.takesKeyboard, "but it does not take the keyboard from the alert")
    expect(plan.liftsModalAlert, "and the alert is raised above it, where it can be answered")
}

private func testCommandKeysAreRefusedExceptEditingInAField() {
    func answer(
        _ key: String, command: Bool = true, other: Bool = false, editing: Bool
    ) -> OverlayKey.Answer {
        OverlayKey.answer(characters: key, command: command, otherModifiers: other, editingText: editing)
    }
    expectEqual(answer("q", editing: true), .refuse, "⌘Q never ends a pause screen")
    expectEqual(answer("w", editing: false), .refuse, "nor ⌘W")
    expectEqual(answer("v", editing: true), .passOn, "⌘V pastes into the password field")
    expectEqual(answer("a", editing: true), .passOn, "⌘A selects in it")
    expectEqual(answer("v", editing: false), .refuse, "with no field being typed in, paste is refused")
    expectEqual(answer("v", other: true, editing: true), .refuse, "⌃⌘V or ⌥⌘V is not paste")
    expectEqual(answer("\t", command: false, editing: false), .passOn, "a plain key is not a command")
}
