import SandglassAppCore
import Foundation

// Which applications the once-a-second sweep sends away again. The walk over
// `NSWorkspace.runningApplications` is `AppBlocker` and cannot be reached from here; what is pinned
// is the rule — who is worth asking about, who is asked, and who actually goes.

func runHideSweepTests() {
    worthAsking()
    theExemptAreNeverEvenAsked()
    onlyTheNoWayThroughStates()
    theGraceIsRespected()
    theBluntResponseOutranksTheGrace()
    everyBundleIDIsAskedAboutOnce()
}

// The id of the binary doing the sweeping, which differs from the packaged one in every run
// used to test it.
private let ourself = "io.github.moritzthln.sandglass.dev"

private func app(
    _ bundleID: String?, hidden: Bool = false, regular: Bool = true
) -> SweepCandidate {
    SweepCandidate(bundleID: bundleID, isHidden: hidden, isRegularApp: regular)
}

/// Runs the whole rule and reports both what was swept and what it had to ask about.
private func sweep(
    _ candidates: [SweepCandidate], graced: String? = nil,
    verdict: (String) -> SweepVerdict = { _ in .noWayThrough }
) -> (swept: [String], asked: [String]) {
    var asked: [String] = []
    let swept = HideSweep.appsToSendAway(
        among: candidates, runningBundleID: ourself, graced: graced
    ) { bundleID in
        asked.append(bundleID)
        return verdict(bundleID)
    }
    return (swept, asked)
}

// MARK: - Stage one: who is worth asking about

private func worthAsking() {
    expectEqual(
        HideSweep.worthAsking(
            among: [app("com.spotify.client"), app("com.tinyspeck.slackmacgap")],
            runningBundleID: ourself
        ),
        ["com.spotify.client", "com.tinyspeck.slackmacgap"],
        "two visible apps, in the order the running list gave them"
    )
    // The whole definition of "the block has already dealt with it".
    expectEqual(
        HideSweep.worthAsking(
            among: [app("com.spotify.client", hidden: true)], runningBundleID: ourself
        ),
        [],
        "an app the user cannot see is not swept"
    )
    expectEqual(
        HideSweep.worthAsking(among: [app(nil)], runningBundleID: ourself),
        [],
        "a helper with no bundle id is nothing a rule could name"
    )
    expectEqual(
        HideSweep.worthAsking(
            among: [app("com.example.agent", regular: false)], runningBundleID: ourself
        ),
        [],
        "a background agent is not an app anybody is looking at"
    )
    // Several instances of one bundle id are one hide: `AppHider` loops over them itself.
    expectEqual(
        HideSweep.worthAsking(
            among: [app("com.google.Chrome"), app("com.google.Chrome")], runningBundleID: ourself
        ),
        ["com.google.Chrome"],
        "two instances of one app are one entry"
    )
    // The hidden instance must not speak for the visible one.
    expectEqual(
        HideSweep.worthAsking(
            among: [app("com.google.Chrome", hidden: true), app("com.google.Chrome")],
            runningBundleID: ourself
        ),
        ["com.google.Chrome"],
        "one instance still visible is enough to sweep the id"
    )
}

// MARK: - The never-hidden list

private func theExemptAreNeverEvenAsked() {
    let candidates = HideExemptions.essentialBundleIDs.sorted().map { app($0) }
        + [app(ourself), app("com.spotify.client")]
    let run = sweep(candidates)
    expectEqual(
        run.swept, ["com.spotify.client"], "only the app that is not on the never-hidden list goes"
    )
    // Not merely filtered afterwards: the cheap half runs first, so an exempt app costs no
    // engine lookup at all — which is what makes a dozen running apps a free tick.
    expectEqual(
        run.asked, ["com.spotify.client"], "an exempt app is never even asked about"
    )
    // A development build has an id of its own; a rule that knew only the packaged one would
    // let the blocker sweep itself away in exactly the runs it is tested in.
    expect(!run.asked.contains(ourself), "the running binary's own id is never asked about")
    expect(
        !run.asked.contains("com.apple.ActivityMonitor"),
        "Activity Monitor is the way out of a block gone wrong and is never asked about"
    )
    // The other cheap gate: a hidden app is dealt with, so nothing is spent deciding about it.
    expectEqual(
        sweep([app("com.spotify.client", hidden: true)]).asked,
        [],
        "a hidden app is never asked about either"
    )
}

