import SandglassAppCore
import AppKit
import Observation

/// Whether a sheet or an alert is attached to the settings window right now.
///
/// What the two doors in the window ask before they come down: one closing under an open sheet
/// waits for it, so the sheet's draft is not destroyed with the page. The rule is `DoorDeferral`'s;
/// this is only the fact it is asked about, kept where AppKit reports it.
@MainActor
@Observable
final class WindowSheets {
    var isOpen = false
}

/// Tells `AppState` what happens to the settings window: it going away, which is what both halves
/// of the settings lock are measured per visit against, and somebody working in it, which is what
/// keeps an unlocked visit from ending as an idle one. It also reports sheets coming and going,
/// for `WindowSheets`.
///
/// `windowWillClose` rather than SwiftUI's `onDisappear`. The red button orders the window out
/// and leaves its view hierarchy standing, so `onDisappear` never fires for the one close that
/// actually happens.
@MainActor
final class SettingsWindowWatcher: NSObject, NSWindowDelegate {
    let appState: AppState
    let sheets: WindowSheets
    private weak var window: NSWindow?
    private var monitor: Any?
    /// Set while a close is waiting for a typed value to be committed. See `windowShouldClose`.
    private var closing = false

    init(appState: AppState, sheets: WindowSheets) {
        self.appState = appState
        self.sheets = sheets
    }

    /// **A typed value is committed before the window goes.** A number field commits when it
    /// loses focus, and the red light closes the window without taking focus from anything — so a
    /// value typed and not yet tabbed out of was dropped in silence. So the focus is taken first,
    /// and the close waits a moment for SwiftUI to deliver that loss to the field, which writes it
    /// while the visit is still the one it was typed in. A window with nothing being typed into
    /// closes at once.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closing, sender.firstResponder is NSText else { return true }
        closing = true
        sender.makeFirstResponder(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak sender] in
            self?.closing = false
            sender?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        sheets.isOpen = false
        appState.settingsWindowClosed()
    }

    func windowWillBeginSheet(_ notification: Notification) {
        sheets.isOpen = true
    }

    func windowDidEndSheet(_ notification: Notification) {
        sheets.isOpen = (notification.object as? NSWindow)?.attachedSheet != nil
    }

    /// Reports every key, click and scroll that lands in the window or in a sheet on it, so a
    /// visit somebody is working in is not ended as an idle one. Mouse movement is left out: it
    /// arrives by the hundred, and a pointer drifting over a window nobody is reading is not
    /// somebody at it.
    func watchActivity(in window: NSWindow) {
        self.window = window
        guard monitor == nil else { return }
        let kinds: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            MainActor.assumeIsolated { self?.noteActivity(from: event) }
            return event
        }
    }

    private func noteActivity(from event: NSEvent) {
        guard let window, var landed = event.window else { return }
        while landed !== window, let parent = landed.sheetParent { landed = parent }
        if landed === window { appState.settingsActivity() }
    }
}
