import SandglassCore
import Foundation

/// One thing the picker can offer: an app on this Mac, or a website somebody might block.
///
/// It knows how to become a `Target`, and that is the whole point of it existing as a value. The
/// add row it replaced produced its target inline, which meant "typed by hand" and "ticked in a
/// list" were two code paths that could disagree about what a target for `youtube.com` looks
/// like — and two targets that differ only in their display name land in two different groups.
public struct TargetCandidate: Identifiable, Equatable, Sendable {
    /// The id the target would have. Also what a selection is keyed by, so a site reachable from
    /// two places in the list cannot be picked twice.
    public let id: String
    public let kind: TargetKind
    public let value: String
    /// What the row reads: the host for a website, the Finder's name for an app.
    public let label: String
    /// Whether the configuration already names it. `Store` refuses a document with two targets of
    /// one id, so these are shown as already blocked rather than left to fail on the click.
    public let alreadyBlocked: Bool

    public init(kind: TargetKind, value: String, label: String, alreadyBlocked: Bool) {
        self.id = Target.id(ofKind: kind, value: value)
        self.kind = kind
        self.value = value
        self.label = label
        self.alreadyBlocked = alreadyBlocked
    }

    /// The target this candidate stands for.
    ///
    /// A website's display name is `DomainInput.displayName(for:)` and nothing else — exactly
    /// what the old text field produced. That is what makes a domain typed by hand and one ticked
    /// in the list the same target: the same id, the same value, and the same name, which is also
    /// what decides which group it lands in.
    public var target: Target {
        Target(
            kind: kind,
            value: value,
            displayName: kind == .domain ? DomainInput.displayName(for: value) : label
        )
    }
}

/// The vocabulary a list of things to tick is built from, and what a selection turns into.
///
/// Here rather than in the view for the reason `ConfigBuilder` is: a list assembled wrong is not
/// cosmetic. Offering something already blocked produces a document the store refuses, and
/// offering a site under the wrong name puts it in a group the user is not looking at.
///
/// What each sheet actually puts on offer is `AppChoices` and `SiteField` — this is the shared
/// half: an installed app, a search over rows, and the way out to `[Target]`.
public enum TargetPicker {

    /// One installed application, as much of it as this reaches for.
    public struct App: Equatable, Sendable {
        public let bundleID: String
        public let name: String

        public init(bundleID: String, name: String) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    /// The candidates a search matches, or all of them when nothing has been typed.
    ///
    /// Case-insensitive and anywhere in the row, so `tube` finds YouTube and `.de` finds every
    /// German host at once.
    public static func matching(_ query: String, in candidates: [TargetCandidate]) -> [TargetCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { $0.label.localizedCaseInsensitiveContains(trimmed) }
    }

    /// What a selection actually adds, in the order the list offered it, **each thing once**.
    ///
    /// Anything already blocked is dropped rather than refused: the row says so, the checkbox
    /// cannot reach it, and a stale id left in a selection must not be able to produce a document
    /// the store then rejects whole.
    ///
    /// The same id twice is the other way to build that document, and it was not being caught.
    /// It has been safe so far only because the one production caller hands over a list
    /// `AppChoices.everything` has already deduped — an invariant asserted in a doc comment two
    /// files away, holding by luck. It is cheap enough to hold here, where the promise is made.
    public static func targets(
        picked: Set<String>, from candidates: [TargetCandidate]
    ) -> [Target] {
        var seen = Set<String>()
        return candidates
            .filter { picked.contains($0.id) && !$0.alreadyBlocked && seen.insert($0.id).inserted }
            .map(\.target)
    }
}
