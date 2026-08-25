//
//  ScheduleViewModelTests.swift
//  RoutineOrganizerTests
//
//  Covers the schedule grouping (pure) and the completion mutations, the latter
//  against an in-memory SwiftData store to prove Completion records are written.
//

import Testing
import Foundation
import SwiftData
@testable import Routly

private let cal = Calendar(identifier: .gregorian)

/// Monday, 20 July 2026, 08:00 — matches the parser suite's reference.
private let monday: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 20; c.hour = 8
    return cal.date(from: c)!
}()

private func startOfDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    cal.startOfDay(for: DateComponents(calendar: cal, year: y, month: m, day: d).date!)
}

@MainActor
private func inMemoryContext() throws -> ModelContext {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self,
        configurations: config
    )
    return ModelContext(container)
}

@Suite("Schedule grouping")
struct ScheduleGroupingTests {
    let vm = ScheduleViewModel()

    @Test("one-off task lands in the correct day section")
    func oneOffPlacement() {
        let item = ScheduleItem(title: "Dentist", scheduledDate: startOfDay(2026, 7, 22))
        let sections = vm.sections(from: [item], now: monday)
        #expect(sections.count == 7)
        #expect(sections[2].items.contains { $0.title == "Dentist" })
        #expect(!sections[0].items.contains { $0.title == "Dentist" })
    }

    @Test("daily routine appears every day in the window")
    func dailyEveryDay() {
        let item = ScheduleItem(title: "Run", recurrence: .everyDay, createdAt: monday)
        let sections = vm.sections(from: [item], now: monday)
        #expect(sections.allSatisfy { $0.items.contains { $0.title == "Run" } })
    }

    @Test("weekly-Monday routine only appears on Mondays")
    func weeklyMonday() {
        let item = ScheduleItem(title: "Standup", recurrence: .weekly(on: [2]), createdAt: monday)
        let sections = vm.sections(from: [item], now: monday)
        #expect(sections[0].items.contains { $0.title == "Standup" })   // Mon Jul 20
        #expect(!sections[1].items.contains { $0.title == "Standup" })  // Tue Jul 21
    }

    @Test("dateless, non-recurring item is unscheduled")
    func unscheduledBucket() {
        let placed = ScheduleItem(title: "Dentist", scheduledDate: startOfDay(2026, 7, 22))
        let floating = ScheduleItem(title: "Read a book")
        let unscheduled = vm.unscheduled(from: [placed, floating])
        #expect(unscheduled.map(\.title) == ["Read a book"])
    }

    @Test("timed items sort ahead of untimed, then alphabetically")
    func sortingWithinDay() {
        let untimed = ScheduleItem(title: "Zebra", scheduledDate: startOfDay(2026, 7, 20))
        let noon = ScheduleItem(
            title: "Lunch",
            scheduledDate: startOfDay(2026, 7, 20),
            startTime: cal.date(bySettingHour: 12, minute: 0, second: 0, of: monday)
        )
        let sections = vm.sections(from: [untimed, noon], now: monday)
        #expect(sections[0].items.map(\.title) == ["Lunch", "Zebra"])
    }
}

@Suite("Completion mutations")
@MainActor
struct CompletionTests {

    @Test("toggling a one-off writes then removes a Completion and flips the flag")
    func oneOffToggle() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = ScheduleItem(title: "Dentist", scheduledDate: startOfDay(2026, 7, 20))
        context.insert(item)

        #expect(!vm.isDone(item, on: monday))
        vm.toggleDone(item, on: monday)
        #expect(vm.isDone(item, on: monday))
        #expect(item.isCompleted)
        #expect(item.completions.count == 1)

