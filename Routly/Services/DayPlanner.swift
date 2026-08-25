//
//  DayPlanner.swift
//  RoutineOrganizer
//
//  What "optimize my day" actually thinks. Given today's fixed blocks and the
//  open to-dos, it works out how much time is genuinely left *from now*, then
//  recommends what to do and roughly when.
//
//  Rule-based and explainable on purpose — the same tier as SuggestionEngine, no
//  pattern learning. Every number here has to survive being turned into a
//  sentence the user reads, which is why the weights are coarse and the urgency
//  curve is a step table rather than a decay: "due tomorrow" is a thing a person
//  can argue with, "0.71" isn't.
//
//  Three rules it will not break:
//    1. Time already gone doesn't count. At 3pm the morning does not exist.
//    2. A task never goes in a gap too small for it.
//    3. What doesn't fit is said out loud, not quietly crammed in.
//
//  Pure value-in/value-out, free of SwiftData and UI, so it's directly testable.
//

import Foundation

// MARK: - Inputs & outputs

/// Tunables for what counts as a usable day.
struct PlannerPreferences: Equatable, Sendable {
    /// The window the planner is allowed to work in. This is the user's own
    /// setting — it replaced a hardcoded 8am–9pm, and with it the assumption
    /// that evenings are fair game. Where something pushed to "tomorrow
    /// morning" lands is derived from it too, rather than being its own number.
    var workingHours: WorkingHours = .default

    /// A gap shorter than this isn't worth offering. You don't start something
    /// in seven minutes.
    var minUsefulGapMinutes = 10
    /// Shaved off each end of a gap that butts against a fixed block, so the
    /// plan accounts for actually getting from one thing to the next.
    var transitionBufferMinutes = 5
    /// A reminder occupies no span, but it does take your attention when it
    /// fires — enough not to start deep work in the minutes before it.
    var reminderAttentionMinutes = 10
    /// Don't propose something starting the instant the user is reading this.
    var startGraceMinutes = 5

    /// At most this many recommendations. More than a handful is just the
    /// to-do list again, and choosing is the whole value being offered.
    var maxRecommendations = 5
    /// Never plan more than this share of the remaining free time. The slack
    /// left over is the point, not waste.
    var maxFillFraction = 0.7

    static let `default` = PlannerPreferences()
}

/// A genuinely open stretch of time today.
struct FreeGap: Equatable {
    var start: Date
    var end: Date

    var minutes: Int { Int(end.timeIntervalSince(start) / 60) }

    func contains(_ other: FreeGap) -> Bool { other.start >= start && other.end <= end }
}

/// One thing to do, at one time, for one stated reason.
struct Recommendation: Identifiable, Equatable {
    var itemID: UUID
    var title: String
    var start: Date
    var minutes: Int
    /// True when we guessed the size rather than being told it — surfaced in
    /// the UI so the user knows which numbers are theirs.
    var effortIsGuess: Bool
    /// Plain-language "why this, why now".
    var reason: String

    var id: UUID { itemID }
    var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
}

/// Something that honestly doesn't fit today, and why.
struct UnplacedTask: Identifiable, Equatable {
    enum Resolution: Equatable {
        /// Nothing to be done today; purely informational.
        case none
        /// It was due today and still didn't fit — offer to move it rather
        /// than let the deadline pass in silence.
        case moveToTomorrowMorning(Date)
    }

    var itemID: UUID
    var title: String
    var minutes: Int
    var reason: String
    var resolution: Resolution

    var id: UUID { itemID }
}

/// The whole answer to "optimize my day".
struct DayPlan: Equatable {
    var recommendations: [Recommendation] = []
    var unplaced: [UnplacedTask] = []
    /// Total open minutes between now and the end of the working day, before
    /// planning.
    var freeMinutes: Int = 0
    /// When the planner stops looking — the end of the working day.
    var horizonEnd: Date = .distantPast
    /// True when the working day is already over. Distinct from `freeMinutes ==
    /// 0`, which also happens on a day that's simply full, and the two want
    /// completely different words on screen.
    var isAfterWorkingHours: Bool = false

    var isEmpty: Bool { recommendations.isEmpty && unplaced.isEmpty }
}

