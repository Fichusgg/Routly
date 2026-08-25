//
//  WorkingHoursTests.swift
//  RoutineOrganizerTests
//
//  The working-hours window, and the three things that are supposed to respect
//  it: the day planner, overload detection, and the alternative slots the
//  conflict detector offers.
//
//  The invariant worth defending here is narrower than "everything happens
//  between 9 and 5". It's this: **a time the user stated is never moved; a time
//  the app chose always lands inside working hours.** Several tests below exist
//  only to hold that line, because the tempting simplification — clamp every
//  time everywhere — would quietly break "dinner at 8pm".
//
//  Step 1 of the working-hours restore covers the value type and its storage
//  only. The planner, overload and conflict-detector suites live in the same
//  file in stash@{0}^3 and arrive with Step 3, when the engines they exercise
//  actually take a window — their `planner(_:)` helper sets
//  `DayPlanner.preferences.workingHours`, which does not exist yet and would be
//  a compile error rather than a failing test.


import Testing
import Foundation
@testable import Routly

private let cal = Calendar(identifier: .gregorian)

/// Monday, 20 July 2026.
private let monday: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 20
    return cal.date(from: c)!
}()

private func at(_ hour: Int, _ minute: Int = 0, day: Date = monday) -> Date {
    cal.date(bySettingHour: hour, minute: minute, second: 0, of: cal.startOfDay(for: day))!
}

private func todo(_ title: String, effort: Int? = nil, due: Date? = monday) -> ScheduleItem {
    ScheduleItem(
        title: title, kind: .todo,
        effortMinutes: effort, dueDate: due.map { cal.startOfDay(for: $0) },
        createdAt: monday
    )
}

private func event(_ title: String, hour: Int, minute: Int = 0, minutes: Int = 60) -> ScheduleItem {
    ScheduleItem(
        title: title, kind: .event,
        scheduledDate: cal.startOfDay(for: monday),
        startTime: at(hour, minute), durationMinutes: minutes, createdAt: monday
    )
}

/// A planner on a stated window, so no test depends on what the shipped default
/// happens to be this month.
private func planner(_ hours: WorkingHours) -> DayPlanner {
    var planner = DayPlanner()
    planner.preferences.workingHours = hours
    return planner
}

private let nineToFive = WorkingHours(startHour: 9, endHour: 17)

// MARK: - The value type

@Suite("Working hours")
struct WorkingHoursValueTests {

    @Test("an inside-out range is normalized rather than trusted")
    func normalizesReversedRange() {
        // A night shift is not supported, and the honest failure is a usable
        // window — not a negative one that produces nonsense three files away.
        let reversed = WorkingHours(startHour: 22, endHour: 6).normalized
        #expect(reversed.endMinutes > reversed.startMinutes)
        #expect(reversed.durationMinutes >= WorkingHours.minimumWindowMinutes)
    }

    @Test("a zero-length range is widened to something plannable")
    func normalizesEmptyRange() {
        let empty = WorkingHours(startHour: 9, endHour: 9).normalized
        #expect(empty.durationMinutes >= WorkingHours.minimumWindowMinutes)
    }

    @Test("the end is exclusive — 5pm is when the day is over, not its last minute")
    func endIsExclusive() {
        #expect(nineToFive.contains(at(16, 59), calendar: cal))
        #expect(!nineToFive.contains(at(17, 0), calendar: cal))
        #expect(!nineToFive.contains(at(8, 59), calendar: cal))
        #expect(nineToFive.contains(at(9, 0), calendar: cal))
    }

    @Test("clamping pulls a stray time to the nearest edge of the same day")
    func clamps() {
        #expect(nineToFive.clamping(at(6, 0), calendar: cal) == at(9, 0))
        #expect(nineToFive.clamping(at(21, 0), calendar: cal) == at(17, 0))
        // Something already inside is left exactly where it is.
        #expect(nineToFive.clamping(at(11, 30), calendar: cal) == at(11, 30))
    }
}


