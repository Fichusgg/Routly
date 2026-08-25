//
//  RoutineOrganizerTests.swift
//  RoutineOrganizerTests
//
//  Phase 0 coverage for the rule-based parser and the scheduling engine.
//  A fixed `now` (Monday, 2026-07-20) keeps relative-date parsing deterministic.
//

import Testing
import Foundation
@testable import Routly

private let calendar = Calendar(identifier: .gregorian)

/// Monday, 20 July 2026, 08:00.
private let referenceNow: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 7; c.day = 20; c.hour = 8
    return calendar.date(from: c)!
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    calendar.startOfDay(for: DateComponents(calendar: calendar, year: year, month: month, day: dayOfMonth).date!)
}

@Suite("Stub parser")
struct StubParserTests {
    let parser = StubAIParsingService()

    /// Most cases capture a single item; this returns the first parsed result.
    private func firstParse(_ text: String, now: Date) async -> ParsedCapture {
        await parser.parse(text, now: now).first ?? ParsedCapture(title: "", sourceText: text)
    }

    @Test("relative date + named time + title cleanup")
    func callMomTomorrowEvening() async {
        let r = await firstParse("remind me to call mom tomorrow evening", now: referenceNow)
        #expect(r.title == "Call mom")
        #expect(r.category == .personal)
        #expect(r.scheduledDate == day(2026, 7, 21))
        let comps = calendar.dateComponents([.hour], from: r.startTime!)
        #expect(comps.hour == 19)
        #expect(r.recurrence == nil)
    }

    @Test("times-per-week recurrence + health category")
    func gymThreeTimes() async {
        let r = await firstParse("gym 3x this week", now: referenceNow)
        #expect(r.category == .health)
        #expect(r.recurrence == .timesPerWeek(3))
        #expect(r.title == "Gym")
    }

    @Test("explicit clock time + duration + work category")
    func meetingAtThree() async {
        let r = await firstParse("meeting at 3pm for 30 min", now: referenceNow)
        #expect(r.category == .work)
        #expect(r.durationMinutes == 30)
        let comps = calendar.dateComponents([.hour, .minute], from: r.startTime!)
        #expect(comps.hour == 15)
        #expect(comps.minute == 0)
        #expect(r.title == "Meeting")
    }

    @Test("daily recurrence")
    func runEveryDay() async {
        let r = await firstParse("run every day", now: referenceNow)
        #expect(r.recurrence == .everyDay)
        #expect(r.category == .health)
        #expect(r.title == "Run")
    }

    @Test("weekly-by-weekday recurrence with a clock time")
    func standupEveryMonday() async {
        let r = await firstParse("team standup every monday at 9am", now: referenceNow)
        #expect(r.recurrence == .weekly(on: [2]))
        #expect(r.category == .work)
        let comps = calendar.dateComponents([.hour], from: r.startTime!)
        #expect(comps.hour == 9)
        // A recurring routine is not pinned to a single weekday date.
        #expect(r.scheduledDate == nil)
    }

    @Test("weekdays keyword maps to Mon–Fri")
    func weekdaysRoutine() async {
        let r = await firstParse("standup every weekday at 10am", now: referenceNow)
        #expect(r.recurrence?.frequency == .weekly)
        #expect(r.recurrence?.weekdays == [2, 3, 4, 5, 6])
    }

    @Test("'next friday' resolves to the following week")
    func nextFriday() async {
        let r = await firstParse("dentist next friday", now: referenceNow)
        // From Mon Jul 20: this Friday is Jul 24, so "next Friday" is Jul 31.
        #expect(r.scheduledDate == day(2026, 7, 31))
        #expect(r.category == .health)
    }

    @Test("24-hour clock + hour duration")
    func hourDuration() async {
        let r = await firstParse("deep work at 15:00 for 1 hour", now: referenceNow)
        let comps = calendar.dateComponents([.hour, .minute], from: r.startTime!)
        #expect(comps.hour == 15)
        #expect(comps.minute == 0)
        #expect(r.durationMinutes == 60)
    }

    @Test("empty input yields no items")
    func emptyInput() async {
        #expect(await parser.parse("   ", now: referenceNow).isEmpty)
    }

