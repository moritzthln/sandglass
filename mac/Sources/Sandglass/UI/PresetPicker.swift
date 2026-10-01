import SandglassAppCore
import SandglassCore
import SwiftUI

/// The preset dropdown: a trigger the caller draws, and a list of two-line rows behind it.
///
/// **A popover rather than a `Menu`, and that is the whole design.** A preset is a set of
/// prepared settings, so a menu of bare names — Gentle, Standard, Strict — asks the user to
/// remember what each one holds and pick blind, which is the one job a preset exists to do for
/// them. A macOS `Menu` is an `NSMenu`: its rows are titles, and a two-line label handed to one
/// is flattened to its first line. So the rows are drawn here, where a row can be a name with
/// its settings underneath it.
///
/// What each dropdown offers is `PresetChoices`', not this view's: it knows how to draw a row
/// and nothing about which rows there are.
struct PresetPicker<Trigger: View>: View {
    let rows: [PresetChoice]
    /// The preset that was picked, or `nil` for Custom — which only the group editor offers.
    let onPick: (String?) -> Void
    @ViewBuilder var trigger: () -> Trigger

    @State private var showing = false

    /// No button style of its own: the header's control is bordered and the sidebar's is a bare
    /// chevron, and both inherit down to the `Button` below. The rows set their own, so nothing
    /// the caller chooses reaches inside the popover.
    var body: some View {
        Button { showing.toggle() } label: { trigger() }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                PresetChoiceList(rows: rows) { presetID in
                    showing = false
                    onPick(presetID)
                }
            }
    }
}

/// The rows, in a box the width of a sentence.
private struct PresetChoiceList: View {
    let rows: [PresetChoice]
    let onPick: (String?) -> Void

    /// Above this many rows the list scrolls at a fixed height instead of growing. A popover
    /// taller than the screen is one AppKit clamps somewhere unhelpful, and a user's own preset
    /// list has no ceiling.
    private static let scrollsAbove = 7
    private static let width: CGFloat = 340

    var body: some View {
        if rows.count > Self.scrollsAbove {
            // Both dimensions given, because a `ScrollView` in a popover has no size of its own
            // to be measured at.
            ScrollView { list }.frame(width: Self.width, height: 420)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                PresetChoiceRow(choice: row) { onPick(row.presetID) }
            }
        }
        .padding(6)
        .frame(width: Self.width)
    }
}

/// One row: a tick, a name, and the settings the name stands for.
private struct PresetChoiceRow: View {
    let choice: PresetChoice
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                // Drawn even when it is not this row's, so every name starts on the same line —
                // a checkmark that appears and disappears would shift the whole list sideways.
                Image(systemName: "checkmark")
                    .imageScale(.small)
                    .opacity(choice.isCurrent ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.name).font(.callout)
                    Text(choice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                hovering ? Palette.hairline : .clear, in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // One label rather than two elements: a screen reader reading "Standard" and then a
        // separate line of numbers would not say the numbers are Standard's.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(choice.name). \(choice.detail)")
        .accessibilityAddTraits(choice.isCurrent ? [.isSelected] : [])
    }
}

/// The group's preset, as the control that sits beside the group's name.
///
/// It is a property of the group, like the name it stands next to — not a heading for one card.
/// It used to be in the title bar of the knobs card, which read as a label for those knobs when
/// what it actually says is "this group runs the settings called Standard".
///
/// Picking one writes the friction knobs and leaves the group's week alone; touching any knob
/// afterwards makes the group Custom, because the values are what the label is read from. Both
/// rules are `ConfigBuilder`'s and neither is restated here.
@MainActor
struct GroupPresetPicker: View {
    @Binding var settings: GroupSettings
    let presets: [NamedPreset]

    var body: some View {
        PresetPicker(rows: rows, onPick: pick) {
            HStack(spacing: 5) {
                Text(currentName).font(.callout).lineLimit(1)
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .help("The settings this group runs. Pick a preset to set them all in one go.")
        .accessibilityLabel("Preset: \(currentName)")
    }

    private var rows: [PresetChoice] {
        PresetChoices.forGroup(presets, settings: settings)
    }

    /// Exactly one row is ever current — Custom's when no preset matches — so the trigger reads
    /// its name off the list rather than working the same question out a second way.
    private var currentName: String {
        rows.first { $0.isCurrent }?.name ?? PresetCopy.custom
    }

    private func pick(_ presetID: String?) {
        let preset = presets.first { $0.id == presetID }
        settings = ConfigBuilder.settings(forPreset: preset, current: settings)
    }
}
