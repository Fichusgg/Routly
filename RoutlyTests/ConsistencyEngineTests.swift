//
//  ConsistencyEngineTests.swift
//  RoutineOrganizerTests
//
//  Covers the per-day consistency roll-up behind the dot grid: how days are
//  bucketed, how the shading level is derived, and the streak rule that lets a
//  still-empty today off the hook.
//

import Testing
import Foundation
@testable import Routly

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.firstWeekday = 1
    return c
}()

/// Wednesday, 15 July 2026 — the "today" every case below is measured against.
private let today: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 15
    return cal.startOfDay(for: cal.date(from: c)!)
}()

private func day(_ offset: Int) -> Date {
    cal.date(byAdding: .day, value: offset, to: today)!
}

/// A daily routine, so it occurs on every day in the window.
private func routine(_ title: String, createdDaysAgo: Int = 60) -> ScheduleItem {
    ScheduleItem(
        title: title,
        kind: .reminder,
        recurrence: RecurrenceRule(frequency: .daily),
        createdAt: day(-createdDaysAgo)
    )
}

/// Marks `item` done on the given day, the same way the view model does.
private func complete(_ item: ScheduleItem, on date: Date) {
    item.completions.append(
        Completion(occurrenceDate: cal.startOfDay(for: date), completedAt: date, status: .done, item: item)
    )
}

private let engine = ConsistencyEngine(calendar: cal)

@Suite("Consistency grid")
struct ConsistencyGridTests {

    @Test("the window covers whole weeks so the grid stays rectangular")
    func wholeWeeks() {
        let days = engine.days(from: [], weeks: 4, endingOn: today)
        #expect(days.count == 28)
        // Every row starts on the calendar's first weekday.
        #expect(cal.component(.weekday, from: days[0].date) == cal.firstWeekday)
    }

    @Test("completions are counted against the day they were for")
    func countsPerDay() {
        let item = routine("Stretch")
        complete(item, on: day(-1))
        complete(item, on: day(-1))   // two things finished that day
        complete(item, on: day(-3))

        let days = engine.days(from: [item], weeks: 4, endingOn: today)
        let byDate = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })

        #expect(byDate[day(-1)]?.completed == 2)
        #expect(byDate[day(-3)]?.completed == 1)
        #expect(byDate[day(-2)]?.completed == 0)
    }

    @Test("future days in the current week carry no schedule")
    func futureDaysAreBlank() {
        let item = routine("Stretch")
        let days = engine.days(from: [item], weeks: 2, endingOn: today)
        let future = days.filter { $0.date > today }
        // The routine occurs daily, but days past today must not be counted as
        // scheduled — otherwise the rest of the week reads as already missed.
        #expect(future.allSatisfy { $0.scheduled == 0 && $0.completed == 0 })
    }

    @Test("a day with nothing planned is empty, not missed")
    func emptyVersusMissed() {
        let nothingPlanned = DayConsistency(date: day(-1), scheduled: 0, completed: 0)
        #expect(nothingPlanned.isEmpty)
        #expect(!nothingPlanned.isMissed)

        let plannedNothingDone = DayConsistency(date: day(-1), scheduled: 3, completed: 0)
        #expect(!plannedNothingDone.isEmpty)
        #expect(plannedNothingDone.isMissed)
    }

    @Test("shading level rises with the number finished")
    func levels() {
        func level(_ completed: Int) -> Int {
            DayConsistency(date: today, scheduled: 10, completed: completed).level
        }
        #expect(level(0) == 0)
        #expect(level(1) == 1)
        #expect(level(2) == 2)
        #expect(level(3) == 3)
        #expect(level(4) == 3)
        #expect(level(5) == 4)
        #expect(level(12) == 4)
    }
}

@Suite("Consistency summary")
struct ConsistencySummaryTests {

    // The record is measured in weeks, so these cases are laid out against the
    // window's week boundaries rather than against loose day offsets. `today` is
    // Wednesday 15 July 2026 and the calendar's first weekday is Sunday, which
    // puts the four whole weeks of a `weeks: 4` window at:
    //
    //   index 0  offsets -24…-18   21–27 Jun
    //   index 1  offsets -17…-11   28 Jun – 4 Jul
    //   index 2  offsets -10…-4    5–11 Jul        (last complete week)
    //   index 3  offsets  -3…+3    12–18 Jul       (the week in progress)
    //
    // Only four days of the current week have happened by Wednesday, so with
    // the provisional bar of five it cannot be met yet — which is exactly the
    // situation the forgiveness rule exists for.

    @Test("a week that reaches the bar counts toward the record")
    func weekMeetingBarCounts() {
        let item = routine("Stretch")
        for offset in [-10, -9, -8, -7, -6] { complete(item, on: day(offset)) }

        let days = engine.days(from: [item], weeks: 4, endingOn: today)
        let summary = engine.summary(for: days, asOf: today)
        #expect(summary.currentWeeks == 1)
        #expect(summary.bestWeeks == 1)
    }

