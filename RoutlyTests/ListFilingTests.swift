//
//  ListFilingTests.swift
//  RoutineOrganizerTests
//
//  "Math homework" landing under School — the parser filing a to-do into one of
//  the user's own lists.
//
//  The interesting failures here are all about *not* filing. A model asked to
//  categorise will categorise, so the value of this feature is bounded by how
//  reliably a bad guess is refused: a name that matches no list, a list handed
//  to an event, a capture that fits nothing. Each one has to end with the task
//  unfiled rather than filed somewhere surprising, because the user pays for a
//  wrong answer twice — once noticing it, once undoing it.
//

import Testing
import Foundation
@testable import Routly

// MARK: - The prompt

@Test func promptOffersTheUsersOwnListsVerbatim() {
    let prompt = ParsingContract.systemPrompt(now: Date(), lists: ["School", "Work", "Groceries"])

    #expect(prompt.contains("\"School\""))
    #expect(prompt.contains("\"Work\""))
    #expect(prompt.contains("\"Groceries\""))
    // The rule that keeps a returned name matchable.
    #expect(prompt.contains("copied character for character"))
    #expect(prompt.contains("Never invent a name"))
}

/// With nothing to file into, the clause collapses to a flat instruction rather
/// than describing an empty set — most people have no lists at all, and that is
/// the prompt every one of their captures carries.
@Test func promptWithNoListsSaysSoPlainly() {
    let prompt = ParsingContract.systemPrompt(now: Date(), lists: [])

    #expect(prompt.contains("- list: always null."))
    #expect(!prompt.contains("copied character for character"))
}

@Test func promptIgnoresBlankListNames() {
    let prompt = ParsingContract.systemPrompt(now: Date(), lists: ["   ", ""])
    #expect(prompt.contains("- list: always null."))
}

/// The JSON shape in the prompt has to carry the field too. Providers without
/// strict schema enforcement follow the example, not the schema.
@Test func promptShapeIncludesTheListField() {
    #expect(ParsingContract.systemPrompt(now: Date()).contains("\"list\":null"))
}

// MARK: - Decoding

@Test func aListNameOnATodoIsCarriedThrough() throws {
    let json = """
    {"items":[{"title":"Math homework","kind":"todo","category":"personal","date":null,\
    "time":null,"durationMinutes":null,"effortMinutes":null,"recurrence":null,\
    "clarification":null,"list":"School"}]}
    """
    let parsed = try ParsingContract.items(fromJSON: json, now: Date(), sourceText: "x")
    #expect(parsed.first?.listName == "School")
}

/// An event has a time, not a list. A model that returns one anyway would
/// otherwise file it somewhere no screen displays.
@Test func aListNameOnAnEventIsDiscarded() throws {
    let json = """
    {"items":[{"title":"Standup","kind":"event","category":"work","date":null,\
    "time":"09:00","durationMinutes":15,"effortMinutes":null,"recurrence":null,\
    "clarification":null,"list":"Work"}]}
    """
    let parsed = try ParsingContract.items(fromJSON: json, now: Date(), sourceText: "x")
    #expect(parsed.first?.listName == nil)
}

@Test func aBlankListNameIsNoListAtAll() throws {
    let json = """
    {"items":[{"title":"Buy milk","kind":"todo","category":"personal","date":null,\
    "time":null,"durationMinutes":null,"effortMinutes":null,"recurrence":null,\
    "clarification":null,"list":"   "}]}
    """
    let parsed = try ParsingContract.items(fromJSON: json, now: Date(), sourceText: "x")
    #expect(parsed.first?.listName == nil)
}

/// Every provider that isn't the strict-schema one can simply omit the key.
/// Decoding has to survive that, or adding the field breaks existing parsing.
@Test func aMissingListKeyDecodesFine() throws {
    let json = """
    {"items":[{"title":"Buy milk","kind":"todo","category":"personal","date":null,\
    "time":null,"durationMinutes":null,"effortMinutes":null,"recurrence":null,\
    "clarification":null}]}
    """
    let parsed = try ParsingContract.items(fromJSON: json, now: Date(), sourceText: "x")
    #expect(parsed.count == 1)
    #expect(parsed.first?.listName == nil)
}

@Test func theSchemaRequiresTheListField() throws {
    let items = try #require(
        (ParsingContract.schema["properties"] as? [String: Any])?["items"] as? [String: Any]
    )
    let item = try #require(items["items"] as? [String: Any])
    let required = try #require(item["required"] as? [String])
    #expect(required.contains("list"))
    #expect((item["properties"] as? [String: Any])?["list"] != nil)
}

// MARK: - The offline parser

/// Offline, the app matches patterns and knows nothing about subjects. It files
/// only when the capture literally names a list, and says nothing otherwise —
/// rather than inventing a taxonomy the user would have to keep correcting.
@Test func theOfflineParserFilesOnlyOnAnExplicitName() async {
    let parser = StubAIParsingService()

    let named = await parser.parse("Shopping milk and eggs", now: Date(),
                                   workingHours: .default, lists: ["Shopping"])
    #expect(named.first?.listName == "Shopping")

    // "math homework" belongs under School to a person and to a model. It does
    // not, and must not, to a regex.
    let inferred = await parser.parse("math homework", now: Date(),
                                      workingHours: .default, lists: ["School"])
    #expect(inferred.first?.listName == nil)
}

/// A list called "Art" must not claim "start the report".
@Test func theOfflineParserMatchesWholeWordsOnly() async {
    let parser = StubAIParsingService()
    let parsed = await parser.parse("start the report", now: Date(),
                                    workingHours: .default, lists: ["Art"])
    #expect(parsed.first?.listName == nil)
}

/// Two lists whose names overlap: the longer one is the more specific answer.
@Test func theOfflineParserPrefersTheLongerListName() async {
    let parser = StubAIParsingService()
    let parsed = await parser.parse("school run at 8", now: Date(),
                                    workingHours: .default, lists: ["School", "School run"])
    #expect(parsed.first?.listName == "School run")
}

@Test func theOfflineParserFilesNothingWithoutLists() async {
    let parser = StubAIParsingService()
    let parsed = await parser.parse("buy milk", now: Date(), workingHours: .default, lists: [])
    #expect(parsed.first?.listName == nil)
}

// MARK: - Draft

@Test func aParsedCaptureCarriesItsListIntoTheDraft() {
    let capture = ParsedCapture(title: "Math homework", kind: .todo,
                                sourceText: "math homework", listName: "School")
    let draft = CaptureDraft(parsed: capture, kind: .todo)

    #expect(draft.suggestedListName == "School")
    // Still unresolved: the draft has no access to the store, so the real list
    // is attached by the screen that has them queried.
    #expect(draft.list == nil)
}
