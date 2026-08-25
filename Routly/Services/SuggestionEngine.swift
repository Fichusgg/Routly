//
//  SuggestionEngine.swift
//  RoutineOrganizer
//
//  Lightweight, heuristic schedule suggestions — no historical learning yet,
//  just sensible observations surfaced gently on Today: back-to-back items with
//  no buffer, a day overloaded while a nearby day is empty, and to-dos that have
//  gone stale.
//
//  Each suggestion carries a plain-language reason, a stable id so the UI can
//  dismiss it without it nagging back, and — where there's an obvious fix — an
//  action the user can apply. Actions are described, never applied silently:
//  the UI always confirms first.
//

import Foundation

/// A concrete change a suggestion can make, addressed by item id so the
/// engine stays free of any persistence dependency.
enum SuggestionAction: Equatable {
    /// Move a timed item to a new start, keeping its duration.
    case reschedule(itemID: UUID, newStart: Date)
    /// Give a to-do a day (no particular time).
    case scheduleTodo(itemID: UUID, day: Date)
    /// Give a to-do a specific slot, blocking out `minutes` for it so the time
    /// is genuinely reserved rather than notionally assigned.
    case scheduleTodoAt(itemID: UUID, start: Date, minutes: Int?)
}

struct ScheduleSuggestion: Identifiable, Equatable {
    enum Kind: String {
        case backToBack, dayImbalance, staleTodo
        /// "Do this, then, because…" — the day planner's output.
        case recommendation
        /// Something that honestly doesn't fit today.
        case wontFit
    }

    let id: String
    let kind: Kind
    let message: String
    let systemImage: String
    /// The change applying this suggestion would make, if any.
    var action: SuggestionAction?
    /// Short label for the confirm button, e.g. "Move to 10:15 AM".
    var actionTitle: String?
    /// Plain-language "why this, why now", shown under the headline.
    var reason: String?
    /// The slot being proposed, for surfaces that lay recommendations out on a
    /// timeline rather than as prose.
    var slotStart: Date?
    var slotMinutes: Int?
    /// True when the length shown was inferred rather than stated.
    var effortIsGuess: Bool = false
}

