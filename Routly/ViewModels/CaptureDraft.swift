//
//  CaptureDraft.swift
//  RoutineOrganizer
//
//  The editable bridge between a ParsedCapture and a saved ScheduleItem. The
//  confirm sheet binds to this so a wrong guess from the parser is fixable
//  before anything is persisted — capture is never silently structured wrong.
//

import Foundation

@Observable
final class CaptureDraft: Identifiable {
    let id = UUID()
    var title: String
    var kind: ItemKind
    var category: Category

    var hasDate: Bool
    var date: Date

    var hasTime: Bool
    var time: Date

    /// End time for events. Duration is derived from `time`…`endTime` rather than
    /// typed directly — you set when it starts and when it ends, and the length
    /// falls out of that. Only meaningful for events with a time.
    var endTime: Date

    /// Retained parser hint / legacy field. No longer user-edited: for a timed
    /// event the effective duration comes from `time`…`endTime`.
    var hasDuration: Bool
    var durationMinutes: Int

    /// Roughly how long a to-do will take. Optional on purpose — nil means the
    /// user skipped it, and the planner estimates instead. Making this required
    /// would tax every capture to serve one screen.
    var effortMinutes: Int?

    /// How far before the start time to be notified, in minutes. 0 = at the
    /// start time. The picker offers `ReminderLead.options`.
    ///
    /// A fresh draft opens on the user's default (Settings → Reminders & voice);
    /// a draft made from an existing item keeps that item's own lead, so
    /// changing the default never re-times a reminder already set.
    var reminderLeadMinutes: Int

    /// The list the parser thinks this to-do belongs under, by name, before
    /// anything has looked it up.
    ///
    /// Separate from `list` on purpose. `list` is a real `TodoList` and is what
    /// gets saved; this is a guess that may match nothing — the list could have
    /// been renamed, or the model could have returned a name that was never
    /// offered. Whoever has the lists queried resolves one into the other, and a
    /// miss simply leaves the to-do unfiled.
    var suggestedListName: String?

    /// To-do only: how much it matters, and whether it's for today or someday.
    /// Both always carry a value — there's no "unset" state to render, just a
    /// default nobody has changed.
    var priority: Priority
    var todoScope: TodoScope
    /// The list this to-do is filed under, if any. A reference rather than a
    /// name: renaming the list must not orphan the draft.
    var list: TodoList?

    /// Which calendars this one item goes to.
    ///
    /// Not a chooser. It starts from the answer already given in Settings —
    /// every connected calendar that is switched on — so the ordinary capture
    /// needs no thought and no tap. It exists for the exception: the one event
    /// you would rather your calendar didn't have. That is why it lives folded
    /// away under "More" rather than in front of every capture.
    ///
    /// For an edit it starts from where the item actually *is*, not from the
    /// setting. An old item that predates the calendar being switched on stays
    /// out of it unless someone says otherwise here — the same rule
    /// `CalendarSync.currentDestinations(of:)` keeps.
    var calendarTargets: Set<CalendarProvider>

    /// What `calendarTargets` was when the sheet opened, so the collapsed
    /// summary can say when it has been deliberately changed — and say nothing
    /// when it hasn't. Without it, every capture's summary would echo a default
    /// back at the person who never touched it.
    let initialCalendarTargets: Set<CalendarProvider>

    /// Present when the parser detected a routine. `keepRecurrence` lets the
    /// user demote it to a one-off without losing what was detected.
    var recurrence: RecurrenceRule?
    var keepRecurrence: Bool

    let sourceText: String

    /// Existing item when editing; nil when confirming a fresh capture.
    let editingItem: ScheduleItem?

    private let calendar = Calendar(identifier: .gregorian)

    /// A fresh, empty draft for a kind the user just tapped (Event/Reminder/To-do).
    /// Dated kinds default to today so the form opens ready to save.
    ///
    /// `defaultLeadMinutes` is passed in rather than read from `AppSettings`
    /// here: that singleton is main-actor isolated and this initializer is not,
    /// which is a warning today and an error under Swift 6. Every caller that
    /// has a user is already on the main actor and hands the real default in;
    /// the zero default keeps tests and previews free of the dependency.
    init(
        kind: ItemKind,
        now: Date = Date(),
        defaultLeadMinutes: Int = 0,
        defaultCalendarTargets: Set<CalendarProvider> = []
    ) {
        let cal = Calendar(identifier: .gregorian)
        title = ""
        self.kind = kind
        category = .personal
        hasDate = kind.requiresDate
        date = cal.startOfDay(for: now)
        hasTime = false
        time = now
        endTime = cal.date(byAdding: .hour, value: 1, to: now) ?? now
        hasDuration = false
        durationMinutes = 30
        effortMinutes = nil
        reminderLeadMinutes = defaultLeadMinutes
        priority = .medium
        todoScope = .today
        recurrence = nil
        keepRecurrence = false
        sourceText = ""
        calendarTargets = defaultCalendarTargets
        initialCalendarTargets = defaultCalendarTargets
        editingItem = nil
    }

