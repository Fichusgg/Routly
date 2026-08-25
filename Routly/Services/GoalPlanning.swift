//
//  GoalPlanning.swift
//  RoutineOrganizer
//
//  Turning a spoken *goal* ("I want to get back into shape") into an actual plan —
//  a small, sane set of routines and first steps — rather than logging one vague
//  to-do. This file holds the pure, offline-testable core:
//
//   • the value types a plan is made of,
//   • `GoalDetector`, the heuristic that decides "goal to expand" vs "list of
//     items to log" (the routing behind the hybrid capture flow), and
//   • `PlanTemplates`, which maps a goal to a starter plan and is the guaranteed
//     fallback when there's no AI key or the model call fails.
//
//  Everything here is deterministic and dependency-free so the routing and the
//  generated plans can be pinned down in tests without a network or SwiftData.
//

import Foundation

/// The time frame a goal is aimed at, when the person states one.
enum PlanHorizon: String, Sendable, Equatable {
    case thisWeek
    case thisMonth
    case thisQuarter

    var displayName: String {
        switch self {
        case .thisWeek: return String(localized: "This week")
        case .thisMonth: return String(localized: "This month")
        case .thisQuarter: return String(localized: "This quarter")
        }
    }
}

/// A goal expanded into a reviewable plan. Its `items` are ordinary
/// `ParsedCapture`s, so a plan flows through the exact same review → edit →
/// commit machinery as normal voice capture.
struct ParsedPlan: Equatable, Sendable {
    var goalTitle: String
    /// One line framing the approach, shown atop the review.
    var summary: String
    var horizon: PlanHorizon?
    var items: [ParsedCapture]
    var sourceText: String
}

/// What a capture turned out to be once interpreted: a flat list of items (the
/// original behavior) or a goal that was expanded into a plan.
enum CaptureInterpretation: Equatable, Sendable {
    case items([ParsedCapture])
    case plan(ParsedPlan)
}

// MARK: - Goal detection

/// Decides whether a capture reads as a broad *goal* to build a plan from, or a
/// *list of discrete things* to log. Deliberately conservative: it only claims
/// "goal" on a reasonably clear aspiration, because the hybrid flow's default is
/// to treat ambiguous input as items (the safer, less surprising interpretation),
/// and the review screen offers a one-tap switch either way.
enum GoalDetector {

    /// Phrases that open an aspiration.
    private static let aspirationLeads = [
        "i want to", "i'd like to", "i would like to", "i wanna", "i need to get",
        "i want ", "my goal is", "i'm trying to", "im trying to", "i hope to",
        "i'd love to", "help me", "i want to start", "i want to get"
    ]

    /// Verbs/phrases that read as long-horizon ambitions rather than one errand.
    private static let ambitionMarkers = [
        "get back into", "get in shape", "get fit", "get healthy", "lose weight",
        "back into shape", "learn", "launch", "start a", "build a", "grow",
        "train for", "run a marathon", "save money", "save up", "read more",
        "eat healthier", "eat better", "get better at", "improve my", "quit",
        "write a book", "get organized", "sleep better", "meditate more",
        "side project", "my startup", "my business", "in shape", "healthier",
        "more consistent", "a habit", "into a routine"
    ]

    /// Markers that a capture is really a list of separate tasks — these veto a
    /// goal reading even if an ambition word appears.
    private static let listMarkers = [
        " and also ", ", and ", "also i ", "then i need", "remind me",
        "pick up", "buy ", "call ", "email ", "at 9", "at 10", "at 11",
        "tomorrow at", "pm ", "am ", "o'clock"
    ]

