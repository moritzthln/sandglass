/// What the overlay puts on each display, and whether it may take the keyboard.
///
/// The decisions `OverlaySet` makes, lifted out of AppKit so they can be tested: the window code
/// is left to build what this says and nothing else.
///
/// **Every display is covered.** The overlay used to stand on one screen only, on the argument
/// that the thing being blocked was on that screen. An application is not on one screen: a
/// blocked app with a window or a video on a second display went on playing there, and the
/// second display's menu bar put Sandglass's own status item back in reach. The pause screen
/// goes on the display the blocked thing was found on; every other display is covered in black.
///
/// **A modal alert outranks it.** The 1 Hz loop keeps running while one of the app's alerts is
/// up — the quit dialogue, a passcode prompt — and an overlay raised over that alert at
/// screen-saver level hid the only window AppKit would deliver events to. The user saw a pause
/// screen whose buttons did nothing. So while an alert is running the overlay stays up but takes
/// no keyboard, and the alert is lifted above it.
public struct OverlayPlan: Equatable {
    public enum Role: Equatable { case pauseScreen, cover }

    public struct Placement: Equatable {
        public let display: UInt32
        public let role: Role
    }

    public let placements: [Placement]
    /// Whether the overlay makes itself key. False while an app-modal alert is running.
    public let takesKeyboard: Bool
    /// Whether the running alert has to be raised above the overlay.
    public let liftsModalAlert: Bool

    /// - Parameters:
    ///   - displays: every display, in the window server's order.
    ///   - target: the display the blocked thing was found on, or `nil` when that is not known.
    ///   - modalAlertRunning: whether one of the app's alerts holds an app-modal session.
    public static func plan(
        displays: [UInt32], target: UInt32?, modalAlertRunning: Bool
    ) -> OverlayPlan {
        let host = target.flatMap { displays.contains($0) ? $0 : nil } ?? displays.first
        return OverlayPlan(
            placements: displays.map {
                Placement(display: $0, role: $0 == host ? .pauseScreen : .cover)
            },
            takesKeyboard: !modalAlertRunning,
            liftsModalAlert: modalAlertRunning
        )
    }
}

/// What the overlay does with a key equivalent — a key pressed with ⌘.
///
/// Every command combination used to be swallowed, which is what keeps ⌘Q and ⌘W from ending a
/// pause screen. It also swallowed paste in the password field, so a password kept in a password
/// manager could not be entered at all. The editing commands are let through while a text field
/// is being typed in, and only then; everything else is still refused.
public enum OverlayKey {
    public enum Answer: Equatable { case refuse, passOn }

    /// The keys the app's hidden Edit menu answers: cut, copy, paste, select all, undo.
    static let editing: Set<String> = ["x", "c", "v", "a", "z"]

    /// - Parameters:
    ///   - characters: the key's characters ignoring modifiers, lower-cased by the caller.
    ///   - command: whether ⌘ is held.
    ///   - otherModifiers: whether ⌃ or ⌥ is held as well.
    ///   - editingText: whether a text field holds the keyboard.
    public static func answer(
        characters: String, command: Bool, otherModifiers: Bool, editingText: Bool
    ) -> Answer {
        guard command else { return .passOn }
        guard editingText, !otherModifiers, editing.contains(characters) else { return .refuse }
        return .passOn
    }
}