    @Test("a list splits into multiple items")
    func multiItemSplit() async {
        let items = await parser.parse("buy milk, gym 3x this week, and call the dentist", now: referenceNow)
        #expect(items.count == 3)
        #expect(items.contains { $0.title == "Buy milk" })
        #expect(items.contains { $0.recurrence == .timesPerWeek(3) })
        #expect(items.contains { $0.title.contains("dentist") })
    }

    @Test("a wordy voice phrase yields a short clean title")
    func voiceStyleTitleCleanup() async {
        let r = await firstParse("remind me to call mom around 6pm tomorrow", now: referenceNow)
        #expect(r.title == "Call mom")
        #expect(r.kind == .reminder)
    }

    @Test("several to-dos in one phrase become separate items")
    func multipleTodosSeparate() async {
        let items = await parser.parse("water the plants and take out the trash and reply to emails", now: referenceNow)
        #expect(items.count == 3)
        #expect(items.allSatisfy { !$0.title.isEmpty })
        #expect(items.contains { $0.title.localizedCaseInsensitiveContains("plants") })
        #expect(items.contains { $0.title.localizedCaseInsensitiveContains("trash") })
        #expect(items.contains { $0.title.localizedCaseInsensitiveContains("emails") })
    }

    @Test("kind is inferred: reminder / event / to-do")
    func kindInference() async {
        let reminder = await firstParse("remind me to stretch", now: referenceNow)
        #expect(reminder.kind == .reminder)
        let event = await firstParse("lunch at noon", now: referenceNow)
        #expect(event.kind == .event)
        let todo = await firstParse("finish the report", now: referenceNow)
        #expect(todo.kind == .todo)
    }
}

@Suite("Schedule engine")
struct ScheduleEngineTests {
    let engine = ScheduleEngine()

    @Test("daily routine occurs every day after its anchor")
    func dailyOccurs() {
        let item = ScheduleItem(title: "Run", recurrence: .everyDay, createdAt: referenceNow)
        #expect(engine.occurs(item, on: referenceNow))
        #expect(engine.occurs(item, on: day(2026, 7, 25)))
        #expect(!engine.occurs(item, on: day(2026, 7, 19))) // before anchor
    }

    @Test("weekly routine occurs only on its weekdays")
    func weeklyOccurs() {
        // Weekly on Monday (weekday 2).
        let item = ScheduleItem(title: "Standup", recurrence: .weekly(on: [2]), createdAt: referenceNow)
        #expect(engine.occurs(item, on: day(2026, 7, 20)))  // Monday
        #expect(!engine.occurs(item, on: day(2026, 7, 21))) // Tuesday
        #expect(engine.occurs(item, on: day(2026, 7, 27)))  // next Monday
    }

    @Test("one-off task occurs only on its scheduled day")
    func oneOffOccurs() {
        let item = ScheduleItem(title: "Dentist", scheduledDate: day(2026, 7, 31))
        #expect(engine.occurs(item, on: day(2026, 7, 31)))
        #expect(!engine.occurs(item, on: day(2026, 7, 30)))
    }

    @Test("occurrences enumerate across an interval")
    func occurrencesInInterval() {
        let item = ScheduleItem(title: "Standup", recurrence: .weekly(on: [2]), createdAt: referenceNow)
        let interval = DateInterval(start: day(2026, 7, 20), end: day(2026, 8, 3))
        let occ = engine.occurrences(of: item, in: interval)
        #expect(occ == [day(2026, 7, 20), day(2026, 7, 27), day(2026, 8, 3)])
    }

    @Test("a routine stops at its end date")
    func endedRoutine() {
        let item = ScheduleItem(title: "Run", recurrence: .everyDay, createdAt: referenceNow)
        item.recurrenceEndDate = day(2026, 7, 22)
        #expect(engine.occurs(item, on: day(2026, 7, 22)))  // inclusive
        #expect(!engine.occurs(item, on: day(2026, 7, 23)))
    }

    @Test("a skipped day drops out without touching its neighbours")
    func skippedDay() {
        let item = ScheduleItem(title: "Run", recurrence: .everyDay, createdAt: referenceNow)
        item.skippedDates = [day(2026, 7, 22)]
        #expect(engine.occurs(item, on: day(2026, 7, 21)))
        #expect(!engine.occurs(item, on: day(2026, 7, 22)))
        #expect(engine.occurs(item, on: day(2026, 7, 23)))
    }
}
