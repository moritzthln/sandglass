import SandglassAppCore
import Foundation

/// The agent file itself: what is written, when it is rewritten, and what removing it removes.
///
/// Reachable at all because `LaunchAgentManager` takes its directory and its bundle rather than
/// finding them — the same seam `SANDGLASS_LAUNCH_AGENT_DIR` is, one layer down. Every case here
/// writes into a throwaway directory and none of them talks to `launchctl`, which is the half
/// `mac/scripts/test-keepalive.sh` part B exists for and the half no unit test may reach: whether
/// launchd *accepts* the job, and whether it really does start the app again within seconds, is
/// something only a real Mac can answer.
///
/// The bundle paths below are strings and nothing else. `/Applications/Sandglass.app` is never
/// written to, read from or created — `mayClaimAgent` asks whether the path *starts* with
/// /Applications, and that is the whole of its involvement.
func runLaunchAgentTests() {
    MainActor.assumeIsolated {
        testAFreshInstallWritesTheJobLaunchdOwns()
        testThePlistIsValidXMLLaunchdCanRead()
        testTheOldOpenShapeIsUpgradedOnce()
        testAnAgentAtTheCurrentShapeIsLeftAlone()
        testAnAgentNamingAnotherBundleIsRepointed()
        testACheckoutBuildDoesNotTakeTheAgentOffTheInstalledCopy()
        testACheckoutBuildClaimsAnAgentNamingSomethingGone()
        testAnUnreadablePlistIsRewritten()
        testNothingIsReconciledWithoutAnAgentOrABundle()
        testRemovingTakesThePlistWithIt()
    }
}

// MARK: - What is written

@MainActor
private func testAFreshInstallWritesTheJobLaunchdOwns() {
    withAgentDir { dir in
        let manager = installedAppManager(dir)
        expectNil(manager.setInstalled(true), "a fresh install writes the agent")
        expect(manager.isInstalled, "and the plist is on disk, which is the whole answer")

        guard let job = writtenJob(manager) else { return }
        expectEqual(
            job["ProgramArguments"] as? [String],
            ["/Applications/Sandglass.app/Contents/MacOS/Sandglass"],
            "launchd runs the executable in the bundle, not `open` on the bundle"
        )
        expectEqual(job["KeepAlive"] as? Bool, true, "and owns the process, so a quit is undone")
        expectEqual(job["RunAtLoad"] as? Bool, true, "starting it at login as well")
        expectEqual(job["ThrottleInterval"] as? Int, 10, "with launchd's own floor between starts")
        expectEqual(job["Label"] as? String, LaunchAgentManager.label, "under the one label")
        expectNil(job["StartInterval"], "no minute tick is left — that was the hole this closes")
    }
}

/// Serialised rather than pasted together, because a bundle path with an `&` in it would produce
/// XML launchd rejects at load time — a failure nobody would find until the Mac had rebooted.
@MainActor
private func testThePlistIsValidXMLLaunchdCanRead() {
    withAgentDir { dir in
        let manager = LaunchAgentManager(
            directory: dir, bundleURL: URL(fileURLWithPath: "/Applications/R&D Block.app")
        )
        expectNil(manager.setInstalled(true), "an install with an ampersand in the path goes through")
        guard let job = writtenJob(manager) else { return }
        expectEqual(
            job["ProgramArguments"] as? [String],
            ["/Applications/R&D Block.app/Contents/MacOS/Sandglass"],
            "and reads back as the path that went in"
        )
    }
}

// MARK: - Migration

/// The launch every Mac carrying an earlier build makes exactly once. Nobody asks for it and no
/// screen mentions it: the app finds a job it would not write today and replaces it.
@MainActor
private func testTheOldOpenShapeIsUpgradedOnce() {
    withAgentDir { dir in
        let manager = installedAppManager(dir)
        writeOldStyleAgent(dir, bundle: "/Applications/Sandglass.app")

        expectNil(manager.reconcileInstalledAgent(), "the old agent is rewritten without complaint")
        guard let job = writtenJob(manager) else { return }
        expectEqual(
            job["ProgramArguments"] as? [String],
            ["/Applications/Sandglass.app/Contents/MacOS/Sandglass"],
            "into the job launchd owns"
        )
        expectNil(job["StartInterval"], "and the minute tick is gone with it")

        let after = fileMarker(manager.plistURL)
        expectNil(manager.reconcileInstalledAgent(), "the launch after that has nothing to do")
        expectEqual(fileMarker(manager.plistURL), after, "and does not touch the file again")
    }
}

