import SandglassAppCore
import AppKit
import SwiftUI

/// A window the keyboard cannot dismiss.
///
/// Everything below exists because the overlay *is* the block: a screen that Escape closes or
/// that ⌘Q quits out from under is not a blocker, it is a suggestion. The window takes key
/// status — otherwise the buttons could not be reached from the keyboard at all — and then
/// refuses to act on the keys that would end it.
///
/// What this covers and what it does not: `performKeyEquivalent` is offered every command
/// combination before the main menu sees it, so ⌘Q and ⌘W stop here; `keyDown` is the last
/// stop for anything no view handled, and swallowing it silently also removes the system
/// beep. It does not cover ⌘⇥ or Mission Control, which the window server handles before any
/// application is asked — but switching away only puts another app *behind* a screen-saver
/// level window, and the activation that follows re-decides the overlay anyway.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Every command combination is swallowed but the editing ones while the password field is
    /// being typed in — a password kept in a password manager has to be pastable. A refusal
    /// by default cannot be walked around with a shortcut nobody thought to list. See `OverlayKey`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let answer = OverlayKey.answer(
            characters: event.charactersIgnoringModifiers?.lowercased() ?? "",
            command: flags.contains(.command),
            otherModifiers: !flags.isDisjoint(with: [.control, .option]),
            editingText: firstResponder is NSText
        )
        if answer == .refuse { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Unhandled keys stop here rather than at a beep. Views that want a key — a focused
    /// button taking Return or Space — are asked first and are unaffected.
    ///
    /// Tab is the exception, and it is `NSWindow`'s own: moving between the buttons and the field
    /// is the window's job, and swallowing it left the keyboard stuck on whichever had focus.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 48 else { return }   // kVK_Tab
        if event.modifierFlags.contains(.shift) {
            selectPreviousKeyView(nil)
        } else {
            selectNextKeyView(nil)
        }
    }

    /// Escape, when nothing on the screen took it. The default looks for something to cancel or
    /// close; there is nothing on this screen the user may leave by any route except the two
    /// buttons on it — and "Back to work" carries Escape as its own shortcut, so it is one of them.
    override func cancelOperation(_ sender: Any?) {}
}

/// The overlay as the user meets it: the pause screen on the screen the blocked thing was on, and
/// every other display covered in black.
///
/// It stood on one screen for a while, on the argument that the thing behind it was on one. An
/// application is not: its window or its video on a second display went on playing, and that
/// display's menu bar put the status item back in reach. Where each window goes, and when the
/// overlay steps back for an alert, is `OverlayPlan`; this type builds what the plan says.
///
/// The window is built when the overlay is shown and released when it is hidden. Keeping one alive
/// between shows would mean carrying a stale frame through every display change, and releasing it
/// is also the cheapest way to stop the countdown of a screen nobody is looking at — the hosting
/// view goes with the window, and its running task with the hosting view.
@MainActor
final class OverlaySet {
    private var windows: [OverlayWindow] = []
    private var hostWindow: OverlayWindow?
    private var hostingView: NSHostingView<PauseScreenView>?
    private var showing: Presentation?
    /// Which display the standing overlay was put on, by the window server's own id. Held so a
    /// rebuild lands back on the same screen rather than on wherever the key window happens to be
    /// by then — which, with the overlay itself showing, is the overlay.
    private var displayID: CGDirectDisplayID?

    private struct Presentation {
        var model: PauseScreenModel
        var onOpen: () -> Void
        var onDismiss: () -> Void
        var onUnlock: (String) -> String?
    }

