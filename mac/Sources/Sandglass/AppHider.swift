import SandglassAppCore
import AppKit
import ApplicationServices
import CoreGraphics

/// Sending a blocked application away, the way that still works on macOS 14+.
///
/// The whole of *what to try* is `HideLadder`, which is a value with tests. What is here is the
/// calls into macOS, none of which can be exercised on a machine with no app open and no
/// permissions granted.
///
/// **Why `hide()` alone was never enough.** An app in native fullscreen answers `hide()` with
/// `true` and leaves its Space standing, so the user watches a block do nothing. Getting it out of
/// fullscreen first is the fix, and there are three ways of asking:
///
/// - `AXFullScreen = false` on the window, which AppKit windows honour;
/// - ⌃⌘F, which Catalyst and Electron windows honour and the attribute write does not reach —
///   a synthetic key event travels through the target app's own menu handling;
/// - ⌃←, which some games and custom windows are the only thing that answers.
///
/// `NSApp.activate(ignoringOtherApps:)` was the fourth and is not used: it is deprecated since
/// macOS 14 and routinely ignored under cooperative activation, so the Space never switched.
///
/// **Nothing here prompts.** `AXIsProcessTrusted()` is the non-prompting question and it gates
/// every call below. `AXIsProcessTrustedWithOptions` with the prompt option would put a system
/// dialog on screen from a background app, which this one is not going to do.
@MainActor
enum AppHider {

    /// "AXFullScreen": the attribute macOS uses for native fullscreen windows. It has no public
    /// constant, only this string.
    private static let fullScreenAttribute = "AXFullScreen" as CFString

    /// How long one AX request may take. The default is six seconds, every one of them spent
    /// blocking the main thread — and an app that hangs is exactly the kind that also refuses to
    /// hide, so waiting for it would freeze Sandglass on the worst possible occasion.
    private static let messagingTimeout: Float = 0.25

    private static let fKeyCode: CGKeyCode = 3           // kVK_ANSI_F
    private static let leftArrowKeyCode: CGKeyCode = 123 // kVK_LeftArrow

    /// The non-prompting question every call below is gated on, asked once where the sweep needs
    /// it for a whole list of applications rather than once per application.
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Sends every running instance of a bundle id away, and answers what happened.
    ///
    /// - `escalating` is what `FullscreenEscalation` added on top of step one, for an app a hide
    ///   already claimed to have sent away and which is still on screen. Empty for every ordinary
    ///   hide, which is every hide an activation causes.
    @discardableResult
    static func hide(bundleID: String, escalating rungs: [HideRung] = []) -> HideOutcome {
        let trusted = isAccessibilityTrusted
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var outcomes: [HideOutcome] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            // The last gate before anything is hidden. A rule that named Finder, System Settings
            // or Sandglass itself would otherwise lock the user out of the machine — see
            // `HideExemptions`.
            guard HideExemptions.mayHide(
                bundleID: app.bundleIdentifier,
                isRegularApp: app.activationPolicy == .regular,
                runningBundleID: Bundle.main.bundleIdentifier
            ) else { continue }
            outcomes.append(send(
                app, away: trusted, isFrontmost: app.processIdentifier == frontmostPID,
                escalating: rungs
            ))
        }
        return HideOutcome.folded(outcomes)
    }

    /// One instance, both steps of the ladder in order.
    private static func send(
        _ app: NSRunningApplication, away trusted: Bool, isFrontmost: Bool,
        escalating rungs: [HideRung]
    ) -> HideOutcome {
        let pid = app.processIdentifier
        let wasFullscreen = fullscreenState(pid: pid)
        let fullscreenRungs = HideLadder.ordered(
            escalation: rungs,
            ordinary: HideLadder.fullscreenRungs(
                accessibilityTrusted: trusted, isFullscreen: wasFullscreen, isFrontmost: isFrontmost
            )
        )
        let leftFullscreen = fullscreenRungs.contains { climb($0, app: app, pid: pid) }
        // Deliberately unconditional. The two steps are a sequence: an app left in fullscreen is
        // still an app that has to be hidden, and one that is out of fullscreen is still on screen.
        let sentAway = HideLadder.sendAwayRungs(accessibilityTrusted: trusted)
            .contains { climb($0, app: app, pid: pid) }
        return HideOutcome(
            wentAway: HideLadder.wentAway(
                wasFullscreen: wasFullscreen, leftFullscreen: leftFullscreen, sentAway: sentAway
            ),
            fullscreenRead: wasFullscreen
        )
    }

    /// One rung. `true` means macOS took it.
    private static func climb(_ rung: HideRung, app: NSRunningApplication, pid: pid_t) -> Bool {
        switch rung {
        case .leaveFullscreen: return exitFullscreen(pid: pid)
        case .sendExitFullscreen: return post(keyCode: fKeyCode, flags: [.maskCommand, .maskControl])
        case .spaceLeft: return post(keyCode: leftArrowKeyCode, flags: [.maskControl])
        case .hide: return app.hide()
        case .minimizeWindows: return minimizeWindows(pid: pid)
        }
    }

    // MARK: - Accessibility

    /// Whether any of the app's windows is in native fullscreen — `nil` when that cannot be
    /// answered at all, which is the normal case for a hidden app (it exposes no AX windows) and
    /// for a denied permission. `HideLadder` reads the `nil` as "not fullscreen", deliberately.
    private static func fullscreenState(pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let windows = windows(pid: pid)
        guard !windows.isEmpty else { return nil }
        return windows.contains(where: isFullscreen)
    }

    private static func exitFullscreen(pid: pid_t) -> Bool {
        set(kCFBooleanFalse, fullScreenAttribute, onWindowsOf: pid, where: isFullscreen)
    }

    private static func minimizeWindows(pid: pid_t) -> Bool {
        set(kCFBooleanTrue, kAXMinimizedAttribute as CFString, onWindowsOf: pid) { _ in true }
    }

    /// Writes one attribute on every window that qualifies, and answers whether any write took.
    private static func set(
        _ value: CFBoolean?,
        _ attribute: CFString,
        onWindowsOf pid: pid_t,
        where qualifies: (AXUIElement) -> Bool
    ) -> Bool {
        guard let value else { return false }
        var changed = false
        for window in windows(pid: pid) where qualifies(window) {
            if AXUIElementSetAttributeValue(window, attribute, value) == .success { changed = true }
        }
        return changed
    }

    private static func windows(pid: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func isFullscreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, fullScreenAttribute, &value
        ) == .success else { return false }
        return (value as? Bool) ?? false
    }

    // MARK: - Synthetic keys

    /// Posts one key combination to whatever holds the keyboard. `false` means events cannot be
    /// posted at all, which is what a missing Accessibility grant looks like from here.
    ///
    /// `.cghidEventTap` rather than `CGEvent.postToPid`: the tap is where the target app's own
    /// menu handling sees the combination, which is the whole reason this rung exists. Which app
    /// receives it is decided by `HideLadder.fullscreenRungs`, which offers these rungs only for
    /// the app that is frontmost.
    private static func post(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