    init(
        parsed: ParsedCapture,
        kind: ItemKind,
        now: Date = Date(),
        defaultLeadMinutes: Int = 0,
        defaultCalendarTargets: Set<CalendarProvider> = []
    ) {
        let cal = Calendar(identifier: .gregorian)
        title = parsed.title
        self.kind = kind
        category = parsed.category
        hasDate = parsed.scheduledDate != nil || kind.requiresDate
        date = parsed.scheduledDate ?? cal.startOfDay(for: now)
        hasTime = kind.usesTime && parsed.startTime != nil
        let start = parsed.startTime ?? now
        time = start
        endTime = cal.date(byAdding: .minute, value: parsed.durationMinutes ?? 60, to: start) ?? start
        hasDuration = kind.usesDuration && parsed.durationMinutes != nil
        durationMinutes = parsed.durationMinutes ?? 30
        // "finish the report, probably two hours" — the parser already heard the
        // size, so the estimate arrives filled in and nobody had to be asked.
        effortMinutes = parsed.effortMinutes ?? (kind == .todo ? parsed.durationMinutes : nil)
        reminderLeadMinutes = defaultLeadMinutes
        priority = .medium
        // A to-do the user gave no deadline to is the definition of "someday";
        // one with a date is on the hook. Better than defaulting everything to
        // today and making the long-term bucket a thing you must remember.
        // Always today's work. This used to file an undated to-do as
        // long-term, on the theory that no date meant no urgency — but most
        // to-dos are captured without a date precisely because they're for now,
        // and landing them under "Long-term" meant every quick capture had to be
        // moved before it counted.
        todoScope = .today
        list = nil
        // Carried, not resolved: this initializer has no access to the store.
        suggestedListName = parsed.listName
        recurrence = parsed.recurrence
        keepRecurrence = parsed.recurrence != nil
        sourceText = parsed.sourceText
        calendarTargets = defaultCalendarTargets
        initialCalendarTargets = defaultCalendarTargets
        editingItem = nil
    }

    init(item: ScheduleItem, now: Date = Date()) {
        let cal = Calendar(identifier: .gregorian)
        title = item.title
        kind = item.kind
        category = item.category
        hasDate = item.scheduledDate != nil
        date = item.scheduledDate ?? cal.startOfDay(for: now)
        hasTime = item.startTime != nil
        let start = item.startTime ?? now
        time = start
        endTime = cal.date(byAdding: .minute, value: item.durationMinutes ?? 60, to: start) ?? start
        hasDuration = item.durationMinutes != nil
        durationMinutes = item.durationMinutes ?? 30
        effortMinutes = item.effortMinutes
        reminderLeadMinutes = item.reminderLeadMinutes ?? 0
        priority = item.priority
        todoScope = item.todoScope
        list = item.list
        recurrence = item.recurrence
        keepRecurrence = item.recurrence != nil
        sourceText = item.sourceText ?? item.title
        // Where the item *is*, not where the setting says new ones go. Editing
        // an old event must not quietly push it somewhere it has never been.
        // Links whose last push failed are included: the person asked for it
        // and didn't get it, so re-saving should retry rather than give up.
        let linked = Set(item.calendarLinks.compactMap(\.provider))
        calendarTargets = linked
        initialCalendarTargets = linked
        editingItem = item
    }

    // MARK: - Calendars

    /// The targets that should actually be written to. An ineligible draft
    /// wants none, whatever the toggles say — and the toggles keep their state
    /// rather than being cleared, so switching a to-do back to an event
    /// restores the answer instead of making the person give it again.
    var effectiveCalendarTargets: Set<CalendarProvider> {
        calendarEligibility.isEligible ? calendarTargets : []
    }

    /// True when the person has deliberately changed where this one item goes.
    var hasChangedCalendarTargets: Bool {
        calendarTargets != initialCalendarTargets
    }

    /// Whether this draft is something a calendar can hold, and if not, why.
    /// The sheet reads it to dim the chips; the push path asks the same
    /// question of the saved item, so the two can't disagree.
    var calendarEligibility: CalendarEligibility {
        CalendarEligibilityCheck.evaluate(
            kind: kind,
            hasDate: hasDate,
            isRepeating: effectiveRecurrence != nil
        )
    }



    var effectiveRecurrence: RecurrenceRule? {
        keepRecurrence ? recurrence : nil
    }

    /// Effective duration in minutes, derived from the start/end pickers. Only
    /// events carry a duration, and only when they have a time.
    private var resolvedDuration: Int? {
        guard kind.usesDuration, hasTime else { return nil }
        let minutes = Self.minutesBetween(time, endTime, calendar: calendar)
        return minutes > 0 ? minutes : nil
    }

