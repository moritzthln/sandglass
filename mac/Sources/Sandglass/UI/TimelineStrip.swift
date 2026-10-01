import SandglassAppCore
import SandglassCore
import SwiftUI

/// The week, drawn: seven days down the left, each one a bar from midnight to midnight with the
/// group's time windows laid over it.
///
/// The single widget worth copying from the mobile reference, and it was copied wrong. It drew
/// **one** bar for the whole list, deliberately ignoring which days each window named — so a
/// Monday-to-Friday block and a Saturday break landed on the same strip, and the picture said the
/// group was both blocked and free every day. A list of windows tells you what exists; this is
/// supposed to tell you what your *week* looks like, which is the one thing the list cannot.
///
/// Kept free of any one screen's state so anything showing a group can use it: it takes windows
/// and draws them, and knows nothing else.
struct TimelineStripView: View {
    let windows: [TimeWindow]
    var showsLegend = true
    /// One day's bar. Thin, because there are seven of them and the shape of the week is read
    /// from where the colour is rather than from how tall it is.
    var rowHeight: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            week
            axis
            if showsLegend, !kindsPresent.isEmpty { legend }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - The week

    private var week: some View {
        VStack(spacing: 3) {
            ForEach(TimeWindowCopy.mondayFirst, id: \.self) { weekday in
                HStack(spacing: Self.labelGap) {
                    Text(TimeWindowCopy.letter(weekday))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    bar(weekday)
                }
            }
        }
    }

    /// The two letters M and T repeat inside a week, so the labels are not identifiers — the row
    /// order is. Monday first, the way this app reads a week everywhere else.
    private static let labelWidth: CGFloat = 12
    private static let labelGap: CGFloat = 6

    /// Segments are drawn in precedence order — strict block, then break — so what sits on top
    /// where two windows overlap is what the engine would actually do.
    private func bar(_ weekday: Int) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Palette.page)
                ForEach(TimeWindow.Kind.allCases, id: \.self) { kind in
                    let segments = TimeWindowList.segments(
                        ofKind: kind, in: windows, onWeekday: weekday
                    )
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(Palette.windowTint(kind))
                            .frame(width: max(2, geometry.size.width * segment.width))
                            .offset(x: geometry.size.width * segment.start)
                    }
                }
                quarterTicks(width: geometry.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.hairline))
        }
        .frame(height: rowHeight)
    }

    private func quarterTicks(width: CGFloat) -> some View {
        ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
                .offset(x: width * fraction)
        }
    }

    /// The axis under the seven rows, inset to start where they do. Spacers rather than absolute
    /// positions, so the two end labels cannot be clipped by the edge of a narrow card.
    private var axis: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.labelWidth + Self.labelGap, height: 1)
            ForEach(Array(Self.axisLabels.enumerated()), id: \.offset) { index, label in
                if index > 0 { Spacer(minLength: 2) }
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private static let axisLabels = ["12 AM", "6 AM", "12 PM", "6 PM", "12 AM"]

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(kindsPresent, id: \.self) { kind in
                HStack(spacing: 5) {
                    Circle().fill(Palette.windowTint(kind)).frame(width: 7, height: 7)
                    Text(TimeWindowCopy.kind(kind)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var kindsPresent: [TimeWindow.Kind] {
        TimeWindow.Kind.allCases.filter { kind in windows.contains { $0.kind == kind } }
    }

    private var accessibilityText: String {
        guard !windows.isEmpty else { return "No time windows" }
        return windows.map { "\(TimeWindowCopy.kind($0.kind)): \(TimeWindowCopy.schedule($0))" }
            .joined(separator: ", ")
    }
}
