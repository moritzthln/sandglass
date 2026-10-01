import Foundation

/// Which group a browser is looking at, asked of the engine.
///
/// Two forwarders to `WebResolver`, which is where the matching itself lives — an address against
/// the configured domains, their subdomains and the advanced rules. They are on the engine because
/// the browser watcher has the engine and nothing else, and they are in a file of their own because
/// `RulesEngine.swift` is at its 800-line ceiling and this is the one part of it that reads only
/// `config`: no clock, no catch-up, no state. Nothing here can be made wrong by time passing, which
/// is not true of a single other method on that type.
extension RulesEngine {

    /// Which group a URL belongs to, and what put it there.
    public func webMatch(forURL url: String) -> WebMatch? {
        WebResolver.match(url: url, in: config)
    }

    /// The configured target a browser host belongs to.
    ///
    /// Kept because the app still asks the question about a bare host, and because it is the
    /// same lookup `webMatch` falls back to — one matcher, so a pause screen can never be named
    /// after a different rule from the one that raised it.
    public func target(forDomain host: String) -> Target? {
        WebResolver.domainTarget(forHost: host, in: config)
    }
}
