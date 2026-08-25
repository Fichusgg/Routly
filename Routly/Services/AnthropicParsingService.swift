//
//  AnthropicParsingService.swift
//  RoutineOrganizer
//
//  Parsing via the Anthropic Messages API (no official Swift SDK exists, so this
//  is a hand-rolled URLSession request against the documented wire format).
//  Structured outputs constrain the model to the shared ParsingContract schema,
//  so one capture can yield many items — key for voice.
//
//  Any failure falls back to the rule-based stub and records why, so capture
//  never silently drops and the UI can explain the downgrade.
//

import Foundation

struct AnthropicParsingService: AIParsingService {
    let apiKey: String
    var model: String = AnthropicConfig.model
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
            guard let json = Self.textContent(from: data) else {
                return await fallbackParse(trimmed, now: now, workingHours: workingHours, lists: lists, reason: "Unexpected reply from Anthropic — used offline parsing.")
            }
            let items = try ParsingContract.items(fromJSON: json, now: now, sourceText: trimmed)
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

    // MARK: - Goal planning

    /// Expand a goal via the model, falling back to the offline template planner
    /// (the protocol default) on any failure — a plan is always produced.
    func plan(forGoal goal: String, now: Date) async -> ParsedPlan {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return PlanTemplates.plan(for: goal, now: now) }

        do {
            let request = try makePlanRequest(goal: trimmed, now: now)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = Self.textContent(from: data),
                  let plan = try ParsingContract.plan(fromJSON: json, now: now, sourceText: trimmed) else {
                return await fallbackPlan(trimmed, now: now, reason: "AI planning failed — used an offline plan.")
            }
            await MainActor.run { ParsingDiagnostics.shared.recordAISuccess() }
            return plan
        } catch {
            return await fallbackPlan(trimmed, now: now, reason: "AI planning unavailable (\(error.localizedDescription)) — used an offline plan.")
        }
    }

    private func fallbackPlan(_ goal: String, now: Date, reason: String) async -> ParsedPlan {
        await MainActor.run { ParsingDiagnostics.shared.recordFallback(reason) }
        return PlanTemplates.plan(for: goal, now: now)
    }

    private func makePlanRequest(goal: String, now: Date) throws -> URLRequest {
        var request = URLRequest(url: AnthropicConfig.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicConfig.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": ParsingContract.plannerSystemPrompt(now: now),
            "output_config": ["format": ["type": "json_schema", "schema": ParsingContract.planSchema]],
            "messages": [["role": "user", "content": goal]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Request

    private func makeRequest(text: String, now: Date, workingHours: WorkingHours, lists: [String]) throws -> URLRequest {
        var request = URLRequest(url: AnthropicConfig.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicConfig.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            // Generous headroom: a long spoken list can produce many items, and
            // a truncated response fails to decode (and would silently fall back).
            "max_tokens": 4096,
            "system": ParsingContract.systemPrompt(now: now, workingHours: workingHours, lists: lists),
            "output_config": ["format": ["type": "json_schema", "schema": ParsingContract.schema]],
            "messages": [["role": "user", "content": text]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response

    private static func textContent(from data: Data) -> String? {
        struct MessagesResponse: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        return (try? JSONDecoder().decode(MessagesResponse.self, from: data))?
            .content.first(where: { $0.type == "text" })?.text
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        struct APIError: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        return (try? JSONDecoder().decode(APIError.self, from: data))?.error?.message
    }
}
