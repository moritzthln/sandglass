import SandglassAppCore
import SandglassCore
import Foundation

/// The banner that says what has already refused an edit on the group editor.
///
/// Checked here rather than by opening the window, because the failure it exists to prevent is
/// silence: every one of these refusals was reachable and none of them was visible until the user
/// pressed something. A rule that only announces itself once it has been broken is worse than no
/// rule, and "does it announce itself" is a question about strings.
func runEditorFreezeTests() {
    testNothingFrozenSaysNothing()
    testTheTimerIsNamedBeforeThePasscode()
    testEveryFreezeThatAppliesIsListed()
    testTheTwoFreezesThatStopEverythingSayThatTheyDo()
    testAWaitNarrowsThePageRatherThanKillingIt()
    testTheGroupsOwnLockSpeaksForItselfOnThePageItHolds()
}

/// The group's own lock is the fourth thing that can have refused an edit here. It says so in the
/// app-wide lock's shape, one scope down — a wait narrows the page and a passcode stops it — and
/// it names no number, because nothing on this window counts this one down.
private func testTheGroupsOwnLockSpeaksForItselfOnThePageItHolds() {
    expect(
        EditorFreeze.tighteningOnly(
            lock: SettingsLockState(), groupLock: GroupLockState(unlockSeconds: 120),
            focusSessionLine: nil
        ),
        "this group's own wait points the whole page in one direction"
    )
    expect(
        !EditorFreeze.freezesEverything(
            lock: SettingsLockState(), groupLock: GroupLockState(unlockSeconds: 120),
            focusSessionLine: nil
        ),
        "and does not kill it: a knob turned towards more friction still goes through"
    )
    expect(
        EditorFreeze.freezesEverything(
            lock: SettingsLockState(), groupLock: GroupLockState(passcodeRequired: true),
            focusSessionLine: nil
        ),
        "while its own passcode stops the lot, on the one path that could draw the page anyway"
    )
    expect(
        !EditorFreeze.freezesEverything(
            lock: SettingsLockState(), groupLock: GroupLockState(resetSeconds: 600),
            focusSessionLine: nil
        ),
        "an hour waiting to clear a forgotten code holds nothing by itself"
    )
    expect(
        !EditorFreeze.tighteningOnly(
            lock: SettingsLockState(), groupLock: GroupLockState(resetSeconds: 600),
            focusSessionLine: nil
        ),
        "and does not narrow the page either"
    )
    expectEqual(
        EditorFreeze.notices(
            lock: SettingsLockState(), groupLock: GroupLockState(unlockSeconds: 120),
            focusSessionLine: nil),
        ["Held by this group's own lock. Only changes that block harder go through while it runs."],
        "and the banner says which lock it is"
    )
    expectEqual(
        EditorFreeze.notices(
            lock: SettingsLockState(unlockSeconds: 300),
            groupLock: GroupLockState(unlockSeconds: 120),
            focusSessionLine: nil).count,
        2, "with both waits running, both are named — they lift at different times"
    )
}

/// The banner and the controls have to agree. The editor drew every knob live under the settings
/// lock and under a focus session, then refused each one on the press — while the sentence at the
/// top of the same page said nothing could change. This is the rule that greys them out, and it
/// covers the two freezes that leave no direction open at all.
private func testTheTwoFreezesThatStopEverythingSayThatTheyDo() {
    expect(
        EditorFreeze.freezesEverything(
            lock: SettingsLockState(passcodeRequired: true), focusSessionLine: nil
        ),
        "a passcode that has not been entered this visit stops the whole page"
    )
    expect(
        EditorFreeze.freezesEverything(
            lock: SettingsLockState(), focusSessionLine: "Everything is blocked until 12:25"
        ),
        "and so does a focus session"
    )
    expect(
        !EditorFreeze.freezesEverything(lock: SettingsLockState(), focusSessionLine: nil),
        "with neither of them running the page is free"
    )
    expect(
        EditorFreeze.freezesEverything(
            lock: SettingsLockState(), groupLock: GroupLockState(passcodeRequired: true),
            focusSessionLine: nil
        ),
        "and so does the group's own code"
    )
    // The banner and the greying-out read the same condition, so they cannot come apart.
    for lock in [SettingsLockState(unlockSeconds: 300), SettingsLockState(passcodeRequired: true)] {
        expect(
            !EditorFreeze.notices(
                lock: lock, focusSessionLine: nil).isEmpty,
            "whatever holds the controls has a sentence above them saying so"
        )
    }
}

/// The half the lock rule added back: a **wait** points the page in a direction rather than
/// killing it, so a knob may still be turned towards more friction while it runs.
///
/// Two questions rather than one, and they must never both be true: a page drawn half-live under a
/// passcode would be two rules arguing on one screen.
private func testAWaitNarrowsThePageRatherThanKillingIt() {
    expect(
        EditorFreeze.tighteningOnly(
            lock: SettingsLockState(unlockSeconds: 300), focusSessionLine: nil
        ),
        "the settings lock's wait narrows the page"
    )
    expect(
        !EditorFreeze.freezesEverything(
            lock: SettingsLockState(unlockSeconds: 300), focusSessionLine: nil
        ),
        "and does not stop it"
    )
    expect(
        !EditorFreeze.tighteningOnly(lock: SettingsLockState(), focusSessionLine: nil),
        "with nothing running there is no direction to point in"
    )
    for held in [
        SettingsLockState(unlockSeconds: 300, passcodeRequired: true),
        SettingsLockState(unlockSeconds: 300),
    ] {
        expect(
            !EditorFreeze.tighteningOnly(
                lock: held, focusSessionLine: "Everything is blocked until 12:25"
            ),
            "a freeze outranks the narrowing, so the two can never both be true"
        )
    }
    expect(
        !EditorFreeze.tighteningOnly(
            lock: SettingsLockState(unlockSeconds: 300, passcodeRequired: true),
            focusSessionLine: nil
        ),
        "and an unanswered passcode does the same, wait or no wait"
    )
}

