//
//  AnthropicConfig.swift
//  RoutineOrganizer
//
//  Where the real parser gets its settings. The API key is read from a
//  gitignored `Secrets.plist` (see Secrets.example.plist) so it never lands in
//  version control; if no key is present the app falls back to the rule-based
//  stub and still runs fully offline.
//
//  ⚠️ Dev-stage only: a key bundled in the app is extractable from the binary.
//  Before shipping to real users, move parsing behind a backend proxy so the
//  key never leaves your server. (See the Phase 2 notes.)
//

import Foundation

enum AnthropicConfig {
    /// User-selected model for parsing (fast + cheap, well-suited to structured
    /// extraction). Behind the AIParsingService protocol, so easy to change.
    static let model = "claude-haiku-4-5"
    static let apiVersion = "2023-06-01"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Everything in `Secrets.plist`, read exactly once.
    ///
    /// Every lookup used to re-open the file. `ParsingServiceFactory.make()`
    /// alone costs five of them — `isConfigured` reads baseURL and model, then
    /// both are read again, then the key — and `make()` is the default argument
    /// of `ScheduleViewModel.init`, which is evaluated inside a `@State`
    /// initializer, which SwiftUI re-runs on every construction of the view
    /// struct. The device log named this directly: "Performing I/O on the main
    /// thread can cause hangs", triggered by `-[NSData initWithContentsOfURL:]`.
    ///
    /// A `TabView` makes that structural rather than incidental — it builds
    /// every tab's content struct in order to build the bar, so the cost would
    /// have been multiplied by the number of tabs, permanently. Caching here
    /// fixes it at the source instead: after the first read there is no file
    /// I/O left to multiply.
    ///
    /// `static let` is lazy and thread-safe. The trade is that editing
    /// Secrets.plist needs a relaunch to take effect, which is right for a
    /// build-time file.
    private static let secrets: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any]
        else { return [:] }
        return dict.compactMapValues { $0 as? String }
    }()

    /// The Anthropic API key, or nil when none is configured.
    /// Looks in a bundled `Secrets.plist` first, then an `AnthropicAPIKey`
    /// Info.plist entry, so either mechanism works.
    static var apiKey: String? { secret("AnthropicAPIKey") }

    static var hasKey: Bool { apiKey != nil }

    /// Reads a string from Secrets.plist, falling back to Info.plist.
    ///
    /// The Info.plist fallback deliberately still queries the bundle each time:
    /// `object(forInfoDictionaryKey:)` reads an already-loaded dictionary, so
    /// it was never the expensive half.
    static func secret(_ key: String) -> String? {
        if let value = secrets[key],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }
}

/// Any provider speaking the OpenAI /chat/completions shape — DeepSeek, Qwen
/// (DashScope), OpenRouter, Groq, or a local Ollama / LM Studio server.
enum OpenAICompatibleConfig {
    static var baseURL: URL? { AnthropicConfig.secret("AIBaseURL").flatMap(URL.init(string:)) }
    static var model: String? { AnthropicConfig.secret("AIModel") }
    /// Optional — local servers usually need no key.
    static var apiKey: String { AnthropicConfig.secret("AIAPIKey") ?? "" }

    /// Configured only when both an endpoint and a model are set.
    static var isConfigured: Bool { baseURL != nil && model != nil }
}
