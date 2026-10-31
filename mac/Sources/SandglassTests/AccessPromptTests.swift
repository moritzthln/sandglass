import Foundation
import SandglassAppCore
import SandglassCore

// The app's half of a group that opens only with its password: the screen it gets, the block
// page's state and its "ask" handoff, the copy under the field, presets and copies, and the
// password typed through `AppState`.

func runAccessPromptTests() {
    testAPasswordBlockIsAScreenWithAFieldRatherThanAWall()
    testTheBlockPageCarriesThePasswordStateAndTheAsk()
    testEachPressIsAnsweredOnce()
    testTheLineUnderTheField()
    testPresetsKeepThePasswordAndCopiesDoNot()
    MainActor.assumeIsolated {
        testThePasswordTypedThroughTheAppOpensThePage()
    }
}

private let password = "drive-2026"
private let passwordBlock = Decision.blocked(reason: .passwordRequired, untilText: "Opens with its password")
private let blockPageURL = URL(fileURLWithPath: "/Applications/Sandglass.app/Contents/Resources/block.html")

private func testAPasswordBlockIsAScreenWithAFieldRatherThanAWall() {
    let info = TargetDisplayInfo(targetID: "domain:drive.google.com", name: "Drive")
    let model = PauseScreenModel.for(decision: passwordBlock, info: info)
    expectEqual(
        model, PauseScreenModel(targetName: "Drive", budgetLine: nil, mode: .password),
        "a password block is drawn with a field and no budget"
    )
    guard let model else { return }
    expectEqual(
        BlockPresentation.for(decision: passwordBlock, info: info), .screen(model),
        "and it has a way through, so the screen goes up instead of the app going away"
    )
    expectEqual(BlockPage.Mode(model.mode), .password, "on the web it is the page's password state")
    expect(
        !BluntBlock.hardReasons.contains(.passwordRequired),
        "a block with a way through is not one revoking a permission should make blunter"
    )
}

private func testTheBlockPageCarriesThePasswordStateAndTheAsk() {
    guard let model = PauseScreenModel.for(
        decision: passwordBlock, info: TargetDisplayInfo(targetID: "x", name: "Drive")
    ) else { return failTest("no model for a password block") }
    let query = BlockPage.Query(model: model, target: "drive.google.com", now: noon, address: nil)
    let address = BlockPage.address(page: blockPageURL, query: query)
    expect(address.contains("mode=password"), "the page is told to draw its password state")
    expect(!address.contains("ask="), "and the app never writes an ask of its own")
    expectEqual(BlockPage.query(of: address, page: blockPageURL), query, "it reads back unchanged")

    let pressed = BlockPage.query(of: address + "&ask=7f3a", page: blockPageURL)
    expectEqual(pressed?.ask, "7f3a", "the press the page appended is read off the address")
    expectEqual(pressed?.mode, .password, "and the page is still the password page")
    let waiting = BlockPage.Query(target: "drive.google.com", name: "Drive", mode: .wait, endsAt: noon)
    let stray = BlockPage.address(page: blockPageURL, query: waiting) + "&ask=7f3a"
    expectNil(BlockPage.query(of: stray, page: blockPageURL)?.ask, "an ask stuck onto any other page asks nothing")
}

private func testEachPressIsAnsweredOnce() {
    var asks = AnsweredAsks()
    expect(!asks.isNew(nil), "a page nobody pressed asks nothing")
    expect(!asks.isNew(""), "nor does an empty nonce")
    expect(asks.isNew("a"), "the first sighting of a press raises the prompt")
    expect(!asks.isNew("a"), "the next second's reading of the same press does not")
    expect(asks.isNew("b"), "a second press is a new question")
    expect(!asks.isNew("a"), "and the first is still answered, so two tabs do not take turns")
    for index in 0..<AnsweredAsks.capacity { _ = asks.isNew("n\(index)") }
    expect(asks.isNew("a"), "only the most recent presses are remembered")
}

private func testTheLineUnderTheField() {
    expectNil(AccessCopy.problem(after: .unlocked(sessionSeconds: 60)), "an open group needs no line")
    expectEqual(AccessCopy.problem(after: .wrong(attemptsLeft: 4)), "That password doesn't match.", "a plain miss")
    expectEqual(
        AccessCopy.problem(after: .wrong(attemptsLeft: 1)),
        "That password doesn't match. 1 more try before a one-minute wait.",
        "the wait is announced before it arrives"
    )
    expectEqual(
        AccessCopy.problem(after: .wrong(attemptsLeft: 0)), "Too many tries. Try again in 1:00.",
        "the miss that starts it says how long"
    )
    expectEqual(AccessCopy.problem(after: .lockedOut(secondsLeft: 42)), "Too many tries. Try again in 0:42.", "as does every try during it")
    expectEqual(
        AccessCopy.problem(after: .refused(scheduleDecision(until: "17:00"))), "Blocked until 17:00",
        "a harder block says what it is"
    )
    expectNil(AccessCopy.problem(after: .refused(.notManaged)), "and nothing blocking says nothing")
    expectEqual(BlockCopy.why(.passwordRequired), "needs its password", "the reason has words of its own")
}

private func testPresetsKeepThePasswordAndCopiesDoNot() {
    var config = webConfig(settings: .standard)
    config.groupSettings[youtubeGroup]?.accessPassword = PasscodeHash.make(password).map(AccessPassword.custom)
    guard let current = config.settings(forGroup: youtubeGroup) else { return failTest("no group") }
    let strict = config.presets.first { $0.id == NamedPreset.strictID }
    expect(
        ConfigBuilder.settings(forPreset: strict, current: current).accessPassword != nil,
        "picking a preset does not take the password away"
    )
    expectEqual(
        ConfigBuilder.presetID(matching: current, in: config.presets), NamedPreset.standardID,
        "and a password does not make the group Custom"
    )
    guard let made = ConfigBuilder.duplicatingGroup(youtubeGroup, in: config),
          let copy = made.config.settings(forGroup: made.groupID)
    else { return failTest("the group could not be copied") }
    expectNil(copy.accessPassword, "a copy is a new group with no password nobody chose for it")
}

@MainActor
private func testThePasswordTypedThroughTheAppOpensThePage() {
    withTempDir { dir in
        var settings = GroupSettings.standard
        settings.accessPassword = PasscodeHash.make(password).map(AccessPassword.custom)
        try? Store(directory: dir).saveConfig(webConfig(settings: settings))
        let blocker = RecordingBlocker()
        let state = makeState(dir, clock: FakeClock(noon), blocker: blocker)
        state.prime()
        expectEqual(state.blockDecision(forURL: "youtube.com/watch"), passwordBlock, "the page asks for the password")
        expectEqual(state.budgetsByGroup.first?.reason, .passwordRequired, "and the group counts as blocked")

        expectEqual(state.tryAccessPassword("nope", forURL: "youtube.com/watch"), .wrong(attemptsLeft: 4), "a miss")
        expectEqual(
            state.tryAccessPassword(password, forURL: "youtube.com/watch"), .unlocked(sessionSeconds: 300),
            "the right one opens the group"
        )
        expectNil(state.budgetsByGroup.first?.reason, "it is no longer blocked")
        expect(blocker.recheckCount > 0, "and the blocker is told at once, so a parked tab goes home")
        state.stop()
    }
}
