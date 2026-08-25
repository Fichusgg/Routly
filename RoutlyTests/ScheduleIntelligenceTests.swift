//
//  ScheduleIntelligenceTests.swift
//  RoutineOrganizerTests
//
//  Covers the conflict/overload detector and the heuristic suggestion engine.
//

import Testing
import Foundation
@testable import Routly

private let cal = Calendar(identifier: .gregorian)

/// Monday, 20 July 2026.
private let monday: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 20; c.hour = 8
    return cal.date(from: c)!
}()

private func at(_ hour: Int, _ minute: Int = 0, day: Date = monday) -> Date {
    cal.date(bySettingHour: hour, minute: minute, second: 0, of: cal.startOfDay(for: day))!
}

private func event(_ title: String, hour: Int, minute: Int = 0, minutes: Int = 60, day: Date = monday) -> ScheduleItem {
    let start = at(hour, minute, day: day)
    return ScheduleItem(
        title: title, kind: .event,
        scheduledDate: cal.startOfDay(for: day),
        startTime: start, durationMinutes: minutes, createdAt: monday
    )
}

@Suite("Conflict detection")
struct ConflictDetectionTests {
    let detector = ConflictDetector()

    @Test("overlapping events are flagged")
    func overlap() {
        let existing = event("Standup", hour: 9, minutes: 60)          // 9:00–10:00
        let candidate = event("Design review", hour: 9, minute: 30)    // 9:30–10:30
        let report = detector.report(for: candidate, against: [existing], on: monday)
        #expect(report.overlaps.map(\.title) == ["Standup"])
        #expect(report.hasConflict)
    }

    @Test("abutting events do not overlap")
    func abutting() {
        let existing = event("Standup", hour: 9, minutes: 60)          // 9:00–10:00
        let candidate = event("Sync", hour: 10, minutes: 30)           // 10:00–10:30
        let report = detector.report(for: candidate, against: [existing], on: monday)
        #expect(report.overlaps.isEmpty)
    }

    @Test("an alternative slot is suggested after the conflict")
    func alternativeAfterConflict() {
        let existing = event("Standup", hour: 9, minutes: 60)          // 9:00–10:00
        let candidate = event("Design review", hour: 9, minute: 30)    // clashes
        let alt = detector.alternative(for: candidate, against: [existing], on: monday)
        #expect(alt != nil)
        // First free 60-min slot at/after 9:30 that clears 9:00–10:00 is 10:00.
        #expect(alt?.start == at(10, 0))
        #expect(alt?.reason.contains("Standup") == true)
    }

    @Test("a day past the hour threshold reads as overloaded")
    func overload() {
        var detector = ConflictDetector()
        // A three-hour working day, entirely bookable — so the threshold is 3h.
        detector.preferences = SchedulingPreferences(
            workingHours: WorkingHours(startHour: 9, endHour: 12),
            maxLoadFraction: 1.0,
            maxTimedItemsPerDay: 10
        )
        let items = [event("A", hour: 9), event("B", hour: 11), event("C", hour: 13)] // 3h existing
        let candidate = event("D", hour: 15)                                          // +1h = 4h > 3
        let report = detector.report(for: candidate, against: items, on: monday)
        #expect(report.isOverloaded)
        #expect(report.scheduledHours == 4)
    }
}

@Suite("Suggestions")
struct SuggestionEngineTests {
    let engine = SuggestionEngine()

    @Test("back-to-back events with no buffer are surfaced")
    func backToBack() {
        let a = event("Standup", hour: 9, minutes: 60)   // ends 10:00
        let b = event("Review", hour: 10, minutes: 60)   // starts 10:00 — no gap
        let s = engine.suggestions(from: [a, b], now: monday)
        #expect(s.contains { $0.kind == .backToBack })
    }

    @Test("a stale to-do is surfaced after several days")
    func staleTodo() {
        let old = ScheduleItem(title: "File taxes", kind: .todo,
                               createdAt: cal.date(byAdding: .day, value: -5, to: monday)!)
        let fresh = ScheduleItem(title: "Water plants", kind: .todo, createdAt: monday)
        let s = engine.suggestions(from: [old, fresh], now: monday)
        let stale = s.filter { $0.kind == .staleTodo }
        #expect(stale.count == 1)
        #expect(stale.first?.message.contains("File taxes") == true)
    }

