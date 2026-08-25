//
//  ScheduleEngine.swift
//  RoutineOrganizer
//
//  Pure scheduling logic, kept free of SwiftData and UI so it stays unit
//  testable. Phase 1 uses it to expand recurring routines into per-day
//  occurrences for the schedule view; Phases 4/5 grow adherence and pattern
//  detection here. Deliberately a plain struct of value-in/value-out functions.
//

import Foundation

struct ScheduleEngine {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1
        return c
    }()

    /// Whether a given item has an occurrence on `day`.
    /// - One-off tasks occur on their `scheduledDate`.
    /// - Routines occur per their recurrence rule. `timesPerWeek` routines have
    ///   no fixed days, so they are treated as "available any day this week"
    ///   and surfaced every day until the weekly target is met (the view layer
    ///   decides how to present that).
    /// - A routine that has been trimmed ("delete this and all future") stops at
    ///   its end date, and days lifted out of the series don't occur at all.
    func occurs(_ item: ScheduleItem, on day: Date) -> Bool {
        let day = calendar.startOfDay(for: day)

        guard let rule = item.recurrence else {
            guard let scheduled = item.scheduledDate else { return false }
            return calendar.isDate(scheduled, inSameDayAs: day)
        }

        // A routine doesn't occur before it was created.
        let anchor = item.recurrenceAnchor(calendar)
        guard day >= anchor else { return false }

        if let end = item.recurrenceEndDate, day > calendar.startOfDay(for: end) { return false }
        if item.skips(day, calendar: calendar) { return false }

        switch rule.frequency {
        case .daily:
            guard rule.interval > 1 else { return true }
            let days = calendar.dateComponents([.day], from: anchor, to: day).day ?? 0
            return days % rule.interval == 0
        case .weekly:
            let weekday = calendar.component(.weekday, from: day)
            return rule.weekdays.contains(weekday)
        case .timesPerWeek:
            return true
        }
    }

    /// All occurrence days for an item within `interval` (inclusive of both ends).
    func occurrences(of item: ScheduleItem, in interval: DateInterval) -> [Date] {
        var results: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        let end = calendar.startOfDay(for: interval.end)
        while day <= end {
            if occurs(item, on: day) { results.append(day) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return results
    }

    // Deliberately no per-item streak here.
    //
    // There used to be a `currentStreak(for:asOf:)` — a rigid consecutive-day
    // count per routine, with no caller but its own test. It was removed while
    // it was still inert rather than left to be rediscovered and wired into a
    // screen, because a daily chain is the mechanic the app's anti-goals rule
    // out: it has one way to end and no way to survive an ordinary bad day, so
    // it drifts from "I want to do this" into "I can't miss today".
    //
    // Consistency is measured in weeks against a bar that a rest day fits
    // inside — see `ConsistencyEngine.currentWeeks`/`bestWeeks`. If something
    // needs a per-item version later, it should be the weekly shape, not this
    // one restored.
}
