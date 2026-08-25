//
//  TodosWidget.swift
//  RoutineOrganizerWidgets
//
//  The to-do list on the home screen, with working checkboxes.
//
//  Modelled on the shape iOS's own Reminders widget uses — heading, a count in
//  the corner, rows with tappable circles — because that shape is already what
//  people expect a to-do widget to be, and spending the user's recognition
//  budget on novelty here would buy nothing.
//
//  Written as its own layout rather than a shrunk `ItemRow`. The app's row
//  carries a category wash, a trailing dot, metadata, swipe-to-delete and an
//  edit tap target; none of that survives a 155pt square, and a widget can't
//  scroll, so what it shows has to be chosen rather than clipped. What it *does*
//  share is the app's tokens, accent and ordering.
//

import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Timeline

struct TodosEntry: TimelineEntry {
    let date: Date
    let snapshot: TodosSnapshot
    /// nil unless the user forced a language — see `AppLanguage.explicitLocale`.
    let locale: Locale?
}

/// Configured rather than static, so one widget can show "Work" and another
/// "Shopping". Everything else about the widget is decided by the app's own
/// rules; which list to look at is the one thing only the user can answer.
struct TodosProvider: AppIntentTimelineProvider {

    typealias Intent = SelectTodoListIntent
    typealias Entry = TodosEntry

    /// How many rows each size can show honestly.
    ///
    /// Both home-screen families fit four — they are the same 155pt height, and
    /// small differs only in width. The lock-screen rectangle fits two, which is
    /// also what Reminders shows there.
    /// A clipped final row reads as a bug, so these are the counts that fit
    /// including everything drawn around them.
    ///
    /// Medium said five for a long time and could not draw it. Five rows leave
    /// nothing for the header and the "+N more" line, so as soon as a sixth
    /// to-do existed — the only time the overflow line appears — the tile
    /// overflowed its 155pt at *both* ends: the heading lost its top half and
    /// "+1 more" was cut off entirely. Seen on the simulator, not reasoned
    /// about. Four rows plus the overflow line is what the height actually
    /// holds, and it says "+2 more" instead of "+1 more" — which is the same
    /// information, drawn.
    static func rowLimit(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall, .systemMedium: return 4
        case .accessoryRectangular: return 2
        default: return 0    // the circular accessory shows the count alone
        }
    }

    func placeholder(in context: Context) -> TodosEntry {
        TodosEntry(date: Date(), snapshot: .placeholder(limit: Self.rowLimit(for: context.family)), locale: nil)
    }

    /// The gallery preview. Real sample content rather than the user's data:
    /// the gallery is browsed before the widget is added, and an empty tile
    /// there makes a widget look broken rather than new.
    ///
    /// Trimmed to the same limit the family really uses, so the preview can't
    /// promise three rows on a size that will only ever draw two.
    func snapshot(for configuration: SelectTodoListIntent, in context: Context) async -> TodosEntry {
        guard !context.isPreview else {
            let snapshot = TodosSnapshot.placeholder(limit: Self.rowLimit(for: context.family))
            return TodosEntry(date: Date(), snapshot: snapshot, locale: nil)
        }
        return entry(from: WidgetStore.read(), configuration: configuration, family: context.family)
    }

    func timeline(for configuration: SelectTodoListIntent, in context: Context) async -> Timeline<TodosEntry> {
        // One read, used for both the entry and the refresh date. Reading the
        // store twice here was pure waste on the one path that runs most often.
        let reading = WidgetStore.read()
        let entry = entry(from: reading, configuration: configuration, family: context.family)
        let next = WidgetSnapshotBuilder().refreshDates(from: reading.items).first

        // A checklist changes when the user acts, not on a clock — the app asks
        // for a reload on every save. The only date this widget genuinely needs
        // is the rollover, so undated to-dos and the day's heading stay right.
        return Timeline(entries: [entry], policy: next.map { .after($0) } ?? .atEnd)
    }

    private func entry(
        from reading: WidgetStore.Reading,
        configuration: SelectTodoListIntent,
        family: WidgetFamily
    ) -> TodosEntry {
        let snapshot = WidgetSnapshotBuilder().todos(
            from: reading.items,
            listID: configuration.selectedListID,
            knownListIDs: reading.knownListIDs,
            groupName: configuration.title(settings: reading.settings),
            limit: Self.rowLimit(for: family)
        )
        return TodosEntry(
            date: Date(),
            snapshot: snapshot,
            locale: reading.settings.appLanguage.explicitLocale
        )
    }
}

