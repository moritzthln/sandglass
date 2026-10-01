import SandglassAppCore
import SandglassCore
import SwiftUI

/// Unblocking everything **for a while**, in its three states: one running, the wait before one
/// can be asked for, and none.
///
/// For a while is the card, and it is now the whole card: a break, the wait in front of it and the
/// week's emergency pass are three strengths of one idea, and every one of them puts itself back.
/// "Reset today's counters" sat here as a fourth and was none of those things — it hands a day's
/// budget back for good, and nothing takes it away again — so it is on the General card now, under
/// "Start of day", with the other thing that decides what a day holds.
///
/// Named after what it does, like the popover's row — this card was called "Quick disable" and
/// its button "Disable blocking…", which is a setting's name for something that is not a setting.
/// A break is what the code calls it, and what the code calls it is not what a card says.
///
/// **The wait comes first and the length second.** The countdown starts when this window opens,
/// runs while the user is doing whatever else they came for, and until it ends there is nothing
/// on this card to operate — no length to pick, and no way to shorten the wait. Which order those
/// two happen in is the whole point: a length chosen at the front of the gap was chosen by the
/// impulse that opened the window. The rule is `BreakWaitGate`; this only draws it.
///
/// The lengths are `PauseFriction.lengths` rather than a list of this card's own: this is the only
/// menu that offers them, and the rule about what a break may be belongs beside the friction rather
/// than in the view that draws it.
///
/// Driven by `breakEnd` rather than by the status line, for the reason the popover is: an
/// emergency pass outranks a break in the status, and one running under a pass still has to be
/// endable.
@MainActor
struct UnblockCard: View {
    let appState: AppState

    /// The one condition everything on this card is held by, read once so that the length picker
    /// and the wait's own row can never come alive at different moments.
    private var waiting: Int? { appState.breakWaitSecondsLeft }

    var body: some View {
        SettingsCard(
            "Unblock everything",
            help: "The wait starts when this window opens, and nothing here can be used until it ends — then you pick how long to unblock for, and blocking comes back on its own when that runs out. This unblocks every group for the whole length you pick, whatever each one's schedule says: a scheduled block does not refuse it and does not cut it short, and the schedules come back the moment it is over. Two things it will not lift, and neither will the emergency pass below: a group set to ignore both of them in its own Lock card, and — for this one only — a running “Block everything”, which the pass does lift. The wait is in front of the choice rather than behind it because a length picked the second you wanted it was picked by the impulse. Closing the window starts it again. The lengths are a choice rather than one number because this is not one thing — a minute to answer a message and a quarter of an hour over lunch are both it, and taking fifteen when one would do is how it turns into an afternoon."
        ) {
            if let end = appState.breakEnd {
                running(end)
            } else if let seconds = waiting {
                SettingsStateRow(text: BreakWaitGate.waitText(seconds))
            } else {
                idle
            }
            // The same separator the Protection card uses, padding and all. These three carried
            // none, which left four points between one row and the next — and this card's labels
            // are the ones that wrap, because its controls are the widest on the page. A row that
            // needs a second line and has four points to put it in writes it over its neighbour.
            Divider().overlay(Palette.hairline).padding(.vertical, 6)
            UnblockWaitRow(appState: appState, waiting: waiting != nil)
            Divider().overlay(Palette.hairline).padding(.vertical, 6)
            EmergencyPassRow(appState: appState)
        }
    }

    /// Both ends, not just the break's: an emergency pass running underneath one outlasts it, and
    /// the card used to name the earlier of the two and offer a button that did nothing. The rule
    /// is `BreakEnd`; this only draws it.
    private func running(_ end: BreakEnd) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsStateRow(text: end.line(clockText: appState.clockText(for:)))
            PrimaryWideButton(title: end.buttonTitle) { appState.endPauseEarly() }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrimaryWideMenu(title: "Unblock everything for…") {
                ForEach(PauseFriction.lengths, id: \.self) { minutes in
                    Button(BreakStarter.label(forMinutes: minutes)) {
                        BreakStarter.start(minutes: minutes, appState: appState)
                    }
                }
            }
            .disabled(appState.pauseBlockedReason != nil)
            .help(
                appState.pauseBlockedReason
                    ?? "Unblocks every group that does not ignore it, for the length you pick"
            )

