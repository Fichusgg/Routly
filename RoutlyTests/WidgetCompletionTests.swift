//
//  WidgetCompletionTests.swift
//  RoutineOrganizerTests
//
//  Completing from the widget writes the same history as completing in the app.
//
//  This is the test that protects the consistency layer. The widget runs in
//  another process and calls `CompletionWriter` directly rather than going
//  through `ScheduleViewModel`, so the invariants that used to be guarded by
//  "there is only one caller" now need stating outright: one record per
//  occurrence, `.done`-only removal, and `isCompleted` for one-offs alone.
//
//  History can't be backfilled if it was never written correctly, which is why
//  these are worth more than the rendering.
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

@Suite("Completing from a widget")
@MainActor
struct WidgetCompletionTests {

    private let writer = CompletionWriter(calendar: cal)
    private let owner = "local:test-owner"

    private func oneOff(in context: ModelContext) -> ScheduleItem {
        let item = ScheduleItem(title: "call the dentist", kind: .todo)
        context.insert(item)
        return item
    }

    private func routine(in context: ModelContext) -> ScheduleItem {
        let item = ScheduleItem(
            title: "stretch",
            kind: .todo,
            scheduledDate: cal.startOfDay(for: Date()),
            recurrence: RecurrenceRule(frequency: .daily)
        )
        context.insert(item)
        return item
    }

    // MARK: - What gets written

    @Test("completing writes a done record for the day, with a timestamp")
    func writesRecord() throws {
        let context = try store()
        let item = oneOff(in: context)
        let now = Date()

        writer.complete(item, on: now, in: context, owner: owner)

        #expect(item.completions.count == 1)
        let record = try #require(item.completions.first)
        #expect(record.status == .done)
        #expect(cal.isDate(record.occurrenceDate, inSameDayAs: now))
        #expect(record.completedAt != nil)
        // Start-of-day, so every reader agrees which day it belongs to.
        #expect(record.occurrenceDate == cal.startOfDay(for: now))
    }

    @Test("a one-off is flagged complete; a routine is not")
    func flagsOnlyOneOffs() throws {
        let context = try store()
        let single = oneOff(in: context)
        let repeating = routine(in: context)

        writer.complete(single, on: Date(), in: context, owner: owner)
        writer.complete(repeating, on: Date(), in: context, owner: owner)

        #expect(single.isCompleted)
        // A routine that set this flag would read as finished forever, on every
        // future occurrence.
        #expect(repeating.isCompleted == false)
        #expect(writer.isDone(repeating, on: Date()))
    }

    @Test("completing twice writes one record, not two")
    func idempotent() throws {
        let context = try store()
        let item = oneOff(in: context)

        // The real case: a widget tapped again before its timeline reloaded.
        writer.complete(item, on: Date(), in: context, owner: owner)
        writer.complete(item, on: Date(), in: context, owner: owner)

        #expect(item.completions.count == 1)
    }

    @Test("the widget's write carries the mirrored owner")
    func stampsOwner() throws {
        let context = try store()
        let item = oneOff(in: context)

        writer.complete(item, on: Date(), in: context, owner: owner)

        #expect(item.completions.first?.ownerID == owner)
    }

    @Test("a missing owner leaves the field nil rather than inventing one")
    func nilOwnerStaysNil() throws {
        let context = try store()
        let item = oneOff(in: context)

        // What happens if the extension runs before the app ever published a
        // mirror. Blank is correctable by the launch backfill; a fabricated id
        // would be indistinguishable from another device's and would not be.
        writer.complete(item, on: Date(), in: context, owner: nil)

        #expect(item.completions.first?.ownerID == nil)
    }

    // MARK: - Taking it back

    @Test("un-ticking removes the done record and clears the flag")
    func uncomplete() throws {
        let context = try store()
        let item = oneOff(in: context)

        writer.complete(item, on: Date(), in: context, owner: owner)
        writer.uncomplete(item, on: Date(), in: context, owner: owner)

        #expect(item.completions.isEmpty)
        #expect(item.isCompleted == false)
    }

    @Test("un-ticking preserves a skip or a reschedule from the same day")
    func preservesOtherStatuses() throws {
        let context = try store()
        let item = routine(in: context)
        let today = cal.startOfDay(for: Date())

        // The pattern layer's raw material. Taking back a completion says
        // nothing about these, and erasing them would be silent data loss.
        let skipped = Completion(occurrenceDate: today, status: .skipped, item: item)
        let moved = Completion(occurrenceDate: today, status: .rescheduled, item: item)
        item.completions.append(contentsOf: [skipped, moved])
        context.insert(skipped)
        context.insert(moved)

        writer.complete(item, on: today, in: context, owner: owner)
        writer.uncomplete(item, on: today, in: context, owner: owner)

        let statuses = Set(item.completions.map(\.status))
        #expect(statuses == [.skipped, .rescheduled])
    }

    @Test("completing one day leaves another day's record alone")
    func perOccurrence() throws {
        let context = try store()
        let item = routine(in: context)
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        writer.complete(item, on: yesterday, in: context, owner: owner)
        writer.complete(item, on: today, in: context, owner: owner)
        writer.uncomplete(item, on: today, in: context, owner: owner)

        #expect(writer.isDone(item, on: yesterday))
        #expect(writer.isDone(item, on: today) == false)
    }

    // MARK: - The app agrees

    @Test("the app's toggle and the widget's complete write the same thing")
    func appAndWidgetAgree() throws {
        let context = try store()
        let viaApp = oneOff(in: context)
        let viaWidget = oneOff(in: context)

        let vm = ScheduleViewModel()
        vm.configure(context: context)
        vm.toggleDone(viaApp, on: Date())
        writer.complete(viaWidget, on: Date(), in: context, owner: CurrentOwner.id)

        #expect(vm.isDone(viaApp, on: Date()) == vm.isDone(viaWidget, on: Date()))
        #expect(viaApp.completions.count == viaWidget.completions.count)
        #expect(viaApp.completions.first?.status == viaWidget.completions.first?.status)
        #expect(viaApp.isCompleted == viaWidget.isCompleted)
    }
}
