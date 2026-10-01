import SwiftUI

/// A rounded container with an optional title and a separator under it.
///
/// The unit every page is built from. It knows nothing about what is inside it, which is what
/// lets the settings page and the group editor look like one product without sharing a line of
/// layout code.
///
/// The title bar carries the title and, optionally, `help` — the note about *what this card is*,
/// stated in the title rather than repeated as a first row underneath it. **And nothing else.**
/// It briefly took an `accessory` as well, for the one control that sets every row of a card at
/// once, which was the group's preset dropdown; the dropdown moved to the editor's header, where
/// it reads as a property of the group rather than a heading for seven knobs, and a title bar
/// that can hold a control is an invitation to put one there.
struct SettingsCard<Content: View>: View {
    var title: String?
    var help: String?
    @ViewBuilder var content: () -> Content

    init(
        _ title: String? = nil,
        help: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.help = help
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let help { InfoButton(help) }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, Metrics.cardPadding)
                .padding(.bottom, 10)
                Divider().overlay(Palette.hairline)
            }
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(Metrics.cardPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCorner).strokeBorder(Palette.hairline)
        )
    }
}

/// A heading inside a card, for a card that holds two topics rather than one.
///
/// The escape hatch of last resort: a card with a heading in it is usually a card that should
/// have been two. It is right where the two halves are only meaningful together — a group's
/// Settings card is one preset, one decision and one thing to compare between groups, and
/// splitting it would put the way in and what it costs on two different cards.
struct SettingsSubheading: View {
    let text: String
    /// Whether a line is drawn above it. The first heading in a card sits under the title's own
    /// separator and needs none.
    var separated = true

    init(_ text: String, separated: Bool = true) {
        self.text = text
        self.separated = separated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if separated {
                Divider().overlay(Palette.hairline).padding(.top, 10)
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, separated ? 12 : 0)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label on the left, control on the right, both centred on the same line.
///
/// Controls right-align on one vertical axis because the alternative — each row as wide as its
/// own label — is what makes a settings screen read as a pile of unrelated widgets.
struct SettingsRow<Control: View>: View {
    let label: String
    var help: String?
    /// A second line under the label, for the rows that need one sentence of explanation.
    var caption: String?
    @ViewBuilder var control: () -> Control

    init(
        _ label: String,
        help: String? = nil,
        caption: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.label = label
        self.help = help
        self.caption = caption
        self.control = control
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                LabelWithInfo(label, help: help)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Deliberately *not* fixedSize on this stack. Wrapping is the two Text views' business
            // and they each ask for it themselves; asking again here fixes the stack's height as
            // well, and a `.firstTextBaseline` row with one fixed side and one free side stops
            // sitting evenly between its neighbours. The bug this fixes was a truncated label, not
            // a stack that needed pinning.
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 7)
        // The row's height is its own, and no parent may propose a shorter one. Not the same thing
        // as pinning the label stack, which is what made a `.firstTextBaseline` row sit unevenly
        // between its neighbours: this leaves the inside of the row exactly as it was and only
        // refuses a height the two Texts cannot fit in. When the row is measured honestly it
        // changes nothing — its ideal height is already what it reports — so it costs nothing in
        // the ordinary case and stops a wrapped second line being written over the row below in
        // the narrow case.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: Metrics.rowHeight)
    }
}

/// A whole row of text with no control — a state line rather than a setting.
struct SettingsStateRow: View {
    let text: String
    var tone: Tone = .primary

    enum Tone { case primary, secondary, warning }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
    }

    private var colour: Color {
        switch tone {
        case .primary: return .primary
        case .secondary: return .secondary
        case .warning: return .orange
        }
    }
}

/// Text with a small `i` beside it that explains itself on hover and on click.
///
/// Both, deliberately: `.help` is what a Mac user reaches for and is invisible to anyone who
/// does not know it is there, and a popover is what a click has to do once there is something
/// to click. One affordance, two ways in.
struct LabelWithInfo: View {
    let text: String
    var help: String?

    init(_ text: String, help: String? = nil) {
        self.text = text
        self.help = help
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // Wraps rather than truncates. A label that ends in an ellipsis has stopped being a
            // label, and these rows sit in columns narrow enough for it to happen.
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // Never squeezed: the `i` is the width of a glyph, and a row that dropped it would
            // take the explanation with it. It keeps its size while the text beside it reflows.
            if let help { InfoButton(help).layoutPriority(1) }
        }
    }
}

struct InfoButton: View {
    let text: String
    @State private var showing = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("What this does")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(width: 280)
        }
    }
}

