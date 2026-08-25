//
//  AppLanguage.swift
//  RoutineOrganizer
//
//  The language the *interface* is written in — independent of the language you
//  speak into the mic (that's `VoiceLanguage`). Someone running their phone in
//  English while dictating in Portuguese is a normal case, not an edge one.
//
//  "System" is the default and the right one for almost everybody: iOS already
//  knows which languages you read, in what order. The override exists for the
//  people that fails — a phone set to a language the app doesn't ship, or a
//  household sharing one device.
//
//  Each option names itself in its own language. A picker that says "Spanish"
//  is useless to the person who needs it most: someone who has landed in a UI
//  they can't read and is looking for the word they recognize.
//

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case spanish
    case portuguese

    var id: String { rawValue }

    /// The language code written into `AppleLanguages`. nil hands the choice
    /// back to iOS.
    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .spanish: return "es"
        case .portuguese: return "pt-BR"
        }
    }

    /// Endonyms — see the file note. Deliberately *not* localized: "Español"
    /// reads the same whatever the UI language happens to be right now.
    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        }
    }

    /// The languages this app actually ships strings for, in menu order.
    static var shipped: [AppLanguage] { [.english, .spanish, .portuguese] }

    /// Which shipped language iOS would pick right now, used to describe what
    /// "System" resolves to rather than leaving the user to guess.
    static var systemResolved: AppLanguage {
        for preferred in Locale.preferredLanguages {
            let code = Locale(identifier: preferred).language.languageCode?.identifier
            switch code {
            case "en": return .english
            case "es": return .spanish
            case "pt": return .portuguese
            default: continue
            }
        }
        // Nothing the app speaks — iOS falls back to the development region.
        return .english
    }

    /// The key iOS itself reads at launch to decide the app's language.
    static let appleLanguagesKey = "AppleLanguages"
    static let storageKey = "appLanguage"

    /// The locale the widget extension should render in.
    ///
    /// The app gets its language from `AppleLanguages`, which iOS reads per
    /// process at launch — and the widget is a *different* process, with its own
    /// domain, that never sees that key. Left alone, someone running Routly in
    /// Spanish would get an English widget on their home screen and no way to
    /// explain it.
    ///
    /// So the extension resolves the preference itself and pushes it into the
    /// SwiftUI environment, where `Text` consults it to pick a localization.
    /// "System" hands the decision back to iOS, which is right for almost
    /// everyone — hence nil rather than a guess.
    var explicitLocale: Locale? {
        localeIdentifier.map(Locale.init(identifier:))
    }
}
