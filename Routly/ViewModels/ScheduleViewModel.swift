//
//  ScheduleViewModel.swift
//  RoutineOrganizer
//
//  Owns the screen's logic: grouping items into per-day sections (pure, so it's
//  unit-testable without SwiftData), and the mutations — capture, edit, delete,
//  and toggling completion, which writes a Completion record so the Phase 4/5
//  consistency layer has real history to work from.
//

import Foundation
import SwiftData

/// One day's worth of occurrences for the schedule view.
struct DaySection: Identifiable {
    let date: Date
    let items: [ScheduleItem]
    var id: Date { date }
}

@Observable
final class ScheduleViewModel {
    private let parser: AIParsingService
    /// The always-available offline parser, held alongside the configured one so
    /// "keep captures on this phone" has somewhere to route to without rebuilding
    /// anything. Free to hold: `StubAIParsingService` is a stateless struct.
    private let offlineParser = StubAIParsingService()
    private let engine: ScheduleEngine
    private let calendar: Calendar
    /// **`let` is the protection here, and it must stay `let`.**
    ///
    /// `@Observable` instruments every mutable stored property, `private` ones
    /// included. When these were briefly `var` so working hours could be pushed
    /// into them, every write became an observation event — and the writes ran
    /// inside `suggestions()`, which `ScheduleView.body` reads on each pass. So
    /// a render read them, mutated them, invalidated itself, and rendered again.
    /// Today froze on first appearance.
    ///
    /// A `let` has no setter, so there is nothing for the macro to instrument
    /// and no mutation to announce: the loop isn't suppressed, it's impossible
    /// to write. Hours reach the engines through `configured(for:)` instead.
    ///
    /// Anything that makes one of these `var` again brings the freeze back.
    private let conflictDetector = ConflictDetector()
    private let suggestionEngine = SuggestionEngine()
    /// `let` for the same reason as the two above — see the note there.
    private let audit: CompletionAudit
    /// Shared with the widget extension, so "done" means one thing in both
    /// processes. Built from the same calendar as everything else here.
    private let completionWriter: CompletionWriter
    /// Which items belong to today, and in what order — also shared, so the
    /// widget's list can't drift from this screen's.
    private let selection: TodaySelection

    /// Suggestion ids the user has dismissed this session, so they don't nag back.
    var dismissedSuggestionIDs: Set<String> = []

    /// Set once the view has a SwiftData context. Mutations no-op until then.
    private var context: ModelContext?

    /// Rows deleted through this view model.
    ///
    /// Deleting is synchronous but redrawing isn't: for one pass a `@Query`
    /// array still contains the row that just went away, and reading a stored
    /// property of a deleted model is a fault that kills the process — not an
    /// error anything can catch. So every list the UI is built from drops these.
    ///
    /// It has to be an explicit set because SwiftData offers no local signal
    /// that survives the save: `isDeleted` is true only between `delete()` and
    /// `save()`, and afterwards a deleted model looks exactly like one that was
    /// never inserted (`modelContext == nil`, `isDeleted == false`). Since the
    /// app saves immediately, the useful window has closed before anything
    /// redraws. `persistentModelID` is the one thing that stays safe to read.
    private var deletedIDs: Set<PersistentIdentifier> = []

    /// Drops rows deleted out from under the view. Cheap, and a no-op until
    /// something has actually been deleted.
    private func live(_ items: [ScheduleItem]) -> [ScheduleItem] {
        guard !deletedIDs.isEmpty else { return items }
        return items.filter { !deletedIDs.contains($0.persistentModelID) }
    }

    /// How many days ahead the weekly view shows (today + next 6).
    let windowDays = 7

    init(parser: AIParsingService = ParsingServiceFactory.make(), engine: ScheduleEngine = ScheduleEngine()) {
        self.parser = parser
        self.engine = engine
        self.calendar = engine.calendar
        // Built from the same calendar rather than its own default, so the
        // sweep's idea of a day can't drift from the schedule's.
        self.audit = CompletionAudit(calendar: engine.calendar)
        self.completionWriter = CompletionWriter(calendar: engine.calendar)
        self.selection = TodaySelection(engine: engine)
    }