        vm.toggleDone(item, on: monday)
        #expect(!vm.isDone(item, on: monday))
        #expect(!item.isCompleted)
        #expect(item.completions.isEmpty)
    }

    @Test("routine completion is tracked per day, not globally")
    func routinePerDay() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = ScheduleItem(title: "Run", recurrence: .everyDay, createdAt: monday)
        context.insert(item)

        let tuesday = startOfDay(2026, 7, 21)
        vm.toggleDone(item, on: monday)

        #expect(vm.isDone(item, on: monday))
        #expect(!vm.isDone(item, on: tuesday)) // different day untouched
        #expect(!item.isCompleted)             // routines don't set the one-off flag
        #expect(item.completions.count == 1)
    }

    @Test("completion fraction reflects done vs total for a day")
    func fraction() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let a = ScheduleItem(title: "A", scheduledDate: startOfDay(2026, 7, 20))
        let b = ScheduleItem(title: "B", scheduledDate: startOfDay(2026, 7, 20))
        context.insert(a); context.insert(b)

        vm.toggleDone(a, on: monday)
        let section = vm.sections(from: [a, b], now: monday)[0]
        #expect(vm.completionFraction(for: section) == 0.5)
    }
}

@Suite("Today home grouping")
struct TodayHomeTests {
    let vm = ScheduleViewModel()

    @Test("timed section holds today's events & reminders, not to-dos")
    func todayTimed() {
        let event = ScheduleItem(title: "Standup", kind: .event, scheduledDate: startOfDay(2026, 7, 20),
                                 startTime: cal.date(bySettingHour: 9, minute: 0, second: 0, of: monday))
        let reminder = ScheduleItem(title: "Pills", kind: .reminder, scheduledDate: startOfDay(2026, 7, 20),
                                    startTime: cal.date(bySettingHour: 8, minute: 0, second: 0, of: monday))
        let todoToday = ScheduleItem(title: "Report", kind: .todo, scheduledDate: startOfDay(2026, 7, 20))
        let eventTomorrow = ScheduleItem(title: "Dentist", kind: .event, scheduledDate: startOfDay(2026, 7, 21))

        let timed = vm.todayTimed(from: [event, reminder, todoToday, eventTomorrow], now: monday)
        #expect(timed.map(\.title) == ["Pills", "Standup"]) // sorted by time, to-do & tomorrow excluded
    }

    @Test("rolling to-dos: undated & overdue roll, completed drop, future wait")
    func rollingTodos() {
        let undated = ScheduleItem(title: "Read", kind: .todo)
        let overdue = ScheduleItem(title: "Overdue", kind: .todo, scheduledDate: startOfDay(2026, 7, 18))
        let done = ScheduleItem(title: "Done", kind: .todo, isCompleted: true)
        let future = ScheduleItem(title: "Future", kind: .todo, scheduledDate: startOfDay(2026, 7, 25))

        let active = vm.activeTodos(from: [undated, overdue, done, future], now: monday)
        let titles = Set(active.map(\.title))
        #expect(titles == ["Read", "Overdue"])
    }

    @Test("a to-do given a slot moves onto the schedule, out of the checklist")
    func slottedTodoMovesToSchedule() {
        // What accepting a recommendation produces: a to-do with a real time.
        let slotted = ScheduleItem(
            title: "Write summary", kind: .todo,
            scheduledDate: startOfDay(2026, 7, 20),
            startTime: cal.date(bySettingHour: 14, minute: 0, second: 0, of: monday),
            durationMinutes: 45
        )
        let loose = ScheduleItem(title: "Read", kind: .todo)

        // It shows where the user was told it would happen…
        #expect(vm.todayTimed(from: [slotted, loose], now: monday).map(\.title) == ["Write summary"])
        // …and isn't also left sitting in the undated list.
        #expect(vm.activeTodos(from: [slotted, loose], now: monday).map(\.title) == ["Read"])
    }

    @Test("a to-do slotted for another day stays in today's checklist")
    func slottedTomorrowStillRolls() {
        let tomorrow = ScheduleItem(
            title: "Overdue thing", kind: .todo,
            scheduledDate: startOfDay(2026, 7, 18),
            startTime: cal.date(bySettingHour: 9, minute: 0, second: 0, of: startOfDay(2026, 7, 18))
        )
        // Slotted on a past day and never done — it still needs to roll forward.
        #expect(vm.activeTodos(from: [tomorrow], now: monday).map(\.title) == ["Overdue thing"])
        #expect(vm.todayTimed(from: [tomorrow], now: monday).isEmpty)
    }