    init() {
        // Never removed, and never needs to be: the app delegate holds this object from
        // launch to quit. The block is delivered on the main queue whatever thread AppKit
        // posted from, which is what makes the isolation assumption below safe.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildIfVisible() }
        }
    }

    /// Puts the overlay on screen, or updates the one already there.
    ///
    /// Re-showing deliberately rebuilds nothing: the same screen re-rendered from a fresh
    /// decision must not flicker, and must not hand back a countdown that starts over every
    /// time the engine is asked again. `PauseScreenModel` being `Equatable` is what lets
    /// SwiftUI tell "the same screen" from "a different one".
    func show(
        model: PauseScreenModel,
        onOpen: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onUnlock: @escaping (String) -> String?
    ) {
        let presentation = Presentation(
            model: model, onOpen: onOpen, onDismiss: onDismiss, onUnlock: onUnlock
        )
        showing = presentation
        if windows.isEmpty {
            build(presentation)
        } else {
            hostingView?.rootView = pauseScreen(presentation)
        }
        present()
    }

    func hide() {
        showing = nil
        // Forgotten here and nowhere else: a rebuild has to land back on the same display, and
        // the next block is a fresh question about wherever the user is by then.
        displayID = nil
        tearDown()
    }

    // MARK: - Windows

    private func build(_ presentation: Presentation) {
        let screens = NSScreen.screens
        let ids = screens.map { Self.displayID(of: $0) ?? 0 }
        let plan = OverlayPlan.plan(displays: ids, target: targetDisplay(), modalAlertRunning: false)
        for (screen, placement) in zip(screens, plan.placements) {
            let window = makeWindow(covering: screen)
            if placement.role == .pauseScreen {
                displayID = placement.display
                let view = NSHostingView(rootView: pauseScreen(presentation))
                window.contentView = view
                hostingView = view
                hostWindow = window
            }
            windows.append(window)
        }
    }

    /// The display the blocked thing is on.
    ///
    /// `NSScreen.main` is that screen as far as AppKit knows — it is the one holding the window
    /// with keyboard focus, and the app being blocked is frontmost at the moment this is asked. A
    /// rebuild asks something different, because by then the focused window is the overlay itself:
    /// it goes back to the display it was already on, and `OverlayPlan` falls through to the first
    /// display when that one has been unplugged.
    private func targetDisplay() -> CGDirectDisplayID? {
        displayID ?? NSScreen.main.flatMap(Self.displayID(of:))
    }

    /// The window server's id for a screen. `NSScreen` itself is not a stable handle across a
    /// display change — the objects are rebuilt — so the number is what a rebuild compares.
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func makeWindow(covering screen: NSScreen) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.setFrame(screen.frame, display: false)
        // Above everything, every display's menu bar included — and therefore above Sandglass's
        // own status item, so the quick actions behind it are out of reach while a pause screen
        // is up.
        // That is the decision, not an oversight: a pause the user can reach around is not a
        // pause. It costs nothing, because the overlay only exists while a blocked app is
        // frontmost, and "Back to work" hands the menu bar straight back.
        window.level = .screenSaver
        // Follows the user across Spaces and sits over full-screen apps, which is where the
        // apps worth blocking usually are.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        // Clicks anywhere on it must not fall through to the app behind it.
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        // The pause screen is designed dark; a Mac in light mode must not repaint it.
        window.appearance = NSAppearance(named: .darkAqua)
        return window
    }

    /// The callbacks are read out of the presentation they were shown with, so a screen that
    /// is updated in place and one that is rebuilt behave identically.
    private func pauseScreen(_ presentation: Presentation) -> PauseScreenView {
        PauseScreenView(
            model: presentation.model,
            onOpen: presentation.onOpen,
            onDismiss: presentation.onDismiss,
            onUnlock: presentation.onUnlock
        )
    }

    private func present() {
        guard !windows.isEmpty else { return }
        for window in windows { window.orderFrontRegardless() }
        // An accessory app is never the active one until it asks. Without this the overlay
        // would be visible while the keyboard still belonged to the app behind it.
        NSApp.activate(ignoringOtherApps: true)
        // One of the app's own alerts is running modally: AppKit delivers events to it alone, so
        // an overlay on top of it is a pause screen whose buttons do nothing. The alert is lifted
        // above the overlay and keeps the keyboard; once it is answered, the overlay's buttons
        // take clicks again and the first one gives it the keyboard back. See `OverlayPlan`.
        let modal = NSApp.modalWindow
        let stacking = OverlayPlan.plan(displays: [], target: nil, modalAlertRunning: modal != nil)
        if stacking.liftsModalAlert, let modal {
            modal.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            modal.makeKeyAndOrderFront(nil)
        }
        if stacking.takesKeyboard { hostWindow?.makeKeyAndOrderFront(nil) }
    }

    private func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        hostingView = nil
        hostWindow = nil
    }

    /// Displays were added, removed, resized or rearranged. A visible overlay is rebuilt
    /// around the new arrangement, because a window sized to a screen that no longer exists
    /// covers nothing at all.
    ///
    /// The rebuild restarts the pause countdown, which is the safe direction to fail in: the
    /// user waits again, and nothing is ever unlocked earlier than it should be.
    private func rebuildIfVisible() {
        guard let presentation = showing else { return }
        tearDown()
        build(presentation)
        present()
    }
}

/// What the pause screen is standing in front of: an application, or one page in a browser.
///
/// Here rather than inside `AppBlocker` because it is the overlay's own subject — the thing
/// `OverlaySet` is raised over — and because that file is the app's longest as it is. The two
/// cases exist for one reason: they part company when there is no way through. An application is
/// hidden; a page has its tab navigated to the block page instead, which stops the video and
/// leaves every other tab alone.
enum BlockSubject {
    case app(bundleID: String, running: NSRunningApplication)
    case page(url: String, browserID: String, running: NSRunningApplication)

    /// The application to send away, and the one a stale frontmost reading would name. For a
    /// page that is the browser: there is nothing smaller to hide.
    var bundleID: String {
        switch self {
        case .app(let bundleID, _): return bundleID
        case .page(_, let browserID, _): return browserID
        }
    }

    var running: NSRunningApplication {
        switch self {
        case .app(_, let running), .page(_, _, let running): return running
        }
    }

    /// Whether this is an application rather than a page.
    var isApplication: Bool {
        if case .app = self { return true }
        return false
    }
}
