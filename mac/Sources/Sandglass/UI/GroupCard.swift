import SandglassAppCore
import SandglassCore
import SwiftUI
import UniformTypeIdentifiers

/// What a dragged group card carries, and the only thing the sidebar accepts a drop of.
///
/// A bare `String` would have done the same work in three fewer lines, and would have made every
/// card in the sidebar a drop target for any text on the machine: a word dragged out of a mail
/// message would light the cards up and then do nothing, and a card dragged the other way would
/// paste its raw id into whatever it landed in. A type of our own says what the payload is, and
/// nothing else in the system writes it.
///
/// Declared in `Info.plist` under `UTExportedTypeDeclarations`, which is what an exported type
/// means — without it macOS says so in the log on every launch.
struct DraggedGroup: Codable, Transferable {
    let groupID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sandglassGroup)
    }
}

extension UTType {
    static let sandglassGroup = UTType(exportedAs: "io.github.moritzthln.sandglass.group")
}

/// One group in the sidebar: what it is called, when it applies, and where its day stands. The
/// whole card is the button.
///
/// **Two rows, because seven groups have to fit.** It was three and a rule across the middle —
/// name, schedule, then a count of what is in it beside the day's line — which made the shortest
/// card 69 points and the tallest 96. The sidebar's list has 496 to spend at the window's minimum
/// size and seven cards came to 633, so a list of seven groups was a list you had to scroll to
/// see the end of. At 51 apiece, eight fit.
///
/// What went is written down where it went: the divider and a third of the padding at `body`,
/// the count of targets at `GroupSummary.cardStatus`, and the wrapping — which is what made two
/// cards taller than the rest — at `standingRow`. Nothing that says whether the group is
/// protecting anything went anywhere: the shield keeps its three states, the strip keeps its
/// seven days and its colour, and a blocked group still says so in red.
struct GroupCard: View {
    let group: ConfigGroup
    /// Where the day stands, or — while the group is blocked — when the block lifts. Which of the
    /// two is `MainWindowView.todayLine`'s decision; see `isBlocked`. Empty for a group the engine
    /// has nothing to say about, and then the row says what is in it instead — `standing`.
    let todayLine: String
    /// Whether that line is a block rather than a count, so it can be read as one at a glance.
    var isBlocked = false
    /// Whether the engine is standing down over this group this second — a break window, or a
    /// pause over the whole app. The shield says so; see `BudgetRow.isOpen`.
    var isOpen = false
    let isSelected: Bool
    /// Whether a card being dragged is over this one right now, so the row can say it is the slot
    /// the drop would take. See `dropIndicator`.
    var isDropTarget = false
    let action: () -> Void

    /// **Not a `Button`, and that is the whole reason the card can be dragged.**
    ///
    /// It was one, with `.draggable` applied over it from the sidebar, on the theory that a button
    /// fires on a press that stays put while a drag begins on movement — so the two could share the
    /// card. On macOS they cannot: `.buttonStyle(.plain)` takes the mouse down and keeps it, the
    /// movement never reaches `.draggable`, and dragging a group did nothing at all.
    ///
    /// A tap gesture yields where a button does not, so selecting and dragging can both live here.
    /// What a button gave for free has to be asked for instead — the trait, so the row is announced
    /// as something to press, and the action, so it can be pressed without a mouse.
    ///
    /// **No divider, and less padding around it.** A rule across the middle of a card divides two
    /// halves, and there are no halves left to divide — it cost 17 points, which is a third of
    /// what a card now is. The padding came down with it, 12 to 10: a two-row card wants less
    /// room around it than a four-row one, or the whitespace outgrows the writing.
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            standingRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The whole card, including the gaps between its text, is the target — for the tap and for
        // the drag alike.
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .background(isSelected ? Palette.selection : Palette.card,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Palette.hairline,
                              lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(dropIndicator)
        .opacity(group.isActive ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(.default, action)
    }

    /// Where the dragged card would land, drawn **on top of** the selection border rather than
    /// instead of it.
    ///
    /// Two facts, two marks: which group is being edited is still the solid accent border, and it
    /// has to go on saying so while a drag passes over it — a drag that repainted the selection
    /// would leave the right-hand page describing a group no longer marked as chosen. Dashed, so
    /// the two are told apart without reading the colour.
    @ViewBuilder
    private var dropIndicator: some View {
        if isDropTarget {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
    }

    /// Shield, name, strip: the row that says which group this is and whether it is guarding
    /// anything. Nothing else may join it — everything here is fixed-width but the name, and the
    /// name is what somebody is reading the sidebar to find.
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: shield.symbol)
                .foregroundStyle(shield.tint)
                .frame(width: 18)
                .help(shield.help)
                .accessibilityLabel(shield.help)
            Text(group.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if !windows.isEmpty {
                WeekdayStrip(weekdays: TimeWindowList.weekdays(in: windows), tint: stripTint)
            }
        }
    }

    /// Three states, not two. A filled shield meant "switched on", which it went on saying over a
    /// group sitting inside a break window with nothing held back — an icon claiming protection
    /// that is not there, which is the one thing this app must never do.
    private var shield: (symbol: String, tint: Color, help: String) {
        guard group.isActive else {
            return ("shield.slash", .secondary, "This group is off and blocks nothing")
        }
        guard !isOpen else {
            return (
                "shield", Palette.windowTint(.break), "On, but nothing is held back right now"
            )
        }
        return ("shield.fill", .accentColor, "This group is on")
    }

    /// The whole of the second row: where the day stands on the left, what the group's week looks
    /// like on the right, under the strip it belongs to.
    ///
    /// **It was two rows, and the top one wrapped.** The schedule used to sit inside the name's
    /// column, which is the 134 points left over beside a 109-point weekday strip — so
    /// "Blocked · 09:00 – 17:00" ran onto a second line and those cards stood 13 points taller
    /// than the rest. Out here it has the width of the card, and a card is one height.
    ///
    /// One line each, and the day's standing is served first: it is the half that moves while you
    /// watch the list, and the schedule is a fact you set once and can read off the strip above it
    /// anyway. So when the two do not both fit, the schedule is what loses its tail.
    private var standingRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(
                GroupSummary.cardStatus(
                    todayLine: todayLine, apps: group.appCount, sites: group.siteCount
                )
            )
            .font(.caption)
            .foregroundStyle(isBlocked ? Color.red : Color.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 6)
            if let standing {
                Text(standing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// A group that is switched off says so before it says anything else — the strip and the
    /// numbers beside it describe a group that is doing nothing.
    private var standing: String? {
        if group.settings == nil { return "No settings" }
        if !group.isActive { return "Off" }
        return TimeWindowCopy.summary(windows)
    }

    /// The strip is the union of every window's days, drawn in the colour of whichever kind covers
    /// most of the week. One colour for both meant a lit Saturday could equally be "blocked all
    /// day" or "free all day", and the card gave no way to tell which.
    private var stripTint: Color {
        TimeWindowList.dominantKind(in: windows).map(Palette.windowTint) ?? .accentColor
    }

    private var windows: [TimeWindow] { group.settings?.timeWindows ?? [] }
}

/// A row in the sidebar's fixed top and pinned bottom zones: icon, label, whole row clickable.
struct SidebarNavRow: View {
    let icon: String
    let title: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isActive ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
