import Foundation

/// The one-time move from the app's previous name, AppBlock.
///
/// Two things carried the old name and both would outlive a plain rename. The data directory:
/// `~/Library/Application Support/AppBlock` holds the user's groups, history and streak, and a
/// Sandglass that started from an empty directory would greet them with a first launch. And the
/// keep-alive agent: `com.moritz.appblock.agent` is a `KeepAlive` job naming the old bundle, so
/// if it stays, launchd starts the old app beside the new one every time it stops — forever.
///
/// Both steps are idempotent and both are safe to run on a Mac that never had the old app, which
/// is every Mac but a handful: they find nothing and do nothing.
public enum LegacyMigration {
    /// The old app's keep-alive label.
    public static let legacyAgentLabel = "com.moritz.appblock.agent"
    /// The old app's bundle identifier, for retiring a copy that is still running.
    public static let legacyBundleID = "com.moritz.appblock"
    /// The old data directory's name, a sibling of Sandglass's under Application Support.
    public static let legacyDirectoryName = "AppBlock"
    /// Left in the old directory after a move, so a user who goes looking finds where it went.
    public static let breadcrumbName = "MOVED-TO-SANDGLASS.txt"

    public enum DataOutcome: Equatable {
        case nothingToDo
        /// The names moved, sorted.
        case moved([String])
        /// The move started and could not finish; the message is for the log.
        case failed(String)
    }

    /// Moves the old directory's files into Sandglass's, once.
    ///
    /// Only when the old directory holds a `config.json` and the new one does not: a Sandglass
    /// that already has a configuration is the user's current one, and nothing may overwrite
    /// it. File by file, skipping any name the destination already has, so no step of this can
    /// replace something Sandglass wrote. Moved rather than copied, which is also what makes it
    /// once: the old directory has no config afterwards, so the next launch finds nothing to do.
    ///
    /// The old directory itself stays, with a one-line breadcrumb in it. Deleting it would erase
    /// the one place a confused user would look, and whatever was skipped is still in there.
    public static func migrateData(
        from legacy: URL, to current: URL, fileManager fm: FileManager = .default
    ) -> DataOutcome {
        guard fm.fileExists(atPath: legacy.appendingPathComponent("config.json").path),
              !fm.fileExists(atPath: current.appendingPathComponent("config.json").path)
        else { return .nothingToDo }
        do {
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            let names = try fm.contentsOfDirectory(atPath: legacy.path)
                .filter { $0 != breadcrumbName }
                .sorted()
            var moved: [String] = []
            for name in names
            where !fm.fileExists(atPath: current.appendingPathComponent(name).path) {
                try fm.moveItem(
                    at: legacy.appendingPathComponent(name),
                    to: current.appendingPathComponent(name)
                )
                moved.append(name)
            }
            let crumb = "Sandglass (formerly AppBlock) moved this data to \(current.path)\n"
            try? Data(crumb.utf8).write(to: legacy.appendingPathComponent(breadcrumbName))
            return .moved(moved)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// What `retireLegacyAgent` found.
public enum LegacyAgentOutcome: Equatable {
    /// No old agent in this directory: the old app was never installed, or already migrated.
    case absent
    /// Booted out and its plist removed.
    case retired
    /// Booted out, but its plist could not be removed; the message is for the log.
    case failed(String)
}

extension LaunchAgentManager {
    /// Retires the old app's keep-alive agent, if this LaunchAgents directory holds one.
    ///
    /// Booted out first, then its plist removed: the bootout stops the running job (and the old
    /// app with it, since launchd owns that process), and removing the plist stops the next
    /// login from loading it again. Tolerant of a job launchd no longer has — a bootout that
    /// finds nothing is not a failure. A plist that cannot be removed is reported, because that
    /// is the one outcome that brings the old app back at the next login.
    ///
    /// `bootout` defaults to the real `launchctl` for the installed app and to nothing at all for
    /// a redirected manager, which is the same rule `talksToLaunchd` keeps everywhere else.
    @discardableResult
    public func retireLegacyAgent(bootout: ((String) -> Void)? = nil) -> LegacyAgentOutcome {
        let plist = directory.appendingPathComponent("\(LegacyMigration.legacyAgentLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return .absent }
        (bootout ?? defaultLegacyBootout)(LegacyMigration.legacyAgentLabel)
        do {
            try FileManager.default.removeItem(at: plist)
            return .retired
        } catch {
            return .failed("Couldn't remove the old AppBlock agent — \(error.localizedDescription)")
        }
    }

    /// Installs Sandglass's own agent when the old app had one, so keep-alive stays on across
    /// the rename.
    ///
    /// Needed because the first-run seed will not do it: a migrated configuration recorded its
    /// keep-alive round long ago under the old name, so `AppState.seedKeepAlive` finds nothing
    /// owed — and with the old agent retired, the user would be left with none at all and a
    /// toggle that quietly says "off". Called after the data has moved, because installing
    /// bootstraps the job, launchd starts a fresh copy of the app, and that copy retires this one.
    @discardableResult
    public func carryOverKeepAlive(from outcome: LegacyAgentOutcome) -> String? {
        guard outcome != .absent, !isInstalled else { return nil }
        return setInstalled(true)
    }
}
