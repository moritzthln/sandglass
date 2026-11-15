import Foundation
import SandglassCore

// The three password modes and the session kinds they buy: what a window-only password opens and
// for how long, what the budget's rules do to each kind of session, and how wrong passwords are
// counted per secret and kept across a relaunch.
//
// Shared fixtures (FakeClock, august, officeHours, makeEngine) live in EngineFixtures.swift.

func runPasswordModeTests() {
    testTheTwoKeysOnDiskReadAsOneMode()
    testAWindowPasswordSessionEndsWithItsWindow()
    testAWindowPasswordSessionEndsWhenItsWindowIsEditedAway()
    testOutsideItsWindowsAWindowPasswordGroupIsABudgetGroup()
    testAPasswordSessionStartsNoCooldown()
    testThePassReachesAWindowPasswordGroupOnlyOutsideItsWindows()
    testTypingAPasswordIntoAnOpenGroupUnlocksNothing()
    testGroupsSharingTheSettingsPasscodeShareOneCounter()
    testOneEntryForAnyPasswordCountsOncePerSecret()
    testTheCountOutlivesARelaunch()
    testAShortSessionGetsNoWarning()
    testAShadowedSessionGetsNoWarning()
    testAShorterOpenLengthShortensTheRunningSession()
    testASessionWithNoEndIsDroppedOnLoad()
}

private let password = "drive-2026"
private let monday = { (hour: Int, minute: Int) in august(10, hour, minute) }

private func customPassword() -> AccessPassword? {
    PasscodeHash.make(password).map(AccessPassword.custom)
}

private func windowPasswordSettings(sessionMinutes: Int? = 20) -> GroupSettings {
    var settings = standardSettings(windows: [officeHours])
    settings.sessionMinutes = sessionMinutes
    settings.passwordMode = customPassword().map(PasswordMode.inStrictWindows) ?? PasswordMode.none
    return settings
}

// MARK: - The mode

