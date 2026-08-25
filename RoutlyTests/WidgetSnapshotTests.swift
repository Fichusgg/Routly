//
//  WidgetSnapshotTests.swift
//  RoutineOrganizerTests
//
//  The widget's data layer, which is the half of a widget that can be tested
//  without a home screen.
//
//  Two of these matter more than the rest. The widget must list *the same*
//  to-dos in *the same* order as the Today screen — a home-screen widget that
//  quietly disagrees with the app teaches the user not to trust it — and the
//  corner count must report the whole list, not the part that fits.
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

@discardableResult
private func todo(
    _ title: String,
    in context: ModelContext,
    sortIndex: Int? = nil,
    list: TodoList? = nil,
    completed: Bool = false,
    startTime: Date? = nil
) -> ScheduleItem {
    let item = ScheduleItem(title: title, kind: .todo, startTime: startTime, isCompleted: completed)
    item.todoSortIndex = sortIndex
    item.list = list
    context.insert(item)
    return item
}

@Suite("Widget snapshots")
@MainActor
struct WidgetSnapshotTests {

    private let builder = WidgetSnapshotBuilder()

    // MARK: - Agreement with the app

    @Test("the widget lists exactly what Today lists, in the same order")
    func matchesTheApp() throws {
        let context = try store()
        todo("third", in: context, sortIndex: 2)
        todo("first", in: context, sortIndex: 0)
        todo("second", in: context, sortIndex: 1)
        let items = try context.fetch(FetchDescriptor<ScheduleItem>())

        // Built the way the screen builds it, rather than by asserting a
        // hardcoded order: if the app's rule changes, this test follows it, and
        // a divergence between the two is what fails.
        let vm = ScheduleViewModel()
        vm.configure(context: context)
        let onScreen = vm.activeTodos(from: items).filter { $0.list == nil }.map(\.title)

        let snapshot = builder.todos(from: items, groupName: "To-dos", limit: 10)
        #expect(snapshot.rows.map(\.title) == onScreen)
        #expect(snapshot.rows.map(\.title) == ["first", "second", "third"])
    }

    @Test("to-dos filed under a list are not in the widget")
    func excludesFiledTodos() throws {
        let context = try store()
        let work = TodoList(name: "Work")
        context.insert(work)
        todo("unfiled", in: context)
        todo("filed", in: context, list: work)

        let snapshot = builder.todos(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            groupName: "To-dos",
            limit: 10
        )
        #expect(snapshot.rows.map(\.title) == ["unfiled"])
    }

    @Test("completed and slotted to-dos drop out, like the app's checklist")
    func excludesDoneAndSlotted() throws {
        let context = try store()
        todo("open", in: context)
        todo("done", in: context, completed: true)
        todo("slotted", in: context, startTime: Date())

        let snapshot = builder.todos(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            groupName: "To-dos",
            limit: 10
        )
        #expect(snapshot.rows.map(\.title) == ["open"])
    }

    // MARK: - Choosing which list the widget shows

    @Test("a widget configured for a list shows that list only")
    func showsTheChosenList() throws {
        let context = try store()
        let work = TodoList(name: "Work")
        let shopping = TodoList(name: "Shopping")
        context.insert(work)
        context.insert(shopping)
        todo("unfiled thing", in: context)
        todo("write the deck", in: context, list: work)
        todo("buy milk", in: context, list: shopping)
        let items = try context.fetch(FetchDescriptor<ScheduleItem>())

        let onWork = builder.todos(
            from: items, listID: work.id, knownListIDs: [work.id, shopping.id],
            groupName: "Work", limit: 10
        )
        #expect(onWork.rows.map(\.title) == ["write the deck"])
        #expect(onWork.remaining == 1)
        #expect(onWork.isDefaultGroup == false)

        // Two widgets, two lists, no interference.
        let onShopping = builder.todos(
            from: items, listID: shopping.id, knownListIDs: [work.id, shopping.id],
            groupName: "Shopping", limit: 10
        )
        #expect(onShopping.rows.map(\.title) == ["buy milk"])
    }

    @Test("no chosen list means the built-in group, as before")
    func defaultsToTheGroup() throws {
        let context = try store()
        let work = TodoList(name: "Work")
        context.insert(work)
        todo("unfiled thing", in: context)
        todo("write the deck", in: context, list: work)

        let snapshot = builder.todos(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            listID: nil, knownListIDs: [work.id],
            groupName: "To-dos", limit: 10
        )
        #expect(snapshot.rows.map(\.title) == ["unfiled thing"])
        #expect(snapshot.isDefaultGroup)
        #expect(snapshot.listExists)
    }

    @Test("the chosen list's order is the app's order, not insertion order")
    func chosenListKeepsTheAppsOrder() throws {
        let context = try store()
        let work = TodoList(name: "Work")
        context.insert(work)
        todo("third", in: context, sortIndex: 2, list: work)
        todo("first", in: context, sortIndex: 0, list: work)
        todo("second", in: context, sortIndex: 1, list: work)

        let snapshot = builder.todos(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            listID: work.id, knownListIDs: [work.id],
            groupName: "Work", limit: 10
        )
        #expect(snapshot.rows.map(\.title) == ["first", "second", "third"])
    }

