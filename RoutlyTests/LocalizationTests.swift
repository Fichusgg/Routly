//
//  LocalizationTests.swift
//  RoutineOrganizerTests
//
//  Localization is the kind of feature that looks finished and isn't: a missing
//  translation falls back to English silently, and a mis-encoded plural picks
//  the wrong form without ever raising an error. Both failures are invisible
//  from the English build, which is the one being looked at.
//
//  So these resolve real strings out of the built bundle in each language
//  rather than inspecting the catalog file — the question is what the app shows
//  a Spanish speaker, not what the JSON contains.
//

import Testing
import Foundation
@testable import Routly

private let en = Locale(identifier: "en")
private let es = Locale(identifier: "es")
private let pt = Locale(identifier: "pt-BR")

/// Passing `locale:` alone is not enough, and quietly so: that parameter picks
/// number/date formatting and the plural *rules*, but the string itself is
/// looked up in whichever localization the bundle was launched in. Without the
/// matching `.lproj` bundle every assertion below would compare English to
/// English and pass while proving nothing.
private func bundle(for code: String) throws -> Bundle {
    let path = try #require(
        Bundle.main.path(forResource: code, ofType: "lproj"),
        "no \(code).lproj in the built app — is \(code) in knownRegions?"
    )
    return try #require(Bundle(path: path))
}

private func localized(
    _ key: String.LocalizationValue,
    _ code: String,
    _ locale: Locale
) throws -> String {
    String(localized: key, bundle: try bundle(for: code), locale: locale)
}

// MARK: - Plain strings

@Test func plainStringsResolvePerLanguage() throws {
    #expect(try localized("Settings", "en", en) == "Settings")
    #expect(try localized("Settings", "es", es) == "Ajustes")
    #expect(try localized("Settings", "pt-BR", pt) == "Ajustes")

    #expect(try localized("A clear day", "es", es) == "Un día despejado")
    #expect(try localized("A clear day", "pt-BR", pt) == "Um dia livre")
}

/// The three languages are actually built into the app. If a region were
/// dropped from the project, everything else here would still pass by falling
/// back to English — this is the test that wouldn't.
@Test func allThreeLocalizationsAreBundled() throws {
    for code in ["en", "es", "pt-BR"] {
        _ = try bundle(for: code)
    }
}

/// A sample from every layer that produces user-facing text, so a whole file
/// going untranslated is caught rather than just a stray key.
@Test func everyLayerIsTranslated() throws {
    let samples = [
        "Optimize my day",          // ScheduleView
        "Voice language",           // CaptureSettingsView
        "At start time",            // ReminderLead
        "Work",                     // Category
        "Event",                    // ItemKind
        "High",                     // Priority
        "Every day",                // RecurrenceRule
        "This week",                // PlanHorizon
        "Soft pastel",              // Palette
        "Discreet",                 // TagDisplayStyle
        "Dark",                     // AppearanceSetting
        "Set for today",            // SuggestionEngine
        "Guest",                    // AccountView
        "Not on a calendar",        // CaptureConfirmSheet
        "Calendars",                // CalendarsView / MenuView
        "Apple Calendar",           // CalendarProvider
        "Not connected",            // CalendarConnections
        "What goes across",         // CalendarsView
    ]
    for key in samples {
        let spanish = try localized(String.LocalizationValue(key), "es", es)
        let portuguese = try localized(String.LocalizationValue(key), "pt-BR", pt)
        #expect(spanish != key, "Spanish falls back to English for “\(key)”")
        #expect(portuguese != key, "Portuguese falls back to English for “\(key)”")
    }
}

/// The privacy copy names the real provider host through `String(format:)`
/// rather than Swift interpolation, so its catalog key carries a literal `%@`.
/// A translation that dropped or mangled the specifier would silently show the
/// sentence without the host — on the one screen whose whole job is to say
/// where the words go.
@Test func providerHostSubstitutesInEveryLanguage() throws {
    let host = "api.example.com"

    for (code, locale) in [("es", es), ("pt-BR", pt)] {
        let bundle = try bundle(for: code)

        let row = String(format: String(localized: "Sent to %@", bundle: bundle, locale: locale), host)
        #expect(row != "Sent to \(host)", "\(code) falls back to English for the settings row")
        #expect(row.contains(host), "\(code) dropped the host: “\(row)”")

        let explanation = String(
            format: String(
                localized: "When you type or speak a capture, those words are sent to %@ to be turned into a dated, timed item. It's what lets “gym tuesday and thursday at 7” become two entries instead of one line of text.",
                bundle: bundle,
                locale: locale
            ),
            host
        )
        #expect(explanation.contains(host), "\(code) dropped the host from the explanation")
        #expect(!explanation.hasPrefix("When you type"), "\(code) falls back to English for the explanation")
    }
}

