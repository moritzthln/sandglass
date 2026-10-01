import Foundation

extension Calendar {
    /// The one calendar every wall-clock decision in Sandglass is made on: Gregorian, in the
    /// caller's time zone.
    ///
    /// Schedules, day keys and week boundaries are promises about the clock on the wall, so
    /// a user whose Mac is set to a Buddhist or Hebrew system calendar has to get the same
    /// answer as everyone else. Three places used to build this for themselves — the engine,
    /// the day key, the week start — and three copies of the same two lines is how the day
    /// boundary and the week boundary end up disagreeing about what a day is.
    ///
    /// The base is built once; copying a `Calendar` value and setting its zone is cheap
    /// enough for a per-request call.
    static func sandglassGregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = gregorianBase
        calendar.timeZone = timeZone
        return calendar
    }

    private static let gregorianBase = Calendar(identifier: .gregorian)
}
