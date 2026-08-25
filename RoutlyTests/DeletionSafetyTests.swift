//
//  DeletionSafetyTests.swift
//  RoutineOrganizerTests
//
//  Deleting an item used to take the whole app down. These run the real delete
//  paths against a live in-memory store, because the failure was never in the
//  pure grouping logic — it was in what `save()` touched on the way out.
//

import Testing
import Foundation
import SwiftData
@testable import Routly

private let cal = Calendar(identifier: .gregorian)

private let monday: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 20; c.hour = 8
    return cal.date(from: c)!
}()

@MainActor
private func liveViewModel() throws -> (ScheduleViewModel, ModelContext) {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self,
        configurations: config
    )
    let context = ModelContext(container)
    let vm = ScheduleViewModel()
    vm.configure(context: context)
    return (vm, context)
}

@MainActor
@Suite("Deleting an item")
struct DeletionSafetyTests {

    /// The original crash: `save()` stamps `updatedAt` on everything the context
    /// reports as changed, and a cascade delete puts the doomed rows in exactly
    /// that bucket. Writing to them is a hard SwiftData fault, which exits the app.
    @Test("deleting an item with completions doesn't fault on save")
    func deleteWithCompletions() throws {
        let (vm, context) = try liveViewModel()

        let item = ScheduleItem(title: "Gym", recurrence: .everyDay, createdAt: monday)
        context.insert(item)
        vm.toggleDone(item, on: monday)
        vm.toggleDone(item, on: cal.date(byAdding: .day, value: 1, to: monday)!)
        #expect(item.completions.count == 2)

        vm.delete(item)

        let remaining = try context.fetch(FetchDescriptor<ScheduleItem>())
        #expect(remaining.isEmpty)
        let orphans = try context.fetch(FetchDescriptor<Completion>())
        #expect(orphans.isEmpty)
    }

    @Test("deleting one occurrence of a routine keeps the item and drops that day")
    func deleteSingleOccurrence() throws {
        let (vm, context) = try liveViewModel()

        let item = ScheduleItem(title: "Run", recurrence: .everyDay, createdAt: monday)
        context.insert(item)
        vm.toggleDone(item, on: monday)

        let outcome = vm.delete(item, scope: .occurrence, on: monday)

        #expect(outcome == .trimmed)
        #expect(item.skips(monday, calendar: cal))
        // The completion is gone — a day that no longer occurs must not keep
        // feeding the consistency record, which is what this line has always
        // been guarding.
        #expect(!item.completions.contains { $0.status == .done })
        // What replaces it is the audit record: lifting a day out is a
        // statement that the occurrence isn't happening, and that's the signal
        // the pattern layer reads. Invisible to every screen.
        #expect(item.completions.map(\.status) == [.skipped])
        #expect(try context.fetch(FetchDescriptor<ScheduleItem>()).count == 1)
        // Still exactly one record in the store — no orphan, no duplicate.
        #expect(try context.fetch(FetchDescriptor<Completion>()).count == 1)
    }

    @Test("deleting this-and-future trims the series and clears later history")
    func deleteFutureOccurrences() throws {
        let (vm, context) = try liveViewModel()

        let item = ScheduleItem(title: "Standup", recurrence: .everyDay, createdAt: monday)
        context.insert(item)
        let wednesday = cal.date(byAdding: .day, value: 2, to: monday)!
        vm.toggleDone(item, on: monday)
        vm.toggleDone(item, on: wednesday)

        let outcome = vm.delete(item, scope: .futureOccurrences, on: wednesday)

        #expect(outcome == .trimmed)
        #expect(item.recurrenceEndDate != nil)
        // Monday happened and stays; Wednesday no longer exists.
        #expect(item.completions.count == 1)
        #expect(try context.fetch(FetchDescriptor<Completion>()).count == 1)
    }

