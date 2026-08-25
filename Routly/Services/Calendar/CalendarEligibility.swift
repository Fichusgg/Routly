//
//  CalendarEligibility.swift
//  RoutineOrganizer
//
//  Which Routly items can go on a calendar at all, and what one looks like when
//  it gets there.
//
//  Both answers are pure functions over plain values, so the add sheet and the
//  push path ask the same question the same way and cannot disagree — the
//  sheet's calendar switches go dim, with the reason under them, for exactly
//  the items the push path would refuse.
//
//  ── What Phase 1 refuses, and why ───────────────────────────────────────
//
//  **To-dos.** A rolling checklist item is not an event. It has no time, it
//  survives the day it was written on, and it leaves the list when it's ticked.
//  Putting one on a calendar as a block would misrepresent all three. Apple's
//  home for these is Reminders, a different EventKit entity — a later phase, if
//  it turns out to be wanted, not a variation on this one.
//
//  **Repeating items.** Routly's `RecurrenceRule` has a `timesPerWeek` case —
//  "gym 3x this week" — and RRULE, which is what both EventKit and Google
//  speak, **cannot express it**. There is no "three times a week, any days" in
//  the iCalendar spec. `daily` and `weekly` would map, but a routine also
//  carries `skippedDates` and `recurrenceEndDate` that have to map with it, and
//  a linked series turns every subsequent edit into a series edit. That is its
//  own phase with its own tests, not a corner of this one.
//
//  **Undated items.** Nothing to place.
//

import Foundation

/// Whether an item can be put on a calendar, and if not, what to tell the user.
enum CalendarEligibility: Equatable, Sendable {
    case eligible
    case notAnEvent
    case undated
    case repeating

    var isEligible: Bool { self == .eligible }

    /// The line shown under the calendar switches in the add sheet's "More"
    /// section. nil when there's nothing to explain.
    ///
    /// Phrased as what Routly does rather than what it can't do — "stays in
    /// Routly" is a statement about where the thing lives, which is true and
    /// useful; "cannot be added" is a complaint about a limitation the reader
    /// didn't ask about.
    var reason: String? {
        switch self {
        case .eligible:
            return nil
        case .notAnEvent:
            return String(localized: "To-dos stay in Routly. Events and reminders are what go on a calendar.")
        case .undated:
            return String(localized: "Give this a day and it can go on a calendar.")
        case .repeating:
            return String(localized: "Repeating items stay in Routly for now — a calendar can't describe every way Routly repeats things.")
        }
    }
}

enum CalendarEligibilityCheck {

    /// The rule, over the four things it depends on.
    ///
    /// Takes primitives rather than a `ScheduleItem` or a `CaptureDraft` so
    /// both can ask it — a draft has no item yet, and an item has no notion of
    /// the sheet's "keep this repeat" toggle.
    ///
    /// Order matters: kind is checked first because "to-dos stay in Routly" is
    /// the honest answer for an undated to-do, and "give this a day" would send
    /// the reader off to add a day that still wouldn't help.
    static func evaluate(
        kind: ItemKind,
        hasDate: Bool,
        isRepeating: Bool
    ) -> CalendarEligibility {
        guard kind != .todo else { return .notAnEvent }
        guard !isRepeating else { return .repeating }
        guard hasDate else { return .undated }
        return .eligible
    }

    static func evaluate(_ item: ScheduleItem) -> CalendarEligibility {
        evaluate(
            kind: item.kind,
            hasDate: item.scheduledDate != nil,
            isRepeating: item.isRoutine
        )
    }
}

// MARK: - Payload

enum CalendarPayloadBuilder {

    /// How long a reminder occupies on a calendar.
    ///
    /// A reminder is a point in time in Routly and has no duration to carry
    /// over. EventKit accepts a zero-length event and calendars render one as a
    /// hairline nobody can see or tap, so it gets a short real span instead.
    static let reminderSpanMinutes = 15

    /// What an event with a day but no time becomes, when a calendar needs an
    /// end as well as a start.
    static let defaultEventSpanMinutes = 60

    /// The event Routly would write for this item, or nil when it wouldn't
    /// write one at all.
    ///
    /// Returning nil rather than throwing is deliberate and load-bearing: an
    /// item that stops being eligible mid-edit — the user switches an event to
    /// a to-do, or clears its day — must have its calendar events *removed*,
    /// and "there is no payload" is exactly the signal the push path reads to
    /// do that.
    static func payload(
        for item: ScheduleItem,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> CalendarEventPayload? {
        guard CalendarEligibilityCheck.evaluate(item).isEligible else { return nil }
        guard let day = item.scheduledDate else { return nil }

        guard let start = item.startTime else {
            // A day with no time is an all-day event. Its end is the *start of
            // the next day*, which is how EventKit and iCalendar both spell a
            // one-day span — setting end to the same day makes a zero-length
            // all-day event that some calendars drop entirely.
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            return CalendarEventPayload(
                title: item.title,
                notes: item.notes,
                start: dayStart,
                end: dayEnd,
                isAllDay: true
            )
        }

        let minutes = item.durationMinutes
            ?? (item.kind == .reminder ? reminderSpanMinutes : defaultEventSpanMinutes)
        let end = calendar.date(byAdding: .minute, value: max(1, minutes), to: start) ?? start

        return CalendarEventPayload(
            title: item.title,
            notes: item.notes,
            start: start,
            end: end,
            isAllDay: false
        )
    }
}
