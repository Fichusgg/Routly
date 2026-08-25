//
//  WidgetSnapshot.swift
//  RoutineOrganizerShared
//
//  What a widget draws, as plain values.
//
//  The widget deliberately does not hand `ScheduleItem` objects to its views.
//  Two reasons, and both have bitten this app before:
//
//   • Reading a stored property of a deleted SwiftData model is a fault that
//     kills the process, not an error anything can catch (see the note on
//     `ScheduleViewModel.deletedIDs`). A timeline entry can outlive the fetch
//     that produced it by minutes, so holding live models in one is exactly the
//     shape of that bug with a longer fuse.
//   • `TimelineEntry` values get archived and handed back later. Plain
//     `Sendable` structs survive that; managed objects do not.
//
//  So the store is read once, flattened into these, and the models are dropped.
//

import Foundation

// MARK: - To-dos

/// One row of the to-do widget.
struct TodoRowSnapshot: Identifiable, Hashable, Sendable {
    /// `ScheduleItem.id`, not the persistent id — this is what the completion
    /// intent carries back across the process boundary, and a `UUID` the app
    /// itself assigned is stable in a way `PersistentIdentifier` is not.
    let id: UUID
    let title: String
    let category: Category
    /// Routines get their occurrence completed rather than the item flagged, so
    /// the intent needs to know which it's dealing with. Also earns a small
    /// glyph in the row.
    let isRoutine: Bool
}

struct TodosSnapshot: Sendable {
    /// The heading: the chosen list's name, or whatever the user calls their
    /// main group — "To-dos" out of the box.
    let groupName: String
    /// The rows that fit this widget family.
    let rows: [TodoRowSnapshot]
    /// How many are open in total, which is **not** `rows.count`: the corner
    /// count has to tell the truth about a list longer than the widget can show.
    let remaining: Int
    /// False when the widget was configured for a list that no longer exists.
    ///
    /// Kept distinct from "empty" because the two deserve different words. A
    /// deleted list showing "All clear" would congratulate someone for finishing
    /// work that simply isn't there any more.
    let listExists: Bool
    /// True when showing the built-in group rather than a named list — the empty
    /// state reads differently for each.
    let isDefaultGroup: Bool

    init(
        groupName: String,
        rows: [TodoRowSnapshot],
        remaining: Int,
        listExists: Bool = true,
        isDefaultGroup: Bool = true
    ) {
        self.groupName = groupName
        self.rows = rows
        self.remaining = remaining
        self.listExists = listExists
        self.isDefaultGroup = isDefaultGroup
    }

    var isEmpty: Bool { remaining == 0 }

    /// How many are open but not shown. Drives the "+3 more" line.
    var overflow: Int { max(0, remaining - rows.count) }
}

// MARK: - Agenda

struct AgendaRowSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    /// nil for an all-day or untimed item, which sorts first and shows no time.
    let start: Date?
    let category: Category
    let isDone: Bool
}

struct AgendaSnapshot: Sendable {
    let day: Date
    let rows: [AgendaRowSnapshot]

    var isEmpty: Bool { rows.isEmpty }
}

// MARK: - Building

/// Turns stored items into the values above.
///
/// Every rule it applies is `TodaySelection`'s, so the widget shows the same
/// things in the same order as the Today screen. This type's own job is only
/// flattening and capping.
struct WidgetSnapshotBuilder {

    let selection: TodaySelection
    let calendar: Calendar

    init(selection: TodaySelection = TodaySelection()) {
        self.selection = selection
        self.calendar = selection.calendar
    }

    /// The to-dos widget's contents, for whichever list it was configured with.
    ///
    /// `limit` caps the rows, never the count — see `TodosSnapshot.remaining`.
    ///
    /// `listID` nil means the built-in group. A non-nil id that matches no list
    /// is reported rather than silently falling back to the group: the widget
    /// would otherwise change what it means without saying so, which is the kind
    /// of thing someone only notices after acting on the wrong list.
    func todos(
        from items: [ScheduleItem],
        listID: UUID? = nil,
        knownListIDs: Set<UUID> = [],
        groupName: String,
        limit: Int,
        now: Date = Date()
    ) -> TodosSnapshot {
        // Checked against the lists themselves, not against the items in them.
        // A real but empty list has no items, and inferring existence from
        // contents would report every emptied list as deleted.
        let exists = listID.map(knownListIDs.contains) ?? true
        let open = selection.todos(from: items, inList: listID, now: now)
        let rows = open.prefix(max(0, limit)).map { item in
            TodoRowSnapshot(
                id: item.id,
                title: item.title,
                category: item.category,
                isRoutine: item.isRoutine
            )
        }
        return TodosSnapshot(
            groupName: groupName,
            rows: Array(rows),
            remaining: open.count,
            listExists: exists,
            isDefaultGroup: listID == nil
        )
    }

    /// The agenda widget's contents: one day's timed items in time order.
    func agenda(
        from items: [ScheduleItem],
        limit: Int,
        on day: Date = Date()
    ) -> AgendaSnapshot {
        let writer = CompletionWriter(calendar: calendar)
        let dayStart = calendar.startOfDay(for: day)
        let rows = selection.timed(from: items, on: day)
            .prefix(max(0, limit))
            .map { item in
                AgendaRowSnapshot(
                    id: item.id,
                    title: item.title,
                    start: item.startTime,
                    category: item.category,
                    isDone: writer.isDone(item, on: dayStart)
                )
            }
        return AgendaSnapshot(day: dayStart, rows: Array(rows))
    }

    // MARK: - Refresh timing

    /// When the widget should next redraw.
    ///
    /// Built from the day's own shape rather than a fixed interval: the moments
    /// a schedule widget becomes wrong are when an event starts, when it ends,
    /// and when the day rolls over. Ticking every fifteen minutes would spend
    /// the refresh budget being right slightly sooner on the boundaries that
    /// matter and redrawing identical pixels the rest of the time.
    ///
    /// Times already past are dropped, the list is capped, and midnight is
    /// always included so an empty evening still becomes tomorrow's agenda.
    func refreshDates(
        from items: [ScheduleItem],
        now: Date = Date(),
        limit: Int = 12
    ) -> [Date] {
        var dates: Set<Date> = []

        for item in selection.timed(from: items, on: now) {
            if let start = item.startTime, start > now {
                dates.insert(start)
                if let minutes = item.durationMinutes,
                   let end = calendar.date(byAdding: .minute, value: minutes, to: start),
                   end > now {
                    dates.insert(end)
                }
            }
        }

        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            dates.insert(midnight)
        }

        return Array(dates.sorted().prefix(limit))
    }
}
