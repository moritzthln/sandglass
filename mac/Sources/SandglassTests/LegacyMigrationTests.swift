import SandglassAppCore
import Foundation

/// The one-time move from the app's previous name, AppBlock, to Sandglass.
///
/// Both halves are reached through seams and nothing else: the data move takes its two directories
/// as arguments, and the agent retirement takes the LaunchAgents directory the manager was built
/// with plus a closure standing in for `launchctl bootout`. Every case writes into `mktemp`-style
/// throwaway directories; none touches `~/Library`.
func runLegacyMigrationTests() {
    testNothingToMoveWhenThereIsNoLegacyConfig()
    testTheLegacyFilesAreMovedOnce()
    testAnExistingSandglassConfigIsNeverOverwritten()
    testAFileAlreadyAtTheDestinationIsKept()
    testTheBreadcrumbSaysWhereTheDataWent()
    testAMissingLegacyDirectoryIsNotAnError()
    MainActor.assumeIsolated {
        testTheLegacyAgentIsBootedOutAndItsPlistRemoved()
        testNoLegacyAgentMeansNoLaunchctl()
        testARedirectedManagerNeverTalksToLaunchd()
        testTheCurrentAgentIsLeftAlone()
        testKeepAliveCarriesOverFromTheOldAgent()
        testNoOldAgentMeansNothingIsCarriedOver()
    }
}

// MARK: - Data

private func testNothingToMoveWhenThereIsNoLegacyConfig() {
    withDirs { legacy, current in
        write("{}", to: legacy.appendingPathComponent("state.json"))
        let outcome = LegacyMigration.migrateData(from: legacy, to: current)
        expectEqual(outcome, .nothingToDo, "a legacy directory without a config is not a migration")
        expect(exists(legacy.appendingPathComponent("state.json")), "and nothing is moved out of it")
        expect(!exists(legacy.appendingPathComponent(LegacyMigration.breadcrumbName)), "nor a breadcrumb left")
    }
}

private func testTheLegacyFilesAreMovedOnce() {
    withDirs { legacy, current in
        write("{\"v\":1}", to: legacy.appendingPathComponent("config.json"))
        write("{\"s\":1}", to: legacy.appendingPathComponent("state.json"))
        write("{}\n", to: legacy.appendingPathComponent("events.jsonl"))
        let outcome = LegacyMigration.migrateData(from: legacy, to: current)
        expectEqual(
            outcome, .moved(["config.json", "events.jsonl", "state.json"]),
            "config, state and events move over"
        )
        expectEqual(read(current.appendingPathComponent("config.json")), "{\"v\":1}", "the config arrives intact")
        expectEqual(read(current.appendingPathComponent("state.json")), "{\"s\":1}", "and the state")
        expect(!exists(legacy.appendingPathComponent("config.json")), "moved, not copied")
        expectEqual(
            LegacyMigration.migrateData(from: legacy, to: current), .nothingToDo,
            "a second launch finds nothing left to move"
        )
    }
}

private func testAnExistingSandglassConfigIsNeverOverwritten() {
    withDirs { legacy, current in
        write("new", to: current.appendingPathComponent("config.json"))
        write("old", to: legacy.appendingPathComponent("config.json"))
        let outcome = LegacyMigration.migrateData(from: legacy, to: current)
        expectEqual(outcome, .nothingToDo, "a Sandglass that already has a config is left alone")
        expectEqual(read(current.appendingPathComponent("config.json")), "new", "its config is untouched")
        expectEqual(read(legacy.appendingPathComponent("config.json")), "old", "and so is the legacy one")
    }
}

private func testAFileAlreadyAtTheDestinationIsKept() {
    withDirs { legacy, current in
        write("current-state", to: current.appendingPathComponent("state.json"))
        write("old-config", to: legacy.appendingPathComponent("config.json"))
        write("old-state", to: legacy.appendingPathComponent("state.json"))
        let outcome = LegacyMigration.migrateData(from: legacy, to: current)
        expectEqual(outcome, .moved(["config.json"]), "only what the destination lacks is moved")
        expectEqual(read(current.appendingPathComponent("state.json")), "current-state", "nothing is overwritten")
        expectEqual(read(legacy.appendingPathComponent("state.json")), "old-state", "the skipped file stays behind")
    }
}

private func testTheBreadcrumbSaysWhereTheDataWent() {
    withDirs { legacy, current in
        write("{}", to: legacy.appendingPathComponent("config.json"))
        _ = LegacyMigration.migrateData(from: legacy, to: current)
        let crumb = read(legacy.appendingPathComponent(LegacyMigration.breadcrumbName)) ?? ""
        expect(crumb.contains(current.path), "the breadcrumb names the new directory")
        expectEqual(crumb.split(separator: "\n").count, 1, "in one line")
        expect(exists(legacy), "and the old directory is left in place rather than deleted")
    }
}