    @Test("recurring to-do shows on its day until completed")
    func recurringTodo() {
        let daily = ScheduleItem(title: "Stretch", kind: .todo, recurrence: .everyDay, createdAt: monday)
        #expect(vm.activeTodos(from: [daily], now: monday).count == 1)

        daily.completions = [Completion(occurrenceDate: startOfDay(2026, 7, 20), status: .done, item: daily)]
        #expect(vm.activeTodos(from: [daily], now: monday).isEmpty) // done today → leaves
    }
}

@Suite("Calendar horizon")
struct CalendarHorizonTests {
    let vm = ScheduleViewModel()

    @Test("week has 7 days and contains the reference day")
    func week() {
        let days = vm.weekDays(containing: monday)
        #expect(days.count == 7)
        #expect(days.contains { cal.isDate($0, inSameDayAs: monday) })
    }

    @Test("month grid is a full 6×7 and includes the month's days")
    func month() {
        let grid = vm.monthGrid(containing: monday)
        #expect(grid.count == 42)
        #expect(grid.contains { cal.isDate($0, inSameDayAs: startOfDay(2026, 7, 1)) })
        #expect(grid.contains { cal.isDate($0, inSameDayAs: startOfDay(2026, 7, 31)) })
    }

    @Test("categories present are distinct for a day")
    func dots() {
        let a = ScheduleItem(title: "A", kind: .event, scheduledDate: startOfDay(2026, 7, 20), category: .work)
        let b = ScheduleItem(title: "B", kind: .event, scheduledDate: startOfDay(2026, 7, 20), category: .work)
        let c = ScheduleItem(title: "C", kind: .event, scheduledDate: startOfDay(2026, 7, 20), category: .health)
        let cats = vm.categoriesPresent(on: startOfDay(2026, 7, 20), from: [a, b, c])
        #expect(Set(cats) == [.work, .health])
        #expect(cats.count == 2) // deduped
    }
}

@Suite("Recurring deletion scopes")
@MainActor
struct RecurringDeletionTests {

    /// Monday-anchored daily routine, so the anchor and `monday` line up.
    private func dailyRoutine() -> ScheduleItem {
        ScheduleItem(title: "Run", kind: .event, scheduledDate: startOfDay(2026, 7, 20),
                     recurrence: .everyDay, createdAt: monday)
    }

    @Test("deleting one occurrence leaves the rest of the series alone")
    func skipSingleDay() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = dailyRoutine()
        context.insert(item)

        let tuesday = startOfDay(2026, 7, 21)
        let outcome = vm.delete(item, scope: .occurrence, on: tuesday)