/// The steady state, and the one that has to cost nothing: an agent already saying what this
/// build would say is not rewritten, so no launch bootstraps a job over a working one.
@MainActor
private func testAnAgentAtTheCurrentShapeIsLeftAlone() {
    withAgentDir { dir in
        let manager = installedAppManager(dir)
        expectNil(manager.setInstalled(true), "it is installed")
        let after = fileMarker(manager.plistURL)

        expectNil(manager.reconcileInstalledAgent(), "the next launch finds nothing to correct")
        expectEqual(fileMarker(manager.plistURL), after, "and the plist is byte for byte the one")
    }
}

/// The move the app makes on every install: built in the checkout, copied to /Applications. An
/// agent naming the copy that used to be there starts nothing at all once that copy is gone.
@MainActor
private func testAnAgentNamingAnotherBundleIsRepointed() {
    withAgentDir { dir in
        let manager = installedAppManager(dir)
        writeCurrentStyleAgent(dir, program: "/Applications/Sandglass 2.app/Contents/MacOS/Sandglass")

        expectNil(manager.reconcileInstalledAgent(), "the agent is re-pointed at this bundle")
        expectEqual(
            writtenJob(manager)?["ProgramArguments"] as? [String],
            ["/Applications/Sandglass.app/Contents/MacOS/Sandglass"],
            "which is the copy the user actually runs"
        )
    }
}

/// Double-clicking a dev build must not aim the user's keep-alive at `mac/build`, which the next
/// build deletes. The installed copy keeps the agent as long as it is there.
@MainActor
private func testACheckoutBuildDoesNotTakeTheAgentOffTheInstalledCopy() {
    withAgentDir { dir in
        let installed = existingBundle(dir, named: "Installed.app")
        writeOldStyleAgent(dir, bundle: installed.path)
        let checkout = LaunchAgentManager(
            directory: dir, bundleURL: URL(fileURLWithPath: "/Users/someone/Sandglass/mac/build/Sandglass.app")
        )

        expectNil(checkout.reconcileInstalledAgent(), "the checkout build reports no problem")
        expectEqual(
            writtenJob(checkout)?["ProgramArguments"] as? [String],
            ["/usr/bin/open", "-g", "-a", installed.path],
            "and leaves the agent naming the copy that is still there, old shape and all"
        )
    }
}

/// The other half of the same rule: an agent naming something deleted is worse than one naming a
/// build that will be, so the checkout build takes it.
@MainActor
private func testACheckoutBuildClaimsAnAgentNamingSomethingGone() {
    withAgentDir { dir in
        writeOldStyleAgent(dir, bundle: dir.appendingPathComponent("Deleted.app").path)
        let checkoutPath = "/Users/someone/Sandglass/mac/build/Sandglass.app"
        let checkout = LaunchAgentManager(
            directory: dir, bundleURL: URL(fileURLWithPath: checkoutPath)
        )

        expectNil(checkout.reconcileInstalledAgent(), "the agent is claimed")
        expectEqual(
            writtenJob(checkout)?["ProgramArguments"] as? [String],
            ["\(checkoutPath)/Contents/MacOS/Sandglass"],
            "by the only build there is"
        )
    }
}