    /// Same-day minutes from `start` to `end` (clamped at 0 — the UI keeps `end`
    /// after `start`, so this never has to invent an overnight span).
    static func minutesBetween(_ start: Date, _ end: Date, calendar: Calendar) -> Int {
        let s = calendar.dateComponents([.hour, .minute], from: start)
        let e = calendar.dateComponents([.hour, .minute], from: end)
        let startMin = (s.hour ?? 0) * 60 + (s.minute ?? 0)
        let endMin = (e.hour ?? 0) * 60 + (e.minute ?? 0)
        return max(0, endMin - startMin)
    }

    /// Human-readable derived length for the picker's result line ("1h 30m").
    var durationDisplay: String {
        let minutes = Self.minutesBetween(time, endTime, calendar: calendar)
        guard minutes > 0 else { return "—" }
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    /// Keep `endTime` strictly after `time`; called when either picker moves.
    /// When the start passes the end, the length resets to a sensible 30 minutes.
    func normalizeEndTime() {
        if Self.minutesBetween(time, endTime, calendar: calendar) <= 0 {
            endTime = calendar.date(byAdding: .minute, value: 30, to: time) ?? time
        }
    }

    /// Effort is a to-do notion — an event's length is its duration.
    private var resolvedEffort: Int? {
        kind == .todo ? effortMinutes : nil
    }

    /// For a to-do, the day the user picked *is* the deadline — that's what
    /// "finish the report by Friday" means, and what the parser fills in. Kept
    /// separately from `scheduledDate` so the planner can move the work to a
    /// slot without moving the deadline with it.
    private var resolvedDueDate: Date? {
        guard kind == .todo, hasDate else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// A lead time only makes sense for a timed item; 0 means "at the start".
    private var resolvedLead: Int? {
        (kind.usesTime && hasTime && reminderLeadMinutes > 0) ? reminderLeadMinutes : nil
    }

    /// Merge a fresh parse into an in-progress add draft — the "parsing under the
    /// hood" step. Keeps the user's chosen kind; fills day/time/recurrence/category
    /// from the natural-language title without turning the form into a chat.
    func applyParsed(_ parsed: ParsedCapture) {
        title = parsed.title
        category = parsed.category
        if let day = parsed.scheduledDate {
            hasDate = true
            date = calendar.startOfDay(for: day)
        }
        if kind.usesTime, let start = parsed.startTime {
            hasTime = true
            time = start
            // Anchor the end to the parsed length (or a 1-hour default) so the
            // start/end pickers open with a sensible span already filled in.
            let minutes = (kind.usesDuration ? parsed.durationMinutes : nil) ?? 60
            endTime = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
        }
        if kind.usesDuration, let minutes = parsed.durationMinutes {
            hasDuration = true
            durationMinutes = minutes
        }
        if kind == .todo, let minutes = parsed.effortMinutes ?? parsed.durationMinutes {
            effortMinutes = minutes
        }
        if let rule = parsed.recurrence {
            recurrence = rule
            keepRecurrence = true
        }
    }

    /// The time-of-day folded onto the chosen day (or today if no day set).
    /// To-dos never carry a time, regardless of the toggle state.
    private var resolvedStartTime: Date? {
        guard kind.usesTime, hasTime else { return nil }
        let base = hasDate ? date : calendar.startOfDay(for: Date())
        let comps = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: base)
    }

    /// Build a new item from the draft.
    func makeItem() -> ScheduleItem {
        let item = ScheduleItem(
            title: cleanedTitle,
            kind: kind,
            scheduledDate: hasDate ? calendar.startOfDay(for: date) : nil,
            startTime: resolvedStartTime,
            durationMinutes: resolvedDuration,
            effortMinutes: resolvedEffort,
            dueDate: resolvedDueDate,
            reminderLeadMinutes: resolvedLead,
            priority: priority,
            todoScope: todoScope,
            category: category,
            recurrence: effectiveRecurrence,
            sourceText: sourceText
        )
        // Not an init parameter — `list` is a relationship, and setting it after
        // construction is what keeps `ScheduleItem.init` free of SwiftData types.
        item.list = kind == .todo ? list : nil
        return item
    }

    /// Apply the draft onto an existing item (edit flow).
    func apply(to item: ScheduleItem) {
        item.title = cleanedTitle
        item.kind = kind
        item.category = category
        item.scheduledDate = hasDate ? calendar.startOfDay(for: date) : nil
        item.startTime = resolvedStartTime
        item.durationMinutes = resolvedDuration
        item.effortMinutes = resolvedEffort
        item.dueDate = resolvedDueDate
        item.reminderLeadMinutes = resolvedLead
        item.priority = priority
        item.todoScope = todoScope
        // Only a to-do is ever filed: an event belongs to a day, not a list.
        item.list = kind == .todo ? list : nil
        // Changing how something repeats re-opens it: a routine the user has
        // trimmed or skipped days out of would otherwise stay invisibly dead
        // after they set a new cadence on it.
        if item.recurrence != effectiveRecurrence {
            item.recurrenceEndDate = nil
            item.skippedDates = []
        }
        item.recurrence = effectiveRecurrence
    }

    private var cleanedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