// MARK: - Persistence

@Suite("Working hours — settings")
@MainActor
struct WorkingHoursSettingsTests {

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    @Test("starts on a conventional working day")
    func shippedDefault() {
        #expect(AppSettings(defaults: scratchDefaults()).workingHours == .default)
    }

    @Test("a chosen window survives a relaunch")
    func persists() {
        let defaults = scratchDefaults()
        AppSettings(defaults: defaults).workingHours = WorkingHours(startHour: 7, startMinute: 30, endHour: 15)

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.workingHours == WorkingHours(startHour: 7, startMinute: 30, endHour: 15))
    }

    /// Midnight is minute zero, which is exactly what a missing key reads as —
    /// so a store that used `integer(forKey:)` would be unable to tell someone
    /// who chose a midnight start from someone who has never chosen at all.
    @Test("a midnight start is distinguishable from no setting at all")
    func midnightIsNotMistakenForUnset() {
        let defaults = scratchDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.workingHours = WorkingHours(startMinutes: 0, endMinutes: 8 * 60)

        #expect(AppSettings(defaults: defaults).workingHours.startMinutes == 0)
    }

    @Test("an inside-out window can't be stored")
    func rejectsReversed() {
        let settings = AppSettings(defaults: scratchDefaults())
        settings.workingHours = WorkingHours(startHour: 18, endHour: 9)
        #expect(settings.workingHours.endMinutes > settings.workingHours.startMinutes)
    }

    /// Today every day gets the same window. The accessor is day-shaped anyway,
    /// so splitting weekdays from weekends later is a change here rather than a
    /// re-thread of the planner, detector and parser.
    @Test("the same window applies across the week")
    func appliesAllWeek() {
        let settings = AppSettings(defaults: scratchDefaults())
        settings.workingHours = WorkingHours(startHour: 10, endHour: 16)
        let saturday = cal.date(byAdding: .day, value: 5, to: monday)!
        #expect(settings.workingHours(on: monday) == settings.workingHours(on: saturday))
    }
}

// MARK: - The parser

/// Two of the four tests in the stashed "chosen times vs stated times" suite
/// belong here: the ones that exercise the parsing path. The other two need
/// `ConflictDetector.preferences.workingHours` and `DayPlanner`'s window, which
/// step 3 wires up.
@Suite("Working hours — parsing")
struct WorkingHoursParsingTests {

    /// The offline parser's time words ("tonight", "this morning") are the
    /// user's own, so they pass through untouched even though they land outside
    /// a 9–5.
    @Test("the offline parser keeps spoken times outside working hours")
    func spokenTimesArePreserved() async {
        let parsed = await StubAIParsingService()
            .parse("call mom tonight", now: at(10, 0), workingHours: nineToFive)
        let call = parsed.first { $0.title.lowercased().contains("mom") }
        #expect(call != nil)
        if let start = call?.startTime {
            #expect(!nineToFive.contains(start, calendar: cal))
        }
    }

    /// The prompt has to carry the window without weakening the rule above it —
    /// an unstated time is still null, and a stated one is still untouchable.
    @Test("the parsing prompt states the window and both rules")
    func promptCarriesTheWindow() {
        let prompt = ParsingContract.systemPrompt(now: monday, workingHours: nineToFive)
        #expect(prompt.contains("09:00"))
        #expect(prompt.contains("17:00"))
        #expect(prompt.lowercased().contains("still null"))
    }
}

// MARK: - The planner

@Suite("Working hours — day planner")
struct WorkingHoursPlannerTests {

    /// The case that prompted the feature: nothing may be proposed at 9pm when
    /// the person's day ends at 5.
    @Test("nothing is ever proposed outside the window")
    func neverPlansOutsideHours() {
        let plan = planner(nineToFive).plan(from: [
            todo("Write the report", effort: 60),
            todo("Call the bank", effort: 30),
            todo("Book flights", effort: 45),
        ], now: at(9, 0))

        #expect(!plan.recommendations.isEmpty)
        for recommendation in plan.recommendations {
            #expect(recommendation.start >= at(9, 0))
            #expect(recommendation.end <= at(17, 0))
        }
    }