        #expect(outcome == .trimmed)
        let sections = vm.sections(from: [item], now: monday)
        #expect(sections[0].items.count == 1)  // Monday survives
        #expect(sections[1].items.isEmpty)     // Tuesday is gone
        #expect(sections[2].items.count == 1)  // Wednesday survives
    }

    @Test("deleting a done occurrence takes its completion with it")
    func skipClearsCompletion() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = dailyRoutine()
        context.insert(item)
        vm.toggleDone(item, on: monday)
        #expect(item.completions.count == 1)

        vm.delete(item, scope: .occurrence, on: monday)
        // A day that never happened can't count as done...
        #expect(!vm.isDone(item, on: monday))
        #expect(!item.completions.contains { $0.status == .done })
        // ...but lifting it out of the series is itself a statement about that
        // day, and it's kept. Nothing renders it: the day now fails `occurs`.
        #expect(item.completions.map(\.status) == [.skipped])
    }

    @Test("deleting this and all future keeps the past, stops the future")
    func trimForward() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = dailyRoutine()
        context.insert(item)

        let wednesday = startOfDay(2026, 7, 22)
        let outcome = vm.delete(item, scope: .futureOccurrences, on: wednesday)

        #expect(outcome == .trimmed)
        let sections = vm.sections(from: [item], now: monday)
        #expect(sections[0].items.count == 1) // Monday
        #expect(sections[1].items.count == 1) // Tuesday
        #expect(sections[2].items.isEmpty)    // Wednesday onward
        #expect(sections[6].items.isEmpty)
    }

    @Test("trimming from the first occurrence removes the item outright")
    func trimFromStartDeletes() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = dailyRoutine()
        context.insert(item)

        let outcome = vm.delete(item, scope: .futureOccurrences, on: monday)
        #expect(outcome == .removed) // nothing would be left to keep
    }

    @Test("deleting the series removes the item, history and all")
    func deleteSeries() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = dailyRoutine()
        context.insert(item)
        vm.toggleDone(item, on: monday)

        let outcome = vm.delete(item, scope: .series, on: monday)
        #expect(outcome == .removed)
        let remaining = try context.fetch(FetchDescriptor<ScheduleItem>())
        #expect(remaining.isEmpty)
    }

    @Test("a one-off item is removed whatever scope is asked for")
    func oneOffIgnoresScope() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = ScheduleItem(title: "Dentist", kind: .event, scheduledDate: startOfDay(2026, 7, 22))
        context.insert(item)

        #expect(vm.delete(item, scope: .occurrence, on: startOfDay(2026, 7, 22)) == .removed)
        #expect(try context.fetch(FetchDescriptor<ScheduleItem>()).isEmpty)
    }

    @Test("trimming never extends an already-shortened routine")
    func trimOnlyShortens() {
        let item = dailyRoutine()
        let cal = Calendar(identifier: .gregorian)
        item.endRecurrence(from: startOfDay(2026, 7, 22), calendar: cal)
        item.endRecurrence(from: startOfDay(2026, 7, 26), calendar: cal)
        #expect(item.recurrenceEndDate == startOfDay(2026, 7, 21))
    }

    @Test("editing the cadence re-opens a trimmed routine")
    func editingClearsTrim() {
        let item = dailyRoutine()
        item.endRecurrence(from: startOfDay(2026, 7, 22), calendar: Calendar(identifier: .gregorian))
        item.skipOccurrence(on: startOfDay(2026, 7, 21), calendar: Calendar(identifier: .gregorian))

        let draft = CaptureDraft(item: item, now: monday)
        draft.recurrence = .weekly(on: [2, 4])
        draft.keepRecurrence = true
        draft.apply(to: item)

        #expect(item.recurrenceEndDate == nil)
        #expect(item.skippedDates.isEmpty)
    }
}

// MARK: - Status history

/// The three statuses were declared from the start and only `.done` was ever
/// written, which made the log a record of successes rather than of what
/// happened. These cover the two writers that fill the gap — and, just as
/// importantly, the cases that must *not* write, since a false entry here is
/// permanent and silently wrong.
@Suite("Completion status history")
@MainActor
struct CompletionStatusTests {

    private func slottedTodo(on day: Date, at hour: Int? = nil) -> ScheduleItem {
        ScheduleItem(
            title: "Report",
            kind: .todo,
            scheduledDate: day,
            startTime: hour.flatMap { cal.date(bySettingHour: $0, minute: 0, second: 0, of: day) },
            createdAt: monday
        )
    }

    private func records(_ item: ScheduleItem, _ status: Completion.Status) -> [Completion] {
        item.completions.filter { $0.status == status }
    }

    // MARK: Reschedules

    @Test("moving an item to another day records the day it left")
    func moveAcrossDaysIsRecorded() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = slottedTodo(on: startOfDay(2026, 7, 20), at: 9)
        context.insert(item)

