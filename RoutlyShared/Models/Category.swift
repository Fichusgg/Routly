//
//  Category.swift
//  RoutineOrganizer
//
//  Life-area category for a schedule item. Kept dependency-free (Foundation
//  only); the color mapping lives in the DesignSystem layer so the model
//  stays UI-agnostic.
//

import Foundation

enum Category: String, Codable, CaseIterable, Identifiable, Sendable {
    case work
    case personal
    case health

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .work: return String(localized: "Work")
        case .personal: return String(localized: "Personal")
        case .health: return String(localized: "Health")
        }
    }

    /// Keywords the stub parser uses to infer a category from raw capture text.
    var keywords: [String] {
        switch self {
        case .work: return ["meeting", "work", "email", "deadline", "standup", "report", "project", "client"]
        case .health: return ["gym", "run", "workout", "exercise", "yoga", "walk", "meditate", "doctor", "dentist", "water"]
        case .personal: return ["mom", "dad", "family", "shopping", "groceries", "clean", "laundry", "birthday"]
        }
    }

    /// Default when nothing matches — the least presumptuous bucket.
    static let fallback: Category = .personal
}
