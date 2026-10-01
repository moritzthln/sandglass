import SandglassCore
import Foundation

/// Why Sandglass switches itself on at login without being asked, and what stops it from ever
/// doing so a second time.
///
/// **It happens once, silently.** Starting at login and coming back after a kill is not a
/// preference the app has an opinion about — a blocker that does not survive a restart is off on
/// the morning somebody reboots and forgets. Finishing the setup wizard used to switch the agent
/// on; the wizard was deleted and nothing took the job over, so a fresh install ran with it off
/// and a toggle in Settings → Protection that explained itself to nobody. There is no dialogue
/// here and no wizard coming back: the app does it, and the toggle stays for anybody who
/// disagrees.
///
/// **A later switch-off has to hold**, which is what the whole shape is for. "Install one when
/// none is installed" reads a first run off the agent's absence — so turning it off would put it
/// straight back on the next launch, and the toggle would be a lie. What is recorded instead is
/// the **offer**: `Config.keepAliveSeed` counts the rounds a file has been offered and never what
/// is present, so the record outlives both the agent being removed and the switch being turned
/// off. That is `Config.categorySeed`'s shape, and it is here for the reason a deleted category
/// stays deleted.
///
/// **A failed install is not recorded, and is tried again next launch.** Writing the plist can
/// fail — a home directory that is read-only this second, a launchd domain that will not answer —
/// and a round written against a write that never happened would make one bad launch permanent:
/// the app would never start at login again and no screen would say why. A retry costs one file
/// write; the alternative costs the feature. Which is why the round follows what the manager says
/// is installed afterwards rather than what was asked of it — see `AppState.seedKeepAlive`.
///
/// **Where it sits at launch.** `LaunchAgentManager.reconcileInstalledAgent` runs first: it
/// rewrites an agent that is not what this build would write — a bundle this app is no longer at,
/// or a job an older build wrote in the older shape. The seed asks only whether an agent is
/// installed, and asks after — so a reconcile that failed, which takes the plist off disk
/// when launchd refuses the rewritten one, is answered with an install rather than with a round
/// recorded against nothing. The other direction is safe by construction: what the seed installs
/// already names this bundle, and the reconcile has been and gone.
public enum KeepAliveSeed {

    /// Whether this configuration is still owed the switch-on.
    public static func isOwed(_ config: Config) -> Bool {
        config.keepAliveSeed < Config.currentKeepAliveSeed
    }

    /// The same configuration with the round written down.
    public static func recorded(_ config: Config) -> Config {
        var recorded = config
        recorded.keepAliveSeed = Config.currentKeepAliveSeed
        return recorded
    }
}