// MARK: - Plurals

/// A single-argument plural, where the whole string varies.
@Test func singleArgumentPluralPicksTheRightForm() throws {
    #expect(try localized("Review \(1) items", "en", en) == "Review 1 item")
    #expect(try localized("Review \(4) items", "en", en) == "Review 4 items")

    #expect(try localized("Review \(1) items", "es", es) == "Revisar 1 elemento")
    #expect(try localized("Review \(4) items", "es", es) == "Revisar 4 elementos")

    #expect(try localized("Review \(1) items", "pt-BR", pt) == "Revisar 1 item")
    #expect(try localized("Review \(4) items", "pt-BR", pt) == "Revisar 4 itens")
}

/// The multi-argument case, which needs `substitutions` to say *which* argument
/// drives the plural. Getting this wrong doesn't throw — it silently picks a
/// form or drops an argument — so it is asserted rather than assumed.
@Test func multiArgumentPluralBindsToTheRightArgument() throws {
    let effort = "~1h"
    let slot = "you've got 2h clear"

    #expect(try localized("Overdue by \(1) days — \(effort), and \(slot).", "en", en)
            == "Overdue by 1 day — ~1h, and you've got 2h clear.")
    #expect(try localized("Overdue by \(3) days — \(effort), and \(slot).", "en", en)
            == "Overdue by 3 days — ~1h, and you've got 2h clear.")

    // The clause arguments are already-localized fragments, so they read as
    // English here — what is being checked is the frame and the day word.
    #expect(try localized("Overdue by \(1) days — \(effort), and \(slot).", "es", es)
            == "Lleva 1 día de retraso: ~1h, y you've got 2h clear.")
    #expect(try localized("Overdue by \(3) days — \(effort), and \(slot).", "es", es)
            == "Lleva 3 días de retraso: ~1h, y you've got 2h clear.")
}

/// The plural argument is the *second* one here — the case most likely to be
/// mis-bound, because binding to argument 1 would still produce a plausible
/// looking sentence.
@Test func pluralOnASecondArgument() throws {
    let title = "Call mom"
    #expect(try localized("“\(title)” has been on your list \(1) days. Give it a day?", "en", en)
            == "“Call mom” has been on your list 1 day. Give it a day?")
    #expect(try localized("“\(title)” has been on your list \(5) days. Give it a day?", "en", en)
            == "“Call mom” has been on your list 5 days. Give it a day?")
    #expect(try localized("“\(title)” has been on your list \(5) days. Give it a day?", "pt-BR", pt)
            == "“Call mom” está na sua lista há 5 dias. Definir um dia?")
}

// MARK: - Reminder countdown

/// The notification's lead-time phrasing, which used to be `leadMinutes / 60`
/// hardcoded as "hours" — so the two shortest leads, and the shipped default
/// among them, read "Starts in 0 hours".
///
/// Asserted against every language rather than against the main bundle, because
/// what language the test host launched in isn't something this file controls:
/// each phrase has to match *one* of the three renderings, which pins the
/// branch and the wording without assuming the run is English.
@Test func countdownPhraseSplitsByMagnitude() throws {
    let expected: [Int: [String]] = [
        0:   ["Starting now", "Empieza ahora", "Começa agora"],
        1:   ["In 1 minute", "En 1 minuto", "Em 1 minuto"],
        10:  ["In 10 minutes", "En 10 minutos", "Em 10 minutos"],
        30:  ["In 30 minutes", "En 30 minutos", "Em 30 minutos"],
        60:  ["In 1 hour", "En 1 hora", "Em 1 hora"],
        90:  ["In 1 hour 30 minutes", "En 1 hora y 30 minutos", "Em 1 hora e 30 minutos"],
        120: ["In 2 hours", "En 2 horas", "Em 2 horas"],
        180: ["In 3 hours", "En 3 horas", "Em 3 horas"],
    ]
    for (minutes, renderings) in expected {
        let phrase = ReminderLead.countdownPhrase(minutes)
        #expect(renderings.contains(phrase),
                "\(minutes) min rendered as “\(phrase)”, none of \(renderings)")
    }
}