/// A plist this app cannot parse is not one it should be trusting to restart it.
@MainActor
private func testAnUnreadablePlistIsRewritten() {
    withAgentDir { dir in
        let manager = installedAppManager(dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("not a plist".utf8).write(to: manager.plistURL)

        expectNil(manager.reconcileInstalledAgent(), "it is replaced rather than left standing")
        expectEqual(
            writtenJob(manager)?["ProgramArguments"] as? [String],
            ["/Applications/Sandglass.app/Contents/MacOS/Sandglass"],
            "with the job this build writes"
        )
    }
}

/// It never installs one, and it never runs at all without a bundle to name.
@MainActor
private func testNothingIsReconciledWithoutAnAgentOrABundle() {
    withAgentDir { dir in
        let manager = installedAppManager(dir)
        expectNil(manager.reconcileInstalledAgent(), "no agent on disk is not a problem to fix")
        expect(!manager.isInstalled, "and a user with keep-alive off keeps it off")

        writeOldStyleAgent(dir, bundle: "/Applications/Sandglass.app")
        let unbundled = LaunchAgentManager(
            directory: dir, bundleURL: URL(fileURLWithPath: "/Users/someone/Sandglass/mac/.build/debug")
        )
        expectNil(unbundled.reconcileInstalledAgent(), "a `swift run` build reports no problem")
        expectEqual(
            writtenJob(unbundled)?["ProgramArguments"] as? [String],
            ["/usr/bin/open", "-g", "-a", "/Applications/Sandglass.app"],
            "and leaves the user's agent exactly as it found it"
        )
    }
}

// MARK: - Removing

@MainActor
private func testRemovingTakesThePlistWithIt() {
    withAgentDir { dir in
        let manager = installedAppManager(dir)
        expectNil(manager.setInstalled(true), "installed")
        expectNil(manager.setInstalled(false), "and removed")
        expect(!manager.isInstalled, "the plist is gone, which is what the toggle reads")
        expect(
            !FileManager.default.fileExists(atPath: manager.plistURL.path),
            "off disk and not merely forgotten"
        )
        expectNil(manager.setInstalled(false), "removing what is not there is not an error either")
    }
}

// MARK: - Fixtures

/// A throwaway LaunchAgents directory per case. Nothing here is ever the user's: the manager is
/// built with an explicit directory, which is also what keeps `launchctl` out of every case.
private func withAgentDir(_ body: (URL) -> Void) {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("sandglass-agent-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: dir) }
    body(dir)
}

/// The manager as the installed copy of Sandglass has it. The path is a string; nothing is written
/// to /Applications by any case in this file.
@MainActor
private func installedAppManager(_ dir: URL) -> LaunchAgentManager {
    LaunchAgentManager(directory: dir, bundleURL: URL(fileURLWithPath: "/Applications/Sandglass.app"))
}

/// A bundle that really is on disk, for the cases that turn on whether what the agent names still
/// exists. A directory is enough — nothing opens it.
private func existingBundle(_ dir: URL, named name: String) -> URL {
    let bundle = dir.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    return bundle
}

/// The job every build before this one wrote: a minute tick running `open -g -a` on the bundle.
private func writeOldStyleAgent(_ dir: URL, bundle: String) {
    writeAgent(dir, job: [
        "Label": LaunchAgentManager.label,
        "ProgramArguments": ["/usr/bin/open", "-g", "-a", bundle],
        "RunAtLoad": true,
        "StartInterval": 60,
    ])
}

/// Today's job, pointed wherever the case needs it.
private func writeCurrentStyleAgent(_ dir: URL, program: String) {
    writeAgent(dir, job: [
        "Label": LaunchAgentManager.label,
        "ProgramArguments": [program],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ThrottleInterval": 10,
    ])
}

private func writeAgent(_ dir: URL, job: [String: Any]) {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = try? PropertyListSerialization.data(
        fromPropertyList: job, format: .xml, options: 0
    ) else {
        failTest("the fixture agent could not be serialised")
        return
    }
    try? data.write(to: dir.appendingPathComponent("\(LaunchAgentManager.label).plist"))
}

/// The job as it now stands on disk, read the way launchd would read it.
@MainActor
private func writtenJob(_ manager: LaunchAgentManager) -> [String: Any]? {
    guard let data = try? Data(contentsOf: manager.plistURL),
          let plist = try? PropertyListSerialization.propertyList(
              from: data, options: [], format: nil
          ) as? [String: Any]
    else {
        failTest("no readable agent plist at \(manager.plistURL.path)")
        return nil
    }
    return plist
}

/// Enough of a file's identity to tell "left alone" from "written again with the same bytes":
/// the contents and the moment it was last written.
private func fileMarker(_ url: URL) -> String {
    let data = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
        .flatMap { $0 as? Date }
    return "\(modified?.timeIntervalSince1970 ?? -1)|\(data)"
}
