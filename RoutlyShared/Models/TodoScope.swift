//
//  TodoScope.swift
//  RoutineOrganizer
//
//  Whether a to-do is for now or for eventually.
//
//  This is the distinction the rolling checklist couldn't make before: an
//  undated to-do rolled forward forever, so "email the landlord" and "learn to
//  sail" sat side by side with equal weight. Marking something long-term says
//  it's real but not today's problem, and the list orders itself accordingly.
//

import Foundation

enum TodoScope: String, Codable, CaseIterable, Identifiable, Sendable {
    /// On the hook now — the default, and what the rolling checklist is for.
    case today
    /// Genuinely wanted, not urgent. Sinks below today's work in the list.
    case longTerm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return String(localized: "Today")
        case .longTerm: return String(localized: "Long-term")
        }
    }

    var symbolName: String {
        switch self {
        case .today: return "sun.max"
        case .longTerm: return "infinity"
        }
    }

    /// Today's work sorts above the long game.
    var rank: Int { self == .today ? 0 : 1 }

    /// What the heading is called until someone renames it.
    var defaultGroupName: String {
        switch self {
        case .today: return String(localized: "To-dos")
        case .longTerm: return String(localized: "Long-term")
        }
    }

    static let unset: TodoScope = .today
}