    @Test("a week that falls short of the bar doesn't count")
    func weekUnderBarDoesNotCount() {
        let item = routine("Stretch")
        // Four days, one short of the provisional bar of five.
        for offset in [-10, -9, -8, -7] { complete(item, on: day(offset)) }

        let days = engine.days(from: [item], weeks: 4, endingOn: today)
        let summary = engine.summary(for: days, asOf: today)
        #expect(summary.currentWeeks == 0)
        #expect(summary.bestWeeks == 0)
    }

    /// The heart of the weekly shape: a Wednesday with two days done cannot have
    /// reached a bar of five yet, and must not therefore read as a break. This
    /// is the old "an empty today doesn't break it" rule, moved up one unit.
    @Test("the week in progress never breaks the run")
    func partialWeekIsForgiven() {
        let item = routine("Stretch")
        for offset in [-10, -9, -8, -7, -6] { complete(item, on: day(offset)) }
        // Under way this week, nowhere near the bar.
        for offset in [-2, -1] { complete(item, on: day(offset)) }

        let days = engine.days(from: [item], weeks: 4, endingOn: today)
        #expect(engine.summary(for: days, asOf: today).currentWeeks == 1)
    }

    @Test("a week in progress that has already reached the bar counts straight away")
    func partialWeekCountsOnceMet() {
        let lowBar = ConsistencyEngine(weeklyBar: 3, calendar: cal)
        let item = routine("Stretch")
        for offset in [-10, -9, -8] { complete(item, on: day(offset)) }
        for offset in [-3, -2, -1] { complete(item, on: day(offset)) }

        let days = lowBar.days(from: [item], weeks: 4, endingOn: today)
        #expect(lowBar.summary(for: days, asOf: today).currentWeeks == 2)
    }

    /// A broken run has to leave the evidence behind — that's the whole reason
    /// `bestWeeks` exists rather than the record collapsing to nothing.
    @Test("the best run survives a break that resets the current one")
    func bestSurvivesABreak() {
        let item = routine("Stretch")
        for offset in [-24, -23, -22, -21, -20] { complete(item, on: day(offset)) }
        for offset in [-17, -16, -15, -14, -13] { complete(item, on: day(offset)) }
        // The last complete week is empty, so the current run is over.

        let days = engine.days(from: [item], weeks: 4, endingOn: today)
        let summary = engine.summary(for: days, asOf: today)
        #expect(summary.currentWeeks == 0)
        #expect(summary.bestWeeks == 2)
    }

    /// The micro rule. Finishing one of the day's two things still keeps the
    /// day — a bar that asked for more would punish the hardest days hardest.
    @Test("one thing finished is enough for a day to count toward the bar")
    func oneCompletionCarriesTheDay() {
        let done = routine("Stretch")
        let untouched = routine("Read")
        for offset in [-10, -9, -8, -7, -6] { complete(done, on: day(offset)) }

        let days = engine.days(from: [done, untouched], weeks: 4, endingOn: today)
        let summary = engine.summary(for: days, asOf: today)
        #expect(summary.currentWeeks == 1)
        // Two routines occurred every day, so this is emphatically not a
        // full-adherence week — and it still counts.
        #expect((summary.completionRate ?? 1) < 0.5)
    }

    @Test("a bar outside 1...7 is clamped rather than making the record meaningless")
    func barIsClamped() {
        let item = routine("Stretch")

        // A zero bar would otherwise make every week count automatically,
        // including four entirely empty ones.
        let zeroBar = ConsistencyEngine(weeklyBar: 0, calendar: cal)
        let emptyDays = zeroBar.days(from: [item], weeks: 4, endingOn: today)
        #expect(zeroBar.summary(for: emptyDays, asOf: today).bestWeeks == 0)

        // Clamped down to seven, so a fully-completed week still counts.
        let impossibleBar = ConsistencyEngine(weeklyBar: 99, calendar: cal)
        for offset in (-10)...(-4) { complete(item, on: day(offset)) }
        let fullDays = impossibleBar.days(from: [item], weeks: 4, endingOn: today)
        #expect(impossibleBar.summary(for: fullDays, asOf: today).currentWeeks == 1)
    }

    @Test("totals and follow-through cover only days that have happened")
    func totals() throws {
        let item = routine("Stretch")
        complete(item, on: day(-1))
        complete(item, on: day(-2))

        let days = engine.days(from: [item], weeks: 2, endingOn: today)
        let summary = engine.summary(for: days, asOf: today)

        #expect(summary.totalCompleted == 2)
        #expect(summary.activeDays == 2)
        // The routine occurs every past day in the window, so the rate is well
        // under 100% — and must never exceed it.
        let rate = try #require(summary.completionRate)
        #expect(rate > 0 && rate < 1)
    }

    @Test("follow-through is nil when nothing was ever scheduled")
    func noRateWithoutSchedule() {
        let days = engine.days(from: [], weeks: 2, endingOn: today)
        #expect(engine.summary(for: days, asOf: today).completionRate == nil)
    }
}
