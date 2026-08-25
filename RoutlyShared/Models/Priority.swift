//
//  Priority.swift
//  RoutineOrganizer
//
//  How much a to-do matters. Three steps, because five is a decision nobody
//  makes honestly and two isn't a scale.
//
//  Medium is the default and reads as "no opinion" — it's what you get for not
//  answering, so the row shows it as a neutral mark rather than a badge
//  demanding attention. Only a deliberate high or low earns colour.
//

import Foundation

enum Priority: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }

    /// A glyph rather than a coloured dot: direction reads instantly at 10pt,
    /// and it survives being seen by someone who can't tell the colours apart.
    var symbolName: String {
        switch self {
        case .low: return "chevron.down"
        case .medium: return "minus"
        case .high: return "chevron.up"
        }
    }

    /// Highest first when sorting.
    var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    /// What a to-do gets when nobody said otherwise.
    static let unset: Priority = .medium
}