/// The failure the old string actually produced, stated directly — and its
/// mirror image, a lead that would round the other way.
@Test func countdownPhraseNeverSaysZero() {
    // Compared as whole numbers rather than substrings, in any language: "0
    // minutes" has to fail this and "10 minutes" — which *contains* "0 minute" —
    // must not. Written as a substring check first, it did fail on 10 and 30.
    for minutes in ([0, 1, 90] + ReminderLead.options) {
        let phrase = ReminderLead.countdownPhrase(minutes)
        let numbers = phrase.split(whereSeparator: { !$0.isNumber })
        #expect(!numbers.contains("0"), "“\(phrase)” for \(minutes) min counts down from zero")
    }
    // A nonsense lead still says something, rather than counting down past zero.
    #expect(ReminderLead.countdownPhrase(-5) == ReminderLead.countdownPhrase(0))
}

/// Resolved through each language bundle the way the call site builds them, so a
/// key Swift generates differently from the catalog — or a plural bound to the
/// wrong argument in the two-number case — fails here rather than at 7am on
/// someone's lock screen.
@Test func countdownPhrasesAreTranslated() throws {
    #expect(try localized("Starting now", "es", es) == "Empieza ahora")
    #expect(try localized("Starting now", "pt-BR", pt) == "Começa agora")

    #expect(try localized("In \(1) minutes", "es", es) == "En 1 minuto")
    #expect(try localized("In \(30) minutes", "es", es) == "En 30 minutos")
    #expect(try localized("In \(30) minutes", "pt-BR", pt) == "Em 30 minutos")

    #expect(try localized("In \(1) hours", "es", es) == "En 1 hora")
    #expect(try localized("In \(2) hours", "pt-BR", pt) == "Em 2 horas")

    // Two plural arguments in one string: "1 hora" must be singular while
    // "30 minutos" stays plural, which only holds if each substitution is bound
    // to its own argument.
    #expect(try localized("In \(1) hours \(30) minutes", "en", en) == "In 1 hour 30 minutes")
    #expect(try localized("In \(1) hours \(30) minutes", "es", es) == "En 1 hora y 30 minutos")
    #expect(try localized("In \(1) hours \(30) minutes", "pt-BR", pt) == "Em 1 hora e 30 minutos")
    #expect(try localized("In \(2) hours \(1) minutes", "es", es) == "En 2 horas y 1 minuto")
}

// MARK: - Voice language

@Test func preferredLocaleFavoursTheDeviceRegion() {
    let supported: Set<String> = ["es-ES", "es-MX", "pt-BR", "pt-PT", "en-US", "en-GB"]

    // A Mexican phone gets Mexican Spanish, not the head of the candidate list.
    #expect(VoiceLanguage.spanish.preferredLocale(supported: supported, deviceRegion: "MX") == "es-MX")
    // A Portuguese phone gets pt-PT even though pt-BR leads the list.
    #expect(VoiceLanguage.portuguese.preferredLocale(supported: supported, deviceRegion: "PT") == "pt-PT")
    // An unrelated region falls back to the first supported candidate.
    #expect(VoiceLanguage.spanish.preferredLocale(supported: supported, deviceRegion: "JP") == "es-ES")
}

@Test func preferredLocaleToleratesUnderscoreIdentifiers() {
    // Apple reports these with either separator depending on the API.
    let supported: Set<String> = ["es_MX", "pt_BR"]
    #expect(VoiceLanguage.spanish.preferredLocale(supported: supported, deviceRegion: "MX") == "es-MX")
}

@Test func preferredLocaleAlwaysReturnsSomething() {
    // Nothing supported at all — still hand back a locale to try rather than
    // refusing to record.
    #expect(VoiceLanguage.portuguese.preferredLocale(supported: [], deviceRegion: nil) == "pt-BR")
}

