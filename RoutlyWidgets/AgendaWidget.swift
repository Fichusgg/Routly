//
//  AgendaWidget.swift
//  RoutineOrganizerWidgets
//
//  Today's timed items — the same content as the schedule box on Today.
//
//  Read-only by design. The schedule is a thing you consult, not a thing you
//  tick off: an event happens when it happens, and the completion this app cares
//  about lives on the to-do list. Adding checkboxes here would offer an action
//  whose meaning nobody could state.
//
//  Medium and large only. Small was dropped on purpose — a time and a title in a
//  155pt square leaves room for neither, and the honest version of this widget
//  at that size is just the next event, which is a different widget.
//

import AppIntents
import SwiftUI
import WidgetKit

struct AgendaEntry: TimelineEntry {
    let date: Date
    let snapshot: AgendaSnapshot
    let locale: Locale?
}

struct AgendaProvider: TimelineProvider {

    static func rowLimit(for family: WidgetFamily) -> Int {
        switch family {
        case .systemMedium: return 4
        default: return 8
        }
    }

    func placeholder(in context: Context) -> AgendaEntry {
        AgendaEntry(date: Date(), snapshot: .placeholder, locale: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgendaEntry) -> Void) {
        guard !context.isPreview else {
            completion(AgendaEntry(date: Date(), snapshot: .placeholder, locale: nil))
            return
        }
        completion(read(for: context.family))
    }

    /// Entries at the day's own turning points.
    ///
    /// One entry per remaining event boundary, plus midnight, rather than a
    /// fixed cadence — see `WidgetSnapshotBuilder.refreshDates`. Each entry
    /// re-renders the *same* snapshot at a later time, which is what lets the
    /// view mark what's already passed without another read of the store.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AgendaEntry>) -> Void) {
        let reading = WidgetStore.read()
        let builder = WidgetSnapshotBuilder()
        let snapshot = builder.agenda(from: reading.items, limit: Self.rowLimit(for: context.family))
        let locale = reading.settings.appLanguage.explicitLocale

        var entries = [AgendaEntry(date: Date(), snapshot: snapshot, locale: locale)]
        for date in builder.refreshDates(from: reading.items) {
            entries.append(AgendaEntry(date: date, snapshot: snapshot, locale: locale))
        }

        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func read(for family: WidgetFamily) -> AgendaEntry {
        let reading = WidgetStore.read()
        return AgendaEntry(
            date: Date(),
            snapshot: WidgetSnapshotBuilder().agenda(from: reading.items, limit: Self.rowLimit(for: family)),
            locale: reading.settings.appLanguage.explicitLocale
        )
    }
}

// MARK: - Views

struct AgendaWidgetView: View {
    let entry: AgendaEntry

    var body: some View {
        Button(intent: OpenRoutlyIntent(.today)) {
            VStack(alignment: .leading, spacing: 6) {
                header

                if entry.snapshot.isEmpty {
                    emptyState
                } else {
                    ForEach(entry.snapshot.rows) { row in
                        AgendaWidgetRow(row: row, now: entry.date)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .containerBackground(Theme.Colors.background, for: .widget)
        .environment(\.locale, entry.locale ?? .autoupdatingCurrent)
    }

    private var header: some View {
        Text("Today’s schedule")
            .font(.caption)
            .fontWeight(.semibold)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Colors.textSecondary)
            .lineLimit(1)
    }

    /// A free day is worth saying warmly rather than reporting as a null result.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("A clear day")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Nothing scheduled.")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .padding(.top, 2)
    }
}

private struct AgendaWidgetRow: View {
    let row: AgendaRowSnapshot
    /// The entry's own time, not `Date()`. A timeline entry rendered at 3pm must
    /// look like 3pm even though it was built at breakfast.
    let now: Date

    /// Past and done both read as spent — dimmed, so what's still ahead is what
    /// the eye lands on.
    private var isSpent: Bool {
        row.isDone || (row.start.map { $0 < now } ?? false)
    }

    var body: some View {
        HStack(spacing: 8) {
            // The category tag, as a small bar. Colour is never the only signal
            // — the time and title carry the row on their own — because these go
            // monochrome under some rendering modes.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.Colors.category(row.category))
                .frame(width: 3, height: 16)
                .opacity(isSpent ? 0.4 : 1)

            Text(timeText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: 44, alignment: .leading)

            Text(row.title)
                .font(.footnote)
                .foregroundStyle(isSpent ? Theme.Colors.textFaint : Theme.Colors.textPrimary)
                .strikethrough(row.isDone, color: Theme.Colors.textFaint)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .opacity(isSpent ? 0.65 : 1)
    }

    private var timeText: String {
        guard let start = row.start else { return String(localized: "All day") }
        return start.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Widget

struct AgendaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RoutlyAgenda", provider: AgendaProvider()) { entry in
            AgendaWidgetView(entry: entry)
        }
        .configurationDisplayName("Today’s agenda")
        .description("What’s scheduled for today, in order.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Sample data

extension AgendaSnapshot {
    static var placeholder: AgendaSnapshot {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: day) ?? day
        }
        return AgendaSnapshot(day: day, rows: [
            AgendaRowSnapshot(id: UUID(), title: String(localized: "Team stand-up"),
                              start: at(9, 30), category: .work, isDone: false),
            AgendaRowSnapshot(id: UUID(), title: String(localized: "Dentist"),
                              start: at(13), category: .health, isDone: false),
            AgendaRowSnapshot(id: UUID(), title: String(localized: "Pick up the kids"),
                              start: at(16, 15), category: .personal, isDone: false),
        ])
    }
}

// MARK: - Previews

#Preview("Medium", as: .systemMedium) {
    AgendaWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .placeholder, locale: nil)
}

#Preview("Large", as: .systemLarge) {
    AgendaWidget()
} timeline: {
    AgendaEntry(date: .now, snapshot: .placeholder, locale: nil)
    AgendaEntry(date: .now, snapshot: AgendaSnapshot(day: .now, rows: []), locale: nil)
}
