//
//  CompletionAuditTests.swift
//  RoutineOrganizerTests
//
//  Covers which past occurrences count as unanswered. The interesting cases are
//  all exclusions: this engine's job is as much about what it refuses to report
//  as what it finds, because every false positive here becomes a permanent,
//  wrong entry in a history that's meant to be read months later.
//

import Testing
import Foundation
@testable import Routly

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.firstWeekday = 1
    return c
}()

/// Wednesday, 15 July 2026.
private let today: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 15
    return cal.startOfDay(for: cal.date(from: c)!)
}()

private func day(_ offset: Int) -> Date {
    cal.date(byAdding: .day, value: offset, to: today)!
}

private func routine(_ title: String) -> ScheduleItem {
    ScheduleItem(
        title: title,
        kind: .reminder,
        recurrence: RecurrenceRule(frequency: .daily),
        createdAt: day(-60)
    )
}

private func stamp(_ item: ScheduleItem, _ status: Completion.Status, on date: Date) {
    item.completions.append(
        Completion(occurrenceDate: cal.startOfDay(for: date), status: status, item: item)
    )
}

private let audit = CompletionAudit(calendar: cal)

@Suite("Completion audit")
struct CompletionAuditTests {

    @Test("a past occurrence with no record at all is reported")
    func unansweredDayIsReported() {
        let item = routine("Stretch")
        let missed = audit.missedOccurrences(in: [item], asOf: today)

        // Seven days back, none of them answered.
        #expect(missed.count == 7)
        #expect(missed.allSatisfy { $0.item === item })
        // Oldest first.
        #expect(missed.first?.day == cal.startOfDay(for: day(-7)))
        #expect(missed.last?.day == cal.startOfDay(for: day(-1)))
    }

    /// The day isn't over. Nothing is missed until it is — this is the same
    /// forgiveness the consistency record extends to a week in progress.
    @Test("today is never reported, however empty it is")
    func todayIsNeverMissed() {
        let item = routine("Stretch")
        let missed = audit.missedOccurrences(in: [item], asOf: today)
        #expect(!missed.contains { $0.day == today })
    }

    @Test("a day that was completed is not reported")
    func doneDayIsAnswered() {
        let item = routine("Stretch")
        stamp(item, .done, on: day(-2))

        let missed = audit.missedOccurrences(in: [item], asOf: today)
        #expect(!missed.contains { $0.day == cal.startOfDay(for: day(-2)) })
        #expect(missed.count == 6)
    }

    /// Idempotency, which is what makes it safe to run on every appearance.
    @Test("a day already marked skipped is not reported again")
    func skippedDayIsNotDoubleCounted() {
        let item = routine("Stretch")
        stamp(item, .skipped, on: day(-2))

        let missed = audit.missedOccurrences(in: [item], asOf: today)
        #expect(!missed.contains { $0.day == cal.startOfDay(for: day(-2)) })
    }

    /// A day the user explicitly moved something off has already been answered.
    /// Counting it as a silent miss as well would record one slip twice.
    @Test("a day something was rescheduled off is not also a miss")
    func rescheduledDayIsAnswered() {
        let item = routine("Stretch")
        stamp(item, .rescheduled, on: day(-3))

        let missed = audit.missedOccurrences(in: [item], asOf: today)
        #expect(!missed.contains { $0.day == cal.startOfDay(for: day(-3)) })
    }

    /// The anti-guilt guarantee, and the single most important case in the file.
    /// An undated to-do rolling forward is the rolling checklist working as
    /// designed; writing a miss for every day it sits there would manufacture
    /// precisely the guilt the app rules out — and would drown the real signal.
    @Test("an undated to-do is never reported, however long it has rolled")
    func undatedTodoIsNeverMissed() {
        let todo = ScheduleItem(title: "Email the landlord", kind: .todo, createdAt: day(-30))
        let missed = audit.missedOccurrences(in: [todo], asOf: today)
        #expect(missed.isEmpty)
    }

    /// A to-do that was given a day and didn't get done on it, however, is a
    /// genuine slip and does get recorded.
    @Test("a dated to-do that came and went is reported")
    func datedTodoIsMissed() {
        let todo = ScheduleItem(
            title: "Renew passport",
            kind: .todo,
            scheduledDate: cal.startOfDay(for: day(-2)),
            createdAt: day(-10)
        )
        let missed = audit.missedOccurrences(in: [todo], asOf: today)
        #expect(missed.count == 1)
        #expect(missed.first?.day == cal.startOfDay(for: day(-2)))
    }

    @Test("the sweep is bounded by the backfill window")
    func windowIsBounded() {
        var short = CompletionAudit(calendar: cal)
        short.backfillDays = 2
        let item = routine("Stretch")

        let missed = short.missedOccurrences(in: [item], asOf: today)
        #expect(missed.count == 2)
        #expect(missed.map(\.day) == [day(-2), day(-1)].map { cal.startOfDay(for: $0) })
    }

    @Test("a zero-day window sweeps nothing")
    func emptyWindow() {
        var none = CompletionAudit(calendar: cal)
        none.backfillDays = 0
        #expect(none.missedOccurrences(in: [routine("Stretch")], asOf: today).isEmpty)
    }

    /// The seam the plate rule will eventually come in through: membership is
    /// injected, so replacing "what occurred" with "what was on the plate"
    /// changes one argument rather than this engine.
    @Test("membership is injectable, so the plate rule can replace occurrence")
    func membershipIsInjectable() {
        let item = routine("Stretch")
        // A rule that counts only the day before yesterday.
        let missed = audit.missedOccurrences(in: [item], asOf: today) { _, candidate in
            cal.isDate(candidate, inSameDayAs: day(-2))
        }
        #expect(missed.count == 1)
        #expect(missed.first?.day == cal.startOfDay(for: day(-2)))
    }
}
