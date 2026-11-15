import Foundation

/// What asking for the settings window does, given the window there already is.
///
/// **A window on screen is brought forward and nothing else.** The menu bar icon used to build a
/// fresh hosting controller on every click, which threw away everything the window was in the
/// middle of: the page that was showing jumped back to Settings, an open sheet went with its
/// draft, a typed stepper value went, and the window jumped to the centre of the screen. Worse,
/// the `onChange` that tells the visit a group page was left lived in the discarded view, so a
/// wait switched on for that group never armed. A click on the icon is somebody asking to see
/// the window, not to start it over.
///
/// A window that was closed is the other case, and it is rebuilt on purpose: a visit starts at
/// the open, so a rename field or a refusal left over from the last visit must not reappear in
/// this one. See `WindowPresenter.show`.
public enum SettingsWindowOpen: Equatable, Sendable {
    /// Build the window's content and centre it — the window is new, or was closed.
    case build
    /// Only `makeKeyAndOrderFront`: the window is open, and what it is showing stays.
    case bringForward

    /// `exists` is whether a window was made before; `onScreen` whether it is still open, which
    /// counts a window in the Dock: minimised is still the same visit.
    public static func action(exists: Bool, onScreen: Bool) -> SettingsWindowOpen {
        exists && onScreen ? .bringForward : .build
    }
}

/// Whether a door stands in front of a page, given that the page may have a sheet open on it.
///
/// **A door that closes while a sheet is open waits for the sheet.** The emergency pass running
/// out, or an unlocked visit ending after ten idle minutes, turns `passcodeRequired` back on, and
/// the window used to swap the page for the door at that second — destroying a category or
/// preset editor, an add sheet or a time-window sheet together with everything typed into it,
/// without a word. Held here, the sheet stays up; its Save is refused by the lock like any other
/// edit, which says why in the sheet itself, and the door comes down the moment the sheet goes.
///
/// It only ever **delays** the door, never skips it. Nothing behind a deferred door can be
/// written — `AppState.applyConfigEdit` asks the same lock — so all a sheet left open buys is the
/// chance to read, or copy, what was typed.
///
/// A door that opens is never held: there is nothing on the far side to protect.
///
/// Which side was drawn last is remembered, and it has to be: a sheet raised **at the door** —
/// the emergency pass asks for confirmation in one — must not be read as a page with a sheet
/// open, or confirming it would flash the page the door is standing in front of.
public struct DoorDeferral: Equatable, Sendable {
    /// Whether the page, rather than the door, was the last thing drawn. `nil` before anything
    /// has been drawn, when there is no page with a sheet to protect.
    private var pageShown: Bool?

    public init() {}

    /// Whether to draw the door now. `doorClosed` is what the lock says; `sheetOpen` whether a
    /// sheet or alert is attached to the window.
    public func showsDoor(doorClosed: Bool, sheetOpen: Bool) -> Bool {
        guard doorClosed else { return false }
        return !(pageShown == true && sheetOpen)
    }

    /// What was just drawn, so the next answer knows which side the open sheet belongs to.
    public mutating func drew(door: Bool) {
        pageShown = !door
    }
}
