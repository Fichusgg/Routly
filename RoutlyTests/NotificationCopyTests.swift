//
//  NotificationCopyTests.swift
//  RoutineOrganizerTests
//
//  What a reminder actually says when it fires.
//
//  This is the only user-facing copy in the app that nobody reviews by using it:
//  it appears on a lock screen, minutes or hours after the code that built it
//  ran, and a wrong string there looks exactly like a working notification. The
//  body spent its whole life saying "Starts in 0 hours" for the default lead
//  because nothing ever read it back.
//
//  The split being defended: **title is the thing happening, body is when** —
//  the way iOS's own reminders read.
//

import Testing
import Foundation
import UserNotifications
@testable import Routly

private let cal = Calendar(identifier: .gregorian)

/// Monday, 20 July 2026, 9am.
private let start: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 20; c.hour = 9
    return cal.date(from: c)!
}()

private func event(_ title: String) -> ScheduleItem {
    ScheduleItem(
        title: title, kind: .event,
        scheduledDate: cal.startOfDay(for: start),
        startTime: start, durationMinutes: 60, createdAt: start
    )
}

@Test func notificationTitleIsTheItemItself() {
    let content = NotificationService.makeContent(for: event("Work on Routly"), start: start, leadMinutes: 30)
    #expect(content.title == "Work on Routly")
    // The timing belongs in the body — a title carrying it would push the item's
    // own name off the end of a lock-screen line.
    #expect(!content.title.contains("30"))
}

@Test func notificationBodyLeadsWithTheCountdown() {
    let clockTime = start.formatted(date: .omitted, time: .shortened)

    for minutes in ([0, 1, 90] + ReminderLead.options) {
        let content = NotificationService.makeContent(for: event("Work on Routly"), start: start, leadMinutes: minutes)
        #expect(content.body.hasPrefix(ReminderLead.countdownPhrase(minutes)),
                "\(minutes) min: “\(content.body)”")
        // Still says the start time, whatever the lead — the countdown alone
        // doesn't survive a notification read an hour after it arrived.
        #expect(content.body.contains(clockTime), "\(minutes) min: “\(content.body)”")
    }
}

/// At the start time there is nothing to count down, so the body says so rather
/// than reaching for a number at all — the case that used to read "in 0 hours".
@Test func notificationAtStartTimeDoesNotCountDown() {
    let content = NotificationService.makeContent(for: event("Work on Routly"), start: start, leadMinutes: 0)
    #expect(content.body.hasPrefix(ReminderLead.countdownPhrase(0)))
    #expect(!content.body.hasPrefix(ReminderLead.countdownPhrase(10)))
}
