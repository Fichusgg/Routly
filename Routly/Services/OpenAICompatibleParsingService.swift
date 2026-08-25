//
//  OpenAICompatibleParsingService.swift
//  RoutineOrganizer
//
//  Parsing via any provider that speaks the OpenAI /chat/completions shape —
//  DeepSeek, Qwen (DashScope), OpenRouter, Groq, Together, or a local model
//  served by Ollama / LM Studio. Same protocol, same prompt, same decoding as
//  the Anthropic path, so the rest of the app is unaffected by the choice.
//
//  Note: most of these support JSON mode (`response_format: json_object`) but
//  not strict JSON-schema enforcement, so the structure comes from the prompt
//  and the decoder is deliberately tolerant of fenced or prose-wrapped replies.
//

import Foundation

struct OpenAICompatibleParsingService: AIParsingService {
    /// Base URL of the provider, e.g. https://api.deepseek.com/v1
    let baseURL: URL
    let model: String
    /// Empty for local servers that need no auth (Ollama, LM Studio).
    var apiKey: String = ""
    var session: URLSession = .shared
    var fallback: AIParsingService = StubAIParsingService()

    func parse(_ text: String, now: Date, workingHours: WorkingHours, lists: [String]) async -> [ParsedCapture] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            let request = try makeRequest(text: trimmed, now: now, workingHours: workingHours, lists: lists)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return await fallbackParse(trimmed, now: now, workingHours: workingHours, lists: lists, reason: "No response from the parser — used offline parsing.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = Self.apiErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                return await fallbackParse(trimmed, now: now, workingHours: workingHours, lists: lists, reason: "AI parsing failed (\(detail)) — used offline parsing.")
            }
            guard let content = Self.messageContent(from: data) else {
                return await fallbackParse(trimmed, now: now, workingHours: workingHours, lists: lists, reason: "Unexpected reply from the provider — used offline parsing.")
            }
            let items = try ParsingContract.items(fromJSON: content, now: now, sourceText: trimmed)
            guard !items.isEmpty else {
                return await fallbackParse(trimmed, now: now, workingHours: workingHours, lists: lists, reason: "AI returned no items — used offline parsing.")
            }
            await MainActor.run { ParsingDiagnostics.shared.recordAISuccess() }
            return items
        } catch {
            return await fallbackParse(trimmed, now: now, workingHours: workingHours, lists: lists, reason: "AI parsing unavailable (\(error.localizedDescription)) — used offline parsing.")
        }
    }

    private func fallbackParse(_ text: String, now: Date, workingHours: WorkingHours, lists: [String], reason: String) async -> [ParsedCapture] {
        await MainActor.run { ParsingDiagnostics.shared.recordFallback(reason) }
        return await fallback.parse(text, now: now, workingHours: workingHours, lists: lists)
    }

    // MARK: - Request

    private func makeRequest(text: String, now: Date, workingHours: WorkingHours, lists: [String]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            // Extraction is not a creative task — sampling variance just makes
            // the same capture split differently between runs.
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": ParsingContract.systemPrompt(now: now, workingHours: workingHours, lists: lists)],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response

    private static func messageContent(from data: Data) -> String? {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        return (try? JSONDecoder().decode(Completion.self, from: data))?
            .choices?.first?.message?.content
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        struct APIError: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        return (try? JSONDecoder().decode(APIError.self, from: data))?.error?.message
    }
}
