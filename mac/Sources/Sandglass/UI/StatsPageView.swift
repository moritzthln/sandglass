import SandglassAppCore
import SandglassCore
import SwiftUI

/// How the days have actually gone: opens taken, pause screens turned away from, and the
/// streak. All of it counted rather than scored.
///
/// The screen shows nothing it worked out for itself. In particular, a week whose log could not
/// be read says so instead of printing a zero — telling someone they spent no time on YouTube
/// when the file simply would not open is the one kind of lie this app cannot afford.
@MainActor
struct StatsPageView: View {
    let appState: AppState

    @State private var weekly: [String: Int] = [:]
    @State private var weeklyComplete = true

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            Text("Stats").font(.largeTitle.weight(.semibold))
            SettingsCard("Today") {
                if groups.isEmpty {
                    SettingsStateRow(text: "Nothing is being blocked yet.", tone: .secondary)
                }
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().overlay(Palette.hairline) }
                    SettingsRow(group.name, caption: weekText(for: group)) {
                        Text(todayText(for: group))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // "Progress" rather than "Streak", which was a card holding a row of its own name —
            // and holding a second row that was not about the streak at all. Both rows count the
            // same kind of thing, which is what the card is named for: the impulses turned away
            // from today, and the run of days that stayed inside their budgets. The streak's own
            // rule went with it, onto the row it is a rule about.
            SettingsCard("Progress") {
                SettingsRow("Pause screens you turned away from today") {
                    Text("\(appState.stats.opensAvoidedToday)").font(.callout).monospacedDigit()
                }
                Divider().overlay(Palette.hairline)
                SettingsRow(
                    "Streak",
                    help: "A day counts when no group went over its budget. Days start at \(TimeWindowCopy.endpoint(appState.config.dayStartMinutes)); the week starts on Monday. One freeze a week absorbs a day that did not, so a single bad evening costs the freeze rather than the streak."
                ) {
                    Text(appState.streakLine).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: reload)
        // Re-read when an open is spent, and on nothing else.
        //
        // The week is counted by walking the whole event log, so the trigger has to be the one
        // number that can change it. Watching the whole snapshot looked equivalent and was not:
        // `usageSecondsToday` moves every second a managed app is in front, so a stats window
        // left open on a second display re-parsed `events.jsonl` once a second, on the main
        // thread, for a count that had not moved.
        .onChange(of: appState.stats.opensUsedToday) { _, _ in reload() }
    }

    private var groups: [ConfigGroup] { ConfigBuilder.groups(in: appState.config) }

    /// The same sentence the sidebar card shows, from the same place: this page and that one
    /// report one fact and used to word it two ways. See `GroupSummary.today`.
    ///
    /// **The block line is handed in, and only a covered week ever reads it.** This page reports a
    /// day rather than a moment, so an ordinary blocked group still shows its budget here — what it
    /// must not do is answer "nothing is held back" over a group its own week is blocking this
    /// second, which is the one case a covered week can be in when it has no budget to state.
    private func todayText(for group: ConfigGroup) -> String {
        let row = appState.budgetsByGroup.first { $0.id == group.id }
        return GroupSummary.today(
            opensUsed: appState.stats.opensUsedToday[group.id] ?? 0,
            opensPerDay: group.settings?.opensPerDay,
            usageSeconds: appState.stats.usageSecondsToday[group.id] ?? 0,
            dailyMinutes: group.settings?.dailyMinutes,
            windows: group.settings?.timeWindows ?? [],
            datedBlock: DatedBlock.standing(
                group.settings?.blockedUntilDay, onDay: appState.today
            ) != nil,
            blockLine: row?.reason != nil ? row?.line : nil
        )
    }

    /// An unreadable log is a gap, not a zero, and it is named as one.
    private func weekText(for group: ConfigGroup) -> String {
        guard weeklyComplete else { return "This week: history incomplete" }
        return "This week: \(weekly[group.id] ?? 0) opens"
    }

    private func reload() {
        let counts = appState.weeklyOpenCounts()
        weekly = counts.counts
        weeklyComplete = counts.complete
    }
}
