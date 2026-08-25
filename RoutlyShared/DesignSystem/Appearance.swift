//
//  Appearance.swift
//  RoutineOrganizer
//
//  The light/dark preference. Light is the app's identity now, but "System" is
//  the default the platform expects — someone who runs their phone dark should
//  get a dark app without hunting for a setting, and everyone else lands on
//  light. The stored value is read at the root and applied once, so no screen
//  has to know the setting exists.
//

import SwiftUI

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// nil hands the decision back to the OS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "iphone"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// One key, shared by the root and the settings screen.
    static let storageKey = "appearance"
}
