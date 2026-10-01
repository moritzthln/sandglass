import Foundation

/// The event kinds V1 writes into `events.jsonl`.
///
/// String constants rather than an `enum` case set, because `Event.kind` is deliberately a
/// plain `String`: the log outlives the build that wrote it, and a reader that meets a kind
/// it has never heard of has to skip that one line. An enum would fail the whole record and
/// take the surrounding week's statistics with it.
public enum EventKind {
    /// The user pushed through a pause screen and the group was opened.
    public static let open = "open"
    /// The user turned back at the pause screen.
    public static let dismissal = "dismissal"
    /// A session ran out or was ended early.
    public static let sessionEnd = "sessionEnd"
    /// Something looked like an attempt to get around the block.
    public static let bypassSignal = "bypassSignal"
    /// A browser would not move the tab it was asked to move — to the block page, or home from
    /// it. The one kind here that is about the app failing rather than about the user, and it is
    /// in this log for want of anywhere better: `NSLog` from a menu-bar app with no console open
    /// reaches nobody, and a block that quietly did nothing has to be findable afterwards.
    public static let navigationFailed = "navigationFailed"
}

/// One line of the append-only log behind the stats screen.
///
/// `groupID` is optional because not every event belongs to a group. Anything that counts
/// per group — `weeklyOpens`, the stats screen — ignores the ones that do not.
public struct Event: Codable, Equatable, Sendable {
    public var ts: Date
    public var kind: String
    public var groupID: String?
    /// What happened, for a kind whose whole value is the detail — which is `navigationFailed`
    /// and, so far, nothing else. A count needs no words; a failure that has to be diagnosed
    /// months later needs the browser's own answer, and the alternative was that answer going
    /// nowhere at all.
    ///
    /// Optional with a default, which is the rule every field added after the fact follows: a
    /// line written by an older build has no `detail` and has to keep decoding, or one release
    /// would take the whole log's statistics with it. See `SandglassJSON`.
    public var detail: String?

    public init(ts: Date, kind: String, groupID: String?, detail: String? = nil) {
        self.ts = ts
        self.kind = kind
        self.groupID = groupID
        self.detail = detail
    }
}
