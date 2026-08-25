//
//  EffortEstimator.swift
//  RoutineOrganizer
//
//  How long a to-do probably takes, when nobody said. Deliberately rule-based —
//  the same tier as SuggestionEngine, no pattern learning yet: keyword shape of
//  the title, nudged by category, falling back to a plain default.
//
//  A guess is never written back onto the item. The planner asks for one at the
//  moment it needs it and labels it as a guess in the UI, so the number the user
//  sees is either their own or visibly ours — never silently ours.
//

import Foundation

/// An effort figure plus where it came from, so the UI can be honest about it.
struct EffortEstimate: Equatable {
    var minutes: Int
    /// True when the user (or the parser reading their words) stated this.
    /// False when we inferred it from the title.
    var isStated: Bool

    var isGuess: Bool { !isStated }
}

struct EffortEstimator {

    /// Used when a title offers no signal at all — long enough to be worth
    /// starting, short enough that being wrong doesn't wreck the day.
    var defaultMinutes = 30

    /// The estimate for an item, preferring what's actually on it.
    func estimate(for item: ScheduleItem) -> EffortEstimate {
        if let stated = item.effortMinutes ?? item.durationMinutes {
            return EffortEstimate(minutes: stated, isStated: true)
        }
        return EffortEstimate(minutes: infer(from: item.title, category: item.category), isStated: false)
    }

    /// Keyword-shaped guess. Ordered longest-commitment first so "write the
    /// report" doesn't get caught by a shorter, weaker signal.
    func infer(from title: String, category: Category = .personal) -> Int {
        let text = title.lowercased()

        for (minutes, keywords) in Self.buckets {
            if keywords.contains(where: { text.contains($0) }) { return minutes }
        }

        // No keyword hit — lean on the category's typical shape. Work tasks
        // skew longer than errands.
        switch category {
        case .work: return 45
        case .health: return 30
        case .personal: return defaultMinutes
        }
    }

    /// Effort buckets, checked in order. Each is a rough "this kind of verb
    /// usually costs about this much".
    private static let buckets: [(Int, [String])] = [
        (120, ["write", "draft", "report", "presentation", "deep clean", "move ",
               "assemble", "taxes", "essay", "study", "revise", "spring clean"]),
        (90,  ["project", "plan ", "review", "research", "prepare", "organize",
               "declutter", "renovate", "paint"]),
        (60,  ["clean", "cook", "meal prep", "workout", "gym", "run", "laundry",
               "shop", "groceries", "errand", "appointment", "meeting"]),
        (30,  ["read", "walk", "tidy", "sort", "practice", "stretch", "yoga",
               "meditate", "budget", "dishes", "water"]),
        (15,  ["email", "reply", "message", "book ", "schedule", "order",
               "pay ", "confirm", "print", "sign", "submit", "renew"]),
        (10,  ["call", "text", "ping", "check", "remind", "rsvp", "quick"]),
    ]
}
