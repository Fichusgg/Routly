//
//  ConsistencyEngine.swift
//  RoutineOrganizer
//
//  Turns the completion log into a per-day picture of how much actually got
//  done. Pure value-in/value-out over `[ScheduleItem]`, like the rest of the
//  engines here, so the grid it feeds can be unit-tested without SwiftData.
//
//  The number that drives the shading is *completions*, not a percentage: the
//  question this screen answers is "how much did I get done", and a day where
//  you finished four things should look busier than a day where you finished
//  one — even if the one-item day was technically 100%. The ratio is still
//  carried on each day so the detail line can be honest about both.
//

import Foundation

/// One day in the consistency grid.
struct DayConsistency: Identifiable, Hashable {
    /// Start of day.
    let date: Date
    /// How many occurrences the day held.
    let scheduled: Int
    /// How many of them were marked done.
    let completed: Int

    var id: Date { date }

    /// Nothing planned, nothing done — rendered as an empty cell rather than a
    /// failed one. A quiet Sunday isn't a missed day.
    var isEmpty: Bool { scheduled == 0 && completed == 0 }

    /// Planned something and finished none of it. Worth showing differently
    /// from a day with nothing on it.
    var isMissed: Bool { scheduled > 0 && completed == 0 }

    var fraction: Double {
        guard scheduled > 0 else { return completed > 0 ? 1 : 0 }
        return min(1, Double(completed) / Double(scheduled))
    }

    /// 0…4, driving how saturated the cell's green is. Fixed thresholds rather
    /// than a scale relative to the window, so the grid doesn't silently
    /// re-shade itself when one unusually busy day enters or leaves.
    var level: Int {
        switch completed {
        case 0: return 0
        case 1: return 1
        case 2: return 2
        case 3...4: return 3
        default: return 4
        }
    }
}

/// The headline numbers above the grid.
struct ConsistencySummary: Equatable {
    /// Consecutive weeks, up to and including this one, that reached the weekly
    /// bar. A week still in progress that hasn't reached it yet doesn't break
    /// the run — it simply isn't counted until it does, the same forgiveness
    /// the old daily rule extended to a still-empty today.
    ///
    /// Weeks rather than days on purpose. A daily chain has exactly one way to
    /// end and no way to survive an ordinary bad Tuesday, which is what turns
    /// it from "I want to do this" into "I can't miss today". A weekly bar of
    /// five makes two off days structural rather than a failure, so rest is
    /// part of the shape instead of damage to it.
    let currentWeeks: Int
    /// The longest run of bar-meeting weeks anywhere in the window.
    ///
    /// Kept beside `currentWeeks` so a broken run leaves evidence rather than
    /// collapsing to nothing. "Best: 6" is the part that survives a bad month,
    /// and seeing it next to a current 0 is what makes starting again cheap —
    /// the record is something you built, not something you just lost.
    let bestWeeks: Int
    /// Days in the window with at least one completion.
    let activeDays: Int
    /// Everything ticked off in the window.
    let totalCompleted: Int
    /// Completed ÷ scheduled across the window, or nil when nothing was ever
    /// scheduled (no honest rate to report).
    let completionRate: Double?
}

struct ConsistencyEngine {
    /// How many days in a week need something finished for that week to count.
    ///
    /// **Provisional — not a decided number.** Five-of-seven is a starting
    /// point pending real usage data; the bar is meant to end up the user's own
    /// ("3 days", "5 days", "every day"), which needs a stored preference and a
    /// picker, neither of which exists yet. It lives here as a named constant
    /// rather than a literal inside `summary` so that when the choice ships,
    /// the only thing that changes is where the value comes from.
    static let provisionalWeeklyBar = 5

    /// Set per-instance so a caller can pass the user's choice once there is
    /// one. Follows `SuggestionEngine.staleTodoDays` — a tunable on the struct,
    /// not a constant buried in the algorithm.
    var weeklyBar: Int = ConsistencyEngine.provisionalWeeklyBar

    var calendar: Calendar = ScheduleEngine().calendar
    private var schedule: ScheduleEngine { ScheduleEngine(calendar: calendar) }