    @Test("an empty list is empty, not deleted")
    func emptyListIsNotMissing() throws {
        let context = try store()
        let work = TodoList(name: "Work")
        context.insert(work)
        todo("unfiled thing", in: context)

        let snapshot = builder.todos(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            listID: work.id, knownListIDs: [work.id],
            groupName: "Work", limit: 10
        )
        // The distinction the empty-state wording rests on: this list exists and
        // has nothing in it, which is not the same as having been deleted.
        #expect(snapshot.isEmpty)
        #expect(snapshot.listExists)
    }

    @Test("a deleted list is reported rather than silently becoming the group")
    func deletedListIsReported() throws {
        let context = try store()
        todo("unfiled thing", in: context)

        // The list the widget was configured for is no longer in the store.
        let snapshot = builder.todos(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            listID: UUID(), knownListIDs: [],
            groupName: "Work", limit: 10
        )
        #expect(snapshot.listExists == false)
        #expect(snapshot.isEmpty)
        // Crucially it does NOT fall back to showing the unfiled to-do, which
        // would change what the widget means without saying so.
        #expect(snapshot.rows.isEmpty)
    }

    @Test("the configuration resolves the sentinel and nil to the group alike")
    func configurationResolvesDefault() {
        // Both a widget that was never configured and one explicitly set to the
        // built-in group must mean the same thing.
        #expect(SelectTodoListIntent(list: nil).selectedListID == nil)

        let group = TodoListEntity(id: TodoListEntity.defaultGroupID, name: "To-dos")
        #expect(SelectTodoListIntent(list: group).selectedListID == nil)

        let work = TodoListEntity(id: UUID(), name: "Work")
        #expect(SelectTodoListIntent(list: work).selectedListID == work.id)
    }

    // MARK: - The count tells the truth

    @Test("the corner count is the whole list, not the rows that fit")
    func countIsNotCapped() throws {
        let context = try store()
        for index in 0..<9 { todo("task \(index)", in: context, sortIndex: index) }

        let snapshot = builder.todos(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            groupName: "To-dos",
            limit: 2
        )
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.remaining == 9)
        #expect(snapshot.overflow == 7)
    }

    @Test("an empty list reports empty rather than a zero-row list")
    func emptyState() throws {
        let context = try store()
        let snapshot = builder.todos(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            groupName: "To-dos",
            limit: 5
        )
        #expect(snapshot.isEmpty)
        #expect(snapshot.overflow == 0)
    }

    @Test("a limit of zero yields no rows and still counts what's open")
    func zeroLimit() throws {
        let context = try store()
        todo("something", in: context)
        let snapshot = builder.todos(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            groupName: "To-dos",
            limit: 0
        )
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.remaining == 1)
    }

    // MARK: - Agenda

    @Test("the agenda is in time order and carries each item's done state")
    func agendaOrder() throws {
        let context = try store()
        let today = cal.startOfDay(for: Date())
        func at(_ hour: Int) -> Date { cal.date(byAdding: .hour, value: hour, to: today)! }

        let late = ScheduleItem(title: "late", kind: .event, scheduledDate: today, startTime: at(16))
        let early = ScheduleItem(title: "early", kind: .event, scheduledDate: today, startTime: at(9))
        context.insert(late)
        context.insert(early)

        let snapshot = builder.agenda(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            limit: 10
        )
        #expect(snapshot.rows.map(\.title) == ["early", "late"])
        #expect(snapshot.rows.allSatisfy { !$0.isDone })
    }

    // MARK: - Refresh timing

    @Test("refresh dates are the day's own boundaries, never a fixed tick")
    func refreshDatesFollowEvents() throws {
        let context = try store()
        let now = Date()
        let today = cal.startOfDay(for: now)
        let past = cal.date(byAdding: .hour, value: -2, to: now)!
        let soon = cal.date(byAdding: .hour, value: 1, to: now)!

        context.insert(ScheduleItem(title: "over", kind: .event, scheduledDate: today, startTime: past))
        context.insert(ScheduleItem(title: "ahead", kind: .event, scheduledDate: today,
                                    startTime: soon, durationMinutes: 30))

        let dates = builder.refreshDates(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            now: now
        )

        // What already happened can't make the widget wrong again.
        #expect(!dates.contains(past))
        #expect(dates.contains(soon))
        // The end of a timed block matters too — that's when it stops being "now".
        #expect(dates.contains(cal.date(byAdding: .minute, value: 30, to: soon)!))
        // And the rollover always, so an empty evening becomes tomorrow.
        #expect(dates.contains(cal.date(byAdding: .day, value: 1, to: today)!))
        #expect(dates == dates.sorted())
    }

    @Test("refresh dates stay within the cap, so the budget can't be blown")
    func refreshDatesCapped() throws {
        let context = try store()
        let now = Date()
        let today = cal.startOfDay(for: now)
        for hour in 1...20 {
            let start = cal.date(byAdding: .hour, value: hour, to: now)!
            context.insert(ScheduleItem(title: "e\(hour)", kind: .event,
                                        scheduledDate: today, startTime: start, durationMinutes: 15))
        }

        let dates = builder.refreshDates(
            from: try context.fetch(FetchDescriptor<ScheduleItem>()),
            now: now,
            limit: 12
        )
        #expect(dates.count == 12)
    }
}