// MARK: - Parsing is not English-only

/// The model is told to emit English weekday codes, but a Spanish or Portuguese
/// capture pulls it towards the day names it just read. That used to drop the
/// recurrence silently — the item saved, just without the repeat.
@Test func recurrenceAcceptsSpanishAndPortugueseWeekdays() throws {
    func rule(_ recurrence: String) throws -> RecurrenceRule? {
        let json = """
        {"items":[{"title":"Gym","kind":"todo","category":"health","date":null,"time":null,\
        "durationMinutes":null,"effortMinutes":null,"recurrence":"\(recurrence)","clarification":null}]}
        """
        return try ParsingContract.items(fromJSON: json, now: Date(), sourceText: "x").first?.recurrence
    }

    // Calendar weekdays: Sunday = 1 … Saturday = 7.
    #expect(try rule("weekly:MON,WED,FRI") == .weekly(on: [2, 4, 6]))
    // Spanish: lunes, miércoles, viernes — including the accent.
    #expect(try rule("weekly:LUN,MIÉ,VIE") == .weekly(on: [2, 4, 6]))
    #expect(try rule("weekly:LUN,MIE,VIE") == .weekly(on: [2, 4, 6]))
    // Portuguese: segunda, quarta, sexta.
    #expect(try rule("weekly:SEG,QUA,SEX") == .weekly(on: [2, 4, 6]))
    // Shared between Spanish and Portuguese.
    #expect(try rule("weekly:DOM,SAB") == .weekly(on: [1, 7]))
}

@Test func horizonDetectionHandlesAllThreeLanguages() {
    #expect(PlanTemplates.detectHorizon("get fit this quarter") == .thisQuarter)
    #expect(PlanTemplates.detectHorizon("ponerme en forma este trimestre") == .thisQuarter)
    #expect(PlanTemplates.detectHorizon("entrar em forma este trimestre") == .thisQuarter)

    #expect(PlanTemplates.detectHorizon("this month") == .thisMonth)
    #expect(PlanTemplates.detectHorizon("este mes") == .thisMonth)
    #expect(PlanTemplates.detectHorizon("este mês") == .thisMonth)

    #expect(PlanTemplates.detectHorizon("this week") == .thisWeek)
    #expect(PlanTemplates.detectHorizon("esta semana") == .thisWeek)

    #expect(PlanTemplates.detectHorizon("no time frame at all") == nil)
}

/// The prompt's own date line must not follow the device language — the input
/// language is the model's business, the instructions are not.
@Test func promptDateLineStaysEnglish() {
    // 2026-07-29 is a Wednesday.
    var components = DateComponents()
    components.year = 2026; components.month = 7; components.day = 29
    let date = ParsingContract.calendar.date(from: components)!

    let prompt = ParsingContract.systemPrompt(now: date)
    #expect(prompt.contains("Wednesday"))
    #expect(!prompt.contains("miércoles"))
    #expect(!prompt.contains("quarta"))
}

/// The prompt has to tell the model to answer in the captured language —
/// without it, whether a Spanish capture yields Spanish titles is undefined.
@Test func promptAsksForTitlesInTheSpokenLanguage() {
    let prompt = ParsingContract.systemPrompt(now: Date())
    #expect(prompt.contains("SAME language"))
    #expect(prompt.contains("never translate"))

    let planner = ParsingContract.plannerSystemPrompt(now: Date())
    #expect(planner.contains("SAME language"))
}

/// A language *named in the capture* is a topic, not a language selection.
///
/// "I have Spanish homework" came back titled in Spanish. Two things in the
/// prompt allowed it: "the SAME language the person spoke" is ambiguous once a
/// language appears in the content, and the ban on translating only covered
/// translating *into English* — so English→Spanish was never prohibited. Both
/// prompts now say the direction is barred either way, and both carry a worked
/// example, because the abstract rule alone is what the model misread.
@Test func promptsForbidTranslatingIntoALanguageTheCaptureMerelyMentions() {
    let prompt = ParsingContract.systemPrompt(now: Date())
    #expect(prompt.contains("either direction"))
    #expect(prompt.contains("subject matter, not an instruction"))
    #expect(prompt.contains("Spanish homework"))

    // The planner is the worse case: "learn Spanish" would otherwise render an
    // entire generated plan — title, summary and every step — in Spanish.
    let planner = ParsingContract.plannerSystemPrompt(now: Date())
    #expect(planner.contains("either direction"))
    #expect(planner.contains("subject matter, not an instruction"))
}

