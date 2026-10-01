import Foundation

/// A number of seconds, in the words a row puts beside a stepper.
///
/// One function rather than one per row, for the reason `TimeWindowCopy` is shared: the settings
/// page now has two seconds-long durations on it — the wait in front of the Unblock card and the
/// warning before a group relocks — and two rows a few points apart that spelled the same ninety
/// seconds two ways would read as two different units.
///
/// In the shared module rather than beside either row, because it is arithmetic with wording
/// attached and an executable target is a target no test can import.
public enum DurationCopy {

    /// `45 sec`, `2 min`, `1 min 30 sec`.
    ///
    /// Whole minutes read as minutes: "90 sec" is a number to be worked out rather than a length
    /// anybody feels. Past the minute the seconds come *after* it rather than instead of it, so a
    /// value off the minute is never rounded away on the row that sets it — which a stepper makes
    /// reachable and a keyboard makes ordinary.
    public static func seconds(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds) sec" }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) sec"
    }
}
