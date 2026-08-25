//
//  AIParsingService.swift
//  RoutineOrganizer
//
//  The parsing seam. Everything that turns messy human text into structured
//  items goes through this protocol, so the rule-based stub and the real
//  Anthropic-backed implementation are interchangeable behind it.
//
//  A single capture can yield *multiple* items — someone listing five things in
//  one breath (especially via voice) should produce five items, not one — so the
//  protocol returns an array.
//

import Foundation

/// The structured result of interpreting one item from a freeform capture.
/// Intentionally a plain value type: the view model turns it into a
/// `ScheduleItem`, so parsing stays free of any persistence dependency.
struct ParsedCapture: Equatable, Sendable {
    var title: String
    var kind: ItemKind
    var scheduledDate: Date?
    var startTime: Date?
    var durationMinutes: Int?
    /// How long the *work* takes, for a to-do that named a size ("finish the
    /// report, probably two hours"). Distinct from `durationMinutes`, which is
    /// how long an event runs on the clock.
    var effortMinutes: Int?
    var category: Category
    var recurrence: RecurrenceRule?
    var sourceText: String

    /// The name of the list this to-do appears to belong under, when the model
    /// recognised one of the user's own lists in it — "math homework" filed
    /// under "School".
    ///
    /// A *name*, not a `TodoList`. These values cross actor boundaries and are
    /// built by services that know nothing about SwiftData; resolving the name
    /// to a real list happens on the screen that already has them queried, and
    /// quietly comes to nothing if the list was renamed or deleted in between.
    var listName: String?

    /// A follow-up question when the input is too ambiguous to resolve. The
    /// stub leaves this nil; the real parser uses it to flag rather than guess.
    var clarificationNeeded: String?

    init(
        title: String,
        kind: ItemKind = .todo,
        scheduledDate: Date? = nil,
        startTime: Date? = nil,
        durationMinutes: Int? = nil,
        effortMinutes: Int? = nil,
        category: Category = .personal,
        recurrence: RecurrenceRule? = nil,
        sourceText: String,
        clarificationNeeded: String? = nil,
        listName: String? = nil
    ) {
        self.title = title
        self.kind = kind
        self.scheduledDate = scheduledDate
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.effortMinutes = effortMinutes
        self.category = category
        self.recurrence = recurrence
        self.sourceText = sourceText
        self.clarificationNeeded = clarificationNeeded
        self.listName = listName
    }
}

protocol AIParsingService: Sendable {
    /// Parse raw capture text into zero or more structured items.
    ///
    /// `now` is injectable so relative dates ("tomorrow") are testable and
    /// deterministic. `workingHours` is passed rather than read from settings
    /// for the same reason, plus one of its own: these services are `Sendable`
    /// and run off the main actor, while `AppSettings` is main-actor isolated.
    /// A plain value crossing the boundary is simpler than a hop, and can't go
    /// stale the way a snapshot taken at construction would.
    ///
    /// `lists` are the user's own list names, passed for the same reasons and
    /// used for the same kind of judgement: the model can only file "math
    /// homework" under "School" if it has been told School exists. Empty is the
    /// normal case — most people have no lists — and means "don't file
    /// anything".
    func parse(
        _ text: String,
        now: Date,
        workingHours: WorkingHours,
        lists: [String]
    ) async -> [ParsedCapture]

    /// Expand a stated goal into a starter plan. Defaulted to the offline
    /// template planner; the AI-backed services override this for richer plans
    /// and fall back to the template on failure.
    func plan(forGoal goal: String, now: Date) async -> ParsedPlan
}

extension AIParsingService {
    /// The everyday form: no lists to file into.
    func parse(
        _ text: String,
        now: Date,
        workingHours: WorkingHours
    ) async -> [ParsedCapture] {
        await parse(text, now: now, workingHours: workingHours, lists: [])
    }

    func parse(_ text: String, now: Date) async -> [ParsedCapture] {
        await parse(text, now: now, workingHours: .default, lists: [])
    }

    func parse(_ text: String) async -> [ParsedCapture] {
        await parse(text, now: Date(), workingHours: .default, lists: [])
    }

    /// The single-item convenience used by the inline "autofill from text" wand,
    /// where the user is editing one item and only the first parse is relevant.
    func parseFirst(
        _ text: String,
        now: Date = Date(),
        workingHours: WorkingHours = .default,
        lists: [String] = []
    ) async -> ParsedCapture? {
        await parse(text, now: now, workingHours: workingHours, lists: lists).first
    }

    /// Default plan generation: the deterministic template planner. Offline,
    /// always available, and the guaranteed fallback for the AI services.
    func plan(forGoal goal: String, now: Date) async -> ParsedPlan {
        PlanTemplates.plan(for: goal, now: now)
    }

    /// The hybrid capture router: is this a broad goal to expand into a plan, or
    /// a list of discrete items to log? Classification is a fast, deterministic
    /// heuristic (one tested path for every provider); the confirm-before-commit
    /// review lets the user flip the interpretation with one tap when it's wrong.
    func interpret(
        _ text: String,
        now: Date = Date(),
        workingHours: WorkingHours = .default,
        lists: [String] = []
    ) async -> CaptureInterpretation {
        if GoalDetector.looksLikeGoal(text) {
            return .plan(await plan(forGoal: text, now: now))
        }
        return .items(await parse(text, now: now, workingHours: workingHours, lists: lists))
    }
}
