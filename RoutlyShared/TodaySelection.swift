//
//  TodaySelection.swift
//  RoutineOrganizerShared
//
//  What's on today, and in what order — for both processes.
//
//  Lifted out of `ScheduleViewModel` for the same reason `CompletionWriter` was:
//  the widget has to show the *same* to-dos, in the *same* order, as the screen
//  it mirrors. A second implementation would agree at first and drift on the
//  first change to either — and a home-screen widget that lists a different top
//  three than the app is worse than no widget, because it quietly teaches the
//  user not to trust it.
//
//  Pure functions over plain arrays: no SwiftData fetching, no observation, no
//  view model. That's what lets the same code serve a `@Query` in the app and a
//  one-shot fetch in a timeline provider, and what makes every rule below
//  testable without a store.
//

import Foundation

struct TodaySelection {

    let calendar: Calendar
    let engine: ScheduleEngine

    init(engine: ScheduleEngine = ScheduleEngine()) {
        self.engine = engine
        self.calendar = engine.calendar
    }

    // MARK: - To-dos

    /// The rolling checklist: incomplete to-dos that have come due (undated or
    /// dated on/before today) roll forward until checked; recurring to-dos show
    /// on days they occur and aren't yet done. Completed ones drop out, and so
    /// do ones already slotted into the schedule — a task shouldn't be listed
    /// twice on one screen.
    func activeTodos(from items: [ScheduleItem], now: Date = Date()) -> [ScheduleItem] {
        let today = calendar.startOfDay(for: now)
        let writer = CompletionWriter(calendar: calendar)
        return items
            .filter { item in
                guard item.kind == .todo else { return false }
                guard !isSlottedToday(item, today: today) else { return false }
                if item.recurrence != nil {
                    return engine.occurs(item, on: today) && !writer.isDone(item, on: today)
                }
                guard !item.isCompleted else { return false }
                if let due = item.scheduledDate {
                    return calendar.startOfDay(for: due) <= today
                }
                return true // undated to-do rolls indefinitely
            }
            .sorted(by: todoComparator)
    }

    /// The to-dos under the built-in heading — everything not filed under a
    /// user-made list.
    ///
    /// This is what the app's first group holds. Expressed here rather than as a
    /// filter at each call site so that "the Today group" has one definition; if
    /// lists ever change how they nest, the widget follows without being touched.
    func unfiledTodos(from items: [ScheduleItem], now: Date = Date()) -> [ScheduleItem] {
        todos(from: items, inList: nil, now: now)
    }

    /// The to-dos under one heading, which is either a named list or the
    /// built-in group.
    ///
    /// `listID` nil means the built-in group, matching how `ScheduleItem.list`
    /// stores it: "no list" is a real state, not a missing one. Both cases go
    /// through `activeTodos` first, so a filed to-do is filtered by exactly the
    /// same rules — due, not done, not already slotted — as an unfiled one.
    func todos(from items: [ScheduleItem], inList listID: UUID?, now: Date = Date()) -> [ScheduleItem] {
        activeTodos(from: items, now: now).filter { item in
            guard let listID else { return item.list == nil }
            return item.list?.id == listID
        }
    }

    /// A hand-arranged order wins over every automatic rule below it: the user
    /// has said where these go. Items never dragged keep the automatic order and
    /// sit after the arranged ones.
    func todoComparator(_ a: ScheduleItem, _ b: ScheduleItem) -> Bool {
        switch (a.todoSortIndex, b.todoSortIndex) {
        case let (x?, y?): if x != y { return x < y }
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): break
        }
        if a.todoScope.rank != b.todoScope.rank { return a.todoScope.rank < b.todoScope.rank }
        if a.priority.rank != b.priority.rank { return a.priority.rank < b.priority.rank }
        return (a.scheduledDate ?? a.createdAt) < (b.scheduledDate ?? b.createdAt)
    }

    /// A to-do that holds an actual time on `today`.
    func isSlottedToday(_ item: ScheduleItem, today: Date) -> Bool {
        guard item.kind == .todo, let start = item.startTime else { return false }
        return calendar.isDate(start, inSameDayAs: today)
    }

    // MARK: - Timed items

    /// The timed part of a day, ordered by time: events and reminders always,
    /// plus any to-do that's been given a real slot.
    func timed(from items: [ScheduleItem], on day: Date = Date()) -> [ScheduleItem] {
        let dayStart = calendar.startOfDay(for: day)
        return items
            .filter { item in
                guard engine.occurs(item, on: dayStart) else { return false }
                guard item.kind == .todo else { return true }
                return isSlottedToday(item, today: dayStart)
            }
            .sorted(by: timeComparator)
    }

    func timeComparator(_ a: ScheduleItem, _ b: ScheduleItem) -> Bool {
        switch (a.startTime, b.startTime) {
        case let (x?, y?): return x < y
        case (nil, _?): return false   // timed items first
        case (_?, nil): return true
        case (nil, nil): return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}
