import Foundation

/// What a change of configuration leaves behind in the state.
///
/// Split out of `RulesEngine` for the reason `GroupBudget` and `GroupLookup` were: it is a rule
/// about edits rather than a step in the loop. It decides nothing about blocking and touches the
/// state exactly once — to forget the groups that are no longer there.
///
/// **It used to refuse edits, and does not any more.** A group inside its own strict window was
/// frozen against loosening: a table of which way each field had to move, the app-wide switches
/// that would defeat any window, and a comparison of what the ticked categories carried. All of it
/// is gone, with the model it belonged to. A time window blocks apps and websites; **whether the
/// configuration may change is the settings lock's question alone** — app-wide, or per group. See
/// `GroupLocks`, which is where the carried-contents comparison lives on as the per-group
/// passcode's side-door guard, and `EditDirection` for the lock rule.
enum ConfigSwap {

    // MARK: - Adopting the new configuration

    /// Brings the state in line with a configuration that has just been accepted.
    ///
    /// State of groups the new configuration no longer knows is dropped, so a removed group
    /// cannot come back later carrying yesterday's spent budget. Switching a group *off* ends
    /// whatever it had running but keeps its counters: the group is off, not gone, and turning it
    /// back on this afternoon must not hand out a fresh budget for today.
    ///
    /// Sessions are dropped silently. Every caller re-reads the decisions after a configuration
    /// change anyway, so an effect announcing the end would be a second telling of the same news.
    static func apply(_ newConfig: Config, to state: inout EngineState) {
        let known = Set(newConfig.groupSettings.keys)
        state.sessions = state.sessions.filter { known.contains($0.key) }
        state.cooldownUntil = state.cooldownUntil.filter { known.contains($0.key) }
        state.cooldownUntilUptime = state.cooldownUntilUptime.filter { known.contains($0.key) }
        state.opensUsed = state.opensUsed.filter { known.contains($0.key) }
        state.deniedAttempts = state.deniedAttempts.filter { known.contains($0.key) }
        state.usageSecondsToday = state.usageSecondsToday.filter { known.contains($0.key) }
        state.sessions = state.sessions.filter { newConfig.activeSettings(forGroup: $0.key) != nil }
    }
}
