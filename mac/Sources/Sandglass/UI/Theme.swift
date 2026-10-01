import SandglassCore
import SwiftUI

/// The numbers every screen in the main window measures itself against.
///
/// One place rather than a literal per view, because the whole point of the design is that
/// two cards on two different pages look like the same card. Anything here that appears twice
/// in a view file is a constant that should have been added to this list.
enum Metrics {
    /// Fixed. The group list scrolls;
    /// the sidebar does not get wider to fit a long name.
    static let sidebarWidth: CGFloat = 320
    /// The floor a resizable window takes from the view inside it — see `WindowPresenter.make`.
    static let minWindowWidth: CGFloat = 1000
    static let minWindowHeight: CGFloat = 700
    /// What it opens at, which is not the same question as what it may be squeezed to. At the
    /// floor the settings page's two columns are about 300 points each and every helper line
    /// under a row wraps to five or six of them; the window was opening there because the floor
    /// was the only size written down.
    static let openWindowWidth: CGFloat = 1180
    static let openWindowHeight: CGFloat = 780

    /// The column the passcode door is drawn in, centred in whatever the window happens to be.
    /// Narrow on purpose: the screen holds a field and one sentence, and a line of text that runs
    /// the width of a 1180-point window is a line nobody's eye can get back to the start of.
    static let doorColumnWidth: CGFloat = 340

    static let cardCorner: CGFloat = 12
    static let cardPadding: CGFloat = 16
    /// Cards never touch.
    static let cardSpacing: CGFloat = 16
    static let pagePadding: CGFloat = 28
    /// Enough that a row with a control in it is the same height as one with only text.
    static let rowHeight: CGFloat = 26
}

/// The two surfaces and the one line between them.
///
/// System colours rather than chosen ones: this app has no brand palette, and a menu-bar tool
/// that ignores the user's appearance settings looks broken rather than designed. Dark mode,
/// increased contrast and a coloured desktop tint all come for free.
enum Palette {
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let page = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.09)
    /// The selected group in the sidebar, and the active nav row.
    static let selection = Color.accentColor.opacity(0.16)

    /// The colour a kind of time window is drawn in, on the timeline strip and as the dot
    /// beside its row. One mapping, because a legend that disagreed with the list it explains
    /// would be worse than no legend.
    ///
    /// Semantic system colours, so they follow the user's appearance and accessibility
    /// settings: red for a hard block, green for a deliberate hole. Never the only signal —
    /// every segment is named in the legend and every row carries its kind in words.
    static func windowTint(_ kind: TimeWindow.Kind) -> Color {
        switch kind {
        case .strictBlock: return .red
        case .break: return .green
        }
    }
}