private func testAMissingLegacyDirectoryIsNotAnError() {
    withDirs { legacy, current in
        try? FileManager.default.removeItem(at: legacy)
        expectEqual(
            LegacyMigration.migrateData(from: legacy, to: current), .nothingToDo,
            "a Mac that never ran the old app has nothing to migrate"
        )
        expect(!exists(legacy), "and no legacy directory is created")
    }
}

// MARK: - The old keep-alive agent

@MainActor
private func testTheLegacyAgentIsBootedOutAndItsPlistRemoved() {
    withDirs { agents, _ in
        let legacyPlist = agents.appendingPathComponent("\(LegacyMigration.legacyAgentLabel).plist")
        write("<plist/>", to: legacyPlist)
        var bootedOut: [String] = []
        let manager = LaunchAgentManager(directory: agents, bundleURL: URL(fileURLWithPath: "/Applications/Sandglass.app"))
        let outcome = manager.retireLegacyAgent(bootout: { bootedOut.append($0) })
        expectEqual(outcome, .retired, "retiring the old agent succeeds")
        expectEqual(bootedOut, [LegacyMigration.legacyAgentLabel], "the old label is booted out")
        expect(!exists(legacyPlist), "and its plist is removed, so the next login does not bring it back")
    }
}

@MainActor
private func testNoLegacyAgentMeansNoLaunchctl() {
    withDirs { agents, _ in
        var bootedOut: [String] = []
        let manager = LaunchAgentManager(directory: agents, bundleURL: URL(fileURLWithPath: "/Applications/Sandglass.app"))
        expectEqual(manager.retireLegacyAgent(bootout: { bootedOut.append($0) }), .absent, "nothing to retire is not an error")
        expect(bootedOut.isEmpty, "and launchctl is not asked about a job that was never installed")
    }
}

@MainActor
private func testARedirectedManagerNeverTalksToLaunchd() {
    withDirs { agents, _ in
        let legacyPlist = agents.appendingPathComponent("\(LegacyMigration.legacyAgentLabel).plist")
        write("<plist/>", to: legacyPlist)
        let manager = LaunchAgentManager(directory: agents, bundleURL: URL(fileURLWithPath: "/Applications/Sandglass.app"))
        expectEqual(manager.retireLegacyAgent(), .retired, "the default path of a redirected manager does not fail")
        expect(!exists(legacyPlist), "it still removes the plist in its own directory")
    }
}

@MainActor
private func testTheCurrentAgentIsLeftAlone() {
    withDirs { agents, _ in
        let manager = LaunchAgentManager(directory: agents, bundleURL: URL(fileURLWithPath: "/Applications/Sandglass.app"))
        _ = manager.setInstalled(true)
        write("<plist/>", to: agents.appendingPathComponent("\(LegacyMigration.legacyAgentLabel).plist"))
        _ = manager.retireLegacyAgent(bootout: { _ in })
        expect(manager.isInstalled, "Sandglass's own agent survives the retirement of the old one")
    }
}

@MainActor
private func testKeepAliveCarriesOverFromTheOldAgent() {
    withDirs { agents, _ in
        write("<plist/>", to: agents.appendingPathComponent("\(LegacyMigration.legacyAgentLabel).plist"))
        let manager = LaunchAgentManager(directory: agents, bundleURL: URL(fileURLWithPath: "/Applications/Sandglass.app"))
        let outcome = manager.retireLegacyAgent(bootout: { _ in })
        expect(!manager.isInstalled, "retiring the old agent does not by itself install the new one")
        expectNil(manager.carryOverKeepAlive(from: outcome), "carrying keep-alive over succeeds")
        expect(manager.isInstalled, "a user who had keep-alive on under the old name keeps it on")
    }
}

@MainActor
private func testNoOldAgentMeansNothingIsCarriedOver() {
    withDirs { agents, _ in
        let manager = LaunchAgentManager(directory: agents, bundleURL: URL(fileURLWithPath: "/Applications/Sandglass.app"))
        _ = manager.carryOverKeepAlive(from: manager.retireLegacyAgent(bootout: { _ in }))
        expect(!manager.isInstalled, "with no old agent, keep-alive is left to the first-run seed and the toggle")
    }
}

// MARK: - Fixtures

private func withDirs(_ body: (URL, URL) -> Void) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("sandglass-migration-\(UUID())", isDirectory: true)
    let legacy = root.appendingPathComponent("AppBlock", isDirectory: true)
    let current = root.appendingPathComponent("Sandglass", isDirectory: true)
    try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    body(legacy, current)
}

private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

private func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}
