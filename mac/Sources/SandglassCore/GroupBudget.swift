import Foundation

/// What one moment's counters add up to: opens spent, time left in a session, time left on a
/// cooldown, and the sentence the pause screen puts under the question.
///
/// Read-only arithmetic over `EngineState`, taken as a snapshot together with the moment it is
/// about. Split out of `RulesEngine` because none of it decides anything — the engine holds the
/// precedence and the mutations, and asks this for the numbers those decisions are made of.
///
/// Built per question rather than held: `EngineState` is a value of copy-on-write dictionaries,
/// so a snapshot costs a retain, and one that could go stale between the mutation and the answer
/// would be worse than free.
struct GroupBudget {
    let state: EngineState

    /// The moment this is about, and the uptime it was read at. Both halves are needed: the
    /// counters are about a wall-clock day, the two countdowns below are about a length of time
    /// nobody can shorten by setting the clock.
    let reading: ClockReading

    /// Opens spent today. Fractional because earn-back credits half of one at a time.
    func opensUsed(_ groupID: String) -> Double { state.opensUsed[groupID] ?? 0 }

    /// Seconds spent in the group today — counted a second at a time by the app, never estimated.
    func usageSeconds(_ groupID: String) -> Int { state.usageSecondsToday[groupID] ?? 0 }

    /// Seconds the day's time budget still has in it, and never fewer than none.
    ///
    /// The one home for that subtraction: `line(_:_:)` reads it to say how long is left, and
    /// `grantedSessionSeconds(_:_:)` reads it to decide how long an open may be. Two spellings of
    /// it is how the number on the screen and the session behind it start disagreeing.
    func secondsLeftToday(_ groupID: String, dailyMinutes: Int) -> Int {
        max(0, dailyMinutes * 60 - usageSeconds(groupID))
    }

    /// Seconds left in the group's session, or `nil` when none is running.
    func remainingSessionSeconds(_ groupID: String) -> Int? {
        guard let session = state.sessions[groupID], let endsAt = session.endsAt else { return nil }
        let remaining = reading.secondsUntil(endsAt, uptime: session.endsAtUptime)
        guard remaining > 0 else { return nil }
        return Int(remaining.rounded(.up))
    }

    func remainingCooldownMinutes(_ groupID: String) -> Int? {
        guard let until = state.cooldownUntil[groupID] else { return nil }
        let remaining = reading.secondsUntil(until, uptime: state.cooldownUntilUptime[groupID])
        guard remaining > 0 else { return nil }
        return Int((remaining / 60).rounded(.up))
    }

    /// The next open has to fit whole: with 4.5 of 5 used, 5.5 > 5 denies. Earn-back therefore
    /// only buys an open once two half credits have added up to one.
    func isExhausted(_ groupID: String, opensPerDay: Int?) -> Bool {
        guard let opensPerDay else { return false }
        return opensUsed(groupID) + 1.0 > Double(opensPerDay)
    }

    /// Whether the group has spent the whole of its day. `false` for a group with no time limit,
    /// which has no day to spend.
    func isTimeLimitReached(_ groupID: String, _ settings: GroupSettings) -> Bool {
        guard let dailyMinutes = settings.dailyMinutes else { return false }
        return usageSeconds(groupID) >= dailyMinutes * 60
    }

    /// How long this group's next pause screen waits, escalation included — or `nil` when there
    /// is no screen for it to wait on.
    ///
    /// Half credits do not shorten the wait: only whole opens already spent lengthen it.
    ///
    /// **`nil` is the whole of the zero-pause rule, and it lives here so escalation composes.**
    /// A group set to no pause has opted out of the screen rather than into a countdown that is
    /// already over: the app or the page opens by itself and the open is spent on arrival. The
    /// test is the *computed* wait rather than the setting behind it, which is what makes a base
    /// of nought with escalation on coherent — the first open of the day is silent, the second
    /// meets a screen with the escalated wait on it. A caller asking `pauseSeconds == 0` for
    /// itself would answer that second open wrong, and every caller would have to be told.
    func countdownSeconds(_ groupID: String, _ settings: GroupSettings) -> Int? {
        let full = Int(opensUsed(groupID).rounded(.down))
        let seconds = settings.pauseSeconds + settings.escalationSeconds * full
        return seconds > 0 ? seconds : nil
    }

    /// How long an open granted right now may last, or `nil` for a group that never relocks.
    ///
    /// **Never longer than the day has left.** `RulesEngine.grantOpen` handed out the full
    /// `sessionMinutes` without consulting the time budget, so a 30-minute limit with 28 spent and
    /// a ten-minute session length cost a whole open, started a ten-minute session and had
    /// `reapSessionsOverTimeLimit` end it two minutes later. The open was gone, and earn-back
    /// could not give it back — that wants the user to end the session early by hand, and they
    /// had not. Two minutes left is a two-minute session; anything else puts a number on the
    /// pause screen the app already knows to be false.
    ///
    /// A group with no session length is left alone rather than given one that ends at the limit.
    /// "No relock" is what the user set, there is no session to shorten, and inventing one would
    /// bring a cooldown and a menu-bar countdown with it.
    ///
    /// What a very short session costs is still a whole open. The alternative is fractional
    /// opens, which is a concept for a problem nobody has.
    ///
    /// The floor of one second is for a `state.json` edited by hand: the only caller reaches here
    /// from a `.pause` decision, which already means the day is not spent, so the subtraction is
    /// at least a second on its own.
    func grantedSessionSeconds(_ groupID: String, _ settings: GroupSettings) -> Int? {
        guard let sessionMinutes = settings.sessionMinutes else { return nil }
        let full = sessionMinutes * 60
        guard let dailyMinutes = settings.dailyMinutes else { return full }
        return max(1, min(full, secondsLeftToday(groupID, dailyMinutes: dailyMinutes)))
    }

    /// The day's budget in the exact words the pause screen shows, or `nil` for a group with
    /// neither budget on — there is nothing to report.
    ///
    /// **Every budget that is on, not only the opens.** It described the opens and nothing else,
    /// so a group with both showed "3 of 5 opens left today" over a day with twelve minutes in
    /// it: the user pushed through the pause knowing one number and was relocked by the other,
    /// which had never been on screen. The two count different things — opens how often you go
    /// in, minutes how long you stay — and neither can be read off the other, so both are said.
    ///
    /// Both are floored, for the reason the opens always were: half an open earned back is not
    /// an open to spend, and forty seconds left is not a minute to stay.
    func line(_ groupID: String, _ settings: GroupSettings) -> String? {
        var parts: [String] = []
        if let opensPerDay = settings.opensPerDay {
            let left = Int((Double(opensPerDay) - opensUsed(groupID)).rounded(.down))
            parts.append("\(max(0, left)) of \(opensPerDay) opens")
        }
        if let dailyMinutes = settings.dailyMinutes {
            parts.append("\(secondsLeftToday(groupID, dailyMinutes: dailyMinutes) / 60) min")
        }
        guard !parts.isEmpty else { return nil }
        return "\(parts.joined(separator: " and ")) left today"
    }
}
