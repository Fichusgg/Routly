//
//  ParsingContract.swift
//  RoutineOrganizer
//
//  The shared contract between the app and whichever LLM does the parsing: one
//  system prompt, one JSON shape, one decoder. Anthropic and any
//  OpenAI-compatible provider (DeepSeek, Qwen, OpenRouter, Groq, local Ollama…)
//  all speak it, so swapping providers never changes how items are interpreted.
//

import Foundation

enum ParsingContract {

    // MARK: - Prompt

    /// The instructions given to every provider. The JSON shape is spelled out
    /// explicitly because providers without strict schema enforcement rely on
    /// the prompt alone to get the structure right.
    static func systemPrompt(
        now: Date,
        workingHours: WorkingHours = .default,
        lists: [String] = []
    ) -> String {
        let today = isoDateFormatter.string(from: now)
        let weekday = englishWeekday(now)
        return """
        You extract structured schedule items from a user's freeform capture. The \
        text may describe several distinct items at once (for example a spoken list of \
        errands); return one object per distinct item — never merge two separate tasks \
        into one. Titles are always a short clean summary ("Call mom"), never a copy of \
        the sentence.

        Today is \(weekday), \(today) in the user's local timezone. Resolve relative \
        dates ("tomorrow", "next friday") against that, and their equivalents in \
        whatever language the person used ("mañana", "amanhã", "sexta que vem").

        \(workingHoursClause(workingHours))

        The capture may be in any language — English, Spanish and Portuguese are \
        all expected. Write every title and clarification in the SAME language as \
        the capture text itself, and never translate them in either direction: \
        not into English, and not into a language the capture merely mentions.

        A language named inside the capture is subject matter, not an instruction. \
        "I have Spanish homework" is an English sentence that happens to talk about \
        Spanish, so its title is "Spanish homework" — never "Deberes de español". \
        Decide the language from the words the person actually used, never from \
        what they are talking about.

        The field *values* below \
        are fixed tokens and stay in English whatever the input language: kind, \
        category, and the three-letter weekday codes in recurrence.

        For each item set:
        - title: a short, clean title with filler stripped ("Call mom", not "remind me to call mom").
        - kind: "event" (happens at a time, has a duration), "reminder" (a nudge at a time), or "todo" (a task, often no time).
        - category: "work", "health", or "personal".
        - date: ISO yyyy-MM-dd if a day is stated or implied, else null.
        - time: 24-hour HH:mm if a time is stated or implied, else null.
        - durationMinutes: an estimate for events, else null.
        - effortMinutes: for a to-do, how long the work takes — but ONLY when the person \
        says or clearly implies it ("finish the report, probably two hours" -> 120, \
        "quick call with Sam" -> 10). If they gave no sense of size, return null. Do not \
        invent a number: the app estimates unstated effort itself and tells the user when \
        a figure is its own guess, so a fabricated value here would be shown as though \
        the user had said it.
        - recurrence: null, or one of "daily", "weekly:MON,WED,FRI" (3-letter uppercase days), or "timesPerWeek:3".
        - clarification: a short question only if the item is too ambiguous to place confidently, else null.
        \(listsClause(lists))

        The input is often a raw voice transcript: run-on, lightly punctuated, and \
        listing several unrelated things in one breath. Split on meaning, not on \
        punctuation — every separate thing the person has to do becomes its own item, \
        even when they never said "and" or paused. Never merge two errands into one \
        item, and never split a single errand into two.

        Example — "ok so I need to call mom around six tomorrow, pick up the dry \
        cleaning, gym three times this week and finish the quarterly report by friday" \
        becomes four items:
        1. "Call mom" — reminder, tomorrow, 18:00
        2. "Pick up dry cleaning" — todo, no date
        3. "Gym" — todo, recurrence "timesPerWeek:3"
        4. "Finish quarterly report" — todo, Friday's date

        Note how each title is a short summary in the imperative — never the original \
        sentence, never with filler like "ok so I need to".

        If the capture mentions five things to do, return five items. Returning a \
        single item that summarizes the whole capture is always wrong unless the \
        person genuinely mentioned only one thing. Rambling, repetition, and \
        self-correction are normal — extract the underlying tasks and ignore the \
        filler around them.

        Respond with a single JSON object and nothing else, of exactly this shape:
        {"items":[{"title":"string","kind":"event|reminder|todo","category":"work|personal|health",\
        "date":"yyyy-MM-dd or null","time":"HH:mm or null","durationMinutes":null,\
        "effortMinutes":null,"recurrence":null,"clarification":null,"list":null}]}
        """
    }