// MARK: - Consistency screen & delete dialogs

/// These two surfaces were English in every language until 13 Aug 2026: their
/// copy went through `String`-typed parameters, and the `String` overloads of
/// `Text`, `.alert` and `.accessibilityLabel` are the ones that skip the
/// catalog entirely. Nothing warned — the app just spoke English.
///
/// Note what these assert and why. Looking a key up by writing the same key
/// string the catalog contains would prove nothing: if the call site generates
/// a *different* key, both the test and the catalog can agree while the app
/// still falls back to English. So the interpolated cases below build their
/// strings the same way the views do — real interpolation, resolved against a
/// language bundle — which makes Swift generate the key rather than the test
/// asserting one. A mismatched specifier fails here.
@Test func consistencyScreenIsTranslated() throws {
    for key in ["Consistent", "weeks in a row", "Follow-through", "of planned",
                "Nothing planned.", "Recent weeks", "Finished"] {
        let spanish = try localized(String.LocalizationValue(key), "es", es)
        let portuguese = try localized(String.LocalizationValue(key), "pt-BR", pt)
        #expect(spanish != key, "Spanish falls back to English for “\(key)”")
        #expect(portuguese != key, "Portuguese falls back to English for “\(key)”")
    }
}

@Test func deleteDialogCopyIsTranslated() throws {
    for key in ["Delete this?", "Tomorrow", "Yesterday",
                "This removes it from your list for good — it won't count as a missed day.",
                "This removes it from your calendar for good."] {
        let spanish = try localized(String.LocalizationValue(key), "es", es)
        #expect(spanish != key, "Spanish falls back to English for “\(key)”")
    }
}

/// The interpolated keys, generated the way the call sites generate them.
/// This is the case a hand-written key can't cover: `%lld` vs `%@`, or a
/// positional specifier the catalog uses and Swift doesn't, both show up here
/// as an English fallback and nowhere else.
@Test func interpolatedConsistencyStringsResolve() throws {
    let esBundle = try bundle(for: "es")
    let ptBundle = try bundle(for: "pt-BR")

    let done = 3, planned = 4

    // ConsistencyView.detailText — two integers in one string.
    let both = String(localized: "\(done) of \(planned) finished.", bundle: esBundle, locale: es)
    #expect(both != "3 of 4 finished.", "two-integer key didn't match: got “\(both)”")
    #expect(both.contains("de"))

    // ConsistencyView.detailText — the missed-day line.
    let missed = String(localized: "\(planned) planned, none finished.", bundle: esBundle, locale: es)
    #expect(missed != "4 planned, none finished.", "single-integer key didn't match: got “\(missed)”")

    // ConsistencyView.rangeLabel — a string interpolation, not an integer.
    // Held in a variable so the interpolation is a `String`, exactly as the
    // view's `first.formatted(...)` produces one.
    let shortDate = "12 Jul"
    let since = String(localized: "Since \(shortDate)", bundle: ptBundle, locale: pt)
    #expect(since != "Since 12 Jul", "string-interpolation key didn't match: got “\(since)”")

    // ConsistencyView.accessibilityLabel — mixed string and two integers.
    let longDate = "12 July"
    let spoken = String(localized: "\(longDate), \(done) of \(planned) finished",
                        bundle: esBundle, locale: es)
    #expect(spoken != "12 July, 3 of 4 finished", "mixed-argument key didn't match: got “\(spoken)”")
}