    /// The days to render, oldest first, covering whole weeks so the grid's
    /// columns line up under their weekday labels.
    func days(from items: [ScheduleItem], weeks: Int, endingOn end: Date = Date()) -> [DayConsistency] {
        guard weeks > 0 else { return [] }

        let today = calendar.startOfDay(for: end)
        // Walk back to the start of the week `weeks - 1` weeks ago, so the last
        // column is the current (possibly partial) week.
        guard let thisWeekStart = startOfWeek(containing: today),
              let firstDay = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeekStart)
        else { return [] }

        let doneCounts = completionCounts(from: items)

        var result: [DayConsistency] = []
        var day = firstDay
        // Whole weeks: run to the end of the current week even though those days
        // are in the future — the view renders them as placeholders so the grid
        // stays rectangular.
        guard let lastDay = calendar.date(byAdding: .day, value: weeks * 7 - 1, to: firstDay) else { return [] }

        while day <= lastDay {
            let scheduled = day <= today ? items.filter { schedule.occurs($0, on: day) }.count : 0
            result.append(
                DayConsistency(
                    date: day,
                    scheduled: scheduled,
                    completed: doneCounts[day] ?? 0
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    func summary(for days: [DayConsistency], asOf now: Date = Date()) -> ConsistencySummary {
        let today = calendar.startOfDay(for: now)
        let past = days.filter { $0.date <= today }

        let activeDays = past.filter { $0.completed > 0 }.count
        let totalCompleted = past.reduce(0) { $0 + $1.completed }
        let totalScheduled = past.reduce(0) { $0 + $1.scheduled }

        // Deliberately over the whole window rather than `past`: the weeks are
        // read by position, and dropping the future tail of the current week
        // would shorten the last chunk without changing what it contains.
        let met = weeksMeetingBar(in: days)

        return ConsistencySummary(
            currentWeeks: currentRun(in: met),
            bestWeeks: longestRun(in: met),
            activeDays: activeDays,
            totalCompleted: totalCompleted,
            completionRate: totalScheduled > 0
                ? min(1, Double(totalCompleted) / Double(totalScheduled))
                : nil
        )
    }

    /// One flag per whole week in the window, oldest first: did that week reach
    /// the bar?
    ///
    /// `days(from:weeks:endingOn:)` already guarantees whole weeks aligned to
    /// the calendar's first weekday, so chunking by seven *is* the week
    /// boundary — there's no second pass of date arithmetic to get wrong, and
    /// the grid's columns and this calculation can't drift apart because
    /// they're reading the same array the same way.
    ///
    /// A day counts when *anything* was finished on it. That's the point of the
    /// micro rule: one thing closed at 11pm on a hard day is the habit
    /// surviving, and a bar that asks for more punishes precisely the days most
    /// worth protecting.
    private func weeksMeetingBar(in days: [DayConsistency]) -> [Bool] {
        // A bar outside 1...7 can't be satisfied or can't be missed; clamping
        // keeps a bad stored value from silently reading as "never consistent".
        let bar = min(max(weeklyBar, 1), 7)
        return stride(from: 0, to: days.count, by: 7).map { start in
            let week = days[start..<min(start + 7, days.count)]
            return week.filter { $0.completed > 0 }.count >= bar
        }
    }

    /// Counts back from the most recent week.
    ///
    /// The week in progress is stepped over rather than counted as a break when
    /// it hasn't reached the bar yet — there are still days left in it, and
    /// showing "0" on a Tuesday because Sunday hasn't happened is exactly the
    /// obligation framing this shape exists to avoid. It's the same forgiveness
    /// the daily rule gave a still-empty today, moved up one unit.
    private func currentRun(in met: [Bool]) -> Int {
        var index = met.count - 1
        if index >= 0 && !met[index] { index -= 1 }

        var run = 0
        while index >= 0 && met[index] {
            run += 1
            index -= 1
        }
        return run
    }

    /// The longest run anywhere in the window, including one still going.
    private func longestRun(in met: [Bool]) -> Int {
        var best = 0
        var run = 0
        for week in met {
            run = week ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    /// Done-completions per occurrence day, normalized to start of day.
    private func completionCounts(from items: [ScheduleItem]) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        for item in items {
            for completion in item.completions where completion.status == .done {
                let day = calendar.startOfDay(for: completion.occurrenceDate)
                counts[day, default: 0] += 1
            }
        }
        return counts
    }

    private func startOfWeek(containing date: Date) -> Date? {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps)
    }
}