    @Test("a plan made before the day opens starts when it opens, not now")
    func waitsForTheDayToStart() {
        let plan = planner(nineToFive).plan(from: [todo("Write the report", effort: 60)], now: at(6, 30))
        #expect(plan.recommendations.first?.start ?? .distantPast >= at(9, 0))
    }

    @Test("once the working day is over there is no free time left to offer")
    func afterHoursHasNoFreeTime() {
        let plan = planner(nineToFive).plan(from: [todo("Write the report", effort: 60)], now: at(21, 0))
        #expect(plan.freeMinutes == 0)
        #expect(plan.recommendations.isEmpty)
        #expect(plan.isAfterWorkingHours)
    }

    /// "No open time left before 5:00 PM" at 9pm reads like a clock bug. A day
    /// that is *over* and a day that is *full* deserve different sentences.
    @Test("being after hours is distinguished from being fully booked")
    func afterHoursIsNotTheSameAsFull() {
        let hours = nineToFive
        let afterHours = planner(hours).plan(from: [todo("File taxes", effort: 60)], now: at(21, 0))
        #expect(afterHours.isAfterWorkingHours)
        #expect(afterHours.unplaced.first?.reason.contains("ended") == true)

        // A packed day, mid-morning: no room, but the day is not over.
        let wall = (9..<17).map { event("Busy \($0)", hour: $0, minutes: 60) }
        let full = planner(hours).plan(from: wall + [todo("File taxes", effort: 60)], now: at(9, 0))
        #expect(!full.isAfterWorkingHours)
    }

    @Test("a longer working day genuinely offers more time")
    func windowLengthChangesFreeTime() {
        let short = planner(WorkingHours(startHour: 9, endHour: 12)).plan(from: [], now: at(9, 0))
        let long = planner(WorkingHours(startHour: 9, endHour: 18)).plan(from: [], now: at(9, 0))
        #expect(long.freeMinutes > short.freeMinutes)
    }

    /// A 7am gym class and an 8pm dinner are real, but they sit outside the
    /// window being planned — so they neither eat into free time nor get
    /// planned around. The alternative (counting them) would report less free
    /// time than the person actually has inside their working day.
    @Test("fixed items outside the window don't consume working time")
    func ignoresCommitmentsOutsideTheWindow() {
        let clear = planner(nineToFive).plan(from: [], now: at(9, 0))
        let withOutsideCommitments = planner(nineToFive).plan(from: [
            event("Gym", hour: 6, minutes: 60),
            event("Dinner", hour: 19, minutes: 120),
        ], now: at(9, 0))
        #expect(withOutsideCommitments.freeMinutes == clear.freeMinutes)
    }

    /// "Tomorrow morning" used to be a hardcoded 9am. For someone working
    /// 6am–2pm, 9am is not the start of their morning.
    @Test("a pushed task lands when tomorrow's working day opens")
    func pushesToTheStartOfTomorrow() {
        let earlyBird = WorkingHours(startHour: 6, endHour: 14)
        let wall = (6..<14).map { event("Busy \($0)", hour: $0, minutes: 60) }
        let plan = planner(earlyBird).plan(from: wall + [todo("File taxes", effort: 90)], now: at(6, 0))

        let unplaced = plan.unplaced.first { $0.title == "File taxes" }
        guard case let .moveToTomorrowMorning(when)? = unplaced?.resolution else {
            Issue.record("a task due today that won't fit should offer tomorrow morning")
            return
        }
        #expect(when == at(6, 0, day: cal.date(byAdding: .day, value: 1, to: monday)!))
    }
}

// MARK: - Overload

@Suite("Working hours — overload")
struct WorkingHoursOverloadTests {

