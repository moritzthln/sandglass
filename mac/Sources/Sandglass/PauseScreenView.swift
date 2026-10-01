import SandglassAppCore
import SandglassCore
import SwiftUI

/// The screen behind a blocked app: what you opened, where it stands, and the two ways out
/// of it.
///
/// Deliberately still. Near-black, no motion beyond the default fades, nothing that rewards
/// looking at it — the screen is a speed bump, not a destination.
@MainActor
struct PauseScreenView: View {
    let model: PauseScreenModel
    let onOpen: () -> Void
    let onDismiss: () -> Void

    /// The live countdown, tagged with the model it was started for.
    ///
    /// Tagged rather than bare because `@State` outlives a model change by one render pass:
    /// an untagged counter would show the previous screen's number, and — for one frame after
    /// a screen with a finished countdown — an enabled "Open" on a screen nobody has waited
    /// for yet. Comparing the tag makes an unrecognised counter fall back to the full wait.
    @State private var countdown: Countdown?

    private struct Countdown: Equatable {
        let model: PauseScreenModel
        var secondsLeft: Int
    }

    var body: some View {
        ZStack {
            Color(white: 0.07)
            column
        }
        .ignoresSafeArea()
        // Re-keyed on the whole model: a re-render with the same screen leaves the wait
        // running, a genuinely different screen starts its own.
        .task(id: model) { await runCountdown() }
    }

    private var column: some View {
        VStack(spacing: 18) {
            Text(model.targetName)
                .font(.title2)
                .fontWeight(.semibold)
            if let budgetLine = model.budgetLine {
                Text(budgetLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            primaryControl
                .padding(.top, 10)
            // The way out never moves. Leaving has to stay predictable — only the button that
            // costs something is worth making the user look for.
            Button("Back to work", action: onDismiss)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .multilineTextAlignment(.center)
        .padding(48)
    }

    /// The one control that differs between the modes. A hard block has no button at all — an
    /// unlock path that cannot work is worse than none.
    ///
    /// The button is in the column, above the one that leaves, and it does not move. It used to:
    /// a setting sent it wandering between five slots so the hand could not learn one. What that
    /// bought was a screen that looked different every time it appeared, which is a screen that
    /// looks broken — and it cost a setting, an enum, a nonce and a rule about when the nonce may
    /// advance. The wait is the friction; where the button is was never going to be.
    @ViewBuilder
    private var primaryControl: some View {
        switch model.mode {
        case .countdown:
            openButton
        case .blocked(let untilText):
            Text(untilText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var openButton: some View {
        Button(openTitle, action: onOpen)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(secondsLeft > 0)
    }

    private var openTitle: String {
        secondsLeft > 0 ? "Open in \(secondsLeft)s…" : "Open"
    }

    /// How much of the wait is left. Falls back to the full countdown whenever there is no
    /// counter for *this* model yet, so the button is never enabled before its own wait ran.
    private var secondsLeft: Int {
        guard case .countdown(let total) = model.mode else { return 0 }
        guard let countdown, countdown.model == model else { return total }
        return countdown.secondsLeft
    }

    /// Counts down once per second for as long as the view is on screen.
    ///
    /// SwiftUI cancels this task when the model changes or the view goes away, and the
    /// overlay releases its hosting view on every hide — so a screen nobody is looking at
    /// counts nothing, and a re-shown screen starts its wait from the top.
    private func runCountdown() async {
        guard case .countdown(let total) = model.mode else {
            countdown = nil
            return
        }
        countdown = Countdown(model: model, secondsLeft: total)
        while (countdown?.secondsLeft ?? 0) > 0 {
            do { try await Task.sleep(nanoseconds: NSEC_PER_SEC) } catch { return }
            // Cancellation is cooperative, so a task whose model changed mid-sleep can still
            // wake up. Decrementing then would take a second off a countdown belonging to a
            // screen this task knows nothing about.
            guard countdown?.model == model else { return }
            countdown?.secondsLeft -= 1
        }
    }
}
