import SandglassAppCore
import SandglassCore
import AppKit
import SwiftUI

/// The menu bar item: an hourglass that reports, and a click that opens the window.
///
/// An `NSObject` because the status button's action is an Objective-C selector.
@MainActor
final class StatusItemController: NSObject {
    private let appState: AppState
    private let statusItem: NSStatusItem

    /// What the button is currently showing. The tick loop calls `refresh()` once a second;
    /// reassigning the same image that often is wasted work and makes the icon flicker on some
    /// displays. The countdown is in here too — it changes every second while a session runs,
    /// and the icon beside it must not be redrawn for that.
    private var applied: Appearance?

    private struct Appearance: Equatable {
        let status: StatusKind
        let countdown: String
    }

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(openWindow)

        appState.onStateChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        let appearance = Appearance(status: appState.statusKind, countdown: countdownText)
        guard appearance != applied else { return }
        applied = appearance
        guard let button = statusItem.button else { return }
        let image = Self.icon(for: appearance.status)
        button.image = image
        button.toolTip = Self.tooltip(for: appearance.status)
        // A symbol this build of macOS does not know would leave an invisible menu bar item.
        // Two letters are worse-looking than an icon and far better than nothing.
        button.title = Self.title(countdown: appearance.countdown, hasIcon: image != nil)
    }

    /// How long the session that relocks first has left, or empty when there is nothing to
    /// count down — no session, or the user switched the countdown off in Settings.
    private var countdownText: String {
        guard appState.config.showsMenuBarCountdown, let session = appState.activeSession else {
            return ""
        }
        let seconds = max(0, session.secondsLeft)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func title(countdown: String, hasIcon: Bool) -> String {
        switch (hasIcon, countdown.isEmpty) {
        case (true, true): return ""
        case (true, false): return " \(countdown)"
        case (false, true): return "AB"
        case (false, false): return "AB \(countdown)"
        }
    }

    /// A click on the icon opens the main window, directly.
    ///
    /// There used to be a popover in between. It shrank as its contents moved into the main
    /// window, until one row was left — "Open Sandglass" — and a menu of one item is not a menu,
    /// it is a detour: every click cost a second click that only ever had one answer. The icon
    /// still says everything the popover used to show (status by its glyph, the session by the
    /// countdown beside it), and the way out lives in the settings footer, behind the door when
    /// one is set.
    @objc private func openWindow() {
        WindowPresenter.showSettings(appState: appState)
    }

    // MARK: - Appearance

    /// One family, four states — an hourglass, matching the app icon.
    ///
    /// **Chosen as rendered, not as described.** Six candidates were drawn at the size a menu bar
    /// actually draws them, seventeen points, and most of what reads well at forty does not survive
    /// it: the shield's checkerboard fills in to a plain pentagon, an hourglass inside a circle
    /// becomes a smudge, and a lifepreserver is indistinguishable from a cog.
    ///
    /// What survives is sand: **top-half filled while something is held back, bottom-half filled
    /// when nothing is.** The same glyph, the sand at the other end — which is the one difference
    /// that is still legible that small, and it says the right thing without a word. The empty
    /// glass is the emergency pass: the hour when the app is standing aside.
    ///
    /// The warning keeps a shape of its own rather than a fourth hourglass, because it is the one
    /// state that is not about blocking at all.
    private static func icon(for status: StatusKind) -> NSImage? {
        switch status {
        case .active:
            return template("hourglass.tophalf.filled", description: "Sandglass is protecting")
        case .paused:
            return template("hourglass.bottomhalf.filled", description: "Sandglass is blocking nothing right now")
        case .emergencyPass:
            return template("hourglass", description: "Sandglass is on an emergency pass")
        case .degraded:
            // Yellow on purpose, and therefore not a template image: a degraded state has to
            // be visible from the bar itself, at a glance.
            let base = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "Sandglass needs attention"
            )
            let coloured = base?.withSymbolConfiguration(.init(paletteColors: [.systemYellow]))
            coloured?.isTemplate = false
            return coloured ?? base
        }
    }

    private static func template(_ name: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    private static func tooltip(for status: StatusKind) -> String {
        switch status {
        case .active(let count):
            return "Sandglass — protecting \(count) \(count == 1 ? "target" : "targets")"
        case .degraded(let line):
            return "Sandglass — \(line)"
        case .paused:
            // Not "nothing is blocked", for the reason the pass below is not "everything is
            // unblocked": the same groups opt out of both, and this line has no group to check
            // itself against either. What is true of every break is that one is running.
            return "Sandglass — a break is running"
        case .emergencyPass:
            // Not "everything is unblocked": a group can opt out of the pass, and this line has no
            // group to check it against. What is true of every pass is that one is running, and
            // the settings page's own caption is where the exception is named. See
            // `GroupSettings.ignoresAppWideUnblocks`.
            return "Sandglass — an emergency pass is running"
        }
    }
}