// MARK: - Views

struct TodosWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodosEntry

    var body: some View {
        content
            .containerBackground(Theme.Colors.background, for: .widget)
            // The extension is its own process and never sees the app's
            // `AppleLanguages`, so the chosen language is pushed in here.
            // nil means "System", which is what iOS resolves on its own.
            .environment(\.locale, entry.locale ?? .autoupdatingCurrent)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular: RemainingCountAccessory(remaining: entry.snapshot.remaining)
        case .accessoryRectangular: RectangularTodoAccessory(snapshot: entry.snapshot)
        default: listBody
        }
    }

    private var metrics: WidgetMetrics { .init(family: family) }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            header

            if entry.snapshot.isEmpty {
                emptyState
            } else {
                ForEach(entry.snapshot.rows) { row in
                    TodoWidgetRow(row: row, metrics: metrics)
                }
                if entry.snapshot.overflow > 0 {
                    Text("+\(entry.snapshot.overflow) more")
                        .font(.system(size: metrics.overflow))
                        .foregroundStyle(Theme.Colors.textFaint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// The group's name, with the outstanding count in the corner.
    ///
    /// The count is the *total* outstanding, not the number of rows shown — a
    /// widget showing two of nine has to say nine, or it quietly under-reports
    /// the day.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.snapshot.groupName)
                .font(.system(size: metrics.heading, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colors.textSecondary)
                // A long list name gives way to the count rather than pushing
                // it off the edge: the number is the smaller and the more
                // important of the two.
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)

            Spacer(minLength: 4)

            if !entry.snapshot.isEmpty {
                // `verbatim` on purpose: `Text("\(count)")` generates the
                // catalog key "%lld", which is a translation entry that says
                // nothing and can only ever be a number. Formatting still
                // follows the locale, because that's `format:`'s job.
                Text(entry.snapshot.remaining, format: .number)
                    .font(.system(size: metrics.count, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.accent)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    /// Three different nothings, and they don't mean the same thing.
    ///
    /// "All clear" is praise, and it would be a lie on a list that was deleted or
    /// one that never had anything in it. Saying which is cheap; guessing wrong
    /// is how a widget stops being trusted.
    private var emptyState: some View {
        Text(entry.snapshot.emptyMessage)
            .font(.system(size: metrics.title))
            .foregroundStyle(Theme.Colors.textFaint)
            .lineLimit(2)
            .padding(.top, 2)
    }
}

extension TodosSnapshot {
    /// Shared by every family so the wording can't drift between them.
    var emptyMessage: LocalizedStringKey {
        if !listExists { return "This list is gone" }
        return isDefaultGroup ? "All clear" : "Nothing in this list"
    }
}

/// The type scale for the home-screen families, in fixed points.
///
/// Two things are deliberate here.
///
/// **Fixed sizes, not text styles.** `.footnote` and friends follow the system
/// text-size setting, and a widget cannot scroll — so at the larger settings the
/// rows grew until the last one was half-drawn, which reads as a broken widget
/// rather than as large text. The app itself draws at fixed sizes for the same
/// reason (see `Theme.Typography`), so this also puts the widget on the app's
/// own scale. Anything too long now clips at the tail instead: a truncated
/// title still says what it is, a squeezed layout says nothing.
///
/// **One scale for both sizes.** Small and medium are the same height and show
/// the same four rows; only the width differs. Sizing them apart made the two
/// tiles look like two apps when they sit side by side on the same screen.
private struct WidgetMetrics {
    let heading: CGFloat
    let count: CGFloat
    let title: CGFloat
    let circle: CGFloat
    let overflow: CGFloat
    let rowSpacing: CGFloat

    init(family: WidgetFamily) {
        // One scale for both home-screen families, deliberately. Small and
        // medium are the same 155pt height and sit on the same wall of icons —
        // a tile that draws its rows larger than the tile beside it reads as a
        // different app, not as a different size. Small differs in width only,
        // which costs it characters, not points.
        //
        // 14 is the ceiling rather than a preference: at 16 the header lost its
        // top half and the "+N more" line was cut off entirely. Checked on the
        // simulator at six to-dos, which is the worst case — every row *and*
        // the overflow line.
        heading = 12; count = 19; title = 14; circle = 16; overflow = 11; rowSpacing = 6
    }
}

/// A title that ends on a whole word instead of trailing off into an ellipsis.
///
/// `.truncationMode(.tail)` draws "Renew the gym membership befor…" — it spends
/// its last three characters saying "there is more", which the "+N more" line
/// already says, and it breaks mid-word so the fragment reads as damage rather
/// than as a name. Cut at the last word that fits, "work on english exam"
/// becomes "work on english": shorter, but every word of it is a real word.
///
/// The width is measured rather than assumed. The same widget is one width on
/// an SE and another on a Pro Max, so a per-family constant would cut correctly
/// on exactly one device.
private struct WordClippedTitle: View {
    let title: String
    let size: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Text(verbatim: Self.clipped(title, toWidth: proxy.size.width, size: size))
                .font(.system(size: size))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        // GeometryReader would otherwise take the whole tile: one line is all
        // this ever draws, so it is given exactly one line's height.
        .frame(height: ceil(UIFont.systemFont(ofSize: size).lineHeight))
        // VoiceOver still hears the whole to-do. What was cut is a fact about
        // the width of the screen, not about the item.
        .accessibilityLabel(Text(verbatim: title))
    }

    /// The longest run of whole words that fits — or, for a single word wider
    /// than the row, as much of that word as fits. Never an ellipsis.
    static func clipped(_ title: String, toWidth width: CGFloat, size: CGFloat) -> String {
        guard width > 0 else { return title }
        let font = UIFont.systemFont(ofSize: size)
        func fits(_ candidate: String) -> Bool {
            (candidate as NSString).size(withAttributes: [.font: font]).width <= width
        }
        guard !fits(title) else { return title }

        var words = title.split(separator: " ")
        while words.count > 1 {
            words.removeLast()
            let candidate = words.joined(separator: " ")
            if fits(candidate) { return candidate }
        }

        // A single word wider than the row — a URL, or German. Trim characters
        // rather than draw an empty line; still no ellipsis.
        var single = title
        while !single.isEmpty, !fits(single) { single.removeLast() }
        return single
    }
}

/// One to-do, with a circle that actually completes it.
private struct TodoWidgetRow: View {
    let row: TodoRowSnapshot
    let metrics: WidgetMetrics

    var body: some View {
        HStack(spacing: 8) {
            // The interactive part. A Button carrying an AppIntent is the only
            // way a widget can act without opening the app, and iOS gives it
            // the tap feedback and the accessibility treatment for free.
            Button(intent: CompleteTodoIntent(todoID: row.id)) {
                Image(systemName: "circle")
                    .font(.system(size: metrics.circle, weight: .medium))
                    .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Complete \(row.title)"))

            // A *sibling* of the circle, never a parent of it: a widget can't
            // nest interactive controls, and wrapping the whole row in an open
            // button would swallow the taps that are the point of this widget.
            // Tapping the words opens the app; tapping the circle completes.
            Button(intent: OpenRoutlyIntent(.today)) {
                HStack(spacing: 0) {
                    // Clipped, never shrunk: a long to-do keeps the row on the
                    // same baseline as its neighbours and loses whole words off
                    // the end rather than shrinking to fit.
                    WordClippedTitle(title: row.title, size: metrics.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The wide lock-screen accessory: the top two to-dos, each tickable.
///
/// Modelled on the shape Reminders uses in this slot — a stack of rows with a
/// circle at the leading edge — because that is what people already read as "my
/// list" on a lock screen, and it puts the two things that matter *and* the
/// gesture to finish them directly on the wallpaper. This is the surface the
/// product brief calls the north star, so it earns the wider family rather than
/// making do with a count.
///
/// No heading. The rectangle is about 160×72pt and a title line spends it far
/// better than a label repeating what the icon already says.
///
/// Rendering here is vibrant or tinted, never full colour, so nothing leans on
/// hue: the circle is a stroked glyph and the text carries itself.
private struct RectangularTodoAccessory: View {
    let snapshot: TodosSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if snapshot.isEmpty {
                Text(snapshot.emptyMessage)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text("Nothing left today.")
                    .font(.system(size: 13))
                    .lineLimit(1)
            } else {
                ForEach(snapshot.rows) { row in
                    HStack(spacing: 6) {
                        // Interactive here, unlike the circular accessory: a
                        // full-width row gives the circle a real tap target,
                        // which is the whole reason this family is worth having.
                        Button(intent: CompleteTodoIntent(todoID: row.id)) {
                            Image(systemName: "circle")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Complete \(row.title)"))

                        // Read at arm's length on a lit screen, without
                        // unlocking — so this is the one family that earns type
                        // larger than the app's own rows. Two lines of 16pt is
                        // what the 72pt rectangle holds; a third row would be
                        // the trade, and two is what Reminders shows here too.
                        WordClippedTitle(title: row.title, size: 14)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetAccentable()
    }
}

/// The lock-screen accessory: how many are left, and nothing else.
///
/// Tinted and monochrome rendering strip colour entirely, so this leans on the
/// glyph and the number rather than on the accent to carry meaning.
private struct RemainingCountAccessory: View {
    let remaining: Int

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                Text(remaining, format: .number)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
        }
        .widgetAccentable()
        .accessibilityLabel(Text("\(remaining) to-dos left"))
    }
}

// MARK: - Widget

struct TodosWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "RoutlyTodos",
            intent: SelectTodoListIntent.self,
            provider: TodosProvider()
        ) { entry in
            TodosWidgetView(entry: entry)
        }
        .configurationDisplayName("To-dos")
        .description("Your open to-dos, with a tap to tick them off. Long-press to pick a list.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Sample data

extension TodosSnapshot {
    /// Used for the placeholder and the gallery. Plausible, short, and not the
    /// same three words in every language — these go through the catalog.
    static var placeholder: TodosSnapshot { placeholder(limit: 3) }

    /// The sample, trimmed the way a real snapshot would be for that family.
    ///
    /// `remaining` stays at 5 regardless, because the overflow line ("+2 more")
    /// is part of what the gallery should be showing off.
    static func placeholder(limit: Int) -> TodosSnapshot {
        let rows = [
            TodoRowSnapshot(id: UUID(), title: String(localized: "Call the dentist"),
                            category: .personal, isRoutine: false),
            TodoRowSnapshot(id: UUID(), title: String(localized: "Finish the report"),
                            category: .work, isRoutine: false),
            TodoRowSnapshot(id: UUID(), title: String(localized: "Water the plants"),
                            category: .personal, isRoutine: true),
        ]
        return TodosSnapshot(
            groupName: String(localized: "To-dos"),
            rows: Array(rows.prefix(max(0, limit))),
            remaining: 5
        )
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    TodosWidget()
} timeline: {
    TodosEntry(date: .now, snapshot: .placeholder, locale: nil)
    TodosEntry(date: .now, snapshot: TodosSnapshot(groupName: "To-dos", rows: [], remaining: 0), locale: nil)
}

#Preview("Medium", as: .systemMedium) {
    TodosWidget()
} timeline: {
    TodosEntry(date: .now, snapshot: .placeholder, locale: nil)
}

#Preview("Circular", as: .accessoryCircular) {
    TodosWidget()
} timeline: {
    TodosEntry(date: .now, snapshot: .placeholder, locale: nil)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    TodosWidget()
} timeline: {
    TodosEntry(date: .now, snapshot: .placeholder(limit: 2), locale: nil)
    TodosEntry(date: .now, snapshot: TodosSnapshot(groupName: "To-dos", rows: [], remaining: 0), locale: nil)
}
