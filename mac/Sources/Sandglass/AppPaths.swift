import SandglassAppCore
import SandglassCore
import Foundation

/// Where Sandglass keeps its files, in one place.
///
/// The override exists for `scripts/test-keepalive.sh`, which drives the real app and must not
/// touch the user's own history to do it. Everything that needs the directory reads it from
/// here, so a redirected run is redirected whole rather than in pieces.
///
/// Its own file rather than a preamble to whichever type happened to need it first: a path
/// policy belongs to nobody in particular.
enum AppPaths {
    static let supportDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["SANDGLASS_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Store.defaultDirectory
    }()

    /// Where the app kept its files under its previous name, AppBlock — or `nil` for a run
    /// redirected by `SANDGLASS_SUPPORT_DIR`, which must never reach into the real Application
    /// Support folder, not even to read from it.
    static var legacySupportDirectory: URL? {
        guard ProcessInfo.processInfo.environment["SANDGLASS_SUPPORT_DIR"].map(\.isEmpty) ?? true
        else { return nil }
        return Store.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent(LegacyMigration.legacyDirectoryName, isDirectory: true)
    }
}
