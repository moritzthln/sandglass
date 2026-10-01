import SandglassAppCore
import SwiftUI

/// The Presets page: the two lists a group is assembled out of.
///
/// They spent a wave on the settings page, in among the switches, and they never belonged there.
/// Settings is what is true of the app — whether it is protecting anything, when the day starts,
/// what the lock asks for. A preset and a category are neither settings nor one group's business:
/// they are the parts several groups are built from, and a screen of their own is what says so.
///
/// Two columns for the same reason the settings page has two: both cards are lists that grow, and
/// stacking them would put the second one below the fold on a page with room beside it.
///
/// They do not end level — measured at the 1000-point floor, presets end at 397 points and
/// categories at 625 — and there is nothing to do about it. One card in each column is one card
/// too few to rebalance with: swapping them changes nothing, and stacking them turns a 655-point
/// page into a 1022-point one. Both lists are the user's own, so the gap is whatever their two
/// lists happen to differ by.
///
/// Each card owns its refusals and shows them at its own foot — the rule the settings page follows,
/// and it matters at least as much here: a save refused inside a sheet has to be explained on the
/// page the sheet is covering.
@MainActor
struct PresetsPageView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            header
            HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                PresetsCard(appState: appState)
                CategoriesCard(appState: appState)
            }
        }
    }

    /// The title, with the sentence that says why the page exists behind the `i` beside it.
    ///
    /// It was a paragraph under the title. What it says still has to be said — a reader who assumes
    /// a preset is a live link is a reader who edits one expecting eight groups to move — but it is
    /// read once and then never again, which is exactly what an info button is for.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Presets").font(.largeTitle.weight(.semibold))
            InfoButton("The pieces a group is assembled from: a preset is settings prepared in advance, a category is a list of apps and websites. They are here rather than inside one group because several groups share them — a category as a live membership, a preset as the copy a group takes when it is put on one.")
            Spacer(minLength: 0)
        }
    }
}
