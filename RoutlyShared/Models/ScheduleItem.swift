//
//  ScheduleItem.swift
//  RoutineOrganizer
//
//  The single unified model for both one-off tasks and recurring routines.
//  A nil `recurrence` means a one-off task; a non-nil rule makes it a routine.
//  Per-occurrence history lives in the related `Completion` records, which
//  feed the Phase 4/5 streak, dot-grid, and pattern-memory features.
//

import Foundation
import SwiftData

@Model
final class ScheduleItem {
    var id: UUID
    var title: String
    var notes: String?

    /// Event / Reminder / To-do. Defaulted so the existing store migrates
    /// lightweight; every code path sets it explicitly.
    var kind: ItemKind = ItemKind.todo

    /// The day this item is anchored to. Optional because messy capture may
    /// not specify one; such items surface as "unscheduled".
    var scheduledDate: Date?

    /// The time-of-day component, when known.
    var startTime: Date?

    var durationMinutes: Int?

    /// Roughly how long the work itself takes, in minutes — distinct from
    /// `durationMinutes`, which is how long a *placed block* runs. Effort is a
    /// property of the task ("the report is a 2-hour job"); duration is a
    /// property of where it landed. The day planner reads this to fit a to-do to
    /// a gap; accepting a recommendation copies it into `durationMinutes` so the
    /// placed block genuinely occupies that time.
    ///
    /// nil means the user never said and nothing has guessed yet — the planner
    /// estimates on the fly rather than writing a guess back here, so a stated
    /// value is always the user's own. Defaulted for lightweight migration.
    var effortMinutes: Int? = nil

    /// When this needs to be done by. Kept separate from `scheduledDate` because
    /// that field doubles as "the day it's parked on", and the planner rewrites
    /// it when a to-do is slotted — a deadline has to survive being scheduled.
    /// nil falls back to `scheduledDate` (see `effectiveDue`), so every item
    /// created before this field existed keeps its old meaning.
    var dueDate: Date? = nil

    /// How many minutes before `startTime` to notify. nil = at the start time.
    /// Defaulted so the existing store migrates lightweight.
    var reminderLeadMinutes: Int? = nil

    // MARK: - To-do attributes
    //
    // Stored as optional raw strings, read through non-optional accessors.
    //
    // This shape is not decoration. A `var priority: Priority = .medium` looks
    // like it migrates lightweight and does not: the Swift default applies only
    // to newly *constructed* objects, while a row that predates the column
    // decodes NULL, and SwiftData traps on NULL for a non-optional keypath
    // ("Passed nil for a non-optional keypath"). The app dies at launch, before
    // any recovery code can run, because the trap is inside the decoder.
    //
    // An optional primitive is the only thing that reliably survives that: NULL
    // decodes as nil, and the accessor supplies the default. Raw `String?`
    // rather than `Priority?` keeps it a primitive column, away from the
    // Codable-enum materialisation that the "Could not materialize Objective-C
    // class" faults come from.

    /// Backing store. Never read directly — use `priority`. Left internal rather
    /// than private so a test can null it out and prove the accessor still
    /// defaults, which is the exact case a migrating row hits.
    var priorityRawValue: String?

    /// Backing store. Never read directly — use `todoScope`.
    var todoScopeRawValue: String?

    /// Where this to-do sits when the user has arranged them by hand.
    ///
    /// nil means "never dragged" — the automatic order still applies. Optional
    /// rather than defaulting to 0, because 0 is a real position and a column of
    /// zeroes is indistinguishable from everyone having been dragged to the top.
    /// An optional primitive is also the only shape that migrates lightweight
    /// (see the long note above).
    var todoSortIndex: Int? = nil

    /// How much this matters. Only meaningful for to-dos — an event happens when
    /// it happens, whatever you think of it. `.medium` is explicitly "nobody
    /// said", and is what every pre-existing row reads as.
    var priority: Priority {
        get { priorityRawValue.flatMap(Priority.init(rawValue:)) ?? .unset }
        set { priorityRawValue = newValue.rawValue }
    }

    /// Today's work versus the long game. Again a to-do notion: it's what stops
    /// the rolling checklist treating "learn to sail" as overdue every morning.
    var todoScope: TodoScope {
        get { todoScopeRawValue.flatMap(TodoScope.init(rawValue:)) ?? .unset }
        set { todoScopeRawValue = newValue.rawValue }
    }

    /// Stored as the enum's raw value by SwiftData.
    var category: Category

    /// nil = one-off task, non-nil = recurring routine.
    var recurrence: RecurrenceRule?

    /// The last day a routine runs, inclusive. nil = open-ended, which is how
    /// every routine starts. Set when the user deletes "this and all future" —
    /// the past stays intact (and so do its completions and streaks) while the
    /// series stops overflowing into every day ahead. Defaulted for lightweight
    /// migration.
    var recurrenceEndDate: Date? = nil

    /// Individual days lifted out of the series — "delete just this one". Stored
    /// as start-of-day. Kept as exceptions rather than materialised occurrences
    /// so a routine stays a single row; a handful of skips is far cheaper than
    /// expanding an open-ended rule into rows on disk.
    var skippedDates: [Date] = []

    /// Single completion state for a one-off item. Recurring items track
    /// completion per-occurrence via `completions` instead.
    var isCompleted: Bool

    var createdAt: Date

    /// The raw text the user captured — provenance for the trust layer.
    var sourceText: String?

    @Relationship(deleteRule: .cascade, inverse: \Completion.item)
    var completions: [Completion]

