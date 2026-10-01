import SandglassCore
import Foundation

/// The one fact the menu bar states this second, and everything else true that it had no room
/// for.
///
/// Three things can be wrong at once — the disk, the system clock, the browser permission — and
/// the icon can only say one thing. So the lines are gathered in one list, the most urgent fact
/// wins the icon, and **the rest are handed back rather than dropped**: whatever the status line
/// does not say, the popover lists. Nothing about a degraded app is ever only implied.
///
/// The precedence is the reason this is one type rather than four questions asked in a row. A
/// running emergency pass outranks a break, which outranks a warning, which outranks the plain
/// count — because the most urgent fact about right now is that nothing is being blocked, and
/// why. Asked separately, that order would be a rule nobody owns.
///
/// It also holds `PermissionWatch`, which is not a fourth job but the same one: what macOS is
/// letting the app do is only ever read as a line in this list.
///
/// `@MainActor` and `internal` for the reason `EngineReadout` is: two of the three things it
/// asks are confined to the actor that owns the engine, and `AppState` is that actor.
@MainActor
struct StatusReadout {
    /// What the disk reported when it was last written or read.
    private let persistence: StatePersistence
    /// The clock warning, and the three facts the icon chooses between.
    private let readout: EngineReadout
    /// Whether macOS is letting the app do its job, and what to say when it is not.
    private var permissions = PermissionWatch()

    init(persistence: StatePersistence, readout: EngineReadout) {
        self.persistence = persistence
        self.readout = readout
    }

    /// What macOS is letting the app read of the frontmost browser. `false` means it is what it
    /// already was, and nothing has to be redrawn.
    mutating func setAccess(_ access: BrowserAccess) -> Bool {
        permissions.setAccess(access)
    }

    /// The icon and the popover's warnings, worked out together so the second cannot repeat the
    /// first — and, on the same pass, what a missing grant is currently being enforced with.
    ///
    /// The third value is handed back rather than asked for separately because it is worked out
    /// here anyway: it decides one of the degraded lines, and the blocker needs the very same
    /// answer to know which application to hide on its next activation. Two derivations of that
    /// would be two chances for the menu bar to say one thing while the blocker does another.
    func status(config: Config, hardBlockedGroups: Set<String>)
        -> (kind: StatusKind, warningLines: [String], blunt: BluntBlock) {
        let blunt = permissions.bluntBlock(config: config, hardBlockedGroups: hardBlockedGroups)
        let degraded = degradedLines(config: config, blunt: blunt)
        // The pass outranks the pause for the same reason a pause outranks a warning: the most
        // urgent fact about right now is that nothing is being blocked, and why.
        let kind: StatusKind
        if let until = readout.emergencyPassEndsAt {
            kind = .emergencyPass(until: until)
        } else if let until = readout.protectionPausedUntil {
            kind = .paused(until: until)
        } else if let first = degraded.first {
            kind = .degraded(first)
        } else {
            kind = .active(targetCount: readout.managedTargetCount)
        }
        if case .degraded = kind { return (kind, Array(degraded.dropFirst()), blunt) }
        return (kind, degraded, blunt)
    }

    /// Everything wrong right now, in one list: what the disk reported when it was last written
    /// or read, then the system clock, then the browser — the last two derived from the clock
    /// every time they are asked, so neither can outlive its cause.
    private func degradedLines(config: Config, blunt: BluntBlock) -> [String] {
        persistence.degradedLines
            + (readout.clockWarningLine.map { [$0] } ?? [])
            + permissions.degradedLines(config: config, blunt: blunt)
    }
}