        let tuesday9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: startOfDay(2026, 7, 21))!
        _ = vm.apply(.reschedule(itemID: item.id, newStart: tuesday9), among: [item])

        let moved = records(item, .rescheduled)
        #expect(moved.count == 1)
        // Stamped against the day it was pushed off, not the day it landed on.
        #expect(moved.first?.occurrenceDate == startOfDay(2026, 7, 20))
        #expect(moved.first?.completedAt == nil)
    }

    @Test("re-timing an item within the same day is still a move")
    func sameDayRetimeIsRecorded() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let monday9 = startOfDay(2026, 7, 20)
        let item = slottedTodo(on: monday9, at: 9)
        context.insert(item)

        let monday5pm = cal.date(bySettingHour: 17, minute: 0, second: 0, of: monday9)!
        _ = vm.apply(.reschedule(itemID: item.id, newStart: monday5pm), among: [item])

        #expect(records(item, .rescheduled).count == 1)
    }

    /// The distinction the whole signal rests on. Giving a to-do its first slot
    /// is the planner working, not a push — counting it would leave every
    /// well-behaved task looking chronically rescheduled.
    @Test("giving an unslotted to-do its first time is not a reschedule")
    func firstPlacementIsNotAMove() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        // Dated today, never given a time.
        let item = slottedTodo(on: startOfDay(2026, 7, 20))
        context.insert(item)

        let monday2pm = cal.date(bySettingHour: 14, minute: 0, second: 0, of: startOfDay(2026, 7, 20))!
        _ = vm.apply(.scheduleTodoAt(itemID: item.id, start: monday2pm, minutes: 60), among: [item])

        #expect(records(item, .rescheduled).isEmpty)
    }

    @Test("an item that was never placed at all is not a reschedule")
    func neverPlacedIsNotAMove() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = ScheduleItem(title: "Someday", kind: .todo, createdAt: monday)
        context.insert(item)

        _ = vm.apply(.scheduleTodo(itemID: item.id, day: startOfDay(2026, 7, 22)), among: [item])
        #expect(records(item, .rescheduled).isEmpty)
    }

    /// An unslotted to-do that leaves its day *is* a push, even with no time.
    @Test("an unslotted to-do moved to another day is a reschedule")
    func unslottedDayMoveIsRecorded() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = slottedTodo(on: startOfDay(2026, 7, 20))
        context.insert(item)

        _ = vm.apply(.scheduleTodo(itemID: item.id, day: startOfDay(2026, 7, 22)), among: [item])

        let moved = records(item, .rescheduled)
        #expect(moved.count == 1)
        #expect(moved.first?.occurrenceDate == startOfDay(2026, 7, 20))
    }

    /// The count is the point: "you've moved this three times" has to mean three.
    @Test("repeated moves accumulate rather than collapsing to one record")
    func movesAccumulate() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = slottedTodo(on: startOfDay(2026, 7, 20), at: 9)
        context.insert(item)

        for dayOffset in 1...3 {
            let next = cal.date(bySettingHour: 9, minute: 0, second: 0,
                                of: startOfDay(2026, 7, 20 + dayOffset))!
            _ = vm.apply(.reschedule(itemID: item.id, newStart: next), among: [item])
        }
        #expect(records(item, .rescheduled).count == 3)
    }

    // MARK: Un-ticking must not erase history

    /// The hazard that made this a single commit: `removeCompletion` used to
    /// delete every record for the day, which was harmless while `.done` was
    /// the only status written and becomes silent data loss the moment it isn't.
    @Test("un-ticking removes only the completion, leaving the audit intact")
    func untickingPreservesHistory() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = slottedTodo(on: startOfDay(2026, 7, 20), at: 9)
        context.insert(item)

        // A move earlier in the day, then finished anyway, then taken back.
        let monday5pm = cal.date(bySettingHour: 17, minute: 0, second: 0, of: startOfDay(2026, 7, 20))!
        _ = vm.apply(.reschedule(itemID: item.id, newStart: monday5pm), among: [item])
        vm.toggleDone(item, on: monday)
        vm.toggleDone(item, on: monday)

        #expect(!vm.isDone(item, on: monday))
        #expect(records(item, .done).isEmpty)
        #expect(records(item, .rescheduled).count == 1)
    }

    // MARK: The sweep

    @Test("the sweep records past occurrences that closed unanswered")
    func sweepRecordsMisses() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        // Anchored well before the swept window. `recurrenceAnchor` is
        // `scheduledDate ?? createdAt` and `occurs` refuses any day before it,
        // so a routine dated today has no past to audit — correctly.
        let item = ScheduleItem(title: "Run", kind: .event,
                                scheduledDate: startOfDay(2026, 7, 1),
                                recurrence: .everyDay, createdAt: startOfDay(2026, 7, 1))
        context.insert(item)

        let written = vm.auditPastDays(from: [item], now: monday)
        #expect(written == 7)
        #expect(records(item, .skipped).count == 7)
        // Nothing was invented about today.
        #expect(!item.completions.contains { $0.occurrenceDate == startOfDay(2026, 7, 20) })
    }

    @Test("running the sweep twice writes nothing the second time")
    func sweepIsIdempotent() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        // Anchored well before the swept window. `recurrenceAnchor` is
        // `scheduledDate ?? createdAt` and `occurs` refuses any day before it,
        // so a routine dated today has no past to audit — correctly.
        let item = ScheduleItem(title: "Run", kind: .event,
                                scheduledDate: startOfDay(2026, 7, 1),
                                recurrence: .everyDay, createdAt: startOfDay(2026, 7, 1))
        context.insert(item)

        #expect(vm.auditPastDays(from: [item], now: monday) == 7)
        #expect(vm.auditPastDays(from: [item], now: monday) == 0)
        #expect(records(item, .skipped).count == 7)
    }

    /// The whole point of the commit: none of this is visible anywhere. Every
    /// reader in the app filters on `.done`, so a store full of audit records
    /// reads exactly as it did before.
    @Test("audit records are invisible to completion and consistency")
    func auditIsInvisible() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        // Anchored well before the swept window. `recurrenceAnchor` is
        // `scheduledDate ?? createdAt` and `occurs` refuses any day before it,
        // so a routine dated today has no past to audit — correctly.
        let item = ScheduleItem(title: "Run", kind: .event,
                                scheduledDate: startOfDay(2026, 7, 1),
                                recurrence: .everyDay, createdAt: startOfDay(2026, 7, 1))
        context.insert(item)
        _ = vm.auditPastDays(from: [item], now: monday)

        // Not done on any of the swept days.
        for offset in 1...7 {
            let past = cal.date(byAdding: .day, value: -offset, to: startOfDay(2026, 7, 20))!
            #expect(!vm.isDone(item, on: past))
        }

        // And the grid counts none of them as finished.
        let engine = ConsistencyEngine(calendar: cal)
        let days = engine.days(from: [item], weeks: 2, endingOn: monday)
        #expect(days.allSatisfy { $0.completed == 0 })
        #expect(engine.summary(for: days, asOf: monday).totalCompleted == 0)
    }
}