    @Test("an overloaded day next to an empty day suggests rebalancing")
    func imbalance() {
        var engine = SuggestionEngine()
        // A two-hour working day, entirely bookable — so the threshold is 2h.
        engine.preferences = SchedulingPreferences(
            workingHours: WorkingHours(startHour: 9, endHour: 11),
            maxLoadFraction: 1.0,
            maxTimedItemsPerDay: 10
        )
        // Monday packed (3h), the rest of the week empty.
        let items = [event("A", hour: 9), event("B", hour: 11), event("C", hour: 13)]
        let s = engine.suggestions(from: items, now: monday)
        #expect(s.contains { $0.kind == .dayImbalance })
    }
}

@Suite("Transcript assembly")
struct TranscriptAssemblyTests {

    @Test("growth is not a reset")
    func growth() {
        #expect(!TranscriptAssembly.isPartialReset(
            new: "buy milk and call mom", previous: "buy milk"))
    }

    @Test("an ordinary revision is not a reset")
    func revision() {
        // Same long prefix, engine corrected the tail.
        #expect(!TranscriptAssembly.isPartialReset(
            new: "buy milk and call mum", previous: "buy milk and call mom"))
    }

    @Test("a restart with unrelated shorter text is a reset")
    func restart() {
        // The engine dropped earlier context and began again — overwriting here
        // would erase everything said so far.
        #expect(TranscriptAssembly.isPartialReset(
            new: "pick up dry cleaning",
            previous: "buy milk and call mom about the weekend plans"))
    }

    @Test("an empty previous transcript is never a reset")
    func emptyPrevious() {
        #expect(!TranscriptAssembly.isPartialReset(new: "buy milk", previous: ""))
    }

    @Test("a trimmed prefix of the previous text is not a reset")
    func trimmed() {
        #expect(!TranscriptAssembly.isPartialReset(
            new: "buy milk", previous: "buy milk and call mom"))
    }
}

@Suite("Suggestion actions")
struct SuggestionActionTests {

    @Test("back-to-back suggestion offers a buffered new start")
    func backToBackAction() {
        let a = event("Standup", hour: 9, minutes: 60)   // ends 10:00
        let b = event("Review", hour: 10, minutes: 60)   // starts 10:00 — no gap
        let engine = SuggestionEngine()
        let suggestion = engine.suggestions(from: [a, b], now: monday)
            .first { $0.kind == .backToBack }

        // The *second* item moves, by the buffer, and never the first.
        #expect(suggestion?.action == .reschedule(itemID: b.id, newStart: at(10, 15)))
    }

    @Test("a stale to-do offers to be set for today")
    func staleTodoAction() {
        let old = ScheduleItem(title: "File taxes", kind: .todo,
                               createdAt: cal.date(byAdding: .day, value: -5, to: monday)!)
        let engine = SuggestionEngine()
        let suggestion = engine.suggestions(from: [old], now: monday)
            .first { $0.kind == .staleTodo }
        #expect(suggestion?.action == .scheduleTodo(itemID: old.id, day: cal.startOfDay(for: monday)))
    }

    @Test("a to-do already set for today is not flagged as stale")
    func staleTodoAlreadyToday() {
        let old = ScheduleItem(title: "File taxes", kind: .todo,
                               scheduledDate: cal.startOfDay(for: monday),
                               createdAt: cal.date(byAdding: .day, value: -5, to: monday)!)
        let engine = SuggestionEngine()
        #expect(!engine.suggestions(from: [old], now: monday).contains { $0.kind == .staleTodo })
    }

