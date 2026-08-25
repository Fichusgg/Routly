//
//  ItemKind.swift
//  RoutineOrganizer
//
//  What sort of thing a ScheduleItem is. Locked in now because Phase 2's real
//  parser will target this shape: the user picks a kind up front (Event /
//  Reminder / To-do), and parsing fills in the details underneath.
//
//  `kind` is orthogonal to `recurrence` — any kind can also repeat.
//

import Foundation

enum ItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Something that happens at a time, for a span — shown time-blocked.
    case event
    /// A point-in-time nudge — dated and timed, but not a block.
    case reminder
    /// A task on a rolling checklist — optional day, no time, leaves the list
    /// once checked off.
    case todo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .event: return String(localized: "Event")
        case .reminder: return String(localized: "Reminder")
        case .todo: return String(localized: "To-do")
        }
    }

    var symbolName: String {
        switch self {
        case .event: return "calendar"
        case .reminder: return "bell"
        case .todo: return "checklist"
        }
    }

    // Which structured fields the add/edit form offers for this kind.
    var usesTime: Bool {
        switch self {
        case .event, .reminder: return true
        case .todo: return false
        }
    }

    var usesDuration: Bool { self == .event }

    /// Events and reminders are inherently dated; a to-do may float undated.
    var requiresDate: Bool {
        switch self {
        case .event, .reminder: return true
        case .todo: return false
        }
    }
}