// MARK: - To-do grouping

/// The to-do list is grouped by scope and carries a finished-today section.
/// The date correctness of that section is the part worth pinning: a one-off's
/// `isCompleted` flag has no date on it, so the obvious implementation reports
/// something ticked off weeks ago as finished today.
@Suite("To-do grouping")
@MainActor
struct TodoGroupingTests {

    private func todo(_ title: String, _ scope: TodoScope) -> ScheduleItem {
        ScheduleItem(title: title, kind: .todo, todoScope: scope, createdAt: monday)
    }

    @Test("scope splits the active list into its two headings")
    func scopeSplits() {
        let vm = ScheduleViewModel()
        let items = [todo("Email", .today), todo("Learn to sail", .longTerm), todo("Bins", .today)]

        #expect(Set(vm.activeTodos(scope: .today, from: items, now: monday).map(\.title))
                == ["Email", "Bins"])
        #expect(vm.activeTodos(scope: .longTerm, from: items, now: monday).map(\.title)
                == ["Learn to sail"])
    }

    @Test("finished today lists what was ticked off today, most recent first")
    func finishedToday() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let first = todo("Email", .today)
        let second = todo("Bins", .today)
        context.insert(first); context.insert(second)

        vm.toggleDone(first, on: monday)
        vm.toggleDone(second, on: monday)

        let finished = vm.completedTodos(from: [first, second], now: monday).map(\.title)
        #expect(finished == ["Bins", "Email"])
    }

    /// The trap. `isDone` reads `isCompleted` for a one-off, which carries no
    /// date — so anything ever finished would show up as finished *today*.
    @Test("a to-do finished on another day is not listed as finished today")
    func finishedOnAnotherDayIsExcluded() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = todo("Renew passport", .today)
        context.insert(item)

        let lastWeek = cal.date(byAdding: .day, value: -7, to: monday)!
        vm.toggleDone(item, on: lastWeek)

        #expect(item.isCompleted)  // the flag really is set…
        #expect(vm.completedTodos(from: [item], now: monday).isEmpty)  // …and today's list is still empty
        #expect(vm.completedTodos(from: [item], now: lastWeek).map(\.title) == ["Renew passport"])
    }

    @Test("an unfinished to-do never appears in finished today")
    func unfinishedIsExcluded() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = todo("Email", .today)
        context.insert(item)
        #expect(vm.completedTodos(from: [item], now: monday).isEmpty)
    }
}