    @Test("optimize offers a slot for an unscheduled to-do")
    func optimizeFreeSlot() {
        // 09:00 reference time; 10:00–11:00 is busy, so the gap at 09:00 is free.
        let now = at(9, 0)
        let busy = event("Standup", hour: 10, minutes: 60)
        let todo = ScheduleItem(title: "Write summary", kind: .todo, createdAt: now)

        let engine = SuggestionEngine()
        let suggestion = engine.optimizeToday(from: [busy, todo], now: now)
            .first { $0.kind == .recommendation }

        #expect(suggestion != nil)
        if case let .scheduleTodoAt(itemID, start, minutes) = suggestion?.action {
            #expect(itemID == todo.id)
            // Proposed slot must not collide with the 10:00–11:00 block.
            #expect(start < at(10, 0) || start >= at(11, 0))
            // The block is reserved for a real length, not left notional.
            #expect((minutes ?? 0) > 0)
        } else {
            Issue.record("expected a scheduleTodoAt action")
        }
        // Every recommendation must be able to say why.
        #expect(suggestion?.reason?.isEmpty == false)
    }

    @Test("optimize proposes no slot when the day is already full")
    func optimizeNoRoom() {
        let now = at(9, 0)
        // Solid 09:00–21:00 wall of events.
        let wall = (9..<21).map { event("Busy \($0)", hour: $0, minutes: 60) }
        let todo = ScheduleItem(title: "Write summary", kind: .todo, createdAt: now)

        let engine = SuggestionEngine()
        let slots = engine.optimizeToday(from: wall + [todo], now: now).filter { $0.kind == .recommendation }
        #expect(slots.isEmpty)
    }
}

// MARK: - The day planner

/// A to-do with the knobs the planner actually reads.
private func todo(
    _ title: String,
    effort: Int? = nil,
    due: Date? = nil,
    created: Date = monday
) -> ScheduleItem {
    ScheduleItem(
        title: title, kind: .todo,
        effortMinutes: effort, dueDate: due.map { cal.startOfDay(for: $0) },
        createdAt: created
    )
}

private func day(_ offset: Int) -> Date {
    cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: monday))!
}

@Suite("Day planner — free time")
struct DayPlannerFreeTimeTests {
    let planner = DayPlanner()

    @Test("the morning doesn't exist once it's the afternoon")
    func startsFromNow() {
        let now = at(15, 30)
        let gaps = planner.freeGaps(from: [], now: now)
        // Everything offered must be after now, never a slot in the lost morning.
        #expect(gaps.allSatisfy { $0.start >= now })
        #expect(gaps.first?.start ?? now >= at(15, 30))
    }

    @Test("free time is only what's left, not the whole day")
    func remainingOnly() {
        // 16:00 on a clear day: at most an hour before the 17:00 cutoff.
        let plan = planner.plan(from: [], now: at(16, 0))
        #expect(plan.freeMinutes <= 60)
    }

    @Test("gaps form around fixed blocks, with a transition buffer")
    func gapsAroundEvents() {
        let now = at(9, 0)
        let standup = event("Standup", hour: 10, minutes: 60)   // 10:00–11:00
        let gaps = planner.freeGaps(from: [standup], now: now)

        // Nothing free may overlap the meeting itself.
        #expect(gaps.allSatisfy { $0.end <= at(10, 0) || $0.start >= at(11, 0) })
        // The gap before it stops short of 10:00 — you need a moment to switch.
        if let before = gaps.first(where: { $0.start < at(10, 0) }) {
            #expect(before.end < at(10, 0))
        }
    }

    @Test("a reminder costs attention even though it has no length")
    func reminderAttention() {
        let now = at(9, 0)
        let ping = ScheduleItem(
            title: "Take pills", kind: .reminder,
            scheduledDate: cal.startOfDay(for: monday),
            startTime: at(12, 0), createdAt: monday
        )
        let gaps = planner.freeGaps(from: [ping], now: now)
        // Noon itself is not free — the reminder interrupts.
        #expect(!gaps.contains { $0.start <= at(12, 0) && $0.end > at(12, 0) })
    }

