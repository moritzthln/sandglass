/// Whether Sandglass may be quit right now.
///
/// **It always may.** That is a decision rather than an omission, taken deliberately against the
/// stricter alternative: both "Quit" and "Turn off and quit" work at any time, strict windows or
/// not. The passcode, when one is set, is the only thing left standing in front of the second of
/// them.
///
/// **What forced it.** A group blocked around the clock made quitting *permanently* impossible.
/// The refusal read "Sandglass can be quit once the block is over" over a block that is never over,
/// which is a dialogue promising a moment that never comes — a trap rather than a commitment
/// device. It bought nothing either: the block lives in `state.json` and launchd starts the app
/// again within seconds, so refusing a quit only ever delayed a pause the user could take anyway
/// with `pkill`. What holds strict mode together is the agent, and never this.
///
/// So one question is left, and it is not about a lock: quitting an app that is back seconds
/// later is worth asking about, or the user watches it reappear believing the quit did not
/// work. `systemInitiated` skips even that. A logout, a restart and a shutdown are the *system*
/// asking, exactly as SIGTERM is, and an app that answers one with a modal dialogue is an app that
/// does not answer: macOS gives it seconds, and "Sandglass cancelled the shutdown" is what the user
/// reads. The caller decides what counts as the system asking; see `AppDelegate`.
///
/// A free function over two facts rather than a method on `AppState`, so the rule can be read
/// without the loop around it. `AppState.quitDecision(systemInitiated:)` is where they come from.
enum QuitPolicy {

    static func decision(systemInitiated: Bool, keepAliveEnabled: Bool) -> QuitDecision {
        if systemInitiated { return .allowed }
        return keepAliveEnabled ? .confirmKeepAlive : .allowed
    }
}
