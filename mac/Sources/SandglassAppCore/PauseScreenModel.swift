import SandglassCore
import Foundation

/// What a pause screen needs to know about the thing standing behind it.
///
/// A struct rather than a tuple, for the same reason as `BudgetRow`: a test can state the
/// whole expected answer at once. `targetID` is in here because every inbound call that
/// spends or refuses an open is keyed by it, and nobody outside this module should be
/// assembling one by hand.
public struct TargetDisplayInfo: Equatable, Sendable {
    public let targetID: String
    public let name: String

    public init(targetID: String, name: String) {
        self.targetID = targetID
        self.name = name
    }
}

/// Everything the pause screen shows, in one value.
///
/// A model rather than a handful of parameters because the overlay is re-rendered straight
/// from the engine's decision, and not only when it first appears: `Equatable` is what lets
/// the view tell "the same screen again" from "a different screen", which is the difference
/// between a countdown that keeps running and one that starts over.
///
/// It lives here, next to no UI framework at all, because turning a `Decision` into a screen
/// is the last rule between the engine and the user — and a rule that decides whether an
/// "Open" button exists is worth a test rather than a look.
public struct PauseScreenModel: Equatable, Sendable {
    public var targetName: String
    /// The day's budget in the engine's words, or `nil` for a group without a limit.
    public var budgetLine: String?
    public var mode: Mode

    public enum Mode: Equatable, Sendable {
        /// There is a way through: the button enables when the countdown reaches zero.
        case countdown(total: Int)
        /// There is not, and no unlock path is offered.
        ///
        /// `untilText` is the engine's own sentence, verbatim ("Blocked until 17:00", "Next
        /// open in 8 min"). Those read as promises, and V1 keeps them that way on purpose.
        /// Nothing caches them — the whole model is re-derived on every recheck, so a block
        /// that changes shape underneath simply reads differently the next time the screen
        /// is drawn.
        case blocked(untilText: String)
    }

    public init(targetName: String, budgetLine: String?, mode: Mode) {
        self.targetName = targetName
        self.budgetLine = budgetLine
        self.mode = mode
    }

    /// A decision, as a screen — or `nil` when there is no screen to build.
    ///
    /// `allowed` is a session the user already paid for and `notManaged` is an app this Mac
    /// does not block; both mean the overlay goes away rather than changes. `opensByItself` is
    /// the third: a group set to no pause has no screen to be drawn, and the open it costs is
    /// spent by `BlockPresentation`'s caller rather than by a button on one.
    ///
    /// Whether the screen is *shown* is `BlockPresentation`'s question, not this one: a model in
    /// `blocked` mode is still built, because the web half needs its words for the block page.
    public static func `for`(decision: Decision, info: TargetDisplayInfo) -> PauseScreenModel? {
        switch decision {
        case .pause(let countdownSeconds, let budgetLine):
            return PauseScreenModel(
                targetName: info.name,
                budgetLine: budgetLine,
                // A negative wait is not a shorter wait; the button would enable a frame early.
                mode: .countdown(total: max(0, countdownSeconds))
            )
        case .blocked(_, let untilText):
            // No budget line: the block already says everything true about right now, and a
            // second number under it would read as a way out that is not on offer.
            return PauseScreenModel(
                targetName: info.name,
                budgetLine: nil,
                mode: .blocked(untilText: untilText)
            )
        case .allowed, .notManaged, .opensByItself:
            return nil
        }
    }
}

/// How a decision reaches the user.
///
/// **A screen appears when there is a button on it. Otherwise the thing just goes away.** If a way
/// through exists — a countdown runs and afterwards you may open — there is a decision to make,
/// and the pause screen is where it is made. If no way through exists, a screen is a notice you
/// have to dismiss: the app is hidden or the tab is navigated instead, and the menu bar carries
/// the status.
///
/// This replaces the behaviour where every blocked activation raised the same full-screen overlay
/// whether or not it had an Open button on it.
///
/// A third answer joined the two: a way through with no wait in front of it, which is a group set
/// to no pause. There is nothing to press, so there is nothing to draw — the visit costs an open
/// and is not interrupted. See `Decision.opensByItself`.
///
/// It is derived from the same `Decision` and the same `PauseScreenModel` the screen is drawn
/// from, deliberately: the engine already knows which case it is in, and a second notion of "is
/// there a way through" living in the blocker is how the two would eventually disagree.
public enum BlockPresentation: Equatable, Sendable {
    /// Nothing stands in the way — a session the user paid for, or a target nobody blocks.
    /// Whatever is on screen goes.
    case nothing
    /// The way through with nothing on it: a group set to no pause. Nothing is drawn and nothing
    /// is dismissed — the caller spends one open where it read this and leaves the app or the
    /// page exactly where it is.
    ///
    /// A case of its own rather than `nothing`, because the two differ by an open: `nothing` is
    /// the engine having no opinion, and this is the engine charging for a visit it does not
    /// interrupt.
    case opensByItself
    /// There is a way through. The overlay, on the screen the app was on.
    case screen(PauseScreenModel)
    /// There is no way through. The model comes with it anyway, because the web half needs its
    /// words for the block page the tab is navigated to.
    case sendAway(PauseScreenModel)

    /// `info` is optional because its callers' is: nothing in the configuration claims this
    /// target, which is the same answer as nothing standing in the way.
    public static func `for`(decision: Decision, info: TargetDisplayInfo?) -> BlockPresentation {
        guard let info else { return .nothing }
        if case .opensByItself = decision { return .opensByItself }
        guard let model = PauseScreenModel.for(decision: decision, info: info) else {
            return .nothing
        }
        switch model.mode {
        case .countdown: return .screen(model)
        case .blocked: return .sendAway(model)
        }
    }

    /// The screen's words, whichever case this is — or `nil` when there is nothing to say.
    public var model: PauseScreenModel? {
        switch self {
        case .nothing, .opensByItself: return nil
        case .screen(let model), .sendAway(let model): return model
        }
    }

    /// Whether anything at all is standing in the way right now.
    ///
    /// What the "Open" button reads. A press that finds nothing left to block has to end in the
    /// way through rather than in a screen quietly disappearing — and a press that is refused
    /// must not be read as one, which is why this is not "is a screen showing".
    ///
    /// A group set to no pause stands in nobody's way: it charges for the visit and lets it
    /// happen. The press cannot reach it — a refused open is `blocked` or `notManaged`, never
    /// this — and if it ever did, "the way through" is the honest answer.
    public var blocks: Bool {
        switch self {
        case .nothing, .opensByItself: return false
        case .screen, .sendAway: return true
        }
    }
}
