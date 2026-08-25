//
//  TodoAttributeTests.swift
//  RoutineOrganizerTests
//
//  Priority and today-vs-long-term: that they survive the round trip through a
//  draft, and that they actually order the checklist rather than just decorating
//  it. A label that doesn't change anything is a label nobody trusts.
//

import Testing
import Foundation
@testable import Routly

private let cal = Calendar(identifier: .gregorian)

private let monday: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 20; c.hour = 8
    return cal.date(from: c)!
}()

@Suite("To-do priority and scope")
struct TodoAttributeTests {
    let vm = ScheduleViewModel()

    private func todo(_ title: String, _ priority: Priority, _ scope: TodoScope) -> ScheduleItem {
        ScheduleItem(
            title: title,
            kind: .todo,
            priority: priority,
            todoScope: scope,
            createdAt: monday
        )
    }

    @Test("a fresh item defaults to medium priority, scoped to today")
    func defaults() {
        let item = ScheduleItem(title: "Something", kind: .todo)
        #expect(item.priority == .medium)
        #expect(item.todoScope == .today)
    }

    /// The shape of a row written before these columns existed: NULL in both.
    ///
    /// This is the regression test for a launch crash. Declaring these as
    /// non-optional `Priority`/`TodoScope` with a Swift default reads fine and
    /// migrates fatally — the default never reaches a decoded row, and
    /// SwiftData traps on nil for a non-optional keypath before any recovery
    /// code can run. The accessor has to absorb nil itself.
    @Test("a row predating these columns reads as the defaults, not a crash")
    func nullColumnsFallBackToDefaults() {
        let item = ScheduleItem(title: "Older than the feature", kind: .todo)
        item.priorityRawValue = nil
        item.todoScopeRawValue = nil

        #expect(item.priority == .medium)
        #expect(item.todoScope == .today)
    }

    /// And a value that isn't in the enum any more (a column written by a newer
    /// build, or a hand-edited store) degrades rather than trapping.
    @Test("an unrecognised stored value falls back instead of failing")
    func unknownRawValueFallsBack() {
        let item = ScheduleItem(title: "From the future", kind: .todo)
        item.priorityRawValue = "catastrophic"
        item.todoScopeRawValue = "next-decade"

        #expect(item.priority == .medium)
        #expect(item.todoScope == .today)
    }

    @Test("setting through the accessor round-trips via the backing column")
    func accessorWritesBackingValue() {
        let item = ScheduleItem(title: "Something", kind: .todo)
        item.priority = .high
        item.todoScope = .longTerm

        #expect(item.priorityRawValue == "high")
        #expect(item.todoScopeRawValue == "longTerm")
        #expect(item.priority == .high)
        #expect(item.todoScope == .longTerm)
    }

    @Test("today's work sorts above long-term, whatever its priority")
    func scopeBeatsPriority() {
        let items = [
            todo("Learn to sail", .high, .longTerm),
            todo("Email the landlord", .low, .today),
        ]
        let ordered = vm.activeTodos(from: items, now: monday).map(\.title)
        #expect(ordered == ["Email the landlord", "Learn to sail"])
    }

    @Test("within a scope, higher priority comes first")
    func priorityOrdersWithinScope() {
        let items = [
            todo("Low thing", .low, .today),
            todo("High thing", .high, .today),
            todo("Middling thing", .medium, .today),
        ]
        let ordered = vm.activeTodos(from: items, now: monday).map(\.title)
        #expect(ordered == ["High thing", "Middling thing", "Low thing"])
    }

    @Test("long-term items keep their own priority order at the bottom")
    func longTermOrdering() {
        let items = [
            todo("Someday low", .low, .longTerm),
            todo("Now", .medium, .today),
            todo("Someday high", .high, .longTerm),
        ]
        let ordered = vm.activeTodos(from: items, now: monday).map(\.title)
        #expect(ordered == ["Now", "Someday high", "Someday low"])
    }

    @Test("editing an item carries priority and scope both ways")
    func draftRoundTrip() {
        let item = todo("Report", .high, .longTerm)

        let draft = CaptureDraft(item: item)
        #expect(draft.priority == .high)
        #expect(draft.todoScope == .longTerm)

        draft.priority = .low
        draft.todoScope = .today
        draft.apply(to: item)

        #expect(item.priority == .low)
        #expect(item.todoScope == .today)
    }

    @Test("a new to-do from the draft carries what was chosen")
    func makeItemCarriesAttributes() {
        let draft = CaptureDraft(kind: .todo, now: monday)
        draft.title = "Fix the tap"
        draft.priority = .high
        draft.todoScope = .longTerm

        let item = draft.makeItem()
        #expect(item.priority == .high)
        #expect(item.todoScope == .longTerm)
    }

    /// Reversed on 16 Aug 2026, deliberately. This asserted that an undated
    /// to-do was "someday" — no deadline to be late against, so not today's
    /// problem. In use that had it backwards: most to-dos are captured without
    /// a date precisely *because* they are for now, and filing them under
    /// Long-term meant every quick capture had to be moved before it counted.
    ///
    /// Long-term is now something you choose, not somewhere you land.
    @Test("a parsed to-do with no date is still today's work")
    func undatedParseIsToday() {
        let parsed = ParsedCapture(
            title: "Learn to sail",
            scheduledDate: nil,
            category: .personal,
            sourceText: "learn to sail"
        )
        let draft = CaptureDraft(parsed: parsed, kind: .todo, now: monday)
        #expect(draft.todoScope == .today)
    }

    @Test("a parsed to-do with a date is today's problem")
    func datedParseIsToday() {
        let parsed = ParsedCapture(
            title: "File the taxes",
            scheduledDate: cal.startOfDay(for: monday),
            category: .work,
            sourceText: "file the taxes today"
        )
        let draft = CaptureDraft(parsed: parsed, kind: .todo, now: monday)
        #expect(draft.todoScope == .today)
    }
}