    static func looksLikeGoal(_ text: String) -> Bool {
        let t = " " + text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + " "
        guard t.count > 6 else { return false }

        // Several comma/"and"-separated clauses reads as a list, not one goal.
        let clauseCount = t.components(separatedBy: CharacterSet(charactersIn: ",")).count
        let listish = listMarkers.filter { t.contains($0) }.count
        let hasAspiration = aspirationLeads.contains { t.contains($0) }
        let hasAmbition = ambitionMarkers.contains { t.contains($0) }

        // A clear list beats a stray ambition word.
        if listish >= 2 { return false }
        if clauseCount >= 3 && !hasAspiration { return false }

        // A goal is an aspiration lead plus a long-horizon ambition, or a very
        // strong ambition phrase on its own in a short, single-clause capture.
        if hasAspiration && hasAmbition { return true }
        if hasAmbition && clauseCount <= 2 && listish == 0 && wordCount(t) <= 12 { return true }
        return false
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }
}

// MARK: - Template planner

/// The deterministic fallback planner. Maps a goal to a small starter plan built
/// from a handful of archetypes; unknown goals get a minimal, honest generic
/// plan rather than nothing. The real AI planner produces richer plans, but this
/// is what runs offline and what every plan is unit-tested against.
enum PlanTemplates {

    /// Never overwhelm: a plan is a nudge, not a life overhaul.
    static let maxItems = 6

    static func plan(for goal: String, now: Date = Date()) -> ParsedPlan {
        let cleaned = cleanGoalTitle(goal)
        let lower = goal.lowercased()
        let horizon = detectHorizon(lower)

        let (summary, drafts) = archetype(for: lower, title: cleaned)
        let items = drafts.prefix(maxItems).map { $0.capture(sourceText: goal, now: now) }

        return ParsedPlan(
            goalTitle: cleaned,
            summary: summary,
            horizon: horizon,
            items: Array(items),
            sourceText: goal
        )
    }

    // MARK: Archetypes

    private static func archetype(for lower: String, title: String) -> (String, [PlanDraft]) {
        if matches(lower, ["shape", "fit", "weight", "gym", "exercise", "workout", "run", "health", "strong", "active"]) {
            return ("A gentle return to fitness — a few sessions a week, not everything at once.", [
                PlanDraft("Work out", kind: .todo, category: .health, recurrence: .timesPerWeek(3)),
                PlanDraft("Move for 20 minutes", kind: .todo, category: .health, recurrence: .everyDay),
                PlanDraft("Plan this week's workouts", kind: .todo, category: .health, dayOffset: 0),
                PlanDraft("Prep healthy meals", kind: .todo, category: .health, recurrence: .weekly(on: [1])),
            ])
        }
        if matches(lower, ["learn", "study", "language", "course", "read", "skill", "practice", "spanish", "french", "code", "guitar", "piano"]) {
            return ("Steady practice beats cramming — small, regular reps toward it.", [
                PlanDraft("Study \(shortSubject(title))", kind: .todo, category: .personal, recurrence: .timesPerWeek(4)),
                PlanDraft("Find a course or resource", kind: .todo, category: .personal, dayOffset: 0),
                PlanDraft("Practice for 15 minutes", kind: .todo, category: .personal, recurrence: .everyDay),
            ])
        }
        if matches(lower, ["launch", "startup", "start-up", "ship", "business", "side project", "product", "company", "mvp", "app"]) {
            return ("Ship in small, visible steps — momentum from weekly progress.", [
                PlanDraft("Define the first milestone", kind: .todo, category: .work, dayOffset: 0),
                PlanDraft("Focused build time", kind: .todo, category: .work, recurrence: .timesPerWeek(3)),
                PlanDraft("Talk to a potential user", kind: .todo, category: .work, recurrence: .weekly(on: [3])),
                PlanDraft("Weekly progress review", kind: .todo, category: .work, recurrence: .weekly(on: [6])),
            ])
        }
        if matches(lower, ["save", "money", "budget", "finance", "spend", "debt", "invest"]) {
            return ("Small, repeatable money habits — awareness first, then momentum.", [
                PlanDraft("Review this week's spending", kind: .todo, category: .personal, recurrence: .weekly(on: [1])),
                PlanDraft("Set a savings target", kind: .todo, category: .personal, dayOffset: 0),
                PlanDraft("Cancel unused subscriptions", kind: .todo, category: .personal, dayOffset: 0),
            ])
        }
        if matches(lower, ["sleep", "meditate", "mindful", "stress", "calm", "journal", "habit", "routine", "consistent", "organized"]) {
            return ("Build the habit gently — one small daily anchor to start.", [
                PlanDraft("Daily wind-down", kind: .todo, category: .health, recurrence: .everyDay),
                PlanDraft("Check in on how it's going", kind: .todo, category: .personal, recurrence: .weekly(on: [1])),
                PlanDraft("Set up what you need to start", kind: .todo, category: .personal, dayOffset: 0),
            ])
        }
        // Generic: break it down + a recurring check-in.
        return ("A simple start — break it into first steps and revisit it weekly.", [
            PlanDraft("Break \"\(shortSubject(title))\" into first steps", kind: .todo, category: .personal, dayOffset: 0),
            PlanDraft("Take the first step", kind: .todo, category: .personal, dayOffset: 0),
            PlanDraft("Weekly check-in on \(shortSubject(title))", kind: .todo, category: .personal, recurrence: .weekly(on: [1])),
        ])
    }

