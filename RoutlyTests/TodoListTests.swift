//
//  TodoListTests.swift
//  RoutineOrganizerTests
//
//  Lists are an entity rather than a string, and the reason is that deleting one
//  must not take its to-dos with it. That is a delete rule on a relationship —
//  one word in a macro — so it gets a test rather than a comment.
//

import Testing
import Foundation
import SwiftData
@testable import Routly

private let cal = Calendar(identifier: .gregorian)

@MainActor
private func store() throws -> ModelContext {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self,
        configurations: config
    )
    return ModelContext(container)
}

@Suite("To-do lists")
@MainActor
struct TodoListTests {

    private func configured() throws -> (ScheduleViewModel, ModelContext) {
        let context = try store()
        let vm = ScheduleViewModel()
        vm.configure(context: context)
        return (vm, context)
    }

    @Test("a created list takes the next position")
    func createOrders() throws {
        let (vm, _) = try configured()
        let first = try #require(vm.createList(named: "Work", after: []))
        let second = try #require(vm.createList(named: "Home", after: [first]))
        #expect(second.sortIndex > first.sortIndex)
    }

    // MARK: - Reordering

    /// Dragging a to-do above another has to *write* the new order, not just
    /// animate it. It didn't for a while: the rows carried drop destinations
    /// that never fired inside a `List`, so a task lifted, moved, and snapped
    /// back with nothing saved. `onMove` is the path now, and this is the
    /// handler behind it.
    @Test("a drag writes a position onto every row in the group")
    func reorderWritesTheWholeGroup() throws {
        let (vm, context) = try configured()
        let items = ["Alpha", "Beta", "Gamma"].map { title -> ScheduleItem in
            let item = ScheduleItem(title: title, kind: .todo, category: .personal)
            context.insert(item)
            return item
        }

        // Every index starts nil — an untouched group sorts by the automatic
        // rules, and that is what a first drag replaces.
        #expect(items.allSatisfy { $0.todoSortIndex == nil })

        // Drag the last one to the front, in `ForEach.onMove` terms.
        vm.reorder(items, from: IndexSet(integer: 2), to: 0)

        #expect(items[2].todoSortIndex == 0, "the dragged row takes the position it was dropped on")
        #expect(items[0].todoSortIndex == 1)
        #expect(items[1].todoSortIndex == 2)
    }

    /// A group where some rows carry an index and some don't sorts by two rules
    /// at once, so the handler stamps all of them rather than only the mover.
    @Test("no row is left without a position after a drag")
    func reorderLeavesNoGaps() throws {
        let (vm, context) = try configured()
        let items = ["Alpha", "Beta", "Gamma"].map { title -> ScheduleItem in
            let item = ScheduleItem(title: title, kind: .todo, category: .personal)
            context.insert(item)
            return item
        }

        vm.reorder(items, from: IndexSet(integer: 0), to: 2)

        #expect(items.allSatisfy { $0.todoSortIndex != nil })
        #expect(Set(items.compactMap(\.todoSortIndex)) == [0, 1, 2], "positions are unique and contiguous")
    }

    @Test("a blank name makes no list")
    func blankNameRefused() throws {
        let (vm, _) = try configured()
        #expect(vm.createList(named: "   ", after: []) == nil)
        #expect(vm.createList(named: "", after: []) == nil)
    }

    @Test("names are trimmed rather than stored with their whitespace")
    func nameTrimmed() throws {
        let (vm, _) = try configured()
        let list = try #require(vm.createList(named: "  Shopping  ", after: []))
        #expect(list.name == "Shopping")
    }

    /// The guarantee the whole entity exists for.
    @Test("deleting a list keeps its to-dos and unfiles them")
    func deleteKeepsItems() throws {
        let (vm, context) = try configured()
        let list = try #require(vm.createList(named: "Work", after: []))

        let item = ScheduleItem(title: "Email the landlord", kind: .todo)
        context.insert(item)
        vm.assign(item, to: list)
        #expect(item.list != nil)

        vm.delete(list)

        // The to-do survives…
        let remaining = try context.fetch(FetchDescriptor<ScheduleItem>())
        #expect(remaining.map(\.title) == ["Email the landlord"])
        // …and is simply no longer filed anywhere.
        #expect(item.list == nil)
        #expect(try context.fetch(FetchDescriptor<TodoList>()).isEmpty)
    }

