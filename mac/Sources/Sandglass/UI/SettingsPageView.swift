import SandglassAppCore
import SandglassCore
import AppKit
import SwiftUI

/// The Settings page: everything that is true of the app rather than of one group.
///
/// Two columns of cards, and a footer under both of them. The left column opens with the one
/// question the page exists to answer — is the protection running — and goes on to the
/// preferences; the right column holds the things you come here to *do* and the lock on doing
/// them.
///
/// Blocking everything is on that right column now, above the card that undoes it. It used to be
/// in the menu bar popover and nowhere else, which put the hardest thing this app does behind a
/// panel that closes when you look away. See `BlockEverythingCard` for what
/// else came here when that panel became two items.
///
/// Presets and Categories were here and are now a page of their own: they are neither app-wide
/// settings nor one group's business, but the parts groups are assembled from. See
/// `PresetsPageView`.
///
/// Every card owns its own refusals. They used to be pushed to the page's banner, which is at
/// the top of a scroll view: a toggle refused at the bottom of the right-hand column explained
/// itself off the top of the screen.
///
/// **Two into three is the balance, and it was measured rather than guessed.** Hung in an
/// off-screen window at the 1000-point floor, the left column ends at 733 points and the right at
/// 679 — 54 apart on a 762-point page, and 37 apart once the settings lock has both frictions
/// switched on and grows to its full height. There is no card to move: each of the five is between
/// 200 and 470 points tall, so any swap trades a 54-point gap for one in the hundreds.
@MainActor
struct SettingsPageView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            Text("Settings").font(.largeTitle.weight(.semibold))
            HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                VStack(spacing: Metrics.cardSpacing) {
                    ProtectionCard(appState: appState)
                    GeneralCard(appState: appState)
                }
                VStack(spacing: Metrics.cardSpacing) {
                    BlockEverythingCard(appState: appState)
                    UnblockCard(appState: appState)
                    SettingsLockCard(appState: appState)
                }
            }
            SettingsFooter(appState: appState)
        }
    }
}

// MARK: - Footer

/// Quitting.
///
/// Quitting was a button inside the Protection card, which made an app-level command look like
/// part of a topic. It spans both columns down here because it belongs to neither.
///
/// What quitting will and will not do was a paragraph above the button and is an info button
/// beside it. The rule is the whole page's: a control, and the prose behind an `i`.
@MainActor
private struct SettingsFooter: View {
    let appState: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SecondaryPillButton(title: "Quit Sandglass") { NSApp.terminate(nil) }
            InfoButton(quitLine)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.top, 4)
    }

    /// What quitting will and will not do.
    ///
    /// It used to open "Sandglass will not quit during a strict window or a focus session", which
    /// stopped being true when the refusal went — see `QuitPolicy`. It says the opposite now, and
    /// says it first, because that is the sentence somebody standing in front of a block came here
    /// to read.
    ///
    /// The passcode is named only when it would actually be asked for, which is narrower than
    /// "a passcode exists": it guards the middle button of the quit dialogue, the one that turns
    /// off "Start at login and keep running", and that dialogue only appears when the agent is
    /// installed. A rule the reader has to work out does not apply to them is worse than no rule.
    private var quitLine: String {
        let base = "Quitting always works — during a strict window, during a focus session, whenever. Logging out or restarting your Mac is never held up either."
        guard appState.keepAliveEnabled, appState.config.settingsLock.passcode != nil else {
            return base
        }
        return "\(base) Quitting for good means turning off “Start at login and keep running”, which asks for your passcode."
    }

}

// MARK: - General

/// App-wide, and about neither of the two questions the other cards ask: not whether blocking is
/// running, and not how to get out of it for a while. Three choices about how the app behaves, and
/// one button. "Start at login and keep running" used to be the first row here and is now the
/// second row of Protection, where the question it answers is asked.
///
/// **The button is last, under "Start of day", and the pair is the reason it is on this card.**
/// Those two are what decide what a day holds — where it begins, and what its counters stand at —
/// and the same lock refuses both while a block is standing, so they carry the same caption and
/// go dead together. "Reset today's counters" spent a wave on the Unblock card among three ways
/// out that all put themselves back; handing a day's budget back is permanent, and the card's own
/// note never mentioned it.
///
/// Every row is a label, a control and nothing else. The two captions under them said what the
/// chosen value meant, which is the same sentence the info button already had to carry for the
/// other values — so both went into the info button, whole.
@MainActor
private struct GeneralCard: View {
    let appState: AppState

    /// Why the last change did not take, shown under the row that was refused rather than in the
    /// page's banner. See `SettingsPageView`.
    @State private var problem: String?

