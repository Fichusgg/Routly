//
//  StubAIParsingService.swift
//  RoutineOrganizer
//
//  A dependency-free, rule-based parser: regex + keyword extraction for dates,
//  times, durations, recurrence, and category. It lets the whole app run and be
//  unit-tested with no API key. Phase 2 replaces it with a real LLM call behind
//  the same `AIParsingService` protocol — nothing else in the app should change.
//

import Foundation

struct StubAIParsingService: AIParsingService {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1
        return c
    }

    /// `workingHours` is accepted and deliberately unused.
    ///
    /// Every time this parser produces is one the person said out loud — an
    /// explicit "at 15:00", or a named part of the day like "tonight" or "this
    /// morning". None of it is the app choosing an hour, so none of it is the
    /// app's to move: clamping "call mom tonight" into a 9–5 window would be
    /// overriding the user, not helping them. The parameter stays in the
    /// signature because the protocol has it and because a future rule here
    /// that *does* invent a time would need it.
    func parse(_ text: String, now: Date, workingHours: WorkingHours, lists: [String]) async -> [ParsedCapture] {
        // Best-effort multi-item split so "call mom, buy milk, gym" yields three.
        // The real parser handles the hard cases (e.g. "call mom and dad"); this
        // just keeps offline/no-key capture usable for simple lists.
        segments(from: text).map { segment in
            var parsed = parseOne(segment, now: now)
            parsed.listName = matchedList(in: segment, from: lists)
            return parsed
        }
    }

    /// The offline answer to "which list is this?", which is deliberately almost
    /// always "no idea".
    ///
    /// This parser matches patterns; it does not know that maths is a school
    /// subject. So it files a task only when the capture literally names one of
    /// the user's lists — "shopping: milk" with a Shopping list — and otherwise
    /// leaves it unfiled for the user to place. Guessing from a keyword list
    /// baked in here would be the app inventing a taxonomy on the user's behalf
    /// and getting it wrong in a way they'd have to keep undoing.
    ///
    /// Whole-word matching, so a list called "Art" doesn't claim "start the
    /// report". Longest name first, so "School run" wins over "School" when the
    /// capture contains both.
    private func matchedList(in segment: String, from lists: [String]) -> String? {
        let lowered = segment.lowercased()
        return lists
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.count > $1.count }
            .first { name in
                let needle = name.lowercased()
                guard let range = lowered.range(of: needle) else { return false }
                let before = range.lowerBound == lowered.startIndex
                    ? nil
                    : lowered[lowered.index(before: range.lowerBound)]
                let after = range.upperBound == lowered.endIndex ? nil : lowered[range.upperBound]
                let isBoundary: (Character?) -> Bool = { char in
                    guard let char else { return true }
                    return !char.isLetter && !char.isNumber
                }
                return isBoundary(before) && isBoundary(after)
            }
    }

    /// Break a capture into candidate item segments on common list separators.
    private func segments(from text: String) -> [String] {
        var parts = [text]
        for separator in ["\n", ";", " then ", " Then ", " and then ", " and ", " And ",
                          " also ", " plus ", " & ", ", ", ","] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private func parseOne(_ segment: String, now: Date) -> ParsedCapture {
        let original = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = original.lowercased()

        // Phrases to strip from the final title, gathered as we recognize them.
        var consumed: [String] = []

        let recurrence = extractRecurrence(from: lowered, consumed: &consumed)
        let (startTime, timePhrases) = extractTime(from: lowered, now: now)
        consumed.append(contentsOf: timePhrases)
        let (scheduledDate, datePhrases) = extractDate(from: lowered, now: now, hasRecurrence: recurrence != nil)
        consumed.append(contentsOf: datePhrases)
        let (duration, durationPhrases) = extractDuration(from: lowered)
        consumed.append(contentsOf: durationPhrases)
        let category = extractCategory(from: lowered)

        // Fold the time component into the scheduled day when we have both.
        let resolvedStart = combine(day: scheduledDate, time: startTime, now: now)

        let title = cleanTitle(from: original, removing: consumed)
        let kind = inferKind(from: lowered, hasTime: resolvedStart != nil)

        return ParsedCapture(
            title: title,
            kind: kind,
            scheduledDate: scheduledDate,
            startTime: resolvedStart,
            durationMinutes: duration,
            category: category,
            recurrence: recurrence,
            sourceText: original
        )
    }

    /// A capture is a reminder if it's phrased as one, an event if it names a
    /// time, otherwise a to-do.
    private func inferKind(from lowered: String, hasTime: Bool) -> ItemKind {
        if lowered.contains("remind") || lowered.contains("remember") { return .reminder }
        return hasTime ? .event : .todo
    }

    // MARK: - Recurrence

    private func extractRecurrence(from text: String, consumed: inout [String]) -> RecurrenceRule? {
        // "3x a week", "3 times this week", "twice a week", etc.
        if text.contains("week") {
            if let count = timesPerWeekCount(in: text, consumed: &consumed) {
                // Strip the "this week" / "a week" tail so it doesn't leak into the title.
                consumed.append(contentsOf: ["this week", "per week", "a week", "week", "times"])
                return .timesPerWeek(count)
            }
        }

        // Weekdays (Mon–Fri).
        if text.contains("weekdays") || text.contains("every weekday") {
            consumed.append("weekdays"); consumed.append("every weekday"); consumed.append("every")
            return .weekly(on: [2, 3, 4, 5, 6])
        }

        // Daily.
        if firstPresent(["every day", "everyday", "daily"], in: text, consumed: &consumed) != nil {
            return .everyDay
        }

        // Weekly by named day(s): "every monday", "mondays", "every mon and wed".
        let days = weekdaysMentioned(in: text)
        let saysEvery = text.contains("every")
        let saysPlural = Self.weekdayNames.contains { text.contains($0 + "s") }
        if !days.isEmpty && (saysEvery || saysPlural) {
            if saysEvery { consumed.append("every") }
            for (name, _) in Self.weekdayLookup where text.contains(name) {
                consumed.append(name + "s"); consumed.append(name)
            }
            consumed.append("on")
            return .weekly(on: Set(days))
        }

        return nil
    }

    private func timesPerWeekCount(in text: String, consumed: inout [String]) -> Int? {
        // Word forms first.
        let words: [String: Int] = ["once": 1, "twice": 2, "thrice": 3]
        for (word, n) in words where text.contains(word) {
            consumed.append(word)
            return n
        }
        // "3x" or "3 times".
        if let match = text.firstMatch(of: /(\d+)\s*(x|times)/) {
            consumed.append(String(match.output.0))
            if let n = Int(match.output.1) { return n }
        }
        return nil
    }

    // MARK: - Time

    /// Returns a time-of-day anchored to `now`'s day plus the phrases consumed.
    private func extractTime(from text: String, now: Date) -> (Date?, [String]) {
        var consumed: [String] = []

        // Explicit clock: "3pm", "3:30 pm", "at 9am".
        if let match = text.firstMatch(of: /(\d{1,2})(?::(\d{2}))?\s*(am|pm)/) {
            consumed.append(String(match.output.0))
            var hour = Int(match.output.1) ?? 0
            let minute = match.output.2.flatMap { Int($0) } ?? 0
            let isPM = match.output.3 == "pm"
            if isPM && hour < 12 { hour += 12 }
            if !isPM && hour == 12 { hour = 0 }
            return (time(hour: hour, minute: minute, on: now), consumed)
        }

        // 24-hour clock: "at 15:00".
        if let match = text.firstMatch(of: /(\d{1,2}):(\d{2})/) {
            consumed.append(String(match.output.0))
            let hour = Int(match.output.1) ?? 0
            let minute = Int(match.output.2) ?? 0
            if (0...23).contains(hour) && (0...59).contains(minute) {
                return (time(hour: hour, minute: minute, on: now), consumed)
            }
        }

        // Named parts of day.
        let named: [(String, Int)] = [
            ("midnight", 0), ("noon", 12), ("morning", 9),
            ("afternoon", 14), ("tonight", 19), ("evening", 19), ("night", 21)
        ]
        for (word, hour) in named where text.contains(word) {
            // "tonight" also implies today; the date extractor handles the day.
            if word != "tonight" { consumed.append(word) }
            return (time(hour: hour, minute: 0, on: now), consumed)
        }

        return (nil, consumed)
    }

    // MARK: - Date

    private func extractDate(from text: String, now: Date, hasRecurrence: Bool) -> (Date?, [String]) {
        var consumed: [String] = []
        let today = calendar.startOfDay(for: now)

        if text.contains("day after tomorrow") {
            consumed.append("day after tomorrow")
            return (calendar.date(byAdding: .day, value: 2, to: today), consumed)
        }
        if text.contains("tomorrow") {
            consumed.append("tomorrow")
            return (calendar.date(byAdding: .day, value: 1, to: today), consumed)
        }
        if text.contains("tonight") || text.contains("today") {
            consumed.append("today")
            return (today, consumed)
        }

        // Don't pin a recurring routine to one weekday date here — the engine
        // expands its occurrences instead.
        if !hasRecurrence, let (name, weekday) = firstWeekday(in: text) {
            let wantsNext = text.contains("next")
            if wantsNext { consumed.append("next") }
            consumed.append(name)
            let date = nextDate(weekday: weekday, after: today, skipToNextWeek: wantsNext)
            return (date, consumed)
        }

        return (nil, consumed)
    }

    // MARK: - Duration

    private func extractDuration(from text: String) -> (Int?, [String]) {
        var consumed: [String] = []
        var minutes = 0
        var matched = false

        if text.contains("half an hour") || text.contains("half hour") {
            consumed.append("half an hour"); consumed.append("half hour")
            return (30, consumed)
        }
        if text.contains("an hour") {
            consumed.append("an hour")
            minutes += 60; matched = true
        }
        for match in text.matches(of: /(\d+)\s*(hours|hour|hrs|hr|h)\b/) {
            consumed.append(String(match.output.0))
            minutes += (Int(match.output.1) ?? 0) * 60; matched = true
        }
        for match in text.matches(of: /(\d+)\s*(minutes|minute|mins|min|m)\b/) {
            consumed.append(String(match.output.0))
            minutes += Int(match.output.1) ?? 0; matched = true
        }

        return (matched && minutes > 0 ? minutes : nil, consumed)
    }

    // MARK: - Category

    private func extractCategory(from text: String) -> Category {
        // Health and work take priority over the personal fallback.
        for category in [Category.health, .work, .personal] {
            if category.keywords.contains(where: { text.contains($0) }) {
                return category
            }
        }
        return .fallback
    }

    // MARK: - Title cleanup

    private func cleanTitle(from original: String, removing phrases: [String]) -> String {
        var result = original

        // Strip leading intent framing.
        let prefixes = ["remind me to ", "remind me ", "remember to ", "i need to ",
                        "i have to ", "i want to ", "need to ", "add "]
        var lower = result.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            lower = result.lowercased()
        }

        // Remove each recognized phrase (longest first, case-insensitive).
        for phrase in phrases.sorted(by: { $0.count > $1.count }) where !phrase.isEmpty {
            while let range = result.range(of: phrase, options: .caseInsensitive) {
                result.replaceSubrange(range, with: " ")
            }
        }

        // Drop dangling connective words left behind by removals.
        let fillers: Set<String> = ["at", "on", "for", "this", "next", "every", "a", "the", "to",
                                    "around", "about", "approximately", "roughly", "by"]
        let words = result.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        var kept = words.filter { !fillers.contains($0.lowercased()) }

        // Trim trailing/leading fillers already handled; collapse to a clean string.
        if kept.isEmpty { kept = words } // avoid nuking everything
        var title = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        if let first = title.first {
            title.replaceSubrange(title.startIndex...title.startIndex, with: String(first).uppercased())
        }
        return title.isEmpty ? original : title
    }

    // MARK: - Helpers

    private func combine(day: Date?, time: Date?, now: Date) -> Date? {
        guard let time else { return nil }
        let base = day ?? calendar.startOfDay(for: now)
        let comps = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: base)
    }

    private func time(hour: Int, minute: Int, on day: Date) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day))
    }

    private func nextDate(weekday: Int, after date: Date, skipToNextWeek: Bool) -> Date? {
        var comps = DateComponents()
        comps.weekday = weekday
        guard let next = calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime) else {
            return nil
        }
        return skipToNextWeek ? calendar.date(byAdding: .day, value: 7, to: next) : next
    }

    private func firstPresent(_ options: [String], in text: String, consumed: inout [String]) -> String? {
        for option in options where text.contains(option) {
            consumed.append(option)
            return option
        }
        return nil
    }

    private func weekdaysMentioned(in text: String) -> [Int] {
        Self.weekdayLookup.compactMap { text.contains($0.key) ? $0.value : nil }.sorted()
    }

    private func firstWeekday(in text: String) -> (String, Int)? {
        // Preserve a stable order so "next monday" resolves deterministically.
        for name in Self.weekdayNames {
            if text.contains(name), let weekday = Self.weekdayLookup[name] {
                return (name, weekday)
            }
        }
        return nil
    }

    // Calendar weekday indices: Sunday = 1 ... Saturday = 7.
    private static let weekdayLookup: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7
    ]
    private static let weekdayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
}