    /// The point of making the threshold relative: the same booked hours mean
    /// different things in a four-hour day and a twelve-hour one.
    @Test("what counts as overloaded scales with the window")
    func overloadIsRelative() {
        let booked = [event("A", hour: 9), event("B", hour: 10), event("C", hour: 11), event("D", hour: 12)]
        let candidate = event("E", hour: 13)  // 5 hours in total

        var shortDay = ConflictDetector()
        shortDay.preferences.workingHours = WorkingHours(startHour: 9, endHour: 14)   // 5h → 4.25h cap
        #expect(shortDay.report(for: candidate, against: booked, on: monday).isOverloaded)

        var longDay = ConflictDetector()
        longDay.preferences.workingHours = WorkingHours(startHour: 7, endHour: 19)    // 12h → 10.2h cap
        #expect(!longDay.report(for: candidate, against: booked, on: monday).isOverloaded)
    }

    /// The old absolute eight hours only fired once a 9–5 was more than
    /// completely full, which is far too late to be worth saying.
    @Test("a 9–5 tips into overloaded before it is 100% booked")
    func firesWhileItStillMatters() {
        var detector = ConflictDetector()
        detector.preferences.workingHours = nineToFive   // 8h → 6.8h cap
        let booked = (9..<16).map { event("Busy \($0)", hour: $0, minutes: 60) }  // 7h
        let report = detector.report(for: booked[0], against: Array(booked.dropFirst()), on: monday)
        #expect(report.scheduledHours == 7)
        #expect(report.isOverloaded)
    }

    @Test("the item-count threshold stays absolute")
    func countIsNotScaled() {
        // Nine separate commitments is a fragmented day whether the window is
        // long or short, so a long day must not excuse the count.
        var detector = ConflictDetector()
        detector.preferences.workingHours = WorkingHours(startHour: 6, endHour: 22)
        let many = (0..<9).map { event("Thing \($0)", hour: 6 + $0, minutes: 1) }
        let report = detector.report(for: many[0], against: Array(many.dropFirst()), on: monday)
        #expect(report.isOverloaded)
    }
}

// MARK: - Alternatives, and whose time it is

/// The other half of the stashed ownership suite; its two parsing tests landed
/// in step 2, and these two needed the engines to take a window.
@Suite("Working hours — chosen times vs stated times")
struct WorkingHoursTimeOwnershipTests {

    @Test("an alternative slot never runs past the end of the working day")
    func alternativesStayInHours() {
        var detector = ConflictDetector()
        detector.preferences.workingHours = nineToFive

        // The afternoon is solid from 13:00 to 17:00, so there is no room for a
        // 60-minute item after the clash. The old code would have walked on to
        // 22:00 and offered an evening slot.
        let busy = (13..<17).map { event("Busy \($0)", hour: $0, minutes: 60) }
        let candidate = event("Design review", hour: 13, minute: 30, minutes: 60)
        let alt = detector.alternative(for: candidate, against: busy, on: monday)

        if let alt, cal.isDate(alt.start, inSameDayAs: monday) {
            #expect(alt.start.addingTimeInterval(60 * 60) <= at(17, 0))
        }
        // Falling through to another day is fine; suggesting 6pm is not.
        #expect(!(alt.map { cal.isDate($0.start, inSameDayAs: monday) && $0.start >= at(17, 0) } ?? false))
    }

    /// The line the feature must not cross. Working hours constrain what the
    /// *app* picks; they say nothing about what the user is allowed to want.
    @Test("a time the user stated is never moved into working hours")
    func statedTimesSurvive() {
        let dinner = event("Dinner with Sam", hour: 20, minutes: 90)
        #expect(dinner.startTime == at(20, 0))

        // It stays put through a planning pass, and is not "corrected" to 5pm.
        let plan = planner(nineToFive).plan(from: [dinner, todo("Write the report", effort: 30)], now: at(9, 0))
        #expect(dinner.startTime == at(20, 0))
        // Nor does the planner treat the evening as its own to use.
        #expect(plan.recommendations.allSatisfy { $0.end <= at(17, 0) })
    }
}
