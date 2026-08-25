//
//  EventLayoutTests.swift
//  RoutineOrganizerTests
//
//  The day-timeline lane packer is pure and the part most likely to be subtly
//  wrong, so it's pinned down here: overlapping events must split into distinct
//  columns, back-to-back events must share a lane, and a triple-booking must
//  widen to three.
//

import Testing
import Foundation
@testable import Routly

struct EventLayoutTests {
    private let calendar = Calendar(identifier: .gregorian)

    /// An item whose start time is `hour:minute` today, with a duration.
    private func item(_ hour: Int, _ minute: Int = 0, minutes: Int) -> ScheduleItem {
        let base = calendar.startOfDay(for: Date())
        let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        return ScheduleItem(title: "\(hour):\(minute)", kind: .event, startTime: start, durationMinutes: minutes)
    }

    @Test func nonOverlappingEventsShareOneColumn() {
        let events = [item(9, minutes: 30), item(10, minutes: 30)]
        let positioned = EventLayout.position(events, calendar: calendar)
        #expect(positioned.count == 2)
        #expect(positioned.allSatisfy { $0.columnCount == 1 })
        #expect(positioned.allSatisfy { $0.column == 0 })
    }

    @Test func overlappingEventsSplitIntoTwoLanes() {
        let events = [item(9, minutes: 60), item(9, 30, minutes: 60)]
        let positioned = EventLayout.position(events, calendar: calendar)
        #expect(positioned.count == 2)
        #expect(positioned.allSatisfy { $0.columnCount == 2 })
        #expect(Set(positioned.map(\.column)) == [0, 1])
    }

    @Test func backToBackEventsDoNotOverlap() {
        // 9:00–10:00 then 10:00–11:00 touch but never overlap.
        let events = [item(9, minutes: 60), item(10, minutes: 60)]
        let positioned = EventLayout.position(events, calendar: calendar)
        #expect(positioned.allSatisfy { $0.columnCount == 1 })
    }

    @Test func tripleBookingWidensToThreeLanes() {
        let events = [item(9, minutes: 90), item(9, 15, minutes: 90), item(9, 30, minutes: 90)]
        let positioned = EventLayout.position(events, calendar: calendar)
        #expect(positioned.count == 3)
        #expect(positioned.allSatisfy { $0.columnCount == 3 })
        #expect(Set(positioned.map(\.column)) == [0, 1, 2])
    }

    @Test func allDayItemsAreIgnored() {
        let allDay = ScheduleItem(title: "no time", kind: .todo)
        let positioned = EventLayout.position([allDay, item(9, minutes: 30)], calendar: calendar)
        #expect(positioned.count == 1)
    }

    @Test func aLaterEventReusesAFreedLane() {
        // A long 9–11 event beside a short 9–9:30; the 10:00 event should reclaim
        // the freed short lane rather than opening a third.
        let events = [item(9, minutes: 120), item(9, minutes: 30), item(10, minutes: 30)]
        let positioned = EventLayout.position(events, calendar: calendar)
        #expect(positioned.map(\.columnCount).max() == 2)
    }
}