/// The pill beside the group editor's switch: what this group is doing *this second*.
///
/// Checked here rather than by opening the window for the reason the banner above it is: it is a
/// sentence, and a sentence written inside a `View` is one no test can read. The state it kept
/// getting wrong is the one the sidebar's shield was fixed for two waves earlier — a group that is
/// on and holding nothing back.
func runEditorStateTests() {
    testASwitchedOffGroupSaysSoBeforeAnythingElse()
    testAGroupTheEngineIsStandingDownOverDoesNotClaimToBeEnforcing()
    testAnOrdinaryGroupShowsTheEnginesOwnLine()
}

private func testASwitchedOffGroupSaysSoBeforeAnythingElse() {
    let row = BudgetRow(id: "grp:a", name: "Social", line: "3 of 5 opens left")
    expectEqual(
        EditorState.pill(isActive: false, row: row).text, "Off",
        "the switch beside it is off, so the budget behind it is not the answer"
    )
    expectEqual(EditorState.pill(isActive: false, row: row).tone, .idle, "and it reads as idle")
    // No row at all is the engine having nothing to say: the group holds neither a target, nor a
    // category, nor a rule.
    expectEqual(
        EditorState.pill(isActive: true, row: nil).text, "Nothing in it yet",
        "which is a different state from being switched off, and named as one"
    )
}

/// A break window over this group, a break over the whole app, or an emergency pass: the group is
/// on, it will block again, and at this moment nothing in it is held back. The pill used to print
/// the budget in the accent colour there — an editor claiming enforcement while the shield in the
/// sidebar beside it said the opposite.
private func testAGroupTheEngineIsStandingDownOverDoesNotClaimToBeEnforcing() {
    let open = BudgetRow(id: "grp:a", name: "Social", line: "3 of 5 opens left", isOpen: true)
    expectEqual(
        EditorState.pill(isActive: true, row: open).text, "Nothing held back",
        "the one fact worth having beside the switch while the engine stands down"
    )
    expectEqual(EditorState.pill(isActive: true, row: open).tone, .open, "in the break colour")
}

private func testAnOrdinaryGroupShowsTheEnginesOwnLine() {
    let running = BudgetRow(id: "grp:a", name: "Social", line: "3 of 5 opens left")
    expectEqual(
        EditorState.pill(isActive: true, row: running).text, "3 of 5 opens left",
        "the engine wrote the sentence; the pill only decides whether it is the right one"
    )
    expectEqual(EditorState.pill(isActive: true, row: running).tone, .running, "on and enforcing")

    let blocked = BudgetRow(
        id: "grp:a", name: "Social", line: "Blocked until 08:00", reason: .schedule
    )
    expectEqual(EditorState.pill(isActive: true, row: blocked).text, "Blocked until 08:00", "or the block")
    expectEqual(EditorState.pill(isActive: true, row: blocked).tone, .blocked, "which reads as one")
}

private func testNothingFrozenSaysNothing() {
    expect(
        EditorFreeze.notices(
            lock: SettingsLockState(), focusSessionLine: nil).isEmpty,
        "an ordinary group on an unlocked screen has nothing to warn about"
    )
}

/// The same order `SettingsLockGate.refusal` answers in: one refusal at a time, and the one with a
/// countdown on it first. Told about the passcode instead, somebody would enter it and be refused
/// a second time for a reason nobody had mentioned.
private func testTheTimerIsNamedBeforeThePasscode() {
    let both = EditorFreeze.notices(
        lock: SettingsLockState(unlockSeconds: 95, passcodeRequired: true),
        focusSessionLine: nil)
    expectEqual(both.count, 1, "the two frictions of one lock are one sentence")
    expectEqual(
        both.first,
        "Held by the settings lock. Only changes that block harder go through while it runs.",
        // It used to read "Settings unlock in 1:35. Nothing can change until then." — a snapshot
        // taken when the page was drawn, in the third of three places the app said the same
        // sentence. The count lives in one place now, at the top of the window, and it ticks.
        "and it is the one with the countdown behind it, named without naming the count"
    )
    expectEqual(
        EditorFreeze.notices(
            lock: SettingsLockState(passcodeRequired: true), focusSessionLine: nil).first,
        "Settings are locked. Enter the passcode to change anything.",
        // It no longer says where. It used to point at a row on the Settings page, and that row
        // went when the passcode moved to the door — where this page cannot be reached from at
        // all. See `EditorFreeze.lockNotice` for why the branch is kept anyway.
        "with the wait over, the passcode is named"
    )
}
/// All of them, not the first: they lift at different times, and a page that revealed the next
/// refusal only once the last had gone would take three visits to explain itself.
///
/// Three, and the fourth is gone: the group's own strict window used to raise a notice of its own
/// saying which direction the page could still be turned in. A window blocks and freezes nothing.
private func testEveryFreezeThatAppliesIsListed() {
    let notices = EditorFreeze.notices(
        lock: SettingsLockState(passcodeRequired: true),
        groupLock: GroupLockState(unlockSeconds: 300),
        focusSessionLine: "Everything is blocked until 12:25"
    )
    expectEqual(notices.count, 3, "three separate things have frozen this page")
    expect(
        notices[0].hasPrefix("Settings are locked"),
        "the app-wide lock refuses first, so it is said first"
    )
    expect(
        notices[1].hasPrefix("Held by this group's own lock"),
        "then the group's own, which is asked second"
    )
    expect(
        notices[2].hasPrefix("Everything is blocked"),
        "then the focus session, which is the engine's and is asked last"
    )
}
