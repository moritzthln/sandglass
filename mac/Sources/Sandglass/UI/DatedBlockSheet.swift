import SandglassCore
import SwiftUI

/// The small sheet behind "A date…": a calendar, and a button that says which day pressing it buys.
///
/// The five quick spans on the menu cover almost every reason to set one of these; this is for the
/// sixth — a trip, a deadline, a day somebody already has in mind. It is a sheet rather than a
/// popover for the reason the window editor is one: it is a decision with a Cancel, and the card it
/// covers is the thing being changed.
///
/// **The confirm button carries the resolved day**, exactly as the menu rows do. A block bought in
/// days and a block bought off a calendar are the same purchase, and both should be readable before
/// the press rather than afterwards — which is also why there is no confirmation behind it.
@MainActor
struct DatedBlockSheet: View {
    /// The day this moment is in. Nothing before tomorrow can be chosen: a block until today is a
    /// block that is already over, and a calendar offering it would be offering a no-op.
    let today: String
    /// The day already set, if there is one, so re-picking opens where the block currently ends.
    let current: String?
    /// The chosen day, as `DatedBlock` spells one.
    let onDone: (String) -> Void
    let onCancel: () -> Void

    /// Midday on the day the calendar is showing — noon rather than midnight, so no zone and no
    /// DST switch can put the picker on the day before. See `DatedBlock.date(_:calendar:)`.
    @State private var picked = Date()
    /// Whether `picked` has been seeded from `today`. `onAppear` rather than an initialiser,
    /// because a `@State` default is evaluated before the view has its properties.
    @State private var seeded = false

    private var calendar: Calendar { .current }

    /// The day the calendar is currently on, in the app's own spelling.
    private var day: String { DatedBlock.day(picked: picked, calendar: calendar) }

    /// Tomorrow, as a date the picker can be bounded by.
    private var earliest: Date {
        DatedBlock.day(.day, from: today)
            .flatMap { DatedBlock.date($0, calendar: calendar) }
            ?? Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Block until a day").font(.headline)
            DatePicker(
                "Blocked until",
                selection: $picked,
                in: earliest...,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            Text(
                "The block ends when this day begins — the same moment a daily budget comes back."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(DatedBlock.rowText(day)) { onDone(day) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 340)
        .onAppear(perform: seed)
    }

    /// Opens on the day already set, or on the first one that can be chosen.
    private func seed() {
        guard !seeded else { return }
        seeded = true
        picked = current
            .flatMap { DatedBlock.date($0, calendar: calendar) }
            .map { max($0, earliest) }
            ?? earliest
    }
}
