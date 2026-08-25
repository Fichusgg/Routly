//
//  VoiceLanguage.swift
//  RoutineOrganizer
//
//  The language you *speak* — chosen explicitly, and deliberately separate from
//  the interface language.
//
//  Why it's a choice rather than something detected: `SFSpeechRecognizer` binds
//  one recognizer to one locale and has no auto-detection, and feeding a single
//  live audio stream to several recognizers at once does not work — whichever
//  request receives the buffer first is the only one that produces results. So
//  "just detect it" is not a thing the platform can do. A recognizer pointed at
//  the wrong language does not fail loudly either; it returns confident-looking
//  nonsense, because it is doing exactly what it was asked to do.
//
//  Hence: pick a language, remember it, make it one tap to change.
//
//  Each language keeps a list of candidate locales rather than one hardcoded
//  identifier, so a phone set to Mexico gets es-MX and one set to Portugal gets
//  pt-PT — same language, noticeably better recognition.
//

import Foundation
import Speech

enum VoiceLanguage: String, CaseIterable, Identifiable, Sendable {
    case english
    case spanish
    case portuguese

    var id: String { rawValue }

    /// Endonyms, for the same reason `AppLanguage` uses them.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        }
    }

    /// A two-letter tag for the compact picker on the mic.
    var shortCode: String {
        switch self {
        case .english: return "EN"
        case .spanish: return "ES"
        case .portuguese: return "PT"
        }
    }

    var languageCode: String {
        switch self {
        case .english: return "en"
        case .spanish: return "es"
        case .portuguese: return "pt"
        }
    }

    /// Regional variants worth trying, best first. The head of the list is the
    /// safe default; earlier entries only win when they match the device region.
    var candidateLocales: [String] {
        switch self {
        case .english: return ["en-US", "en-GB", "en-AU", "en-CA", "en-IE", "en-IN", "en-NZ", "en-ZA"]
        case .spanish: return ["es-ES", "es-MX", "es-US", "es-AR", "es-CL", "es-CO"]
        case .portuguese: return ["pt-BR", "pt-PT"]
        }
    }

    // MARK: - Locale resolution

    /// Pick the best supported locale for this language: prefer one matching the
    /// device's own region, else the first candidate the recognizer supports,
    /// else the head of the list so there is always something to try.
    ///
    /// Split from `resolvedLocale()` so the preference order can be tested
    /// without depending on what the test machine happens to have installed.
    func preferredLocale(supported: Set<String>, deviceRegion: String?) -> String {
        let normalized = Set(supported.map(Self.normalize))

        if let deviceRegion {
            let regional = "\(languageCode)-\(deviceRegion)"
            if normalized.contains(Self.normalize(regional)) { return regional }
        }
        for candidate in candidateLocales where normalized.contains(Self.normalize(candidate)) {
            return candidate
        }
        return candidateLocales[0]
    }

    /// The locale to hand `SFSpeechRecognizer`, resolved against what this
    /// device actually supports.
    func resolvedLocale() -> Locale {
        Locale(identifier: preferredLocale(
            supported: Self.supportedIdentifiers(),
            deviceRegion: Locale.current.region?.identifier
        ))
    }

    /// Apple reports locales with mixed separators depending on the API and OS
    /// version; compare on a single normal form rather than trusting either.
    private static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func supportedIdentifiers() -> Set<String> {
        Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
    }

    // MARK: - On-device availability

    /// Whether this language can be transcribed without sending audio to Apple.
    ///
    /// This genuinely varies by device and language — the on-device model for a
    /// language may simply not be present. The app's default is on-device, so
    /// the answer decides whether we have to ask permission to leave it.
    func supportsOnDeviceRecognition() -> Bool {
        SFSpeechRecognizer(locale: resolvedLocale())?.supportsOnDeviceRecognition ?? false
    }

    // MARK: - Defaults

    /// The language to start someone on: what their phone is set to, when the
    /// app can transcribe it. Otherwise English — a wrong guess they can fix in
    /// one tap beats refusing to record.
    static var systemDefault: VoiceLanguage {
        for preferred in Locale.preferredLanguages {
            let code = Locale(identifier: preferred).language.languageCode?.identifier
            if let match = allCases.first(where: { $0.languageCode == code }) { return match }
        }
        return .english
    }

    static let storageKey = "voiceLanguage"
}
