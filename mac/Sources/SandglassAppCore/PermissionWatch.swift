import SandglassCore
import Foundation

/// Whether macOS is letting this app do its job, and what to say when it is not.
///
/// It was `WebProtectionWatch` and was about websites alone, because that was all the Accessibility
/// grant bought: reading the address of the page in front. It buys more than that now. Sending a
/// blocked application away starts by taking it out of its fullscreen Space, and every way of doing
/// that — the attribute write and both keystrokes — is gated on the same grant. Without it a
/// fullscreen app answers `hide()` with `true` and stays exactly where it is.
///
/// **Which makes a stale grant a real bug rather than a nicety.** An ad-hoc signed app loses the
/// Accessibility grant every time it is reinstalled, and macOS goes on showing the old entry in
/// System Settings with its switch on. This app is reinstalled constantly. So the question is asked
/// of `AXIsProcessTrusted()` — the live, non-prompting answer — and never of the list.
///
/// A value with no clock of its own, like the two guards in `ActivationGuards`: every rule here is
/// a function of its arguments, and `AppState` is left with when to ask and what to do with the
/// answer.
public struct PermissionWatch: Equatable {

    /// What macOS is letting the app see and do. Set by the blocker on every tick.
    public private(set) var access: BrowserAccess = .unknown

    public init() {}

    /// Records what macOS is letting the app do, and answers whether that was news — asked once a
    /// second, so "was this news" is what keeps a settings window from redrawing itself all day
    /// over an identical value.
    public mutating func setAccess(_ access: BrowserAccess) -> Bool {
        guard self.access != access else { return false }
        self.access = access
        return true
    }

    /// What a missing grant is costing this second, given what the engine is holding shut.
    ///
    /// Asked here rather than anywhere else because this type owns the live answer about the
    /// grant, and one copy of that answer is what keeps the warning and the hiding from ever
    /// disagreeing about whether the permission is there. The rule itself is `BluntBlock`.
    public func bluntBlock(config: Config, hardBlockedGroups: Set<String>) -> BluntBlock {
        BluntBlock.standing(
            hardBlockedGroups: hardBlockedGroups, config: config, access: access
        )
    }

    /// Everything wrong with the protection right now.
    ///
    /// Derived on every refresh rather than stored, like every other warning in this app: one that
    /// outlived its cause is worse than none.
    ///
    /// The blunt response's own sentence wins where there is one, and replaces rather than joins
    /// the general warning below: it already names the same missing grant, and two lines about one
    /// permission is a status area repeating itself. See `BluntBlock.line`, which is also where
    /// the reason it speaks only about browsers is written down.
    public func degradedLines(config: Config, blunt: BluntBlock) -> [String] {
        if let line = blunt.line { return [line] }
        guard let line = permissionLine(protectsAnything: Self.protectsAnything(config)) else {
            return []
        }
        return [line]
    }

    /// The warning that something is being protected and macOS is not letting the app protect it
    /// properly.
    ///
    /// Two conditions, each one a way of not crying wolf: something is actually protected, and the
    /// permission has been looked at and found missing — `.unknown` warns about nothing, because
    /// nobody has checked yet.
    ///
    /// It used to ask only whether a *website* was protected. That was right when the grant only
    /// bought reading an address bar; it now also decides whether a fullscreen app can be sent
    /// away, so a Mac blocking nothing but applications was being told everything was fine while
    /// three of the four things it does were switched off.
    ///
    /// Automation is deliberately not in here. A browser that refuses it falls back to the
    /// accessibility route and is still protected, so a warning would be about nothing; the
    /// settings row reports it instead.
    private func permissionLine(protectsAnything: Bool) -> String? {
        guard protectsAnything, access.accessibility == .denied else { return nil }
        return "Blocking needs the Accessibility permission"
    }

    /// Whether this configuration is holding anything back at all.
    ///
    /// Assembled here rather than added to `Config`, out of the accessors that are already there:
    /// `protectsAnyWebsite` covers the four ways a group reaches the web without a target of its
    /// own, and the second clause covers every target in a group that is switched on — which is
    /// what an application is. A group that is off is not protecting anything, so a permission it
    /// would need is not missing.
    private static func protectsAnything(_ config: Config) -> Bool {
        if config.protectsAnyWebsite { return true }
        return config.targets.contains { config.activeSettings(forGroup: $0.groupID) != nil }
    }
}
