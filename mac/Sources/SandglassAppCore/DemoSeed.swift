import SandglassCore
import Foundation

/// The manual test harness for the overlay, behind `SANDGLASS_SEED_DEMO`.
///
/// A type of its own rather than three methods on `AppState`, because none of it is production
/// surface: it exists so a verification run has something to block without touching whatever the
/// person running it actually blocks. What is seeded is deliberately never written to disk —
/// `AppState.seedConfigInMemory` is the only way in, and it is the only way in that does not save.
///
/// Nothing is seeded over an existing configuration. A demo run on a Mac that has real targets
/// would otherwise replace them for the length of the run, which is exactly the surprise the
/// in-memory rule exists to avoid.
@MainActor
public enum DemoSeed {

    /// One app on `settings`, which is what the native overlay is exercised against.
    ///
    /// `settings` is a parameter so the gentle preset can be reached on a real Mac: gentle grants
    /// an open with no session behind it, which is the case the blocker's activation grace exists
    /// for and the one no other preset can reproduce.
    public static func app(_ state: AppState, settings: GroupSettings = .standard) {
        seedIfEmpty(
            state,
            Target(kind: .app, value: "com.apple.Notes", displayName: "Notes"),
            settings: settings
        )
    }

    /// The same harness for the browser side: one website on the standard preset, which is what
    /// the pause screen over a page is exercised against.
    public static func domain(_ state: AppState) {
        seedIfEmpty(
            state,
            Target(kind: .domain, value: "youtube.com", displayName: "YouTube"),
            settings: .standard
        )
    }

    private static func seedIfEmpty(_ state: AppState, _ target: Target, settings: GroupSettings) {
        guard state.config.targets.isEmpty else { return }
        state.seedConfigInMemory(Config(
            version: 1,
            targets: [target],
            groupSettings: [target.groupID: settings]
        ))
    }
}
