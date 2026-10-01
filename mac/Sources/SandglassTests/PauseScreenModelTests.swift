import SandglassAppCore
import SandglassCore
import Foundation

/// The last rule between the engine and the user: which decision gets a screen, and what that
/// screen offers. Getting it wrong is either an "Open" button on a hard block or a pause
/// screen over an app the user already paid for, so it is pinned rather than eyeballed.
func runPauseScreenModelTests() {
    testPauseBecomesACountdown()
    testCountdownIsNeverNegative()
    testHardBlockDropsTheBudgetLine()
    testNothingToBlockHasNoScreen()
    testOnlyAWayThroughGetsAScreen()
    testAMissingTargetBlocksNothing()
    testNoPauseIsNeitherAScreenNorNothing()
}

private let info = TargetDisplayInfo(targetID: "app:com.apple.Notes", name: "Notes")

private func testPauseBecomesACountdown() {
    let model = PauseScreenModel.for(
        decision: .pause(countdownSeconds: 10, budgetLine: "3 of 5 opens left today"), info: info
    )
    expectEqual(
        model,
        PauseScreenModel(
            targetName: "Notes",
            budgetLine: "3 of 5 opens left today",
            mode: .countdown(total: 10)
        ),
        "a pause carries the engine's own budget line and the wait it asked for"
    )
}

/// A wait cannot be shorter than none. A negative countdown would enable the button a frame
/// early, which is the one direction this screen must never fail in.
private func testCountdownIsNeverNegative() {
    let model = PauseScreenModel.for(
        decision: .pause(countdownSeconds: -5, budgetLine: nil), info: info
    )
    expectEqual(model?.mode, .countdown(total: 0), "a negative wait is clamped, not honoured")
    expectNil(model?.budgetLine, "and an unlimited group still reports no budget")
}

/// The block already says everything true about right now. A budget under it would read as a
/// way out that is not on offer.
private func testHardBlockDropsTheBudgetLine() {
    let model = PauseScreenModel.for(
        decision: .blocked(reason: .schedule, untilText: "Blocked until 17:00"), info: info
    )
    expectEqual(
        model,
        PauseScreenModel(
            targetName: "Notes",
            budgetLine: nil,
            mode: .blocked(untilText: "Blocked until 17:00")
        ),
        "a hard block states itself and offers nothing"
    )
}

private func testNothingToBlockHasNoScreen() {
    expectNil(
        PauseScreenModel.for(decision: .allowed(remainingSessionSeconds: 300), info: info),
        "a session the user already paid for has no screen"
    )
    expectNil(
        PauseScreenModel.for(decision: .notManaged, info: info),
        "and neither has an app this Mac does not block"
    )
}

/// The rule the whole design turns on: a screen appears when there is a button on it, and
/// otherwise the thing goes away. Every blocked activation used to raise the same full-screen
/// overlay whether or not it had an Open button, which made a hard block a notice to dismiss.
private func testOnlyAWayThroughGetsAScreen() {
    let waiting = BlockPresentation.for(
        decision: .pause(countdownSeconds: 10, budgetLine: nil), info: info
    )
    expectEqual(
        waiting,
        .screen(PauseScreenModel(targetName: "Notes", budgetLine: nil, mode: .countdown(total: 10))),
        "a countdown that ends in an Open is a decision to make, so it gets the screen"
    )

    let walled = BlockPresentation.for(
        decision: .blocked(reason: .budgetExhausted, untilText: "Blocked until tomorrow"),
        info: info
    )
    expectEqual(
        walled,
        .sendAway(
            PauseScreenModel(
                targetName: "Notes",
                budgetLine: nil,
                mode: .blocked(untilText: "Blocked until tomorrow")
            )
        ),
        "a spent budget offers nothing to press, so the thing is sent away instead"
    )
    // The words survive the screen not being shown: the web half needs them for the block page.
    expectEqual(walled.model?.targetName, "Notes", "a send-away still carries what to say")

    expectEqual(
        BlockPresentation.for(decision: .allowed(remainingSessionSeconds: 300), info: info),
        .nothing,
        "a session already paid for stands in nobody's way"
    )
    expectEqual(
        BlockPresentation.for(decision: .notManaged, info: info),
        .nothing,
        "and neither does an app this Mac does not block"
    )
}

/// What the "Open" button reads. A refusal that hides the app shows no screen, and reading that
/// as "the block lifted" would spend nothing and let the user straight through.
private func testAMissingTargetBlocksNothing() {
    let hardBlock = Decision.blocked(reason: .cooldown, untilText: "Next open in 8 min")
    expect(BlockPresentation.for(decision: hardBlock, info: info).blocks, "a hard block blocks")
    expect(
        BlockPresentation.for(decision: .pause(countdownSeconds: 5, budgetLine: nil), info: info)
            .blocks,
        "so does a wait"
    )
    expect(
        !BlockPresentation.for(decision: .allowed(remainingSessionSeconds: 1), info: info).blocks,
        "an allowed decision does not"
    )
    // Nothing in the configuration claims this target any more — the same answer as nothing
    // standing in the way, and the case that used to be a separate `guard let info`.
    expectEqual(
        BlockPresentation.for(decision: hardBlock, info: nil),
        .nothing,
        "a target nothing claims cannot be blocked, whatever the engine last said about it"
    )
    expectNil(BlockPresentation.nothing.model, "and there is nothing to say about it")
}

/// A group set to no pause is a third answer, and it has to be told from the other two: `nothing`
/// is the engine having no opinion, this is the engine charging for a visit it does not
/// interrupt. A screen built from it would be a countdown of nought seconds with a button on it —
/// exactly the reading the decision exists to replace.
private func testNoPauseIsNeitherAScreenNorNothing() {
    let presentation = BlockPresentation.for(decision: .opensByItself, info: info)
    expectEqual(presentation, .opensByItself, "no wait is its own presentation")
    expectNil(presentation.model, "there is no screen to draw")
    expectNil(
        PauseScreenModel.for(decision: .opensByItself, info: info),
        "and none to build from the decision either"
    )
    expect(!presentation.blocks, "nothing stands in the way — the visit is charged for, not held")
    expectEqual(
        BlockPresentation.for(decision: .opensByItself, info: nil),
        .nothing,
        "a target nothing claims costs nothing, whatever the engine last said about it"
    )
}
