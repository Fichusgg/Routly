//
//  WorkingHours.swift
//  RoutineOrganizer
//
//  The window of the day the app is allowed to plan inside.
//
//  Before this, three different files each had their own idea of when a day
//  starts and ends — the planner worked 8am–9pm, the conflict detector offered
//  alternative slots until 10pm, and "overloaded" meant more than eight hours
//  booked no matter how long the person's day actually was. None of them agreed,
//  and none of them were the user's.
//
//  Stored as minutes from midnight rather than `Date`, so a range carries no
//  date and no timezone of its own — it's resolved against whichever day is
//  being planned. That's what keeps one stored value correct across DST, travel,
//  and a plan made at 11:59pm.
//
//  Overnight ranges (a shift ending before it starts) are deliberately not
//  supported: every consumer here treats the window as a single contiguous
//  stretch within one calendar day, and quietly accepting 10pm–6am would produce
//  a negative window rather than a night shift. `normalized` enforces that, and
//  the settings picker won't offer it.
//

import Foundation

struct WorkingHours: Equatable, Sendable {

    /// Minutes from midnight. 540 is 9:00 AM.
    var startMinutes: Int
    /// Minutes from midnight, always greater than `startMinutes`.
    var endMinutes: Int

    /// A conventional working day. Not a claim about the user — just somewhere
    /// to stand before they've said otherwise.
    static let `default` = WorkingHours(startMinutes: 9 * 60, endMinutes: 17 * 60)

    /// The shortest window worth calling a working day. Below this the planner
    /// has nothing useful to say, and the arithmetic downstream starts producing
    /// gaps too small to offer.
    static let minimumWindowMinutes = 30

    init(startMinutes: Int, endMinutes: Int) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    init(startHour: Int, startMinute: Int = 0, endHour: Int, endMinute: Int = 0) {
        self.init(
            startMinutes: startHour * 60 + startMinute,
            endMinutes: endHour * 60 + endMinute
        )
    }

    // MARK: - Shape

    /// How long the window is.
    var durationMinutes: Int { max(endMinutes - startMinutes, 0) }

    var durationHours: Double { Double(durationMinutes) / 60 }

    /// A range guaranteed to be usable: inside one day, in the right order, and
    /// long enough to plan in. Applied on the way in and on the way out of
    /// storage, so nothing downstream has to defend itself against a bad pair.
    var normalized: WorkingHours {
        let start = min(max(startMinutes, 0), 24 * 60 - Self.minimumWindowMinutes)
        let end = min(max(endMinutes, start + Self.minimumWindowMinutes), 24 * 60)
        return WorkingHours(startMinutes: start, endMinutes: end)
    }

    // MARK: - Resolving against a day

    /// When the working day opens on `day`.
    func start(on day: Date, calendar: Calendar) -> Date {
        resolve(startMinutes, on: day, calendar: calendar)
    }

    /// When it closes on `day`.
    func end(on day: Date, calendar: Calendar) -> Date {
        resolve(endMinutes, on: day, calendar: calendar)
    }

    /// Built by adding minutes to midnight rather than by setting an hour
    /// component, so a day where the hour doesn't exist — DST springing
    /// forward — still lands on a real instant instead of failing.
    private func resolve(_ minutes: Int, on day: Date, calendar: Calendar) -> Date {
        let midnight = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .minute, value: minutes, to: midnight) ?? midnight
    }

    /// Whether an instant falls inside the working day it belongs to. The end is
    /// exclusive: 5:00 PM is when the day is over, not the last minute of it.
    func contains(_ date: Date, calendar: Calendar) -> Bool {
        date >= start(on: date, calendar: calendar) && date < end(on: date, calendar: calendar)
    }

    /// The nearest instant inside the window on that same day.
    ///
    /// Used wherever the *app* picked a time rather than the user — a time the
    /// person stated themselves is never passed through here.
    func clamping(_ date: Date, calendar: Calendar) -> Date {
        let open = start(on: date, calendar: calendar)
        let close = end(on: date, calendar: calendar)
        if date < open { return open }
        if date >= close { return close }
        return date
    }

    // MARK: - Display

    /// "9:00 AM – 5:00 PM", in the user's own time format.
    func rangeText(calendar: Calendar = .current) -> String {
        let reference = Date()
        let open = start(on: reference, calendar: calendar)
        let close = end(on: reference, calendar: calendar)
        return "\(open.formatted(date: .omitted, time: .shortened)) – \(close.formatted(date: .omitted, time: .shortened))"
    }
}