    func configure(context: ModelContext) {
        self.context = context
    }

    // MARK: - Grouping (pure)

    /// Items that have no day and no recurrence — captured but not yet placed.
    func unscheduled(from items: [ScheduleItem]) -> [ScheduleItem] {
        live(items)
            .filter { $0.recurrence == nil && $0.scheduledDate == nil && !$0.isCompleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The next `windowDays` days, each with the items that occur on it.
    func sections(from items: [ScheduleItem], now: Date = Date()) -> [DaySection] {
        let today = calendar.startOfDay(for: now)
        let liveItems = live(items)
        return (0..<windowDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let dayItems = liveItems
                .filter { engine.occurs($0, on: day) }
                .sorted(by: sortComparator)
            return DaySection(date: day, items: dayItems)
        }
    }

    // MARK: - Today home

    /// The timed part of today, ordered by time. Events and reminders always,
    /// plus any to-do that's been given a real slot — once you've accepted "do
    /// the report at 2pm", 2pm is where you should see it, not buried in a
    /// loose checklist. These keep their strikethrough when completed.
    func todayTimed(from items: [ScheduleItem], now: Date = Date()) -> [ScheduleItem] {
        selection.timed(from: live(items), on: now)
    }

    /// The rolling to-do checklist: incomplete to-dos that have come due (undated
    /// or dated on/before today) roll forward until checked; recurring to-dos
    /// show on days they occur and aren't yet done. Completed ones drop out, and
    /// so do ones already slotted into the schedule above — a task shouldn't be
    /// listed twice on the same screen.
    func activeTodos(from items: [ScheduleItem], now: Date = Date()) -> [ScheduleItem] {
        selection.activeTodos(from: live(items), now: now)
    }

    /// The active to-dos in one scope, in the same order as `activeTodos`.
    ///
    /// Scope is what the removed priority/scope badges were replaced by: it says
    /// itself once as a heading rather than on every row.
    func activeTodos(scope: TodoScope, from items: [ScheduleItem], now: Date = Date()) -> [ScheduleItem] {
        activeTodos(from: items, now: now).filter { $0.todoScope == scope }
    }

    /// To-dos finished today, most recent first.
    ///
    /// Deliberately not `isDone`: for a one-off that reads `isCompleted`, which
    /// carries no date, so a to-do ticked off last month would surface here as
    /// finished today. The completion *record* is the only thing that knows
    /// which day it happened on.
    func completedTodos(from items: [ScheduleItem], now: Date = Date()) -> [ScheduleItem] {
        let today = calendar.startOfDay(for: now)
        return live(items)
            .filter { item in
                guard item.kind == .todo else { return false }
                return item.completions.contains {
                    $0.status == .done && calendar.isDate($0.occurrenceDate, inSameDayAs: today)
                }
            }
            .sorted { completedAt($0, on: today) > completedAt($1, on: today) }
    }

    private func completedAt(_ item: ScheduleItem, on day: Date) -> Date {
        item.completions
            .first { $0.status == .done && calendar.isDate($0.occurrenceDate, inSameDayAs: day) }?
            .completedAt ?? .distantPast
    }

    /// Today's work above the long game, urgent above idle, then oldest first.
    /// Scope leads because it answers a different question from priority: a
    /// high-priority long-term task is still not what you should look at first
    /// thing this morning.
    ///
    /// Lives in `TodaySelection` now, so the widget lists to-dos in exactly this
    /// order rather than in one that merely resembles it.
    private func todoComparator(_ a: ScheduleItem, _ b: ScheduleItem) -> Bool {
        selection.todoComparator(a, b)
    }

    /// A to-do that holds an actual time on `today`.
    private func isSlottedToday(_ item: ScheduleItem, today: Date) -> Bool {
        selection.isSlottedToday(item, today: today)
    }

    // MARK: - Calendar horizon

    func startOfWeek(containing date: Date) -> Date {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    }

    /// The seven days of the week containing `date`.
    func weekDays(containing date: Date = Date()) -> [Date] {
        let start = startOfWeek(containing: date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// A 6×7 month grid aligned to the week, including adjacent-month days that
    /// pad the first and last rows (standard calendar layout).
    func monthGrid(containing date: Date = Date()) -> [Date] {
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let firstOfMonth = calendar.date(from: comps) else { return [] }
        let gridStart = startOfWeek(containing: firstOfMonth)
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    func isInMonth(_ day: Date, of reference: Date) -> Bool {
        calendar.component(.month, from: day) == calendar.component(.month, from: reference)
    }

    /// Every item occurring on `day`, timed items first — the calendar's per-day
    /// column contents.
    func items(on day: Date, from items: [ScheduleItem]) -> [ScheduleItem] {
        live(items).filter { engine.occurs($0, on: day) }.sorted(by: sortComparator)
    }

    /// Distinct categories with an item on `day`, for the month dot-grid.
    func categoriesPresent(on day: Date, from items: [ScheduleItem]) -> [Category] {
        var seen: [Category] = []
        for item in live(items) where engine.occurs(item, on: day) {
            if !seen.contains(item.category) { seen.append(item.category) }
        }
        return seen
    }

    private func sortComparator(_ a: ScheduleItem, _ b: ScheduleItem) -> Bool {
        selection.timeComparator(a, b)
    }

    // MARK: - Completion

    func isDone(_ item: ScheduleItem, on day: Date) -> Bool {
        completionWriter.isDone(item, on: day)
    }

    /// Ticks an item on or off.
    ///
    /// The work moved to `CompletionWriter`, in the shared folder, so the widget
    /// extension's completion button runs *this* logic rather than its own
    /// version of it. What a completion is — one record per occurrence, the
    /// `.done`-only removal rule, `isCompleted` for one-offs only — is now
    /// defined in exactly one place for both processes. See the note there.
    func toggleDone(_ item: ScheduleItem, on day: Date) {
        guard let context else { return }
        completionWriter.toggle(item, on: day, in: context, owner: CurrentOwner.id)
        WidgetRefresh.reload()
    }

    /// Removes records for one day, narrowed to the statuses named.
    ///
    /// Delegates to the shared writer, whose `.done`-only default is the
    /// load-bearing part: un-ticking something is the user taking back a
    /// completion, and is not a statement about a reschedule or a skip that may
    /// also have happened that day. Callers that genuinely mean "this day never
    /// happened" — trimming a series — pass every status.
    private func removeCompletion(
        _ item: ScheduleItem,
        on dayStart: Date,
        statuses: Set<Completion.Status> = [.done]
    ) {
        guard let context else { return }
        completionWriter.removeCompletion(item, on: dayStart, in: context, statuses: statuses)
    }

    /// Appends one record. The single place a non-`.done` status is written.
    ///
    /// `completedAt` stays nil: nothing was completed. The field means what it
    /// says, and a skip that carried a completion timestamp would be a lie the
    /// competence signals would later read as fact.
    private func record(
        _ status: Completion.Status,
        for item: ScheduleItem,
        on day: Date,
        scheduledTime: Date? = nil
    ) {
        let completion = Completion(
            occurrenceDate: calendar.startOfDay(for: day),
            scheduledTime: scheduledTime,
            completedAt: nil,
            status: status,
            item: item
        )
        item.completions.append(completion)
        context?.insert(completion)
    }

    /// Writes a `.skipped` record for every past occurrence that closed without
    /// one, and returns how many it wrote.
    ///
    /// This is the only thing in the app that notices a day ended unanswered.
    /// It is deliberately not a nudge, a badge or a number anyone is shown —
    /// every reader in the app filters on `.done`, so nothing visible moves.
    /// It exists so that in twelve weeks there is something real to read a
    /// pattern out of.
    ///
    /// Idempotent: a day already carrying any record is left alone, so running
    /// it on every appearance is safe.
    func auditPastDays(from items: [ScheduleItem], now: Date = Date()) -> Int {
        let missed = audit.missedOccurrences(in: live(items), asOf: now)
        guard !missed.isEmpty else { return 0 }
        for entry in missed {
            record(.skipped, for: entry.item, on: entry.day)
        }
        save()
        return missed.count
    }

    /// Fraction of a day's items completed — drives the day-header ring.
    func completionFraction(for section: DaySection) -> Double {
        guard !section.items.isEmpty else { return 0 }
        let done = section.items.filter { isDone($0, on: section.date) }.count
        return Double(done) / Double(section.items.count)
    }

    /// Records a hand-arranged order for one group of to-dos.
    ///
    /// Every item in the group is stamped, not just the one that moved. A single
    /// index among nils would sort against items that have no position at all,
    /// which is how "I dragged one row and three others jumped" happens.
    func reorderTodos(_ ordered: [ScheduleItem]) {
        for (index, item) in ordered.enumerated() where item.kind == .todo {
            item.todoSortIndex = index
        }
        save()
    }

    /// Moves a to-do into a group and places it at `index` within that group's
    /// current order.
    ///
    /// One method for both kinds of drag, because from the user's side there is
    /// one gesture: pick a task up, put it where it belongs. Where it lands
    /// decides what changes — a scope heading changes its scope, a list heading
    /// files it — and the position within the group is written down either way,
    /// so a drop is also a reorder.
    func move(
        _ item: ScheduleItem,
        toScope scope: TodoScope?,
        list: TodoList?,
        within group: [ScheduleItem],
        at index: Int
    ) {
        guard item.kind == .todo else { return }
        if let scope { item.todoScope = scope }
        item.list = list

        var ordered = group.filter { $0.persistentModelID != item.persistentModelID }
        ordered.insert(item, at: min(max(index, 0), ordered.count))
        for (position, entry) in ordered.enumerated() {
            entry.todoSortIndex = position
        }
        save()
    }

    /// Rearranges one group after a drag, in `ForEach.onMove` terms.
    ///
    /// Writes an explicit position to every row in the group rather than only
    /// the one that moved. `todoSortIndex` is optional, and a group where some
    /// rows have one and some don't sorts by two different rules at once — so
    /// the first drag in a group is also the moment its order stops being
    /// automatic. That is the intended meaning: arranging one task by hand is
    /// the user taking the whole group's order into their own hands.
    func reorder(_ items: [ScheduleItem], from source: IndexSet, to destination: Int) {
        var ordered = items
        ordered.move(fromOffsets: source, toOffset: destination)
        for (position, entry) in ordered.enumerated() {
            entry.todoSortIndex = position
        }
        save()
    }

    // MARK: - Lists

    /// Creates a list, placed after the ones that already exist.
    ///
    /// Returns nil for a blank name rather than making an untitled list — a row
    /// with no name is indistinguishable from a bug, and there is nothing useful
    /// to call it on the user's behalf.
    @discardableResult
    func createList(named name: String, after existing: [TodoList]) -> TodoList? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let list = TodoList(name: clean, sortIndex: (existing.map(\.sortIndex).max() ?? -1) + 1)
        context?.insert(list)
        save()
        return list
    }

    /// Renames in place. One write, wherever the list is shown — which is the
    /// reason a list is an entity rather than a string on each to-do.
    func rename(_ list: TodoList, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != list.name else { return }
        list.name = clean
        save()
    }

    /// Deletes the list and **keeps its to-dos**, which simply stop being filed
    /// anywhere. The nullify rule on `TodoList.items` is what guarantees that;
    /// this method exists to make the guarantee callable and to be the place the
    /// intent is written down.
    func delete(_ list: TodoList) {
        deletedIDs.insert(list.persistentModelID)
        context?.delete(list)
        save()
    }

    /// Files a to-do under a list, or under none. Only to-dos: an event belongs
    /// to a day, not to a list.
    func assign(_ item: ScheduleItem, to list: TodoList?) {
        guard item.kind == .todo else { return }
        item.list = list
        save()
    }

    /// The lists, in the order they were put in.
    func lists(from lists: [TodoList]) -> [TodoList] {
        live(lists).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Drops lists deleted out from under the view, for the same reason
    /// `live(_:)` does it for items — reading a stored property of a deleted
    /// model is a fault that kills the process, not an error anything can catch.
    private func live(_ lists: [TodoList]) -> [TodoList] {
        guard !deletedIDs.isEmpty else { return lists }
        return lists.filter { !deletedIDs.contains($0.persistentModelID) }
    }

    // MARK: - Capture / edit / delete

    /// The parser this capture should go through.
    ///
    /// Resolved per call rather than at `init`, for the same reason
    /// `configured(for:)` re-reads working hours: the setting is changed on a
    /// screen presented *above* this view model, and a choice captured at
    /// construction would keep sending captures to the cloud until the next
    /// launch — on the one setting where "it'll apply later" is not good enough.
    ///
    /// Reading `AppSettings.shared` here is safe because every caller below is
    /// `@MainActor`; the parsing services themselves stay `Sendable` and take
    /// plain values, exactly as `AIParsingService` documents.
    @MainActor
    private var activeParser: AIParsingService {
        AppSettings.shared.cloudParsingEnabled ? parser : offlineParser
    }

    /// Parse raw text into one or more structured captures — the voice review
    /// flow uses all of them.
    ///
    /// `lists` are the user's list names, passed down so the parser can file a
    /// to-do under one. Names rather than models: see `AIParsingService.parse`.
    @MainActor
    func parseAll(_ text: String, now: Date = Date(), lists: [String] = []) async -> [ParsedCapture] {
        await activeParser.parse(
            text,
            now: now,
            workingHours: AppSettings.shared.workingHours(on: now),
            lists: lists
        )
    }

    /// The first parsed item, for the inline "autofill from text" wand where the
    /// user is editing a single item.
    @MainActor
    func parseFirst(_ text: String, now: Date = Date(), lists: [String] = []) async -> ParsedCapture? {
        await activeParser.parseFirst(
            text,
            now: now,
            workingHours: AppSettings.shared.workingHours(on: now),
            lists: lists
        )
    }

    /// Route a capture: a broad goal becomes a plan, everything else a list of
    /// items. Backs the hybrid voice flow.
    @MainActor
    func interpret(_ text: String, now: Date = Date(), lists: [String] = []) async -> CaptureInterpretation {
        await activeParser.interpret(
            text,
            now: now,
            workingHours: AppSettings.shared.workingHours(on: now),
            lists: lists
        )
    }

    /// Force the planner over a stated goal — the deliberate "Plan a goal" path.
    ///
    /// `@MainActor` so it can honour the same preference as the parse paths. A
    /// goal is sent to the provider as text like any other capture, so leaving
    /// this one routed to the cloud would have made "keep captures on this
    /// phone" quietly untrue for the whole plan-a-goal flow. Its only caller is
    /// already on the main actor.
    @MainActor
    func planForGoal(_ text: String, now: Date = Date()) async -> ParsedPlan {
        await activeParser.plan(forGoal: text, now: now)
    }

    /// Persist a brand-new item from a (possibly user-edited) draft.
    func commit(_ item: ScheduleItem) {
        context?.insert(item)
        save()
    }

    // MARK: - Conflicts & suggestions

    /// The engines, carrying the working hours that apply on `day`.
    ///
    /// These are **copies**. `ConflictDetector`, `SuggestionEngine`, the
    /// `DayPlanner` one of them holds, and both preference types are all
    /// structs, so assigning to a local `var` duplicates the whole chain and the
    /// stored properties above are never touched.
    ///
    /// Configuring per call rather than once at `init` is deliberate: the
    /// settings sheet sits above this view model, so a window captured at
    /// construction would be wrong until the next launch. Two struct copies per
    /// call is not a cost worth optimising away.
    @MainActor
    private func configured(for day: Date) -> (conflict: ConflictDetector, suggestion: SuggestionEngine) {
        let hours = AppSettings.shared.workingHours(on: day)
        var conflict = conflictDetector
        conflict.preferences.workingHours = hours
        var suggestion = suggestionEngine
        suggestion.setWorkingHours(hours)
        return (conflict, suggestion)
    }

    /// Checks a timed draft against the day it would land on. Returns a pending
    /// conflict to surface, or nil when it's clear to place. Untimed/undated
    /// items never conflict.
    @MainActor
    func conflict(for draft: CaptureDraft, among items: [ScheduleItem]) -> PendingConflict? {
        guard draft.kind.usesTime, draft.hasTime, draft.hasDate else { return nil }
        let candidate = draft.makeItem()
        guard let day = candidate.scheduledDate else { return nil }
        let detector = configured(for: day).conflict
        // Don't let an item conflict with its own former self when editing.
        let others = items.filter { $0.id != draft.editingItem?.id }
        let report = detector.report(for: candidate, against: others, on: day)
        guard report.hasConflict else { return nil }
        let alternative = detector.alternative(for: candidate, against: others, on: day)
        return PendingConflict(draft: draft, report: report, alternative: alternative)
    }

    /// Heuristic suggestions for the Today surface, minus anything dismissed.
    @MainActor
    func suggestions(from items: [ScheduleItem], now: Date = Date()) -> [ScheduleSuggestion] {
        return configured(for: now).suggestion.suggestions(from: items, now: now)
            .filter { !dismissedSuggestionIDs.contains($0.id) }
    }

    func dismiss(_ suggestion: ScheduleSuggestion) {
        dismissedSuggestionIDs.insert(suggestion.id)
    }

    /// A focused pass over today, framed around finishing what's outstanding.
    @MainActor
    func optimizeToday(from items: [ScheduleItem], now: Date = Date()) -> [ScheduleSuggestion] {
        return configured(for: now).suggestion.optimizeToday(from: items, now: now)
            .filter { !dismissedSuggestionIDs.contains($0.id) }
    }

    /// The underlying plan, for the headline "how much time is actually left".
    @MainActor
    func dayPlan(from items: [ScheduleItem], now: Date = Date()) -> DayPlan {
        return configured(for: now).suggestion.dayPlan(from: items, now: now)
    }

    /// Records that an item was moved off the day it was sitting on, before the
    /// move is applied — the old placement is still readable at that point.
    ///
    /// The distinction this draws is the whole value of the signal. "You've
    /// moved this three times" is only worth saying if the count means three
    /// *moves*: giving a to-do its first slot is the planner doing its job, and
    /// counting that as a push would leave every well-behaved task looking
    /// chronically rescheduled. So:
    ///
    /// - Never placed at all (`scheduledDate == nil`) — a first placement.
    /// - Had a day but no time, and keeps the same day — being slotted for the
    ///   first time, which is also a first placement, not a move.
    /// - Left the day it was on — a move, whether or not it had a time.
    /// - Kept the day but changed a time it already had — also a move; pushing
    ///   something from 2pm to 5pm is the behaviour worth noticing even though
    ///   the day never changed.
    ///
    /// Unlike `.done`, these are an event log rather than one-per-occurrence:
    /// three moves off the same day are three records, because the count is the
    /// point. `.done` and `.skipped` stay at most one per occurrence.
    private func noteReschedule(of item: ScheduleItem, toDay newDay: Date, newStart: Date?) {
        guard let previousDay = item.scheduledDate else { return }

        let from = calendar.startOfDay(for: previousDay)
        let movedDay = from != calendar.startOfDay(for: newDay)
        // A time it never had is not a time it was moved from.
        let movedTime = newStart != nil && item.startTime != nil && item.startTime != newStart

        guard movedDay || movedTime else { return }
        record(.rescheduled, for: item, on: from, scheduledTime: item.startTime)
    }

    /// Applies a suggestion's change. Only ever called after the user confirms —
    /// nothing here happens silently.
    @discardableResult
    func apply(_ action: SuggestionAction, among items: [ScheduleItem]) -> ScheduleItem? {
        func item(_ id: UUID) -> ScheduleItem? { items.first { $0.id == id } }

        switch action {
        case let .reschedule(itemID, newStart):
            guard let target = item(itemID) else { return nil }
            noteReschedule(of: target, toDay: newStart, newStart: newStart)
            target.scheduledDate = calendar.startOfDay(for: newStart)
            target.startTime = newStart
            save()
            return target

        case let .scheduleTodo(itemID, day):
            guard let target = item(itemID) else { return nil }
            // Only the day moves here; the time, if any, is left alone.
            noteReschedule(of: target, toDay: day, newStart: nil)
            target.scheduledDate = calendar.startOfDay(for: day)
            save()
            return target

        case let .scheduleTodoAt(itemID, start, minutes):
            guard let target = item(itemID) else { return nil }
            noteReschedule(of: target, toDay: start, newStart: start)
            // Deliberately does *not* touch `dueDate`: giving something a slot
            // must never quietly move its deadline. `scheduledDate` is where it
            // now sits; the deadline stays where the user put it.
            target.scheduledDate = calendar.startOfDay(for: start)
            target.startTime = start
            if let minutes {
                // Reserve the block for real, so the rest of the day plans
                // around it and the conflict detector can see it.
                target.durationMinutes = minutes
                // An estimate the user has just confirmed on screen stops being
                // a guess, so it's worth keeping — but a size they stated
                // themselves always wins.
                if target.effortMinutes == nil { target.effortMinutes = minutes }
            }
            save()
            return target
        }
    }

    /// How much of a repeating item a delete takes with it.
    enum DeletionScope: Hashable {
        /// Just the day you're looking at — the rest of the series survives.
        case occurrence
        /// This day and everything after it; the past stays as it happened.
        case futureOccurrences
        /// The whole thing, history included.
        case series
    }

    /// What actually happened, so the caller knows whether the item still exists.
    enum DeletionOutcome: Hashable {
        /// The item was removed from the store.
        case removed
        /// The item survived with fewer occurrences.
        case trimmed
    }

    func delete(_ item: ScheduleItem) {
        // Recorded *before* the delete, while the item is still safe to touch.
        // Every list the UI reads filters on this, so the row is gone from the
        // next redraw rather than lingering as a model nobody may read.
        deletedIDs.insert(item.persistentModelID)
        context?.delete(item)
        save()
    }

    /// Delete at the granularity the user chose. A one-off item has only one
    /// occurrence, so every scope means the same thing for it.
    @discardableResult
    func delete(_ item: ScheduleItem, scope: DeletionScope, on day: Date) -> DeletionOutcome {
        guard item.isRoutine, scope != .series else {
            delete(item)
            return .removed
        }

        let dayStart = calendar.startOfDay(for: day)

        switch scope {
        case .occurrence:
            item.skipOccurrence(on: dayStart, calendar: calendar)
            // A day that no longer exists shouldn't keep feeding the record.
            removeCompletion(item, on: dayStart)
            // But it did happen to the person, and lifting a day out of a
            // series is one of the clearest statements available that this
            // occurrence isn't going to happen — which is exactly the signal
            // the pattern layer needs. Recorded, never rendered as a failure:
            // the day now fails `occurs`, so the grid counts nothing scheduled
            // and `isMissed` can't fire for it.
            record(.skipped, for: item, on: dayStart)
        case .futureOccurrences:
            // Trimming to before the routine even started leaves nothing behind,
            // so there's no honest way to keep it — that's a full delete.
            guard item.endRecurrence(from: dayStart, calendar: calendar) else {
                delete(item)
                return .removed
            }
            for completion in item.completions where calendar.startOfDay(for: completion.occurrenceDate) >= dayStart {
                item.completions.removeAll { $0.id == completion.id }
                context?.delete(completion)
            }
        case .series:
            break // handled above
        }

        save()
        return .trimmed
    }

    /// Stamps ownership and writes.
    ///
    /// The stamping moved to `StoreWrite`, shared with the extension, so a
    /// widget-written completion carries the same owner and merge clock as an
    /// app-written one. This is still the single funnel every mutation in the
    /// app passes through — which is why one hook here covers capture, edit,
    /// completion, planning and deletion alike, and why the sync layer won't
    /// need to touch the mutation code later.
    ///
    /// The widget reload rides along for the same reason: anything that changed
    /// the store may have changed what the widget is showing, and putting it
    /// here means no future mutation can forget to ask for one.
    func save() {
        guard let context else { return }
        StoreWrite.save(context, owner: CurrentOwner.id)
        WidgetRefresh.reload()
    }

    var calendarForViews: Calendar { calendar }
}
