//
//  ParsingServiceFactory.swift
//  RoutineOrganizer
//
//  Chooses the parser at runtime: the real Anthropic service when an API key is
//  configured, otherwise the offline rule-based stub. One place decides, so the
//  rest of the app just depends on the AIParsingService protocol.
//

import Foundation

enum ParsingServiceFactory {
    static func make() -> AIParsingService {
        // An OpenAI-compatible endpoint wins when configured, so pointing the app
        // at DeepSeek / Qwen / a local model is purely a Secrets.plist change.
        if OpenAICompatibleConfig.isConfigured,
           let baseURL = OpenAICompatibleConfig.baseURL,
           let model = OpenAICompatibleConfig.model {
            return OpenAICompatibleParsingService(
                baseURL: baseURL,
                model: model,
                apiKey: OpenAICompatibleConfig.apiKey
            )
        }
        if let key = AnthropicConfig.apiKey {
            return AnthropicParsingService(apiKey: key)
        }
        Task { @MainActor in
            ParsingDiagnostics.shared.recordFallback(
                "No AI provider configured — using offline parsing, which merges tasks and produces rough titles."
            )
        }
        return StubAIParsingService()
    }

    /// Where captures would be sent, or nil when this build has no cloud parser
    /// configured at all and everything is read on the phone regardless.
    ///
    /// Exposed so the settings screen can state the destination as a fact read
    /// off the same configuration `make()` uses, rather than as a sentence
    /// someone wrote once and has to remember to update. A screen that says
    /// "your captures stay on this phone" while a key is quietly configured is
    /// worse than saying nothing.
    ///
    /// The host is deliberately the real one — "api.groq.com" tells the user
    /// something checkable, where "a cloud service" asks them to take it on
    /// trust. `localhost` and friends are still reported: a local server is
    /// off-device from the phone's point of view, even if it never leaves the
    /// building.
    static var cloudHost: String? {
        if OpenAICompatibleConfig.isConfigured {
            return OpenAICompatibleConfig.baseURL?.host
        }
        if AnthropicConfig.hasKey {
            return AnthropicConfig.endpoint.host
        }
        return nil
    }
}