// MARK: - The planner

struct DayPlanner {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1
        return c
    }()
    var engine = ScheduleEngine()
    var estimator = EffortEstimator()
    var preferences: PlannerPreferences = .default

    /// A to-do counts as "hanging around" after this many days on the list.
    private let stalenessCeilingDays = 7.0

    // MARK: Entry point

    func plan(from items: [ScheduleItem], now: Date = Date()) -> DayPlan {
        let gaps = freeGaps(from: items, now: now)
        let horizonEnd = endOfWorkingDay(for: now)
        let freeMinutes = gaps.reduce(0) { $0 + $1.minutes }

        var plan = DayPlan(
            freeMinutes: freeMinutes,
            horizonEnd: horizonEnd,
            isAfterWorkingHours: isAfterWorkingHours(now)
        )
        let open = candidates(from: items, now: now)
        guard !open.isEmpty else { return plan }

        let ranked = open
            .map { scored($0, now: now) }
            .sorted { lhs, rhs in
                if lhs.staticScore != rhs.staticScore { return lhs.staticScore > rhs.staticScore }
                // Stable tiebreak so the same day plans the same way twice.
                return lhs.item.title < rhs.item.title
            }

        var remaining = gaps
        // The share of free time we're willing to spend, so the day keeps some
        // slack. It governs how much piles up — never whether the single most
        // important thing gets said, which is when one clear answer matters most.
        var budget = max(Int(Double(freeMinutes) * preferences.maxFillFraction), 0)

        for candidate in ranked {
            if plan.recommendations.count >= preferences.maxRecommendations {
                // Out of slots to offer — everything else is genuinely "not today".
                if let unplaced = unplacedEntry(for: candidate, gaps: remaining, now: now, cause: .listFull) {
                    plan.unplaced.append(unplaced)
                }
                continue
            }

            guard let placement = bestPlacement(for: candidate, in: remaining) else {
                if let unplaced = unplacedEntry(for: candidate, gaps: remaining, now: now, cause: .noRoom) {
                    plan.unplaced.append(unplaced)
                }
                continue
            }

            // The top pick is always offered if it genuinely fits — holding back
            // breathing room is worthless if it means an empty answer.
            let withinBudget = plan.recommendations.isEmpty || candidate.effort.minutes <= budget
            guard withinBudget else {
                if let unplaced = unplacedEntry(for: candidate, gaps: remaining, now: now, cause: .budgetSpent) {
                    plan.unplaced.append(unplaced)
                }
                continue
            }

            plan.recommendations.append(Recommendation(
                itemID: candidate.item.id,
                title: candidate.item.title,
                start: placement.start,
                minutes: candidate.effort.minutes,
                effortIsGuess: candidate.effort.isGuess,
                reason: reason(for: candidate, placement: placement, items: items, now: now)
            ))
            budget -= candidate.effort.minutes
            remaining = consume(placement, from: remaining)
        }

        // Chosen by priority, but read as a day: chronological order is how a
        // person walks through their afternoon. Each row's reason carries the
        // urgency, so nothing is lost by not ranking them on screen.
        plan.recommendations.sort { $0.start < $1.start }
        return plan
    }

    // MARK: - Free time

    /// The open stretches between now and the end of the day. Everything before
    /// `now` is gone; the planner never pretends otherwise.
    func freeGaps(from items: [ScheduleItem], now: Date = Date()) -> [FreeGap] {
        let horizonStart = startOfHorizon(for: now)
        let horizonEnd = endOfWorkingDay(for: now)
        guard horizonStart < horizonEnd else { return [] }

        let busy = mergedBusyBlocks(from: items, now: now, clippedTo: (horizonStart, horizonEnd))

        // Walk the horizon, taking whatever the busy blocks leave behind.
        var gaps: [FreeGap] = []
        var cursor = horizonStart
        for block in busy {
            if block.start > cursor {
                gaps.append(FreeGap(start: cursor, end: block.start))
            }
            cursor = max(cursor, block.end)
        }
        if cursor < horizonEnd {
            gaps.append(FreeGap(start: cursor, end: horizonEnd))
        }

        return gaps
            .map { buffered($0, horizonStart: horizonStart, horizonEnd: horizonEnd) }
            .filter { $0.minutes >= preferences.minUsefulGapMinutes }
    }

    /// Give back a little time at any edge that touches a fixed block — you
    /// don't walk out of a meeting and into the next thing at the same second.
    private func buffered(_ gap: FreeGap, horizonStart: Date, horizonEnd: Date) -> FreeGap {
        var result = gap
        let buffer = TimeInterval(preferences.transitionBufferMinutes * 60)
        if gap.start > horizonStart { result.start = gap.start.addingTimeInterval(buffer) }
        if gap.end < horizonEnd { result.end = gap.end.addingTimeInterval(-buffer) }
        // A buffer must never turn a gap inside out.
        if result.end < result.start { result.end = result.start }
        return result
    }

    /// Today's fixed commitments as non-overlapping, time-ordered blocks.
    private func mergedBusyBlocks(
        from items: [ScheduleItem],
        now: Date,
        clippedTo horizon: (start: Date, end: Date)
    ) -> [FreeGap] {
        let today = calendar.startOfDay(for: now)
        let blocks = items
            .filter { $0.startTime != nil && engine.occurs($0, on: today) }
            .compactMap(occupiedBlock)
            .compactMap { block -> FreeGap? in
                // Trim to the window we care about; drop what's already past.
                let start = max(block.start, horizon.start)
                let end = min(block.end, horizon.end)
                return end > start ? FreeGap(start: start, end: end) : nil
            }
            .sorted { $0.start < $1.start }

        return blocks.reduce(into: [FreeGap]()) { merged, block in
            if let last = merged.last, block.start <= last.end {
                merged[merged.count - 1].end = max(last.end, block.end)
            } else {
                merged.append(block)
            }
        }
    }

    /// How much of the clock an item really takes up.
    private func occupiedBlock(for item: ScheduleItem) -> FreeGap? {
        guard let start = item.startTime else { return nil }
        let minutes: Int
        switch item.kind {
        case .event:
            minutes = item.durationMinutes ?? 60
        case .todo:
            // A to-do that's already been slotted holds its block.
            minutes = item.durationMinutes ?? item.effortMinutes ?? estimator.estimate(for: item).minutes
        case .reminder:
            // No span, but it does interrupt.
            minutes = item.durationMinutes ?? preferences.reminderAttentionMinutes
        }
        guard minutes > 0 else { return nil }
        return FreeGap(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    /// Planning starts now (plus a moment to read this), never at the top of a
    /// day that's already half spent — and never before the working day opens,
    /// so a plan made at 7am still begins at 9.
    private func startOfHorizon(for now: Date) -> Date {
        let dayStart = preferences.workingHours.start(on: now, calendar: calendar)
        let grace = calendar.date(byAdding: .minute, value: preferences.startGraceMinutes, to: now) ?? now
        return roundedUpToQuarterHour(max(dayStart, grace))
    }

    /// The end of the *working* day, which is where planning stops — not
    /// midnight, and not the old hardcoded 9pm.
    private func endOfWorkingDay(for now: Date) -> Date {
        preferences.workingHours.end(on: now, calendar: calendar)
    }

    /// True once the working day is behind us. Worth distinguishing from "the
    /// day is simply full": at 9pm with hours ending at 5pm there is nothing
    /// left to plan, and saying so beats reporting zero free minutes as though
    /// the day had merely filled up.
    func isAfterWorkingHours(_ now: Date) -> Bool {
        now >= endOfWorkingDay(for: now)
    }

    private func roundedUpToQuarterHour(_ date: Date) -> Date {
        let minute = calendar.component(.minute, from: date)
        let remainder = minute % 15
        let base = calendar.date(bySetting: .second, value: 0, of: date) ?? date
        guard remainder != 0 else { return base }
        return calendar.date(byAdding: .minute, value: 15 - remainder, to: base) ?? date
    }

    // MARK: - Candidates & scoring

    /// A to-do the planner could sensibly propose, with its worked-out numbers.
    struct ScoredCandidate {
        var item: ScheduleItem
        var effort: EffortEstimate
        /// Whole days from today until it's due. nil when it has no deadline.
        var daysUntilDue: Int?
        var daysOnList: Int
        var urgency: Double
        var staleness: Double
        var quickWin: Double

        /// Everything independent of *where* it would go. Fit is per-gap, so it
        /// joins later, at placement time.
        var staticScore: Double { 0.55 * urgency + 0.12 * staleness + 0.08 * quickWin }
    }

    /// Open to-dos worth considering: anything unfinished and not already given
    /// a slot today. Future deadlines are included deliberately — working ahead
    /// is allowed, the urgency weighting just ranks them below what's due soon.
    func candidates(from items: [ScheduleItem], now: Date = Date()) -> [ScheduleItem] {
        let today = calendar.startOfDay(for: now)
        return items.filter { item in
            guard item.kind == .todo else { return false }
            guard !isDone(item, on: today) else { return false }
            // Already has a real slot today — nothing left to recommend.
            if let start = item.startTime, calendar.isDate(start, inSameDayAs: today) { return false }
            // A routine only counts on a day it actually falls on.
            if item.recurrence != nil { return engine.occurs(item, on: today) }
            return true
        }
    }

    private func isDone(_ item: ScheduleItem, on day: Date) -> Bool {
        if item.recurrence == nil { return item.isCompleted }
        return item.completions.contains {
            $0.status == .done && calendar.isDate($0.occurrenceDate, inSameDayAs: day)
        }
    }

    private func scored(_ item: ScheduleItem, now: Date) -> ScoredCandidate {
        let today = calendar.startOfDay(for: now)
        let effort = estimator.estimate(for: item)

        let daysUntilDue = item.effectiveDue.map {
            calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: $0)).day ?? 0
        }
        let daysOnList = max(calendar.dateComponents([.day], from: item.createdAt, to: now).day ?? 0, 0)

        return ScoredCandidate(
            item: item,
            effort: effort,
            daysUntilDue: daysUntilDue,
            daysOnList: daysOnList,
            urgency: urgency(daysUntilDue: daysUntilDue),
            staleness: min(Double(daysOnList) / stalenessCeilingDays, 1),
            quickWin: effort.minutes <= 15 ? 1 : 0
        )
    }

    /// Deadline pressure. A step table, not a curve: each rung is a phrase a
    /// person can recognise, and it refuses to imply precision we don't have.
    /// Undated work sits at a floor — not urgent, but never invisible.
    private func urgency(daysUntilDue: Int?) -> Double {
        guard let days = daysUntilDue else { return 0.25 }
        switch days {
        case ..<0: return 1.00    // overdue
        case 0:    return 0.95    // due today
        case 1:    return 0.70
        case 2:    return 0.50
        case 3...6: return 0.30
        default:   return 0.15
        }
    }

    /// How well a task's size suits a gap. This is where "don't put a 2-hour
    /// job in a 20-minute hole" lives — and its mirror image: a 5-minute errand
    /// shouldn't eat a two-hour stretch that something big needs.
    private func fit(effortMinutes: Int, gapMinutes: Int) -> Double? {
        guard gapMinutes > 0, effortMinutes <= gapMinutes else { return nil }
        let ratio = Double(effortMinutes) / Double(gapMinutes)
        switch ratio {
        case 0.6...:  return 1.0   // uses the gap well
        case 0.3..<0.6: return 0.7
        default:      return 0.4   // fits, but wastes the room
        }
    }

    // MARK: - Placement

    private struct Placement {
        var start: Date
        /// The task's own length — what actually gets reserved.
        var minutes: Int
        var gap: FreeGap
        var fit: Double

        var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
        /// Room available from the aligned start to the end of the gap.
        var usableMinutes: Int { Int(gap.end.timeIntervalSince(start) / 60) }
    }

    /// The best gap for one task.
    ///
    /// Two different questions, depending on the pressure. For something due
    /// today or already overdue, "when can I start?" beats "where does it pack
    /// neatly?" — so those go as early as they fit. For everything else, the
    /// tidier choice wins: take the gap it suits best and leave the long clear
    /// stretches for the work that needs them.
    private func bestPlacement(for candidate: ScoredCandidate, in gaps: [FreeGap]) -> Placement? {
        let preferEarliest = (candidate.daysUntilDue ?? .max) <= 0

        var best: Placement?
        for gap in gaps {
            let start = roundedUpToQuarterHour(gap.start)
            let usable = Int(gap.end.timeIntervalSince(start) / 60)
            guard let fit = fit(effortMinutes: candidate.effort.minutes, gapMinutes: usable) else { continue }
            let placement = Placement(start: start, minutes: candidate.effort.minutes, gap: gap, fit: fit)

            guard let current = best else {
                best = placement
                continue
            }
            let better = preferEarliest
                ? (start < current.start || (start == current.start && fit > current.fit))
                : (fit > current.fit || (fit == current.fit && start < current.start))
            if better { best = placement }
        }
        return best
    }

    /// Take a placement out of the free time, keeping whatever's left either
    /// side of it — a 20-minute task in a 2-hour gap gives back the rest.
    private func consume(_ placement: Placement, from gaps: [FreeGap]) -> [FreeGap] {
        gaps.flatMap { gap -> [FreeGap] in
            guard gap == placement.gap else { return [gap] }
            var pieces: [FreeGap] = []
            let head = FreeGap(start: gap.start, end: placement.start)
            if head.minutes >= preferences.minUsefulGapMinutes { pieces.append(head) }
            let tail = FreeGap(start: placement.end, end: gap.end)
            if tail.minutes >= preferences.minUsefulGapMinutes { pieces.append(tail) }
            return pieces
        }
    }

    // MARK: - Being honest about what doesn't fit

    private enum UnplacedCause {
        case noRoom       // no gap big enough
        case budgetSpent  // we're deliberately not filling the day to the brim
        case listFull     // already offered as much as is useful to choose from
    }

    private func unplacedEntry(
        for candidate: ScoredCandidate,
        gaps: [FreeGap],
        now: Date,
        cause: UnplacedCause
    ) -> UnplacedTask? {
        // Only speak up about things that actually wanted today: due within a
        // couple of days, or overdue. Silence about next week isn't dishonest.
        guard let days = candidate.daysUntilDue, days <= 2 else { return nil }

        let effortText = MinutesText.approx(candidate.effort.minutes)
        let longest = gaps.map(\.minutes).max() ?? 0

        let reason: String
        switch cause {
        // The working day being over is a different fact from the working day
        // being full, and blurring them reads as a bug at 9pm: "no open time
        // left before 5:00 PM" sounds like the app has lost track of the clock.
        case .noRoom where isAfterWorkingHours(now):
            let endText = endOfWorkingDay(for: now).formatted(date: .omitted, time: .shortened)
            reason = String(localized: "Needs \(effortText), and your working day ended at \(endText).")
        case .noRoom where longest == 0:
            let endText = endOfWorkingDay(for: now).formatted(date: .omitted, time: .shortened)
            reason = String(localized: "Needs \(effortText) and there's no open time left before \(endText).")
        case .noRoom:
            let longestText = MinutesText.short(longest)
            reason = String(localized: "Needs \(effortText); your longest free stretch left today is \(longestText).")
        case .budgetSpent:
            reason = String(localized: "Needs \(effortText). Fitting it in too would leave you no breathing room today.")
        case .listFull:
            reason = String(localized: "Needs \(effortText), and today's open time is spoken for by the items above.")
        }

        // Due today and still homeless: don't just note it — offer the honest
        // move, which is tomorrow morning rather than a crammed slot today.
        var resolution: UnplacedTask.Resolution = .none
        if days <= 0, let tomorrowMorning = tomorrowMorning(after: now) {
            resolution = .moveToTomorrowMorning(tomorrowMorning)
        }

        return UnplacedTask(
            itemID: candidate.item.id,
            title: candidate.item.title,
            minutes: candidate.effort.minutes,
            reason: reason,
            resolution: resolution
        )
    }

    /// Where a pushed task lands: the moment tomorrow's working day opens.
    /// Derived rather than its own constant, so someone who works 6am–2pm gets
    /// 6am here and not a stranger's idea of morning.
    private func tomorrowMorning(after now: Date) -> Date? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        return preferences.workingHours.start(on: tomorrow, calendar: calendar)
    }

    // MARK: - Reasons

    /// One sentence: why this, why now. Leads with whatever actually won the
    /// ranking, then justifies the slot. Never mentions a score.
    private func reason(
        for candidate: ScoredCandidate,
        placement: Placement,
        items: [ScheduleItem],
        now: Date
    ) -> String {
        let gapMinutes = placement.usableMinutes
        let effortText = MinutesText.approx(candidate.effort.minutes)
        // Built as two whole phrases rather than a suffix glued onto a number.
        // "(my estimate)" is a parenthetical in English and an inflected phrase
        // elsewhere; appending it would leave translators no way to move it.
        let effortPhrase = candidate.effort.isGuess
            ? String(localized: "\(effortText) (my estimate)")
            : effortText

        // Why now — anchored to whatever makes the slot make sense. Naming the
        // next commitment only helps when it's the thing actually closing this
        // gap; "free until a meeting eight hours away" explains nothing.
        let slotClause: String
        if let next = nextFixedItem(after: placement.start, items: items, now: now),
           next.start <= placement.gap.end.addingTimeInterval(TimeInterval((preferences.transitionBufferMinutes + 1) * 60)) {
            let timeText = next.start.formatted(date: .omitted, time: .shortened)
            let nextTitle = next.title
            slotClause = String(localized: "you're free until \(nextTitle) at \(timeText)")
        } else if placement.fit == 1.0 {
            let gapText = MinutesText.short(gapMinutes)
            slotClause = String(localized: "this \(gapText) gap is about the right size")
        } else {
            let gapText = MinutesText.short(gapMinutes)
            slotClause = String(localized: "you've got \(gapText) clear")
        }

        // Why this — the dominant pressure.
        // Each branch is one whole sentence. The day counts interpolate as
        // numbers so the catalog can carry proper plural forms per language —
        // English needs two, and picking the word here would deny translators
        // the ones their language actually has.
        switch candidate.daysUntilDue {
        case .some(let days) where days < 0:
            let overdue = abs(days)
            return String(localized: "Overdue by \(overdue) days — \(effortPhrase), and \(slotClause).")
        case .some(0):
            return String(localized: "Due today — \(effortPhrase), and \(slotClause).")
        case .some(1):
            return String(localized: "Due tomorrow. It's \(effortPhrase) and \(slotClause).")
        case .some(let days) where days <= 6:
            let weekday = candidate.item.effectiveDue?.formatted(.dateTime.weekday(.wide))
                ?? String(localized: "later this week")
            return String(localized: "Due \(weekday) — worth getting ahead of, and \(slotClause).")
        case .some:
            return String(localized: "Not due for a while, but it's only \(effortPhrase) and \(slotClause).")
        case .none where candidate.daysOnList >= 3:
            let days = candidate.daysOnList
            return String(localized: "On your list \(days) days. It's \(effortPhrase) and \(slotClause).")
        case .none:
            return String(localized: "It's \(effortPhrase), and \(slotClause).")
        }
    }

    /// The next immovable thing after a proposed start, for grounding the reason
    /// in something the user can see on their own day.
    private func nextFixedItem(after start: Date, items: [ScheduleItem], now: Date) -> (title: String, start: Date)? {
        let today = calendar.startOfDay(for: now)
        return items
            .filter { $0.kind != .todo && engine.occurs($0, on: today) }
            .compactMap { item -> (title: String, start: Date)? in
                guard let itemStart = item.startTime, itemStart > start else { return nil }
                return (item.title, itemStart)
            }
            .min { $0.start < $1.start }
    }
}

// MARK: - Formatting

/// Shared, human-sounding minute formatting. "90 min" reads like a machine;
/// "1h 30m" reads like a person.
enum MinutesText {
    static func short(_ minutes: Int) -> String {
        guard minutes >= 60 else { return String(localized: "\(minutes) min") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0
            ? String(localized: "\(hours)h")
            : String(localized: "\(hours)h \(rest)m")
    }

    static func approx(_ minutes: Int) -> String {
        String(localized: "~\(short(minutes))")
    }
}
