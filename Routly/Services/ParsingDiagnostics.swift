//
//  ParsingDiagnostics.swift
//  RoutineOrganizer
//
//  Records which parser actually produced the last result. Without this, a
//  failed API call silently falls back to the offline stub and the user just
//  sees worse results with no explanation — which is exactly how "the AI isn't
//  splitting my tasks" turns into a mystery.
//

import Foundation

@MainActor
@Observable
final class ParsingDiagnostics {
    static let shared = ParsingDiagnostics()

    /// True when the last parse came from the Anthropic API.
    private(set) var lastUsedAI = false
    /// Why the last parse fell back to the offline stub, if it did.
    private(set) var fallbackReason: String?

    private init() {}

    func recordAISuccess() {
        lastUsedAI = true
        fallbackReason = nil
    }

    func recordFallback(_ reason: String) {
        lastUsedAI = false
        fallbackReason = reason
    }

    /// A short, user-facing explanation to show above a parsed review, or nil
    /// when parsing is working normally.
    var offlineNotice: String? {
        guard !lastUsedAI else { return nil }
        if let fallbackReason { return fallbackReason }
        return nil
    }
}