struct SuggestionEngine {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1
        return c
    }()
    var engine = ScheduleEngine()
    var planner = DayPlanner()
    var preferences: SchedulingPreferences = .default

    /// A to-do is "stale" once it's rolled unfinished for this many days.
    var staleTodoDays = 3
    /// Breathing room inserted between back-to-back items.
    var bufferMinutes = 15

    /// One place to set the working window, so this engine and the planner it
    /// delegates to can't end up disagreeing about when the day ends — which
    /// would show up as a recommendation for a time the engine then calls
    /// overloaded.
    mutating func setWorkingHours(_ hours: WorkingHours) {
        preferences.workingHours = hours
        planner.preferences.workingHours = hours
    }

    // MARK: - Ambient suggestions (the Today card)

    func suggestions(from items: [ScheduleItem], now: Date = Date(), horizonDays: Int = 7) -> [ScheduleSuggestion] {
        var result: [ScheduleSuggestion] = []
        let today = calendar.startOfDay(for: now)
        let days = (0..<horizonDays).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }

        result.append(contentsOf: backToBackSuggestions(items: items, days: days))
        if let imbalance = imbalanceSuggestion(items: items, days: days) {
            result.append(imbalance)
        }
        result.append(contentsOf: staleTodoSuggestions(items: items, now: now))
        return result
    }

    // MARK: - "Optimize my day" (today only, deadline-focused)

    /// A focused pass over *today*: what would help actually finish today's
    /// work. The real thinking is the `DayPlanner`'s — this turns its plan into
    /// the suggestion currency the rest of the app already speaks, so the
    /// confirm-then-apply path is shared rather than forked.
    func optimizeToday(from items: [ScheduleItem], now: Date = Date()) -> [ScheduleSuggestion] {
        let today = calendar.startOfDay(for: now)
        let plan = planner.plan(from: items, now: now)
        var result: [ScheduleSuggestion] = []

        // 1. What to do, when, and why — the heart of it.
        result.append(contentsOf: plan.recommendations.map(suggestion(from:)))

        // 2. What genuinely won't fit. Said plainly, never crammed in above.
        result.append(contentsOf: plan.unplaced.map(suggestion(from:)))

        // 3. Then the ambient housekeeping, below the plan.
        result.append(contentsOf: backToBackSuggestions(items: items, days: [today]))
        result.append(contentsOf: staleTodoSuggestions(items: items, now: now))

        return result
    }

    /// The full plan, for surfaces that want the headline numbers (how much
    /// time is actually left) alongside the individual rows.
    func dayPlan(from items: [ScheduleItem], now: Date = Date()) -> DayPlan {
        planner.plan(from: items, now: now)
    }

    private func suggestion(from recommendation: Recommendation) -> ScheduleSuggestion {
        let timeText = recommendation.start.formatted(date: .omitted, time: .shortened)
        return ScheduleSuggestion(
            id: "plan-\(recommendation.itemID)",
            kind: .recommendation,
            message: recommendation.title,
            systemImage: "target",
            action: .scheduleTodoAt(
                itemID: recommendation.itemID,
                start: recommendation.start,
                minutes: recommendation.minutes
            ),
            actionTitle: String(localized: "Schedule for \(timeText)"),
            reason: recommendation.reason,
            slotStart: recommendation.start,
            slotMinutes: recommendation.minutes,
            effortIsGuess: recommendation.effortIsGuess
        )
    }

    private func suggestion(from unplaced: UnplacedTask) -> ScheduleSuggestion {
        var action: SuggestionAction?
        var actionTitle: String?
        if case let .moveToTomorrowMorning(date) = unplaced.resolution {
            action = .scheduleTodoAt(itemID: unplaced.itemID, start: date, minutes: unplaced.minutes)
            actionTitle = String(localized: "Move to tomorrow morning")
        }

        return ScheduleSuggestion(
            id: "wontFit-\(unplaced.itemID)",
            kind: .wontFit,
            message: unplaced.title,
            systemImage: "exclamationmark.triangle",
            action: action,
            actionTitle: actionTitle,
            reason: unplaced.reason,
            slotMinutes: unplaced.minutes
        )
    }

    // MARK: - Back-to-back with no buffer

    private func backToBackSuggestions(items: [ScheduleItem], days: [Date]) -> [ScheduleSuggestion] {
        var out: [ScheduleSuggestion] = []
        for day in days {
            let timed = items
                .filter { $0.startTime != nil && $0.kind == .event && engine.occurs($0, on: day) }
                .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
            for (a, b) in zip(timed, timed.dropFirst()) {
                guard let aStart = a.startTime, let bStart = b.startTime else { continue }
                let aEnd = calendar.date(byAdding: .minute, value: a.durationMinutes ?? 60, to: aStart) ?? aStart
                guard aEnd >= bStart else { continue }

                let newStart = calendar.date(byAdding: .minute, value: bufferMinutes, to: aEnd) ?? bStart
                let timeText = newStart.formatted(date: .omitted, time: .shortened)
                out.append(ScheduleSuggestion(
                    id: "backToBack-\(a.id)-\(b.id)",
                    kind: .backToBack,
                    message: String(localized: "“\(a.title)” runs right into “\(b.title)” with no buffer. Add a gap?"),
                    systemImage: "arrow.left.arrow.right",
                    action: .reschedule(itemID: b.id, newStart: newStart),
                    actionTitle: String(localized: "Move “\(b.title)” to \(timeText)")
                ))
            }
        }
        return out
    }

    // MARK: - One day overloaded while a nearby day is empty

    private func imbalanceSuggestion(items: [ScheduleItem], days: [Date]) -> ScheduleSuggestion? {
        let loads = days.map { day -> (day: Date, hours: Double, count: Int) in
            let timed = items.filter { $0.startTime != nil && engine.occurs($0, on: day) }
            let hours = timed.reduce(0.0) { $0 + Double($1.durationMinutes ?? ($1.kind == .event ? 60 : 0)) / 60 }
            return (day, hours, timed.count)
        }

        guard let overloaded = loads.first(where: {
            $0.hours > preferences.maxScheduledHours(on: $0.day) || $0.count > preferences.maxTimedItemsPerDay
        }) else { return nil }
        guard let empty = loads.first(where: { $0.count == 0 }) else { return nil }

        let fullName = overloaded.day.formatted(.dateTime.weekday(.wide))
        let openName = empty.day.formatted(.dateTime.weekday(.wide))

        // Offer to move the last non-recurring item of the packed day.
        let movable = items
            .filter { $0.startTime != nil && $0.recurrence == nil && engine.occurs($0, on: overloaded.day) }
            .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
            .last

        // The item keeps its own time on the new day — moving something to
        // Thursday shouldn't also silently re-time it. Only the fallback, for
        // when the components don't resolve, is ours to choose, and that lands
        // at the top of the working day rather than at a hardcoded 9am.
        var action: SuggestionAction?
        var actionTitle: String?
        if let movable, let start = movable.startTime {
            let comps = calendar.dateComponents([.hour, .minute], from: start)
            let openingHour = preferences.workingHours.startMinutes / 60
            let openingMinute = preferences.workingHours.startMinutes % 60
            if let newStart = calendar.date(
                bySettingHour: comps.hour ?? openingHour,
                minute: comps.minute ?? openingMinute,
                second: 0,
                of: empty.day
            ) {
                action = .reschedule(itemID: movable.id, newStart: newStart)
                actionTitle = String(localized: "Move “\(movable.title)” to \(openName)")
            }
        }

        return ScheduleSuggestion(
            id: "imbalance-\(Int(overloaded.day.timeIntervalSince1970))",
            kind: .dayImbalance,
            message: String(localized: "\(fullName) is packed while \(openName) is open. Move something over?"),
            systemImage: "calendar.badge.exclamationmark",
            action: action,
            actionTitle: actionTitle
        )
    }

    // MARK: - Stale to-dos

    private func staleTodoSuggestions(items: [ScheduleItem], now: Date) -> [ScheduleSuggestion] {
        let today = calendar.startOfDay(for: now)
        return items.compactMap { item in
            guard item.kind == .todo, item.recurrence == nil, !item.isCompleted else { return nil }
            let age = calendar.dateComponents([.day], from: item.createdAt, to: now).day ?? 0
            guard age >= staleTodoDays else { return nil }
            // Already set for today? Then there's nothing to fix.
            if let due = item.scheduledDate, calendar.isDate(due, inSameDayAs: today) { return nil }
            return ScheduleSuggestion(
                id: "stale-\(item.id)",
                kind: .staleTodo,
                message: String(localized: "“\(item.title)” has been on your list \(age) days. Give it a day?"),
                systemImage: "clock.arrow.circlepath",
                action: .scheduleTodo(itemID: item.id, day: today),
                actionTitle: String(localized: "Set for today")
            )
        }
    }
}
