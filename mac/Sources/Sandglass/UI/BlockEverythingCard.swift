import SandglassAppCore
import SandglassCore
import SwiftUI

/// Blocking every group at once, for a while.
///
/// It lived in the menu bar popover and nowhere else, which made the hardest thing this app does
/// reachable only from a panel that closes when you look away. The popover is two items now, so
/// this is where it is — above the card that undoes it, against how often each is used. A page
/// that leads with its own escape hatch is an app that expects you to fail.
///
/// Named after its effect rather than after the engine's word for it. `RulesEngine` calls this a
/// focus session; a card called "Focus session" says what the code calls it, not what pressing it
/// does.
///
/// Two states and no third: one running, or none. There is deliberately no way to end one early —
/// that is the whole of what separates this from a break, and the only thing that lifts it is the
/// week's emergency pass, which is a row on the card below. The pass **lifts** it rather than
/// ending it: a four-hour block interrupted by an hour of relief still has three to run.
///
/// Through that hour the card says what the pass is holding off and when it comes back, rather
/// than either the running line (nothing is blocked) or the menu (which the pass disables anyway).
/// `AppState.focusSessionLine` is what is holding right now and goes quiet;
/// `heldFocusSessionLine` is what is waiting. Saying neither would keep a four-hour block secret
/// for an hour and then reimpose it out of nowhere.
@MainActor
struct BlockEverythingCard: View {
    let appState: AppState

    @State private var showsCustom = false
    @State private var customMinutes = ""

    var body: some View {
        SettingsCard(
            "Block everything",
            help: "Every group at once, whatever each one's own budget and schedule say. It cannot be ended early and it ends a break that is running, so only the week's emergency pass lifts it — for that pass's hour, after which whatever is left of this goes on blocking. Blocking starts the moment you pick a length — including over whatever is in front of you right now."
        ) {
            // What is blocking, or what a pass is holding off until its hour is up. The menu is
            // dead through a pass either way — see `blockedReason` — so the held line stands in
            // its place rather than beside it.
            if let line = appState.focusSessionLine ?? appState.heldFocusSessionLine {
                SettingsStateRow(text: line)
            } else {
                idle
            }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrimaryWideMenu(title: "Block everything for…") {
                ForEach(Self.lengths, id: \.self) { minutes in
                    Button("\(minutes) minutes") { start(minutes: minutes) }
                }
                Button("Custom…") { showsCustom = true }
            }
            .disabled(blockedReason != nil)
            .help(blockedReason ?? "Blocks every group until it ends")

            if showsCustom { customRow }
            if let blockedReason {
                SettingsStateRow(text: blockedReason, tone: .secondary)
            }
        }
    }

    /// The two lengths a working block is actually taken in, and then whatever you like.
    private static let lengths = [25, 50]

    /// Why everything cannot be blocked right now, or `nil` when it can.
    ///
    /// Only the emergency pass stops one, and it stops one because starting a session *ends* a
    /// running pass while the week's pass stays spent — an hour bought once and lost to a misclick,
    /// with nothing left to buy it back with. Disabling the control says that before the fact; a
    /// confirmation dialogue would say it after, and cost a dialogue.
    private var blockedReason: String? {
        guard case .emergencyPass(let until) = appState.statusKind else { return nil }
        return "Emergency pass runs until \(appState.clockText(for: until))"
    }

    private var customRow: some View {
        HStack(spacing: 8) {
            TextField(Self.customPlaceholder, text: $customMinutes)
                .frame(width: 92)
                .onSubmit(startCustom)
            // The row outlives the menu that opened it, so a pass starting while it is on screen
            // has to close the same door the menu above is already holding shut.
            Button("Start", action: startCustom)
                .disabled(parsedCustomMinutes == nil || blockedReason != nil)
            Button("Cancel", action: dismissCustom)
        }
    }

    /// One minute to four hours.
    ///
    /// Blocking everything is the hardest thing this app does: it ends every running session and
    /// there is no way out but the week's emergency pass. So an unbounded field was a ten-hour lock
    /// two keystrokes away, bought by somebody who meant 60 and typed 600. Four hours is longer
    /// than any working block anybody sits through in one go, and short enough that a slip costs an
    /// afternoon rather than a day.
    private static let customRange = 1...240

    private static var customPlaceholder: String {
        "\(customRange.lowerBound)–\(customRange.upperBound) min"
    }

    /// `nil` disables Start, so a number outside the range is refused rather than quietly turned
    /// into one inside it: clamping 600 to 240 would start a block the user did not ask for, and
    /// this is not a control to be generous with.
    private var parsedCustomMinutes: Int? {
        guard let minutes = Int(customMinutes.trimmingCharacters(in: .whitespaces)),
              Self.customRange.contains(minutes) else { return nil }
        return minutes
    }

    private func startCustom() {
        guard let minutes = parsedCustomMinutes else { return }
        start(minutes: minutes)
    }

    private func start(minutes: Int) {
        appState.startFocusSession(minutes: minutes)
        dismissCustom()
    }

    private func dismissCustom() {
        showsCustom = false
        customMinutes = ""
    }
}