private func testTheTwoKeysOnDiskReadAsOneMode() {
    var settings = GroupSettings.standard
    settings.passwordMode = .inStrictWindows(.settingsPasscode)
    let text = encodedText(settings) ?? ""
    expect(text.contains(#""accessPassword""#), "the password is written under its old key")
    expect(text.contains(#""passwordOnlyInStrictWindows":true"#), "and the scope under its own")
    let back = decodedSettings(text)
    expectEqual(back?.passwordMode, .inStrictWindows(.settingsPasscode), "and both read back as one mode")

    settings.passwordMode = .always(.settingsPasscode)
    expect(encodedText(settings)?.contains("passwordOnlyInStrictWindows") == false, "always writes no scope")

    let strayScope = (encodedText(.standard) ?? "").replacingOccurrences(
        of: #""pauseSeconds""#, with: #""passwordOnlyInStrictWindows":true,"pauseSeconds""#
    )
    expectEqual(
        decodedSettings(strayScope)?.passwordMode, PasswordMode.none, "a scope with no password is none"
    )

    var edited = GroupSettings.standard
    edited.passwordOnlyInStrictWindows = true
    expectEqual(edited.passwordMode, PasswordMode.none, "and setting a scope alone sets nothing")
    edited.accessPassword = .settingsPasscode
    edited.passwordOnlyInStrictWindows = true
    expectEqual(edited.passwordMode, .inStrictWindows(.settingsPasscode), "the scope narrows a password")
    edited.accessPassword = nil
    expectEqual(edited.passwordMode, PasswordMode.none, "and goes with it")
}

private func encodedText(_ settings: GroupSettings) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(settings)).flatMap { String(data: $0, encoding: .utf8) }
}

private func decodedSettings(_ text: String) -> GroupSettings? {
    try? JSONDecoder().decode(GroupSettings.self, from: Data(text.utf8))
}

// MARK: - A window-only password

/// The owner's call: a password session ends at the end of its strict window. Past the window
/// the group spends its budget again, so a session running on would be a free open.
private func testAWindowPasswordSessionEndsWithItsWindow() {
    let clock = FakeClock(monday(16, 50))
    let (engine, target) = makeEngine(settings: windowPasswordSettings(), clock: clock)
    expectEqual(
        engine.tryAccessPassword(password, targetID: target.id), .unlocked(sessionSeconds: 600),
        "ten minutes before the window closes, the password opens it for those ten minutes"
    )
    clock.advance(seconds: 599)
    expectEqual(
        engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 1), "to the last second"
    )
    clock.advance(seconds: 1)
    expect(engine.tick().contains(.sessionEnded(groupID: youtubeGroup)), "then it ends, and says so")
    guard case .pause = engine.decision(targetID: target.id) else {
        return expect(false, "after the window it is the ordinary pause again")
    }
    expectEqual(opensUsed(engine), 0, "and the password spent nothing")
}

private func testAWindowPasswordSessionEndsWhenItsWindowIsEditedAway() {
    let clock = FakeClock(monday(10, 0))
    let (engine, target) = makeEngine(settings: windowPasswordSettings(), clock: clock)
    _ = engine.tryAccessPassword(password, targetID: target.id)
    var config = engine.config
    config.groupSettings[youtubeGroup]?.timeWindows = []
    engine.updateConfig(config)
    expect(engine.tick().contains(.sessionEnded(groupID: youtubeGroup)), "no window, no password session")
    guard case .pause = engine.decision(targetID: target.id) else {
        return expect(false, "and the group is a budget group")
    }
}

/// Outside its windows the group spends its budget, and every rule of a budget follows: the time
/// limit relocks what the budget bought, and leaving early earns half an open back.
private func testOutsideItsWindowsAWindowPasswordGroupIsABudgetGroup() {
    let clock = FakeClock(monday(18, 0))
    var settings = windowPasswordSettings(sessionMinutes: 20)
    settings.dailyMinutes = 10
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    guard case .granted = engine.consumeOpen(targetID: target.id) else {
        return expect(false, "an ordinary open after hours")
    }
    engine.recordUsage(groupID: youtubeGroup, seconds: 600)
    expect(engine.tick().contains(.sessionEnded(groupID: youtubeGroup)), "the time limit relocks it")
    expectNil(engine.state.sessions[youtubeGroup], "and the session is gone")

    let (early, site) = makeEngine(settings: windowPasswordSettings(), clock: clock)
    _ = early.consumeOpen(targetID: site.id)
    clock.advance(seconds: 60)
    early.endSession(targetID: site.id, early: true)
    expectEqual(opensUsed(early), 0.5, "leaving early earns half an open back")
}

private func testAPasswordSessionStartsNoCooldown() {
    let clock = FakeClock(monday(16, 30))
    let (engine, target) = makeEngine(settings: windowPasswordSettings(), clock: clock)
    _ = engine.tryAccessPassword(password, targetID: target.id)
    clock.advance(seconds: 60)
    engine.endSession(targetID: target.id, early: true)
    expectNil(engine.state.cooldownUntil[youtubeGroup], "leaving a password session starts no cooldown")
    expectEqual(opensUsed(engine), 0, "and earns nothing back")
    clock.now = monday(17, 1)
    guard case .pause = engine.decision(targetID: target.id) else {
        return expect(false, "so the first open after the window is the ordinary pause")
    }
}

private func testThePassReachesAWindowPasswordGroupOnlyOutsideItsWindows() {
    let clock = FakeClock(monday(18, 0))
    let (engine, target) = makeEngine(settings: windowPasswordSettings(), clock: clock)
    expect(engine.useEmergencyPass(), "the pass is spent")
    expectEqual(
        engine.decision(targetID: target.id), .notManaged, "after hours it lifts the group like any other"
    )

    let inside = FakeClock(monday(10, 0))
    let (held, site) = makeEngine(settings: windowPasswordSettings(), clock: inside)
    expect(held.useEmergencyPass(), "a pass inside the window")
    guard case .blocked(.passwordRequired, _) = held.decision(targetID: site.id) else {
        return expect(false, "inside the window the password is still the way through")
    }
    let (paused, pausedSite) = makeEngine(settings: windowPasswordSettings(), clock: clock)
    expect(paused.pauseProtection(minutes: 30), "a break after hours")
    expectEqual(paused.decision(targetID: pausedSite.id), .notManaged, "reaches it too")
    expect(windowPasswordSettings().shutsOutAppWideUnblocks, "and the settings stay behind the password")
}

// MARK: - What the prompt says

private func testTypingAPasswordIntoAnOpenGroupUnlocksNothing() {
    let clock = FakeClock(monday(18, 0))
    let (engine, target) = makeEngine(settings: windowPasswordSettings(), clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    let open = engine.decision(targetID: target.id)
    expectEqual(
        engine.tryAccessPassword("nope", targetID: target.id), .refused(open),
        "a wrong password typed into an open group is not an unlock"
    )
    expectNil(engine.state.accessAttempts, "and nothing was counted")
}

// MARK: - Counting

private func testGroupsSharingTheSettingsPasscodeShareOneCounter() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.passwordMode = .always(.settingsPasscode)
    let (engine, site, other) = makeTwoGroupEngine(youtube: settings, reddit: settings, clock: clock)
    var config = engine.config
    config.settingsLock.passcode = PasscodeHash.make("2468")
    engine.updateConfig(config)
    for _ in 1...3 { _ = engine.tryAccessPassword("1111", targetID: site.id) }
    expectEqual(
        engine.tryAccessPassword("1111", targetID: other.id), .wrong(attemptsLeft: 1),
        "the other group's door is in front of the same secret"
    )
    _ = engine.tryAccessPassword("1111", targetID: other.id)
    expectEqual(
        engine.tryAccessPassword("2468", targetID: site.id), .lockedOut(secondsLeft: 60),
        "five misses between them, not five each"
    )
}

private func testOneEntryForAnyPasswordCountsOncePerSecret() {
    let clock = FakeClock(noon)
    var shared = GroupSettings.standard
    shared.passwordMode = .always(.settingsPasscode)
    var own = GroupSettings.standard
    own.passwordMode = customPassword().map(PasswordMode.always) ?? PasswordMode.none
    let (engine, _, _) = makeTwoGroupEngine(youtube: shared, reddit: own, clock: clock)
    var config = engine.config
    config.settingsLock.passcode = PasscodeHash.make("2468")
    engine.updateConfig(config)
    let groups = [youtubeGroup, redditGroup]
    expectNil(
        engine.verifyAnyAccessPassword(password, groupIDs: groups), "the second group's password is enough"
    )
    expectNil(engine.state.accessAttempts, "and the first group's secret was charged nothing for it")
    expectEqual(
        engine.verifyAnyAccessPassword("nope", groupIDs: groups), .wrong(attemptsLeft: 4),
        "a miss is one miss"
    )
    expectEqual(
        engine.verifyAccessPassword("nope", groupID: youtubeGroup), .wrong(attemptsLeft: 3),
        "on each secret it was a guess at"
    )
}

/// The count used to live in memory, so quitting reset it — and the keep-alive's restart made
/// quitting cheap.
private func testTheCountOutlivesARelaunch() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.passwordMode = customPassword().map(PasswordMode.always) ?? PasswordMode.none
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    for _ in 1...5 { _ = engine.tryAccessPassword("nope", targetID: target.id) }
    guard let data = try? JSONEncoder().encode(engine.state),
          let saved = try? JSONDecoder().decode(EngineState.self, from: data) else {
        return expect(false, "the state round-trips")
    }
    clock.advance(seconds: 10)
    let relaunched = RulesEngine(config: engine.config, state: saved, clock: clock, calendar: testCalendar)
    expectEqual(
        relaunched.tryAccessPassword(password, targetID: target.id), .lockedOut(secondsLeft: 50),
        "the wait is still running after a relaunch"
    )
    clock.reboot()
    let rebooted = RulesEngine(config: engine.config, state: saved, clock: clock, calendar: testCalendar)
    expectEqual(
        rebooted.accessWaitSeconds(groupID: youtubeGroup), 50,
        "and after a reboot the wall date carries it"
    )
    var old = initialState(clock)
    old.accessAttempts = nil
    let text = (try? JSONEncoder().encode(old)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    expect(!text.contains("accessAttempts"), "a state with nothing counted writes no key")
}

// MARK: - Sessions

private func testAShortSessionGetsNoWarning() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.dailyMinutes = 1
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    engine.recordUsage(groupID: youtubeGroup, seconds: 30)
    guard case .granted(let seconds?) = engine.consumeOpen(targetID: target.id) else {
        return expect(false, "an open with half a minute of the day left")
    }
    expectEqual(seconds, 30, "is half a minute long")
    expect(engine.tick().isEmpty, "and its first tick warns of nothing the grant did not say")
}

