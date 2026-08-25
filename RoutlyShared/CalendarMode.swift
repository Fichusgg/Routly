//
//  CalendarMode.swift
//  RoutineOrganizer
//
//  The three ways to look at a schedule, and the pure date math for stepping the
//  visible window forward and back. Kept together so the header, the gesture
//  layer, and the keyboard shortcuts all reason about periods the same way.
//

import SwiftUI

/// Declaration order is the order of the mode switcher, and Agenda leads
/// because it's where the calendar opens: "what's coming up" is the question
/// people actually arrive with. Week and Month are one tap away for the times
/// you want shape rather than sequence.
enum CalendarMode: String, CaseIterable, Identifiable {
    case agenda = "Agenda"
    case week = "Week"
    case month = "Month"

    var id: String { rawValue }

    /// What the calendar shows when you open it.
    static let landing: CalendarMode = .agenda

    var symbolName: String {
        switch self {
        case .week: return "calendar.day.timeline.left"
        case .month: return "calendar"
        case .agenda: return "list.bullet"
        }
    }

    /// The `Calendar.Component` one step of this mode advances by.
    var step: (component: Calendar.Component, value: Int) {
        switch self {
        case .week, .agenda: return (.day, 7)
        case .month: return (.month, 1)
        }
    }
}

/// Pure helpers for moving and titling the visible window. Free functions so
/// they're trivially testable and shared by every calendar surface.
enum CalendarPeriod {
    /// Shift `anchor` by one period of `mode` in `direction` (+1 next, -1 prev).
    static func shifted(_ anchor: Date, mode: CalendarMode, by direction: Int,
                        calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        let step = mode.step
        return calendar.date(byAdding: step.component, value: step.value * direction, to: anchor) ?? anchor
    }

    /// The large title for the current window (e.g. "July 2026").
    static func title(for anchor: Date, mode: CalendarMode,
                      calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        anchor.formatted(.dateTime.month(.wide).year())
    }

    /// The secondary line under the title — the concrete range in view.
    static func subtitle(for anchor: Date, mode: CalendarMode,
                         calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        switch mode {
        case .month:
            return "\(daysInMonth(anchor, calendar: calendar)) days"
        case .week, .agenda:
            let start = startOfWeek(anchor, calendar: calendar)
            guard let end = calendar.date(byAdding: .day, value: 6, to: start) else { return "" }
            let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
            let startStr = start.formatted(.dateTime.month(.abbreviated).day())
            let endStr = sameMonth
                ? end.formatted(.dateTime.day())
                : end.formatted(.dateTime.month(.abbreviated).day())
            return "\(startStr) – \(endStr)"
        }
    }

    static func startOfWeek(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    }

    private static func daysInMonth(_ date: Date, calendar: Calendar) -> Int {
        calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }
}