    /// A one-off to-do is the case the hold-to-delete gesture hits most, and it
    /// goes through the same `save()` as everything else.
    @Test("deleting a plain to-do leaves the store clean")
    func deletePlainTodo() throws {
        let (vm, context) = try liveViewModel()

        let keep = ScheduleItem(title: "Keep me", kind: .todo)
        let drop = ScheduleItem(title: "Drop me", kind: .todo)
        context.insert(keep)
        context.insert(drop)
        vm.save()

        vm.delete(drop, scope: .series, on: monday)

        let remaining = try context.fetch(FetchDescriptor<ScheduleItem>())
        #expect(remaining.map(\.title) == ["Keep me"])
    }

    /// The guard the views depend on. A `@Query` array can still hold a deleted
    /// row for one render pass, and building a row from it reads a stored
    /// property on a dead model — which is a fault, not an error. Every list the
    /// UI consumes filters through `aliveOnly()` for exactly this window.
    @Test("a deleted item is filtered out of every list the UI reads")
    func deletedItemsNeverReachTheUI() throws {
        let (vm, context) = try liveViewModel()

        let keep = ScheduleItem(title: "Keep me", kind: .todo, createdAt: monday)
        let drop = ScheduleItem(title: "Drop me", kind: .todo, createdAt: monday)
        let event = ScheduleItem(
            title: "Doomed meeting",
            kind: .event,
            scheduledDate: cal.startOfDay(for: monday),
            startTime: monday,
            createdAt: monday
        )
        for item in [keep, drop, event] { context.insert(item) }
        vm.save()

        vm.delete(drop)
        vm.delete(event)

        // The stale array is exactly what SwiftUI would still be holding.
        let stale = [keep, drop, event]

        #expect(vm.activeTodos(from: stale, now: monday).map(\.title) == ["Keep me"])
        #expect(vm.todayTimed(from: stale, now: monday).isEmpty)
        #expect(vm.items(on: monday, from: stale).isEmpty)
        #expect(vm.sections(from: stale, now: monday).allSatisfy {
            !$0.items.contains { $0.title == "Drop me" || $0.title == "Doomed meeting" }
        })
        #expect(vm.categoriesPresent(on: monday, from: stale).isEmpty)
    }

    /// The filter keys on identity, not on any SwiftData liveness flag, so a
    /// model that was never inserted anywhere still renders. This is the case
    /// every preview and every pure grouping test is built from, and an earlier
    /// attempt at this guard silently emptied all of them.
    @Test("an item that was never in a context still renders")
    func detachedItemsStillRender() {
        let vm = ScheduleViewModel()
        let item = ScheduleItem(title: "Never saved", kind: .todo, createdAt: monday)
        #expect(vm.activeTodos(from: [item], now: monday).count == 1)
    }

    /// Deleting through one view model must not blank the row in another — the
    /// calendar and Today each hold their own, over the same store.
    @Test("the filter only drops rows this view model deleted")
    func filterIsScopedToRealDeletes() throws {
        let (vm, context) = try liveViewModel()
        let a = ScheduleItem(title: "A", kind: .todo, createdAt: monday)
        let b = ScheduleItem(title: "B", kind: .todo, createdAt: monday)
        context.insert(a)
        context.insert(b)
        vm.save()

        vm.delete(a)

        #expect(vm.activeTodos(from: [a, b], now: monday).map(\.title) == ["B"])
    }

    /// Ownership stamping is the hook every write funnels through, so it has to
    /// stay correct for the rows that *survive* a delete.
    @Test("surviving rows still get stamped after a sibling is deleted")
    func stampingSurvivesDelete() throws {
        let (vm, context) = try liveViewModel()

        let keep = ScheduleItem(title: "Keep me", kind: .todo)
        let drop = ScheduleItem(title: "Drop me", kind: .todo)
        context.insert(keep)
        context.insert(drop)
        vm.save()

        keep.title = "Renamed"
        vm.delete(drop)

        #expect(keep.ownerID != nil)
        #expect(keep.updatedAt > .distantPast)
    }
}