    var body: some View {
        SettingsCard("General") {
            SettingsRow(
                "Show the countdown in the menu bar",
                help: "While a session is running, the menu bar shows how long is left next to the icon."
            ) {
                SettingsToggle(isOn: countdown, label: "Show the countdown in the menu bar")
            }
            Divider().overlay(Palette.hairline)
            SettingsRow(
                "Warning before a group relocks",
                help: "How long before a group relocks the heads-up arrives — long enough to finish what you are doing, short enough not to be a second countdown. None turns it off, and then a group relocks without warning."
            ) {
                // A quantity with an off state at the bottom of its own span, which is the daily
                // time limit's shape rather than a dropdown's: four named lengths were somebody
                // else's opinion about how much warning is enough, offered as the only opinions
                // available. Nought is None; see `Config.expiryWarningRange`.
                StepperControl(
                    value: expiryWarning,
                    range: Config.expiryWarningRange,
                    nextValue: Config.expiryWarningSeconds(after:goingUp:),
                    format: Self.warningLabel(_:)
                )
            }
            Divider().overlay(Palette.hairline)
            // Held by the settings lock and by nothing else. "Block everything" used to freeze it
            // in both directions, on the argument that moving it either way can bring the next
            // rollover forward and hand a spent budget back early; a scheduled block held it
            // before that, permanently for a group blocked around the clock. Both block and
            // neither is a lock — see `RulesEngine.updateConfig`.
            SettingsRow(
                "Start of day",
                help: "Daily open counts reset and streaks update at this time. Later than midnight by default, so scrolling after midnight still counts against the day before rather than tapping a fresh budget."
            ) {
                // A time of day, so it is written the way every other time of day the user picks
                // is: `FieldNotation.clock` for the keyboard, and `TimeWindowCopy.endpoint` — the
                // notation's own draft function — for the row at rest, so the two cannot disagree.
                // Whole hours were all the dropdown could offer; a quarter-hour is what somebody
                // whose day starts at half past five needs.
                StepperControl(
                    value: dayStart,
                    range: Config.dayStartRange,
                    nextValue: ControlRules.clockMinutes(after:goingUp:),
                    notation: .clock,
                    format: TimeWindowCopy.endpoint
                )
            }
            if let problem {
                SettingsStateRow(text: problem, tone: .warning)
            }
            Divider().overlay(Palette.hairline)
            ResetTodayRow(appState: appState)
        }
    }

    /// Nought is off, and says so. Every other value is the page's one spelling of a length in
    /// seconds — see `DurationCopy`, which the wait on the Unblock card is written by too.
    private static func warningLabel(_ seconds: Int) -> String {
        seconds == 0 ? "None" : DurationCopy.seconds(seconds)
    }

    /// Nought on the stepper is `nil` in the file, in both directions.
    ///
    /// The two spellings mean the same thing and neither can be dropped: the control needs a number
    /// at the bottom of its span, and `config.json` has always said "no warning" by holding no
    /// number — a `0` written there would be a duration of nought seconds, which is a warning that
    /// arrives as the group relocks rather than no warning at all. The translation is one line and
    /// it lives here, where the control is, rather than in the model.
    private var expiryWarning: Binding<Int> {
        Binding(
            get: { appState.config.expiryWarningSeconds ?? 0 },
            set: { seconds in
                var config = appState.config
                config.expiryWarningSeconds = seconds == 0 ? nil : seconds
                problem = appState.applyConfigEdit(config)
            }
        )
    }

    private var countdown: Binding<Bool> {
        Binding(
            get: { appState.config.showsMenuBarCountdown },
            set: { isOn in
                var config = appState.config
                config.showsMenuBarCountdown = isOn
                problem = appState.applyConfigEdit(config)
            }
        )
    }

    private var dayStart: Binding<Int> {
        Binding(
            get: { appState.config.dayStartMinutes },
            set: { minutes in
                var config = appState.config
                config.dayStartMinutes = minutes
                problem = appState.applyConfigEdit(config)
            }
        )
    }
}
/// Handing today's budget back, on the card with the other two things that hand time back.
///
/// It spent a wave on the Stats page, under the counters it clears, which is a good argument and
/// the wrong one: Stats reports and this acts, and the settings page is where somebody setting a
/// group up goes looking for the way to try it again. It is here and only here — the same
/// confirm-and-destroy button in two places is one more thing to keep in step, and the counters
/// it clears are named in its own popover.
///
/// Behind the settings lock, exactly as an edit is: resetting hands back a budget that has already
/// been spent, which is loosening today's rules. Behind a confirmation too, because it cannot be
/// undone.
///
/// **And behind nothing else.** The engine held it as well — a strict window did, permanently for
/// a group blocked around the clock, and then "Block everything" did for as long as it ran — so
/// the button was drawn dead with the reason under it. Neither holds it now: both of them block,
/// and under the lock rule a block is not a lock. The `problem` line stays for the failures
/// that are not a lock, which is a settings file the app cannot write.
@MainActor
private struct ResetTodayRow: View {
    let appState: AppState

    @State private var confirming = false
    /// Why the reset was refused, under the row that raised it — the rule this page follows.
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(
                "Reset today's counters",
                help: "Sets today's opens, the time counted against a limit, the pause screens you turned away from and every waiting cooldown back to zero. Useful while setting a group up. It is not a way to undo a day: the streak, the week's history and a day already over budget all stand.\n\nA settings lock is what holds it. “Block everything” does not: it blocks, and a block is not a lock."
            ) {
                SecondaryPillButton(title: "Reset today") { confirming = true }
            }
            if let problem {
                SettingsStateRow(text: problem, tone: .warning)
            }
        }
        .alert("Reset today's counters?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { problem = appState.resetTodaysCounters() }
        } message: {
            Text("Today's opens, the time counted against a limit, the pause screens you turned away from and every waiting cooldown go back to zero. The streak is not rewritten: a day already over budget still counts against it tonight.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