private func testAShadowedSessionGetsNoWarning() {
    let clock = FakeClock(monday(8, 50))
    var settings = standardSettings(windows: [officeHours])
    settings.sessionMinutes = 15
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.now = monday(9, 4).addingTimeInterval(30)
    expect(
        !engine.tick().contains { if case .sessionWarning = $0 { return true } else { return false } },
        "a session the strict window is holding is not warned about"
    )
}

private func testAShorterOpenLengthShortensTheRunningSession() {
    let clock = FakeClock(noon)
    var settings = GroupSettings.standard
    settings.sessionMinutes = 30
    let (engine, target) = makeEngine(settings: settings, clock: clock)
    _ = engine.consumeOpen(targetID: target.id)
    clock.advance(seconds: 60)
    var config = engine.config
    config.groupSettings[youtubeGroup]?.sessionMinutes = 5
    engine.updateConfig(config)
    expectEqual(
        engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 240),
        "a shorter open length cuts the open already running"
    )
    config.groupSettings[youtubeGroup]?.sessionMinutes = 60
    engine.updateConfig(config)
    expectEqual(
        engine.decision(targetID: target.id), .allowed(remainingSessionSeconds: 240),
        "and a longer one hands nothing back"
    )
}

private func testASessionWithNoEndIsDroppedOnLoad() {
    let clock = FakeClock(noon)
    var state = initialState(clock)
    state.sessions[youtubeGroup] = ActiveSession(
        groupID: youtubeGroup, startedAt: noon, endsAt: nil, warned: false
    )
    let target = Target(kind: .domain, value: "youtube.com", displayName: "YouTube")
    let engine = makeEngine(
        targets: [target], groupSettings: [youtubeGroup: .standard], state: state, clock: clock
    )
    expectNil(engine.state.sessions[youtubeGroup], "a session nothing would ever end is not kept")
}