    // MARK: Helpers

    private static func matches(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    /// These are the offline path — the model handles horizons itself when it is
    /// reachable. Spanish and Portuguese phrasings are listed alongside the
    /// English so a goal stated out loud in either still lands somewhere, rather
    /// than silently losing its time frame the moment the network drops.
    ///
    /// Longest span first: "este mes" is a substring of nothing here, but
    /// "quarter" must be tested before "month" for "this quarter of the month"
    /// style phrasings.
    static func detectHorizon(_ lower: String) -> PlanHorizon? {
        let quarter = ["this quarter", "this year", "next few months",
                       "este trimestre", "este año", "este ano",
                       "próximos meses", "proximos meses"]
        let month = ["this month", "este mes", "este mês", "neste mes", "neste mês"]
        let week = ["this week", "esta semana", "nesta semana"]

        if matches(lower, quarter) { return .thisQuarter }
        if matches(lower, month) { return .thisMonth }
        if matches(lower, week) { return .thisWeek }
        return nil
    }

    /// Strip the leading intent ("I want to …") and tidy into a short title.
    static func cleanGoalTitle(_ goal: String) -> String {
        var s = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let leads = ["i want to ", "i'd like to ", "i would like to ", "i wanna ",
                     "i need to ", "my goal is to ", "my goal is ", "i'm trying to ",
                     "im trying to ", "i hope to ", "help me ", "i'd love to "]
        let lower = s.lowercased()
        for lead in leads where lower.hasPrefix(lead) {
            s = String(s.dropFirst(lead.count))
            break
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        guard let first = s.first else { return String(localized: "New goal") }
        return first.uppercased() + s.dropFirst()
    }

    /// A compact noun-ish fragment for embedding in a title ("Get back into shape").
    private static func shortSubject(_ title: String) -> String {
        let words = title.split(separator: " ")
        return words.prefix(5).joined(separator: " ").lowercased()
    }
}

/// A lightweight recipe for one plan item, resolved to a `ParsedCapture` with a
/// concrete date when needed.
private struct PlanDraft {
    let title: String
    let kind: ItemKind
    let category: Category
    let recurrence: RecurrenceRule?
    /// A concrete day for a one-off first step (0 = today), else nil = undated
    /// (rolls on the Today to-do list).
    let dayOffset: Int?

    init(_ title: String, kind: ItemKind, category: Category,
         recurrence: RecurrenceRule? = nil, dayOffset: Int? = nil) {
        self.title = title
        self.kind = kind
        self.category = category
        self.recurrence = recurrence
        self.dayOffset = dayOffset
    }

    func capture(sourceText: String, now: Date) -> ParsedCapture {
        let calendar = Calendar(identifier: .gregorian)
        let date = dayOffset.flatMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now)) }
        return ParsedCapture(
            title: title,
            kind: kind,
            scheduledDate: recurrence == nil ? date : nil,
            startTime: nil,
            durationMinutes: nil,
            category: category,
            recurrence: recurrence,
            sourceText: sourceText
        )
    }
}
