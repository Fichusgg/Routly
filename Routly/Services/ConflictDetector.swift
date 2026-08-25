//
//  ConflictDetector.swift
//  RoutineOrganizer
//
//  Before a timed item is placed or moved, this checks it against what's already
//  on that day: direct time overlaps between events, and days getting overloaded.
//  Pure value-in/value-out so it's unit-testable, and it always offers an
//  alternative with a plain-language reason — the "why did it do that" principle.
//

import Foundation

/// Adjustable thresholds for what counts as an overloaded day.
struct SchedulingPreferences: Equatable, Sendable {
    /// The user's working day. Overload is measured against this window rather
    /// than against a flat number of hours, so a short day gets called full
    /// sooner than a long one.
    var workingHours: WorkingHours = .default

    /// The share of the working day that can be booked before it counts as
    /// overloaded.
    ///
    /// This used to be an absolute eight hours, which against a 9–5 meant a day
    /// only registered as overloaded once it was more than *completely* full —
    /// so it almost never fired. A fraction fires while there's still something
    /// to be done about it: 9–5 tips at 6h48m booked.
    var maxLoadFraction: Double = 0.85

    /// Deliberately not scaled by the window. Nine separate commitments is a
    /// fragmented day whether they span six hours or twelve — a count measures
    /// something a duration doesn't.
    var maxTimedItemsPerDay: Int = 8

    /// The hours-booked threshold for a given day.
    ///
    /// `day` is unused while one window covers the whole week, but the callers
    /// ask per day — the 7-day sweep in `SuggestionEngine` compares each day
    /// against its own threshold, which is exactly what a weekday/weekend split
    /// would need and the reason it can be added here alone.
    func maxScheduledHours(on day: Date) -> Double {
        _ = day
        return workingHours.durationHours * maxLoadFraction
    }

    static let `default` = SchedulingPreferences()
}

/// What a candidate placement runs into on a given day.
struct ConflictReport {
    /// Existing timed events the candidate directly overlaps.
    var overlaps: [ScheduleItem]
    /// Whether the day (including the candidate) exceeds the thresholds.
    var isOverloaded: Bool
    var scheduledHours: Double
    var timedItemCount: Int

    var hasConflict: Bool { !overlaps.isEmpty || isOverloaded }
}

/// A proposed different time (or day) for a conflicting item.
struct AlternativeSlot {
    var start: Date
    var reason: String
}

struct ConflictDetector {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1
        return c
    }()
    var engine = ScheduleEngine()
    var preferences: SchedulingPreferences = .default

    // MARK: - Detection

    func report(for candidate: ScheduleItem, against items: [ScheduleItem], on day: Date) -> ConflictReport {
        let existing = timedItems(on: day, from: items, excluding: candidate)

        let overlaps: [ScheduleItem]
        if let candidateInterval = occupiedInterval(for: candidate) {
            overlaps = existing.filter { item in
                guard let other = occupiedInterval(for: item) else { return false }
                return strictlyOverlap(candidateInterval, other)
            }
        } else {
            overlaps = []
        }

        // Load = the candidate plus everything already timed that day.
        let dayItems = existing + (candidate.startTime != nil ? [candidate] : [])
        let hours = dayItems.reduce(0.0) { $0 + durationHours(for: $1) }
        let overloaded = dayItems.count > preferences.maxTimedItemsPerDay
            || hours > preferences.maxScheduledHours(on: day)

        return ConflictReport(
            overlaps: overlaps,
            isOverloaded: overloaded,
            scheduledHours: hours,
            timedItemCount: dayItems.count
        )
    }

    // MARK: - Alternatives

    /// Suggests the nearest non-overlapping slot later that day, or the same time
    /// tomorrow if the day can't fit it.
    func alternative(for candidate: ScheduleItem, against items: [ScheduleItem], on day: Date) -> AlternativeSlot? {
        guard let start = candidate.startTime else { return nil }
        let durationMin = durationMinutes(for: candidate)
        let existing = timedItems(on: day, from: items, excluding: candidate)
        let busy = existing.compactMap { occupiedInterval(for: $0) }

        let conflictTitle = report(for: candidate, against: items, on: day).overlaps.first?.title

        // Walk forward in 15-minute steps, looking for a gap — but only inside
        // the working day, and only far enough that the item still *finishes*
        // before it closes. Offering a 4:45pm start for an hour-long thing in a
        // 9–5 day would technically be within hours and obviously wrong.
        var probe = start
        let workingEnd = preferences.workingHours.end(on: day, calendar: calendar)
        let limit = calendar.date(byAdding: .minute, value: -durationMin, to: workingEnd) ?? workingEnd
        while probe <= limit {
            let candidateInterval = DateInterval(start: probe, duration: TimeInterval(durationMin * 60))
            let clashes = busy.contains { strictlyOverlap($0, candidateInterval) }
            if !clashes && probe > start {
                let timeText = probe.formatted(date: .omitted, time: .shortened)
                let reason: String
                if let conflictTitle {
                    reason = String(localized: "That time overlaps “\(conflictTitle)”, so I moved it to \(timeText).")
                } else {
                    reason = String(localized: "That slot is taken, so I moved it to \(timeText).")
                }
                return AlternativeSlot(start: probe, reason: reason)
            }
            guard let next = calendar.date(byAdding: .minute, value: 15, to: probe) else { break }
            probe = next
        }

        // No room today — same time tomorrow.
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) {
            let dayName = tomorrow.formatted(.dateTime.weekday(.wide))
            return AlternativeSlot(
                start: tomorrow,
                reason: String(localized: "That day is full around then, so I suggest the same time on \(dayName).")
            )
        }
        return nil
    }

    // MARK: - Helpers

    private func timedItems(on day: Date, from items: [ScheduleItem], excluding candidate: ScheduleItem) -> [ScheduleItem] {
        items.filter { item in
            item.id != candidate.id && item.startTime != nil && engine.occurs(item, on: day)
        }
    }

    /// The block an item occupies. Events default to 60 min when no duration is
    /// set; reminders/to-dos are points and never conflict.
    private func occupiedInterval(for item: ScheduleItem) -> DateInterval? {
        guard let start = item.startTime else { return nil }
        let minutes = durationMinutes(for: item)
        guard minutes > 0 else { return nil }
        return DateInterval(start: start, duration: TimeInterval(minutes * 60))
    }

    private func durationMinutes(for item: ScheduleItem) -> Int {
        if let d = item.durationMinutes { return d }
        return item.kind == .event ? 60 : 0
    }

    private func durationHours(for item: ScheduleItem) -> Double {
        Double(durationMinutes(for: item)) / 60
    }

    /// True only when the two blocks genuinely overlap — abutting blocks
    /// (one ending exactly when the next begins) do not count.
    private func strictlyOverlap(_ a: DateInterval, _ b: DateInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }
}