    @Test("slivers of time are not offered as usable")
    func ignoresSlivers() {
        let now = at(9, 0)
        // Two meetings five minutes apart leave nothing worth starting.
        let a = event("A", hour: 10, minutes: 60)          // ends 11:00
        let b = event("B", hour: 11, minute: 5, minutes: 60)
        let gaps = planner.freeGaps(from: [a, b], now: now)
        #expect(!gaps.contains { $0.start >= at(11, 0) && $0.end <= at(11, 5) })
    }
}

@Suite("Day planner — recommendations")
struct DayPlannerRecommendationTests {
    let planner = DayPlanner()

    @Test("a big task is never squeezed into a small gap")
    func effortMustFitTheGap() {
        let now = at(9, 0)
        // Wall of meetings leaving exactly one 20-minute hole at 11:00.
        let a = event("A", hour: 9, minute: 15, minutes: 105)   // 09:15–11:00
        let b = event("B", hour: 11, minute: 20, minutes: 580)  // 11:20 onwards
        let big = todo("Write the report", effort: 120, due: monday)

        let plan = planner.plan(from: [a, b, big], now: now)
        #expect(plan.recommendations.isEmpty)
        // And it's said out loud rather than dropped.
        #expect(plan.unplaced.contains { $0.title == "Write the report" })
    }

    @Test("a task that doesn't fit explains itself in real terms")
    func unplacedExplains() {
        let now = at(9, 0)
        let wall = (9..<21).map { event("Busy \($0)", hour: $0, minutes: 60) }
        let due = todo("File taxes", effort: 90, due: monday)

        let plan = planner.plan(from: wall + [due], now: now)
        let unplaced = plan.unplaced.first { $0.title == "File taxes" }
        #expect(unplaced != nil)
        #expect(unplaced?.reason.contains("1h 30m") == true)
        // Due today and homeless — it gets an honest way out, not a dead end.
        if case .moveToTomorrowMorning = unplaced?.resolution {} else {
            Issue.record("a task due today that won't fit should offer tomorrow morning")
        }
    }

    @Test("a deadline outranks having sat on the list longer")
    func deadlineBeatsStaleness() {
        let now = at(9, 0)
        let urgent = todo("Submit invoice", effort: 30, due: monday, created: monday)
        let old = todo("Sort the loft", effort: 30, due: day(20), created: day(-14))

        let plan = planner.plan(from: [urgent, old], now: now)
        #expect(plan.recommendations.first?.title == "Submit invoice")
    }

    @Test("overdue outranks due today")
    func overdueFirst() {
        let now = at(9, 0)
        let dueToday = todo("Pay rent", effort: 30, due: monday)
        let overdue = todo("Return the parcel", effort: 30, due: day(-2))

        let plan = planner.plan(from: [dueToday, overdue], now: now)
        #expect(plan.recommendations.first?.title == "Return the parcel")
        #expect(plan.recommendations.first?.reason.contains("Overdue") == true)
    }

    @Test("the day is not filled to the brim")
    func leavesBreathingRoom() {
        let now = at(9, 0)
        // A clear day and far more work than time.
        let tasks = (0..<10).map { todo("Task \($0)", effort: 90, due: monday) }
        let plan = planner.plan(from: tasks, now: now)

        let planned = plan.recommendations.reduce(0) { $0 + $1.minutes }
        #expect(planned <= Int(Double(plan.freeMinutes) * 0.7))
    }

    @Test("something overdue goes as early as it fits, not where it packs neatly")
    func urgentGoesEarly() {
        let now = at(9, 0)
        // A snug 30-minute hole at 13:00 would be the tidier fit, but an
        // overdue task should start at the first opportunity instead.
        let block = event("Afternoon block", hour: 13, minute: 35, minutes: 300)
        let overdue = todo("Return the parcel", effort: 30, due: day(-1))

        let plan = DayPlanner().plan(from: [block, overdue], now: now)
        #expect(plan.recommendations.first?.start ?? at(23, 0) < at(11, 0))
    }