            // Live state and nothing else. It used to fall back to a sentence about the wait and
            // the passcode, which is true of every break there will ever be — so it is on the
            // card's own info button now, said once, rather than under the menu every time.
            if let line = appState.pauseBlockedReason ?? appState.pauseStoppedReason {
                SettingsStateRow(text: line, tone: .secondary)
            }
        }
    }
}

/// The wait, on the card it stands in front of — and standing behind itself.
///
/// Inert while the countdown runs, and that is the whole design rather than a nicety: a wait that
/// could be shortened the moment it became inconvenient would be worth nothing, so making the
/// friction smaller costs the friction one last time. It is held by the value the length picker is
/// held by — `AppState.breakWaitSecondsLeft`, read once by the card — so the two cannot come alive
/// at different moments, and the refusal behind it is `AppState.setBreakWaitSeconds`'s: this row
/// declines to ask, it does not decide.
///
/// A `StepperControl` like every other number on these screens, so ten minutes is a typed "600"
/// rather than a hundred and twenty presses.
@MainActor
private struct UnblockWaitRow: View {
    let appState: AppState
    let waiting: Bool

    /// Why the number did not take, under the row that set it — the rule this page follows.
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(
                "Wait before unblocking",
                help: "How long this card sits there before it will offer a length, counted from the moment this window opens. Nought means no wait. Changing this is behind the wait as well: shortening the friction costs the friction one last time, which is what makes it a decision rather than a preference.",
                caption: caption
            ) {
                StepperControl(
                    value: seconds,
                    range: Config.breakWaitRange,
                    step: 5,
                    format: DurationCopy.seconds
                )
                .disabled(waiting)
            }
            if let problem {
                SettingsStateRow(text: problem, tone: .warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one state worth a line under the label. Nought is a legitimate answer and an unusual
    /// one, and a card that offers a length the instant it opens should say that is what was asked
    /// for rather than look broken.
    private var caption: String? {
        appState.config.breakWaitSeconds == 0
            ? "No wait: a length is offered the moment this window opens."
            : nil
    }

    private var seconds: Binding<Int> {
        Binding(
            get: { appState.config.breakWaitSeconds },
            set: { problem = appState.setBreakWaitSeconds($0) }
        )
    }

}

/// The week's escape hatch, under the break it is the stronger version of.
///
/// It used to be the top of an "Advanced" card, which held two buttons and not one setting. A
/// break and a pass are the same idea at two strengths — everything off for a while — and the
/// only real difference is that one is free and the other is rationed. So they share a card, and
/// the pass is the row under the break rather than a heading of its own.
///
/// Not behind the settings lock, and deliberately: the pass is the escape the lock is allowed to
/// have, and gating it would turn a commitment into a trap. Behind a confirmation, because it
/// cannot be given back.
@MainActor
private struct EmergencyPassRow: View {
    let appState: AppState

    @State private var confirming = false

    var body: some View {
        // Wrapped and widened like every other row on this page, rather than left bare. A
        // `SettingsRow` claims no width of its own, so on its own in a card it is sized to what it
        // would like to be — and this is the one row here with a caption long enough to want more
        // than the column has.
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(
                "Emergency pass",
                help: "Lifts every block for one hour, including scheduled blocks and a running “Block everything”. It lifts them rather than ending them: whatever still has time left blocks again when the hour is over. One per week; the week starts on Monday.",
                caption: appState.emergencyPassLine
            ) {
                SecondaryPillButton(title: "Use pass") { confirming = true }
                    .disabled(!appState.emergencyPassAvailable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Use this week's emergency pass?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Use it", role: .destructive) { appState.useEmergencyPass() }
        } message: {
            Text("This unblocks everything for one hour. You get one per week.")
        }
    }
}

/// Every group at once, on the card that asks whether anything is being blocked.
///
/// It is here rather than on Unblock, and what decides that is what each one leaves behind. The
/// Unblock card lifts a block and puts it back on its own — a break, its wait, a pass — so
/// everything on it self-reverses and none of it needs remembering. This does not: it stays off
/// until it is switched back, which makes it an answer to "is the protection running", the
/// question this card exists to ask. Among three temporary escapes it would read as a fourth,
/// which is the one thing it is not. It is deliberately not in the menu bar popover either: that
/// is two rows now, and it stays two.
///
/// The button says how much it will move before it is pressed, the caption says what it is
/// leaving alone, and the line underneath says what happened. All three are `AllGroupsSwitch`'s —
/// the counting and the wording live there, and this only draws them, so what the button promises
/// and what the sentence reports cannot drift.
@MainActor
private struct AllGroupsRow: View {
    let appState: AppState

    /// What the last press did. A short-lived note about one click, like every refusal on this
    /// page — the caption above it is the state, and this is the news.
    @State private var said: AllGroupsSwitch.Outcome?

    private var plan: AllGroupsSwitch.Plan { appState.allGroupsSwitch }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(
                "Every group at once",
                help: "Switches every group that is on off in one press, and remembers which ones it changed. Pressing it again switches those back on and nothing else: a group you had switched off yourself stays off, which is the whole reason this remembers rather than simply switching everything on. The list is part of your settings, so quitting and coming back does not lose the way home.\n\nA group with a lock of its own is left where it is when the press switches groups **off**: ending everything a group was doing is exactly what a lock refuses. The way back is the other direction — putting a block back is nothing a lock exists to stop — so it sweeps up every group it remembers, locked or not. The button says how many groups will actually move.",
                caption: AllGroupsSwitch.caption(plan)
            ) {
                SecondaryPillButton(title: AllGroupsSwitch.buttonTitle(plan)) {
                    said = appState.switchAllGroups()
                }
                .disabled(!AllGroupsSwitch.isPressable(plan))
            }
            if let said {
                SettingsStateRow(text: said.text, tone: said.refused ? .warning : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Whether the protection is actually running, and everything it needs in order to be.
///
/// One question, asked at the top of the page: is this doing anything right now. Under it the one
/// control that changes the answer wholesale — every group off, and back on again — and then the
/// two things that decide whether it *can* block at all: the app being open, and being allowed to
/// read a browser's address bar. None of them is a preference about *how* to block; all of them
/// are the difference between blocking and not.
///
/// This card used to be called Protection and hold three unrelated topics: the settings lock,
/// quitting, and browser access. Browser access — the switch that decides whether website
/// blocking works — was at the bottom of the tallest card on the page, below the fold at the size
/// the window opened at.
@MainActor
struct ProtectionCard: View {
    let appState: AppState

    /// Why the keep-alive switch did not take. Held by the view, like every refusal on this
    /// screen: it describes one click rather than a state of the app.
    @State private var keepAliveProblem: String?

    var body: some View {
        SettingsCard("Protection") {
            SettingsStateRow(text: headline, tone: isDegraded ? .warning : .primary)
            // Everything else that is wrong, under the one thing that outranked it. `statusKind`
            // carries the first degraded line and `warningLines` the rest, and this card showing
            // only the first would be the app knowing about a second problem on the very page
            // that exists to fix them. The popover has always shown both.
            ForEach(appState.warningLines, id: \.self) { line in
                SettingsStateRow(text: line, tone: .warning)
            }
            Divider().overlay(Palette.hairline).padding(.vertical, 6)
            // Directly under the headline, because it is the one control on the page that changes
            // what that headline says outright. Everything below it is about whether blocking can
            // happen at all, which is a different question and a quieter one.
            AllGroupsRow(appState: appState)
            Divider().overlay(Palette.hairline).padding(.vertical, 6)
            SettingsRow(
                "Start at login and keep running",
                help: "Sandglass opens when you log in, and comes back within seconds if it stops. Nothing is blocked while it is not running. macOS is what runs it while this is on, so turning it off lets go of the app and quits it too."
            ) {
                SettingsToggle(isOn: keepAlive, label: "Start at login and keep running")
            }
            if let keepAliveProblem {
                SettingsStateRow(text: keepAliveProblem, tone: .warning)
            }
            Divider().overlay(Palette.hairline).padding(.vertical, 6)
            BrowserAccessSection(appState: appState)
            Divider().overlay(Palette.hairline).padding(.vertical, 6)
            ClockGuardRow(appState: appState)
        }
    }

    /// The popover's own sentence, which is the point: two screens answering "is this on right
    /// now" in two different ways is how one of them ends up wrong. A running focus session is
    /// named here for the first time — the page refuses three different things because of one
    /// and never said it was happening.
    private var headline: String {
        BlockCopy.headline(
            status: appState.statusKind,
            focusSessionLine: appState.focusSessionLine,
            blockedGroups: appState.budgetsByGroup.filter { $0.reason != nil }.count,
            groups: appState.budgetsByGroup.count,
            clockText: appState.clockText(for:)
        )
    }

    private var isDegraded: Bool {
        if case .degraded = appState.statusKind { return true }
        return false
    }

    /// The one control on this page that does not write `config.json`, gated like the ones that
    /// do: this is the settings window, so both frictions apply. A refusal leaves
    /// `keepAliveEnabled` untouched, which is what snaps the toggle back to what is installed.
    private var keepAlive: Binding<Bool> {
        Binding(
            get: { appState.keepAliveEnabled },
            set: { keepAliveProblem = appState.setKeepAlive($0, requiring: .settingsWindow) }
        )
    }
}

/// The clock guard, under the browser rows: the third thing that decides whether a block holds.
///
/// It shipped on by default and hand-edit only, which made it the one piece of enforcement with
/// no control anywhere — and the one nobody could turn off for the case it genuinely gets wrong,
/// a Mac whose time is set by hand.
///
/// The help line is deliberately modest about what this does. No app can stop a Mac's clock being
/// changed; what it can do is refuse to carry on as if nothing happened. Promising more on a
/// settings row is how somebody ends up trusting a guard that was never there.
///
/// **Nothing freezes it any more.** It was held in one direction while "Block everything" ran —
/// switching it off takes a guard away from every group at once — and before that by a scheduled
/// block as well, permanently for a group blocked around the clock. Both of those block; neither
/// is a lock, and under the lock rule only the settings lock decides what may change. That one
/// still guards this row, through `applyConfigEdit`.
@MainActor
private struct ClockGuardRow: View {
    let appState: AppState

    /// Why the switch did not take, under the switch — the rule every card on this page follows.
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(
                "Hold blocks when the system clock changes",
                help: "Sandglass cannot stop the clock being changed, only stop it from buying anything: while the clock disagrees with the time Sandglass has already seen, every group stays blocked. Moving it forward ends no wait early either way — every countdown is measured against how long the Mac has been awake. Turn it off if you set this Mac's clock by hand.\n\nA settings lock or a group passcode is what holds this row; nothing else does, “Block everything” included."
            ) {
                SettingsToggle(isOn: enabled, label: "Hold blocks when the system clock changes")
            }
            if let problem {
                SettingsStateRow(text: problem, tone: .warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { appState.config.preventTimeChange },
            set: { isOn in
                var config = appState.config
                config.preventTimeChange = isOn
                problem = appState.applyConfigEdit(config)
            }
        )
    }
}

/// What holds when you try to talk yourself out of it.
///
/// Its own card now. It shared one with browser access and with quitting under the title
/// "Protection", which is true of all three and describes none of them — and it is the only one
/// of the three with controls on it.
@MainActor
struct SettingsLockCard: View {
    let appState: AppState

    var body: some View {
        // The two paragraphs that used to sit at the foot of this card are the card's own note
        // now. They say what is true of the lock rather than what is true this second, which is
        // the difference between a state row and an explanation — and named one by one, because
        // the line before them ("settings also lock automatically during strict windows") claimed
        // the whole page while locking four things. A rule that over-claims invites the user to
        // trust a lock that is not there.
        SettingsCard(
            "Settings lock",
            help: "Two frictions on changing anything here, both off until you turn them on. Neither blocks a thing on its own: what they buy is the gap between wanting to raise a limit and being able to.\n\nEach group can carry a lock of its own as well, in its editor — a wait and a passcode that hold that group and nothing else. While “Block everything” runs, nothing in the app can change until it ends. An emergency pass lifts all of it."
        ) {
            SettingsLockSection(appState: appState)
        }
    }
}