    @Test("renaming is one write, seen through the item")
    func renameIsOneWrite() throws {
        let (vm, context) = try configured()
        let list = try #require(vm.createList(named: "Wrok", after: []))
        let item = ScheduleItem(title: "Report", kind: .todo)
        context.insert(item)
        vm.assign(item, to: list)

        vm.rename(list, to: "Work")
        #expect(item.list?.name == "Work")
    }

    @Test("a blank rename is refused rather than blanking the name")
    func blankRenameRefused() throws {
        let (vm, _) = try configured()
        let list = try #require(vm.createList(named: "Work", after: []))
        vm.rename(list, to: "  ")
        #expect(list.name == "Work")
    }

    /// An event belongs to a day, not to a list. Nothing in the UI offers the
    /// choice, and the view model refuses it too rather than relying on that.
    @Test("only a to-do can be filed under a list")
    func onlyTodosAreFiled() throws {
        let (vm, context) = try configured()
        let list = try #require(vm.createList(named: "Work", after: []))

        let event = ScheduleItem(title: "Standup", kind: .event,
                                 scheduledDate: cal.startOfDay(for: Date()))
        context.insert(event)
        vm.assign(event, to: list)
        #expect(event.list == nil)
    }

    @Test("the count on a list ignores finished work")
    func openCountIgnoresDone() throws {
        let (vm, context) = try configured()
        let list = try #require(vm.createList(named: "Work", after: []))

        let open = ScheduleItem(title: "Open", kind: .todo)
        let done = ScheduleItem(title: "Done", kind: .todo, isCompleted: true)
        context.insert(open); context.insert(done)
        vm.assign(open, to: list)
        vm.assign(done, to: list)

        #expect(list.items.count == 2)
        #expect(list.openCount == 1)
    }
}

@Suite("Manual to-do order")
@MainActor
struct TodoOrderTests {

    private func todo(_ title: String, _ priority: Priority) -> ScheduleItem {
        ScheduleItem(title: title, kind: .todo, priority: priority)
    }

    /// A hand-arranged order has to beat the automatic one, or dragging a row
    /// and watching it spring back is the whole experience.
    @Test("a hand-arranged order overrides the priority sort")
    func manualOrderWins() throws {
        let context = try store()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let low = todo("Low", .low)
        let high = todo("High", .high)
        for item in [low, high] { context.insert(item) }

        // Automatic order puts High first.
        #expect(vm.activeTodos(from: [low, high]).map(\.title) == ["High", "Low"])

        // Dragging Low above High must stick.
        vm.reorderTodos([low, high])
        #expect(vm.activeTodos(from: [low, high]).map(\.title) == ["Low", "High"])
    }

    /// Stamping only the moved row would leave it sorting against items that
    /// have no position at all — which is how "I moved one and three jumped"
    /// happens.
    @Test("reordering stamps every item in the group, not just the moved one")
    func everyItemStamped() throws {
        let context = try store()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let items = [todo("A", .medium), todo("B", .medium), todo("C", .medium)]
        for item in items { context.insert(item) }

        vm.reorderTodos(items)
        #expect(items.allSatisfy { $0.todoSortIndex != nil })
        #expect(items.map(\.todoSortIndex) == [0, 1, 2])
    }

    @Test("an unarranged to-do sorts after arranged ones")
    func unarrangedGoesLast() throws {
        let context = try store()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let arranged = todo("Arranged", .low)
        let untouched = todo("Untouched", .high)
        for item in [arranged, untouched] { context.insert(item) }

        vm.reorderTodos([arranged])
        // Even though Untouched is higher priority, it has no position yet.
        #expect(vm.activeTodos(from: [arranged, untouched]).map(\.title)
                == ["Arranged", "Untouched"])
    }
}