/// `SectionLabel` took a `String` so it could `.uppercased()` it, which meant
/// all 22 of its distinct headers — Settings, Today, the calendar, every sheet —
/// resolved through the non-localizing `Text` overload and stayed English.
/// One sample per screen that owns headers, so a whole screen regressing is
/// caught rather than just a stray key.
@Test func sectionHeadersAreTranslated() throws {
    let samples = [
        "Your day",           // MenuView
        "Capture",            // MenuView
        "AI & privacy",       // MenuView
        "Reminders",          // CaptureSettingsView
        "Theme",              // AppearanceView
        "Where",              // CaptureParsingView
        "Where your schedule lives", // PrivacyView
        "Tag colours",        // ColorSettingsView
        "Today’s schedule",   // ScheduleView  (note the typographic apostrophe)
        "To-dos",             // ScheduleView
        "Categories",         // CalendarView
        "When",               // CaptureConfirmSheet
        "Your plan",          // PlanReviewView
        "You said",           // CaptureReviewView
        "Overlaps",           // ConflictResolutionView
        "What I'd do",        // OptimizeDayView
        "Won't fit today",    // OptimizeDayView
    ]
    for key in samples {
        let spanish = try localized(String.LocalizationValue(key), "es", es)
        let portuguese = try localized(String.LocalizationValue(key), "pt-BR", pt)
        #expect(spanish != key, "Spanish falls back to English for “\(key)”")
        #expect(portuguese != key, "Portuguese falls back to English for “\(key)”")
    }
}

// MARK: - Calendars

/// The calendar copy is the app speaking about somebody else's data, and every
/// sentence in it is either a permission explanation or a limitation. A missing
/// translation here doesn't degrade to "slightly English" — it degrades to a
/// Spanish speaker being told, in English, why their event didn't appear.
@Test func calendarCopyIsTranslated() throws {
    let samples = [
        "To-dos stay in Routly. Events and reminders are what go on a calendar.",
        "Repeating items stay in Routly for now — a calendar can't describe every way Routly repeats things.",
        "Routly can add events here but can't change or remove them. Allow full access in the Settings app to keep them in step.",
        "Turn Calendars on for Routly in the Settings app to add events here.",
        "Couldn't reach your calendar",
        "Routly still sends its own reminder. It doesn't add a second alert to the calendar, so nothing tells you twice.",
    ]
    for key in samples {
        let spanish = try localized(String.LocalizationValue(key), "es", es)
        let portuguese = try localized(String.LocalizationValue(key), "pt-BR", pt)
        #expect(spanish != key, "Spanish falls back to English for “\(key)”")
        #expect(portuguese != key, "Portuguese falls back to English for “\(key)”")
    }
}

/// The provider's name is substituted with `String(format:)`, so its key
/// carries a literal `%@`. A translation that dropped the specifier would leave
/// the sentence naming no calendar at all — which is the one thing it exists to
/// say when two are connected.
@Test func calendarFailureNamesTheProvider() throws {
    for (code, locale) in [("es", es), ("pt-BR", pt)] {
        let bundle = try bundle(for: code)
        let sentence = String(
            format: String(localized: "Couldn't update %@. %@", bundle: bundle, locale: locale),
            "Apple Calendar",
            "…"
        )
        #expect(sentence.contains("Apple Calendar"), "\(code) dropped the provider name: “\(sentence)”")
        #expect(!sentence.hasPrefix("Couldn't update"), "\(code) falls back to English")
    }
}

/// Both calendar counts vary the whole sentence, and Spanish moves the number
/// to the middle of it — so the plural forms have to be real translations
/// rather than a suffix bolted onto an English stem.
@Test func calendarCountsPluralizePerLanguage() throws {
    #expect(try localized("\(1) items are in this calendar.", "en", en) == "1 item is in this calendar.")
    #expect(try localized("\(3) items are in this calendar.", "en", en) == "3 items are in this calendar.")

    let oneEs = try localized("\(1) items couldn't be added to a calendar.", "es", es)
    let manyEs = try localized("\(3) items couldn't be added to a calendar.", "es", es)
    #expect(oneEs == "No se pudo añadir 1 elemento a un calendario.")
    #expect(manyEs == "No se pudieron añadir 3 elementos a un calendario.")

    let onePt = try localized("\(1) items couldn't be added to a calendar.", "pt-BR", pt)
    let manyPt = try localized("\(3) items couldn't be added to a calendar.", "pt-BR", pt)
    #expect(onePt == "1 item não pôde ser adicionado a um calendário.")
    #expect(manyPt == "3 itens não puderam ser adicionados a um calendário.")
}