    /// The list this to-do belongs to, if any.
    ///
    /// Optional, and defaulted, so an existing store migrates lightweight: a row
    /// that predates the column decodes NULL, which is a legitimate value here
    /// rather than a trap (see the long note above about non-optional
    /// properties). "No list" is a real state, not a missing one — most to-dos
    /// never get filed anywhere and shouldn't have to be.
    ///
    /// The inverse and the nullify delete rule live on `TodoList.items`.
    var list: TodoList? = nil

    /// Where this item also lives, outside Routly.
    ///
    /// To-many rather than a triple of columns, because an item can go to Apple
    /// *and* Google at once and a single (provider, calendar, external id) can
    /// only hold one of them. See `CalendarLink` for the shape and for the
    /// at-most-one-per-provider invariant.
    ///
    /// Cascade: the links describe *this* item's presence in a calendar, so
    /// they have no meaning once it's gone. Taking the remote events out is a
    /// separate step that has to happen **before** the delete, while the links
    /// are still readable — see `CalendarSync.pendingRemovals(for:)`.
    ///
    /// Defaulted to `[]` so the property is additive: a store that predates the
    /// entity opens with every item simply having no links.
    @Relationship(deleteRule: .cascade, inverse: \CalendarLink.item)
    var calendarLinks: [CalendarLink] = []

    // MARK: - Sync groundwork
    //
    // These four fields exist so that adding cloud sync later is a new *layer*
    // rather than another schema migration over live user data. Nothing in the
    // app reads them yet beyond the ownership backfill; they are deliberately
    // all defaulted so the existing store migrates lightweight.

    /// Who this row belongs to: the device's local guest id while signed out,
    /// rewritten to the account id when someone signs in (see `DataOwnership`).
    /// nil means a row created before this field existed — backfilled at launch.
    var ownerID: String? = nil

    /// Last local mutation, stamped in `ScheduleViewModel.save()`. The merge
    /// clock for the future sync layer. `.distantPast` marks a row that predates
    /// the field; the launch backfill rewrites those to `createdAt`.
    var updatedAt: Date = Date.distantPast

    /// Last confirmed push to the server. nil, or older than `updatedAt`, means
    /// the row is dirty. Always nil until the sync layer ships.
    var syncedAt: Date? = nil

    /// Tombstone. Deletes stay hard-deletes for now — flipping them to soft
    /// deletes is the sync phase's job, and doing it early would change delete
    /// behaviour for no present benefit. The column exists now purely so that
    /// change needs no second migration.
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        title: String,
        kind: ItemKind = .todo,
        notes: String? = nil,
        scheduledDate: Date? = nil,
        startTime: Date? = nil,
        durationMinutes: Int? = nil,
        effortMinutes: Int? = nil,
        dueDate: Date? = nil,
        reminderLeadMinutes: Int? = nil,
        priority: Priority = .medium,
        todoScope: TodoScope = .today,
        category: Category = .personal,
        recurrence: RecurrenceRule? = nil,
        recurrenceEndDate: Date? = nil,
        skippedDates: [Date] = [],
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        sourceText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.notes = notes
        self.scheduledDate = scheduledDate
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.effortMinutes = effortMinutes
        self.dueDate = dueDate
        self.reminderLeadMinutes = reminderLeadMinutes
        self.priorityRawValue = priority.rawValue
        self.todoScopeRawValue = todoScope.rawValue
        self.category = category
        self.recurrence = recurrence
        self.recurrenceEndDate = recurrenceEndDate
        self.skippedDates = skippedDates
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.completions = []
    }

    /// True when this item repeats (has a recurrence rule).
    var isRoutine: Bool { recurrence != nil }

    /// The first day this routine can run — an explicit day if it has one, else
    /// the day it was captured. Nothing occurs before it.
    func recurrenceAnchor(_ calendar: Calendar) -> Date {
        calendar.startOfDay(for: scheduledDate ?? createdAt)
    }

    /// True when this specific day was lifted out of the series.
    func skips(_ day: Date, calendar: Calendar) -> Bool {
        skippedDates.contains { calendar.isDate($0, inSameDayAs: day) }
    }

    /// Lift one day out of the series. Idempotent.
    func skipOccurrence(on day: Date, calendar: Calendar) {
        let dayStart = calendar.startOfDay(for: day)
        guard !skips(dayStart, calendar: calendar) else { return }
        skippedDates.append(dayStart)
    }

    /// Stop the routine repeating from `day` onward, keeping everything before
    /// it. Returns false when that would leave no occurrences at all — the
    /// caller should delete the item outright rather than keep an empty husk.
    @discardableResult
    func endRecurrence(from day: Date, calendar: Calendar) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        guard let lastDay = calendar.date(byAdding: .day, value: -1, to: dayStart),
              lastDay >= recurrenceAnchor(calendar) else { return false }
        // Never push an existing end later — trimming only ever shortens.
        if let current = recurrenceEndDate, calendar.startOfDay(for: current) <= lastDay { return true }
        recurrenceEndDate = lastDay
        skippedDates.removeAll { calendar.startOfDay(for: $0) > lastDay }
        return true
    }

    /// The deadline to plan against. Items predating `dueDate` fall back to the
    /// day they were filed under, which is what that field meant for them.
    var effectiveDue: Date? { dueDate ?? scheduledDate }

    /// True once a to-do has been given a real slot in the day, rather than
    /// just a day to sit on. Such a to-do belongs on the timeline, not in the
    /// loose checklist.
    var isSlotted: Bool { kind == .todo && startTime != nil }
}
