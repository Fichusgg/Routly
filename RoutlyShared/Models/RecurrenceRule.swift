//
//  RecurrenceRule.swift
//  RoutineOrganizer
//
//  A small, explicit recurrence value type. Deliberately not a raw RRULE
//  string so the stub parser and ScheduleEngine can reason about it directly.
//  Stored as a Codable property on ScheduleItem (nil = one-off task).
//

import Foundation

struct RecurrenceRule: Codable, Hashable, Sendable {
    enum Frequency: String, Codable, Sendable {
        case daily
        case weekly
        /// "3x this week" — a target count with no fixed days.
        case timesPerWeek
    }

    var frequency: Frequency

    /// Every N periods (e.g. every 2 weeks). Defaults to 1.
    var interval: Int

    /// Calendar weekdays this routine lands on (1 = Sunday ... 7 = Saturday).
    /// Used for `.weekly`. Empty for `.daily` / `.timesPerWeek`.
    var weekdays: Set<Int>

    /// Target completions per week for `.timesPerWeek` (e.g. "gym 3x this week").
    var targetCount: Int?

    init(frequency: Frequency, interval: Int = 1, weekdays: Set<Int> = [], targetCount: Int? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.targetCount = targetCount
    }

    // MARK: Convenience constructors

    static let everyDay = RecurrenceRule(frequency: .daily)

    static func weekly(on weekdays: Set<Int>, interval: Int = 1) -> RecurrenceRule {
        RecurrenceRule(frequency: .weekly, interval: interval, weekdays: weekdays)
    }

    static func timesPerWeek(_ count: Int) -> RecurrenceRule {
        RecurrenceRule(frequency: .timesPerWeek, targetCount: count)
    }

    /// Plain-language description for the trust layer ("why did it do that").
    var displayDescription: String {
        switch frequency {
        case .daily:
            return interval <= 1
                ? String(localized: "Every day")
                : String(localized: "Every \(interval) days")
        case .weekly:
            // Weekday names come from `Calendar`, so they are already in the
            // reader's language — only the surrounding phrasing needs a string.
            let names = weekdays.sorted().compactMap { Self.weekdaySymbol($0) }
            // A comma list, not `.list(type: .and)` — this is a compact tag in a
            // row, and "Mon, Wed, and Fri" is longer without being clearer.
            let base = names.isEmpty
                ? String(localized: "Weekly")
                : names.joined(separator: ", ")
            return interval <= 1 ? base : String(localized: "\(base) (every \(interval) weeks)")
        case .timesPerWeek:
            let count = targetCount ?? 1
            return String(localized: "\(count)× this week")
        }
    }

    /// Short weekday label for a Calendar weekday index (1 = Sunday).
    static func weekdaySymbol(_ weekday: Int) -> String? {
        let symbols = Calendar(identifier: .gregorian).shortWeekdaySymbols // ["Sun", ...]
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return nil }
        return symbols[index]
    }
}