    @Test("one big task still gets offered on a nearly-full day")
    func breathingRoomNeverMeansSilence() {
        // 15:00, so only ~2h of the working day remain — a 90-minute job is past
        // the 70% mark but is still the single most useful thing to say.
        let now = at(15, 0)
        let big = todo("Finish the deck", effort: 90, due: monday)
        let plan = DayPlanner().plan(from: [big], now: now)
        #expect(plan.recommendations.first?.title == "Finish the deck")
    }

    @Test("no more than a handful of recommendations")
    func staysChoosable() {
        let now = at(9, 0)
        let tasks = (0..<20).map { todo("Task \($0)", effort: 10, due: monday) }
        let plan = planner.plan(from: tasks, now: now)
        #expect(plan.recommendations.count <= 5)
    }

    @Test("recommendations never overlap each other")
    func placementsDontCollide() {
        let now = at(9, 0)
        let tasks = (0..<5).map { todo("Task \($0)", effort: 60, due: monday) }
        let plan = planner.plan(from: tasks, now: now)

        let ordered = plan.recommendations.sorted { $0.start < $1.start }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            #expect(a.end <= b.start)
        }
    }

    @Test("an unstated size is estimated and flagged as a guess")
    func estimatesAreLabelled() {
        let now = at(9, 0)
        let vague = todo("Call the dentist", due: monday)          // no effort given
        let stated = todo("Write the brief", effort: 45, due: monday)

        let plan = planner.plan(from: [vague, stated], now: now)
        #expect(plan.recommendations.first { $0.title == "Call the dentist" }?.effortIsGuess == true)
        #expect(plan.recommendations.first { $0.title == "Write the brief" }?.effortIsGuess == false)
    }

    @Test("a to-do already slotted today isn't recommended again")
    func skipsAlreadyPlaced() {
        let now = at(9, 0)
        let placed = ScheduleItem(
            title: "Write summary", kind: .todo,
            scheduledDate: cal.startOfDay(for: monday),
            startTime: at(14, 0), durationMinutes: 60,
            createdAt: monday
        )
        let plan = DayPlanner().plan(from: [placed], now: now)
        #expect(!plan.recommendations.contains { $0.title == "Write summary" })
    }

    @Test("a completed to-do is left alone")
    func skipsCompleted() {
        let now = at(9, 0)
        let done = ScheduleItem(title: "Buy milk", kind: .todo, isCompleted: true, createdAt: monday)
        let plan = DayPlanner().plan(from: [done], now: now)
        #expect(plan.recommendations.isEmpty)
    }

    @Test("every recommendation carries a reason")
    func alwaysExplains() {
        let now = at(9, 0)
        let tasks = [
            todo("Overdue thing", effort: 30, due: day(-1)),
            todo("Due today", effort: 30, due: monday),
            todo("Due tomorrow", effort: 30, due: day(1)),
            todo("Undated", effort: 30, created: day(-5)),
        ]
        let plan = DayPlanner().plan(from: tasks, now: now)
        #expect(!plan.recommendations.isEmpty)
        #expect(plan.recommendations.allSatisfy { !$0.reason.isEmpty })
    }

    @Test("nothing is proposed to start in the seconds you're reading it")
    func respectsStartGrace() {
        let now = at(13, 37)
        let task = todo("Quick call", effort: 10, due: monday)
        let plan = DayPlanner().plan(from: [task], now: now)
        #expect(plan.recommendations.allSatisfy { $0.start > now })
    }
}

@Suite("Effort estimation")
struct EffortEstimatorTests {
    let estimator = EffortEstimator()

    @Test("a stated size always wins over a guess")
    func statedWins() {
        let item = todo("Write the annual report", effort: 20)
        let estimate = estimator.estimate(for: item)
        #expect(estimate.minutes == 20)
        #expect(estimate.isStated)
    }

    @Test("a quick errand reads shorter than a big job")
    func shapeOfTheTitle() {
        #expect(estimator.infer(from: "Call mom") < estimator.infer(from: "Write the quarterly report"))
    }

    @Test("an unknown task gets a sane default rather than nothing")
    func fallback() {
        let estimate = estimator.estimate(for: todo("Xyzzy"))
        #expect(estimate.minutes > 0)
        #expect(estimate.isGuess)
    }
}