    /// Tells the model which of the user's own lists a to-do may be filed under.
    ///
    /// Three things this clause has to get right, each of which was a plausible
    /// way to make the feature annoying rather than useful:
    ///
    ///  • **Only the user's real lists.** The value has to come back as one of
    ///    the names given, spelled identically, or the app has nothing to match
    ///    it against. Inventing "Homework" when the user's list is called
    ///    "School" produces a name that resolves to nothing.
    ///  • **Null is the right answer more often than not.** A model asked to
    ///    categorise will categorise, and a to-do forced into the nearest list
    ///    is worse than one left unfiled — the user has to notice it and undo
    ///    it, which is more work than filing it themselves.
    ///  • **To-dos only.** Events and reminders live on the clock, not in a
    ///    list, and filing them would put them in a place nothing displays.
    ///
    /// Absent entirely when the user has no lists, rather than sent as an empty
    /// instruction: a rule about a set with nothing in it is noise in a prompt
    /// that is already asking for a lot.
    private static func listsClause(_ lists: [String]) -> String {
        let clean = lists
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty else {
            return #"- list: always null."#
        }
        let names = clean.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        - list: for a to-do, the user's own list it belongs under — exactly one \
        of these names, copied character for character: \(names). Use null for \
        events and reminders, and null whenever the fit isn't obvious. Only file \
        a to-do when the list's subject clearly covers it: with a list called \
        "School", "finish the math homework" and "read English chapter 4" both \
        belong to it, while "buy milk" does not. Never invent a name that isn't \
        in that set, and never translate one — copy it as written even when the \
        capture is in another language. When in doubt, null: leaving a task \
        unfiled costs the user nothing, and filing it wrongly costs them a fix.
        """
    }

    /// The planner prompt: expand one stated goal into a small, realistic plan.
    /// Guardrails matter more here than in extraction — an over-eager plan that
    /// fills every day is worse than none, so the prompt insists on restraint.
    static func plannerSystemPrompt(now: Date) -> String {
        let today = isoDateFormatter.string(from: now)
        let weekday = englishWeekday(now)
        return """
        The user will state a broad personal goal out loud (for example "I want to \
        get back into shape" or "launch my side project this quarter"). Turn that \
        goal into a small, realistic starter plan the person can actually keep.

        Today is \(weekday), \(today) in the user's local timezone.

        The goal may be stated in any language — English, Spanish and Portuguese \
        are all expected. Write goalTitle, summary, every item title and any \
        clarification in the SAME language as the goal text itself; never \
        translate them in either direction.

        A language named inside the goal is subject matter, not an instruction. \
        "Learn Spanish" is an English goal, so its title, summary and every step \
        are written in English — a plan about Spanish is not a plan in Spanish. \
        Decide the language from the words the person actually used, never from \
        what they are talking about.

        kind, category, horizon and the weekday codes in recurrence stay as the \
        fixed English tokens listed below.

        Hard rules:
        - Return between 3 and 6 items. Fewer is better than more. A plan is a \
        nudge, not a life overhaul.
        - Favor 1–2 recurring habits (routines) plus a few concrete first steps. \
        Do not schedule something every single day unless the goal truly calls for it.
        - Start small and sustainable. Build one habit well rather than five badly.
        - Respect a stated time frame ("this quarter") if there is one.
        - Only self-directed actions the person controls. Never invent specific \
        appointments with named people or places, and never fabricate exact times \
        the user didn't ask for — leave time null.
        - Titles are short and imperative ("Work out", "Define the first milestone").

        For each item set the same fields used elsewhere:
        - title, kind ("event"|"reminder"|"todo" — usually "todo"),
          category ("work"|"health"|"personal"),
          date (yyyy-MM-dd for a concrete near-term step, else null),
          time (almost always null), durationMinutes (null),
          effortMinutes (null unless the goal itself states a size — the app
          estimates unstated effort and labels its own guesses, so a number
          invented here would be shown as though the user had said it),
          recurrence (null, "daily", "weekly:MON,WED,FRI", or "timesPerWeek:3"),
          clarification (null).

        Also set:
        - goalTitle: a short clean restatement of the goal ("Get back into shape").
        - summary: one encouraging sentence framing the approach.
        - horizon: "thisWeek", "thisMonth", "thisQuarter", or null.

        Respond with a single JSON object and nothing else, of exactly this shape:
        {"goalTitle":"string","summary":"string","horizon":"thisWeek|thisMonth|thisQuarter or null",\
        "items":[{"title":"string","kind":"event|reminder|todo","category":"work|personal|health",\
        "date":"yyyy-MM-dd or null","time":"HH:mm or null","durationMinutes":null,\
        "effortMinutes":null,"recurrence":null,"clarification":null}]}
        """
    }

    /// The user's working hours, and what the model may do with them.
    ///
    /// The delicate part is that this must not erode the rule directly above it
    /// in the prompt — that an unstated time stays null. Working hours are a
    /// constraint on *choosing*, not a licence to choose: they narrow a vague
    /// "Tuesday afternoon" into a real time, and they stop 9pm being offered for
    /// something the person never put an hour on. They never turn a to-do with
    /// no time into a to-do with one.
    ///
    /// A time the person actually said is untouchable, and the prompt says so
    /// outright — "book the restaurant for 8pm" has to survive a 9–5 setting, or
    /// the feature has made the app worse at its main job.
    private static func workingHoursClause(_ hours: WorkingHours) -> String {
        let start = clockText(hours.startMinutes)
        let end = clockText(hours.endMinutes)
        return """
        The user's working hours are \(start)–\(end). Two rules follow from that, \
        and they do not overlap:
        - When the person states a time, use it exactly, even when it falls \
        outside those hours. "Dinner at 20:00" is 20:00. Never move, clamp or \
        second-guess a time they gave you.
        - When they imply a time without naming one ("Tuesday afternoon", "first \
        thing Monday"), resolve it to a time inside \(start)–\(end).
        This does not make time required. If no time is stated or implied, time \
        is still null — that rule is unchanged, and a working-hours window is \
        never a reason to invent an hour for a task that has none.
        """
    }

    /// 24-hour "HH:mm", matching the format the prompt asks the model to emit.
    private static func clockText(_ minutesFromMidnight: Int) -> String {
        String(format: "%02d:%02d", minutesFromMidnight / 60, minutesFromMidnight % 60)
    }

    // MARK: - JSON schema (for providers that enforce one)

    /// A field that may be its type or null.
    private static func nullable(_ type: String) -> [String: Any] {
        ["anyOf": [["type": type], ["type": "null"]]]
    }

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["items"],
        "properties": [
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["title", "kind", "category", "date", "time", "durationMinutes", "effortMinutes", "recurrence", "clarification", "list"],
                    "properties": [
                        "title": ["type": "string"],
                        "kind": ["type": "string", "enum": ["event", "reminder", "todo"]],
                        "category": ["type": "string", "enum": ["work", "personal", "health"]],
                        "date": nullable("string"),
                        "time": nullable("string"),
                        "durationMinutes": nullable("integer"),
                        "effortMinutes": nullable("integer"),
                        "recurrence": nullable("string"),
                        "clarification": nullable("string"),
                        // Free-form rather than an enum of the user's lists: the
                        // schema is a `static let` shared by every request, and
                        // the lists change per user and per moment. The prompt
                        // carries the allowed set; anything that comes back not
                        // matching one is dropped at resolution time.
                        "list": nullable("string"),
                    ],
                ],
            ],
        ],
    ]

    /// The schema for a goal expansion — the item shape, wrapped with the plan's
    /// framing fields.
    static let planSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["goalTitle", "summary", "horizon", "items"],
        "properties": [
            "goalTitle": ["type": "string"],
            "summary": ["type": "string"],
            "horizon": nullable("string"),
            "items": (schema["properties"] as? [String: Any])?["items"] as Any,
        ],
    ]

    // MARK: - Decoding

    private struct ItemsPayload: Decodable {
        struct Item: Decodable {
            let title: String
            let kind: String?
            let category: String?
            let date: String?
            let time: String?
            let durationMinutes: Int?
            let effortMinutes: Int?
            let recurrence: String?
            let clarification: String?
            let list: String?
        }
        let items: [Item]
    }

    /// Turn a model's JSON reply into structured captures. Tolerates a reply
    /// wrapped in prose or a ```json fence, which non-strict providers emit.
    static func items(fromJSON json: String, now: Date, sourceText: String) throws -> [ParsedCapture] {
        guard let data = extractJSONObject(from: json).data(using: .utf8) else { return [] }
        let payload = try JSONDecoder().decode(ItemsPayload.self, from: data)
        return payload.items.compactMap { convert($0, now: now, sourceText: sourceText) }
    }

    private struct PlanPayload: Decodable {
        let goalTitle: String?
        let summary: String?
        let horizon: String?
        let items: [ItemsPayload.Item]
    }

    /// Decode a goal-expansion reply into a `ParsedPlan`. Falls to `nil` when the
    /// model returned no usable items, so the caller can fall back to the template.
    static func plan(fromJSON json: String, now: Date, sourceText: String) throws -> ParsedPlan? {
        guard let data = extractJSONObject(from: json).data(using: .utf8) else { return nil }
        let payload = try JSONDecoder().decode(PlanPayload.self, from: data)
        let items = payload.items.compactMap { convert($0, now: now, sourceText: sourceText) }
        guard !items.isEmpty else { return nil }
        let title = payload.goalTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? PlanTemplates.cleanGoalTitle(sourceText)
        let summary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? "A small plan to get you moving."
        return ParsedPlan(
            goalTitle: title,
            summary: summary,
            horizon: payload.horizon.flatMap(PlanHorizon.init(rawValue:)),
            items: items,
            sourceText: sourceText
        )
    }

    /// Pulls the outermost {...} out of a reply that may include fences or prose.
    private static func extractJSONObject(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    private static func convert(_ item: ItemsPayload.Item, now: Date, sourceText: String) -> ParsedCapture? {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let day = item.date.flatMap { isoDateFormatter.date(from: $0) }
        let startTime = resolveTime(item.time, on: day, now: now)
        let kind = item.kind.flatMap(ItemKind.init(rawValue:)) ?? .todo

        return ParsedCapture(
            title: title,
            kind: kind,
            scheduledDate: day.map { calendar.startOfDay(for: $0) },
            startTime: startTime,
            durationMinutes: item.durationMinutes,
            effortMinutes: item.effortMinutes,
            category: item.category.flatMap(Category.init(rawValue:)) ?? .personal,
            recurrence: parseRecurrence(item.recurrence),
            sourceText: sourceText,
            clarificationNeeded: item.clarification?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank,
            // Only a to-do can be filed. A model that ignores that half of the
            // instruction and hands back a list for an event would otherwise
            // put it somewhere no screen shows it.
            listName: kind == .todo
                ? item.list?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                : nil
        )
    }

    private static func resolveTime(_ time: String?, on day: Date?, now: Date) -> Date? {
        guard let time, let parsed = timeFormatter.date(from: time) else { return nil }
        let comps = calendar.dateComponents([.hour, .minute], from: parsed)
        let base = day ?? calendar.startOfDay(for: now)
        return calendar.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: base)
    }

    private static func parseRecurrence(_ raw: String?) -> RecurrenceRule? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        if raw == "daily" { return .everyDay }
        if raw.hasPrefix("weekly:") {
            let days = raw.dropFirst("weekly:".count)
                .split(separator: ",")
                .compactMap { weekdayIndex(String($0)) }
            return days.isEmpty ? nil : .weekly(on: Set(days))
        }
        if raw.hasPrefix("timesperweek:") {
            return .timesPerWeek(Int(raw.dropFirst("timesperweek:".count)) ?? 1)
        }
        return nil
    }

    /// Calendar weekdays: Sunday = 1 ... Saturday = 7.
    ///
    /// The contract asks for English codes, and the model usually obliges — but
    /// a Spanish or Portuguese capture pulls it towards the day names it just
    /// read ("LUN", "QUA"). An unrecognized token used to return nil, which
    /// dropped the whole recurrence silently: the item saved, just without the
    /// repeat the user asked for. Accepting the obvious equivalents costs one
    /// table and removes a failure nobody would think to report.
    ///
    /// Accents are stripped first, so "MIÉ" and "MIE" are the same token, and
    /// Spanish/Portuguese are separated where they disagree — "SAB" is Saturday
    /// in both, but "DOM" is Sunday and "SEG"/"TER"/"QUA"/"QUI"/"SEX" are
    /// Portuguese Monday–Friday, which collide with nothing in Spanish.
    private static func weekdayIndex(_ token: String) -> Int? {
        let key = token
            .trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .prefix(3)
            .description

        return weekdayTokens[key]
    }

    private static let weekdayTokens: [String: Int] = [
        // English — the contract's own tokens.
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
        // Spanish: domingo, lunes, martes, miércoles, jueves, viernes, sábado.
        "dom": 1, "lun": 2, "mar": 3, "mie": 4, "jue": 5, "vie": 6, "sab": 7,
        // Portuguese: domingo, segunda, terça, quarta, quinta, sexta, sábado.
        // "dom"/"sab" match Spanish; the weekday stems do not collide.
        "seg": 2, "ter": 3, "qua": 4, "qui": 5, "sex": 6,
    ]

    /// The prompt's date line, always in English.
    ///
    /// This used to use the device locale, so a phone set to Spanish injected
    /// "miércoles" into an otherwise English instruction — harmless-looking, but
    /// it made the prompt vary by a setting that has nothing to do with parsing.
    /// The input language is the model's business; the instructions are not.
    private static func englishWeekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_US_POSIX")))
    }

    // MARK: - Formatters

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1
        return c
    }()

    static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