// MARK: - Only the states the hide already serves

private func onlyTheNoWayThroughStates() {
    expectEqual(
        sweep([app("com.spotify.client")]) { _ in .noWayThrough }.swept,
        ["com.spotify.client"],
        "blocked with no button on the screen is swept"
    )
    expectEqual(
        sweep([app("com.spotify.client")]) { _ in .hiddenWhole }.swept,
        ["com.spotify.client"],
        "the blunt response is swept too"
    )
    // The boundary that matters most: a countdown is a flow the user is in the middle of, and
    // sweeping it would hide the app out from under the screen offering the way through.
    expectEqual(
        sweep([app("com.spotify.client")]) { _ in .leaveAlone }.swept,
        [],
        "a pause screen with a way through is never swept"
    )
    let mixed = sweep([
        app("com.spotify.client"), app("com.apple.Safari"), app("com.tinyspeck.slackmacgap"),
    ]) { $0 == "com.apple.Safari" ? .leaveAlone : .noWayThrough }
    expectEqual(
        mixed.swept, ["com.spotify.client", "com.tinyspeck.slackmacgap"],
        "the one with a way through is stepped over and the rest still go"
    )
}

// MARK: - The open the user just paid for

private func theGraceIsRespected() {
    expectEqual(
        sweep([app("com.spotify.client")], graced: "com.spotify.client") { _ in .noWayThrough }
            .swept,
        [],
        "an app whose open was just spent is not swept a second later"
    )
    // The grace covers one app; an unrelated one it happens to be outstanding for changes
    // nothing about this one.
    expectEqual(
        sweep([app("com.spotify.client")], graced: "com.apple.Safari") { _ in .noWayThrough }.swept,
        ["com.spotify.client"],
        "somebody else's grace protects nobody"
    )
    expectEqual(
        sweep([app("com.spotify.client")], graced: nil) { _ in .noWayThrough }.swept,
        ["com.spotify.client"],
        "no grace outstanding, so nothing is forgiven"
    )
}

// MARK: - Which of the two wins

private func theBluntResponseOutranksTheGrace() {
    // The same order `handle(activationOf:)` walks. The two cannot meet — a hard block grants no
    // opens, so there is no forgiven activation to swallow — and where they ever did, a
    // forgiveness issued under a block with no way through would be the bug.
    expectEqual(
        sweep([app("com.google.Chrome")], graced: "com.google.Chrome") { _ in .hiddenWhole }.swept,
        ["com.google.Chrome"],
        "the blunt response is not forgiven by a grace"
    )
}

// MARK: - What a tick costs

private func everyBundleIDIsAskedAboutOnce() {
    let run = sweep([
        app("com.google.Chrome"), app("com.google.Chrome"), app("com.google.Chrome"),
    ]) { _ in .leaveAlone }
    expectEqual(
        run.asked, ["com.google.Chrome"],
        "three instances of one app cost one engine lookup, not three"
    )
    // A dozen running apps is a dozen lookups and nothing else: no window is read, no hide is
    // attempted, and nothing at all happens for the ones nobody blocks.
    let dozen = (1...12).map { app("com.example.app\($0)") }
    let quiet = sweep(dozen) { _ in .leaveAlone }
    expectEqual(quiet.asked.count, 12, "a dozen apps is a dozen asks")
    expectEqual(quiet.swept, [], "and on an ordinary tick nothing at all is sent away")
}