/// The app's one window, built by hand.
///
/// By hand, and not as a SwiftUI `Settings` scene, for a reason worth keeping written down:
/// a scene tree makes this a SwiftUI `App`, and SwiftUI answers an activation that finds no
/// window on screen by opening its only scene — which put an empty "Sandglass Settings" window
/// behind the overlay every time a blocked app happened to be frontmost at launch. Task 6
/// removed the scene tree; this is what replaces it.
///
/// One window: asking again brings the existing one forward rather than stacking a second copy
/// of the same screen. It is not released on close, because it is kept for the next time.
///
/// There were two. The other was a setup wizard, and it is gone — a first launch opens *this*
/// window on an empty group list, because the sidebar's `+` and the editor are the whole story
/// and a wizard that teaches them is a second screen saying the same thing worse.
@MainActor
enum WindowPresenter {
    private static var settings: NSWindow?
    /// Retained here because `NSWindow.delegate` is weak.
    private static var watcher: SettingsWindowWatcher?

    /// The main window: sidebar plus whichever page it is showing. Resizable, and its floor
    /// comes from the view inside it — see `make`.
    /// Whether this run has already put the system's Accessibility prompt up. Once: the dialog
    /// adds Sandglass to the list by itself, and a person who dismissed it has answered for the
    /// rest of this run — asking again on every window open would be nagging, not helping.
    private static var promptedForAccessibility = false

    static func showSettings(
        appState: AppState, selecting: MainWindowView.Selection = .settings
    ) {
        // The one moment a permission prompt is honest: the user has just clicked, so somebody is
        // there to read it. The prompt cannot grant — nothing can, macOS reserves that for the
        // user — but it writes Sandglass into the Accessibility list on its own, so what is left
        // is flipping the switch rather than hunting for a "+" and a bundle in /Applications.
        if !promptedForAccessibility, !AXIsProcessTrusted() {
            promptedForAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        let window = settings ?? make(title: "Sandglass", resizable: true)
        settings = window
        // Traffic lights and nothing else: the sidebar carries the wordmark, so a title bar
        // repeating it is a second name for the same window.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        watch(window, appState: appState)
        // `performClose` rather than `close`, so Escape at the passcode door goes down exactly
        // the path the red traffic light does — the delegate below included, which is what ends
        // the visit. Weakly, because the window owns the controller that owns this closure.
        let content = MainWindowView(appState: appState, initialSelection: selecting) {
            [weak window] in window?.performClose(nil)
        }
        show(content, in: window)
    }

    /// Tells the settings lock that a window able to edit the configuration is on screen.
    ///
    /// The gate ignores an open it already knows about, so bringing an open window forward does
    /// not restart its timer.
    private static func watch(_ window: NSWindow, appState: AppState) {
        let watcher = watcher ?? SettingsWindowWatcher(appState: appState)
        self.watcher = watcher
        window.delegate = watcher
        appState.settingsWindowOpened()
    }

    /// The window is reused, its hosting controller is not — the same trade the popover makes,
    /// and for the same reason: a retained controller keeps its SwiftUI `@State`, so the group
    /// editor would reopen with a rename field it read the first time and a refusal from a write
    /// nobody remembers. A fresh controller costs one `AppScanner.scan()`, which is cached.
    private static func show(_ content: some View, in window: NSWindow) {
        window.contentViewController = NSHostingController(rootView: content)
        window.center()
        present(window)
    }

    /// A resizable window takes its floor from the view inside it: SwiftUI turns a
    /// `minWidth`/`minHeight` frame into the hosting controller's minimum size, so a window too
    /// small to be usable cannot be dragged into existence either. A view with a fixed frame is
    /// given a window that cannot be resized at all, rather than one it would sit marooned in.
    ///
    /// It opens at `openWindowSize` rather than at that floor. The two are different questions —
    /// the smallest the window may be squeezed to, and the size it is worth reading at — and
    /// opening at the floor was how the settings page came up with two 300-point columns.
    private static func make(title: String, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: Metrics.openWindowWidth, height: Metrics.openWindowHeight
            ),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        // Kept for the next open; releasing it on close would leave a dangling reference.
        window.isReleasedWhenClosed = false
        return window
    }

    private static func present(_ window: NSWindow) {
        // An accessory app is never the active one, and an inactive window takes no keyboard
        // focus — every text field on both screens would swallow keystrokes in silence.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Tells `AppState` when a settings window goes away, which is what both halves of the settings
/// lock are measured per visit against: the timer starts again, and a passcode entered during
/// this visit is forgotten.
///
/// `windowWillClose` rather than SwiftUI's `onDisappear`. The red button orders the window out
/// and leaves its view hierarchy standing, so `onDisappear` never fires for the one close that
/// actually happens.
@MainActor
private final class SettingsWindowWatcher: NSObject, NSWindowDelegate {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func windowWillClose(_ notification: Notification) {
        appState.settingsWindowClosed()
    }
}
