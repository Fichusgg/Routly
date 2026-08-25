//
//  CalendarLinkTests.swift
//  RoutineOrganizerTests
//
//  The calendar feature's two failure modes are both invisible from inside the
//  app, and both land in somebody's real calendar:
//
//   • **A duplicate.** The same item pushed twice, so a person has two lunches
//     at noon and no way to tell which one Routly owns.
//   • **An orphan.** An event Routly created and then lost the thread of, which
//     no later edit or delete can ever reach again.
//
//  Neither shows up in the app's own UI, so neither can be caught by looking.
//  Everything that decides between them — eligibility, the payload, the
//  revision, and the plan — is a pure function over value types precisely so it
//  can be asserted on here instead.
//
//  The end-to-end suite at the bottom drives the real `CalendarSync` against a
//  fake provider, so the store writes are covered too without a permission
//  grant or a device.
//

import Testing
import Foundation
import SwiftData
@testable import Routly

private let cal = Calendar(identifier: .gregorian)

private let day: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 14
    return cal.date(from: c)!
}()

private let nineAM: Date = cal.date(byAdding: .hour, value: 9, to: day)!

private func event(
    title: String = "Lunch with Sam",
    kind: ItemKind = .event,
    date: Date? = day,
    time: Date? = nineAM,
    duration: Int? = 45,
    recurrence: RecurrenceRule? = nil
) -> ScheduleItem {
    ScheduleItem(
        title: title,
        kind: kind,
        scheduledDate: date,
        startTime: time,
        durationMinutes: duration,
        recurrence: recurrence
    )
}

// MARK: - Access

/// The finding that shaped the whole phase, pinned so it can't be quietly
/// re-assumed: iOS 17's write-only grant can add an event and nothing else.
/// Anything that changes `canModify` to include `.writeOnly` is claiming Routly
/// can update and delete under a grant that cannot look an event up.
@Suite("Calendar access")
struct CalendarAccessTests {

    @Test("write-only can create but not modify")
    func writeOnlyIsAddOnly() {
        #expect(CalendarAccess.writeOnly.canCreate)
        #expect(!CalendarAccess.writeOnly.canModify)
    }

    @Test("full access can do both")
    func fullDoesBoth() {
        #expect(CalendarAccess.full.canCreate)
        #expect(CalendarAccess.full.canModify)
    }

    @Test("no grant can do neither, and only the unasked state is worth asking")
    func refusedStates() {
        for access in [CalendarAccess.denied, .restricted, .notDetermined] {
            #expect(!access.canCreate, "\(access) should not create")
            #expect(!access.canModify, "\(access) should not modify")
        }
        #expect(CalendarAccess.notDetermined.isAskable)
        #expect(!CalendarAccess.denied.isAskable)
        #expect(!CalendarAccess.restricted.isAskable)
    }
}

// MARK: - Eligibility

@Suite("Calendar eligibility")
struct CalendarEligibilityTests {

    @Test("a dated event is eligible")
    func datedEventIsEligible() {
        #expect(CalendarEligibilityCheck.evaluate(event()) == .eligible)
    }

    @Test("a dated reminder is eligible")
    func datedReminderIsEligible() {
        #expect(CalendarEligibilityCheck.evaluate(event(kind: .reminder, duration: nil)) == .eligible)
    }

    @Test("a to-do is not an event, whether or not it has a day")
    func todosAreNeverEligible() {
        #expect(CalendarEligibilityCheck.evaluate(event(kind: .todo, time: nil, duration: nil)) == .notAnEvent)
        // The undated case must still answer "to-do", not "give this a day" —
        // adding a day wouldn't help, and sending the user off to do it would
        // be a wasted trip.
        let undated = event(kind: .todo, date: nil, time: nil, duration: nil)
        #expect(CalendarEligibilityCheck.evaluate(undated) == .notAnEvent)
    }

    @Test("an undated event has nothing to place")
    func undatedIsIneligible() {
        #expect(CalendarEligibilityCheck.evaluate(event(date: nil, time: nil)) == .undated)
    }

    @Test("a repeating item stays in Routly in this phase")
    func repeatingIsIneligible() {
        let routine = event(recurrence: .everyDay)
        #expect(CalendarEligibilityCheck.evaluate(routine) == .repeating)
    }

    /// `timesPerWeek` is the case with no RRULE at all — there is no way to say
    /// "three times a week, any days" in iCalendar. If recurrence support ever
    /// lands, this one still has to be refused.
    @Test("times-per-week has no calendar equivalent and is refused")
    func timesPerWeekIsIneligible() {
        var rule = RecurrenceRule.everyDay
        rule.frequency = .timesPerWeek
        rule.targetCount = 3
        #expect(CalendarEligibilityCheck.evaluate(event(recurrence: rule)) == .repeating)
    }

    @Test("every refusal explains itself, and eligibility says nothing")
    func reasonsExist() {
        #expect(CalendarEligibility.eligible.reason == nil)
        for state in [CalendarEligibility.notAnEvent, .undated, .repeating] {
            #expect(state.reason?.isEmpty == false, "\(state) has no reason to show")
        }
    }
}

// MARK: - Payload

@Suite("Calendar payload")
struct CalendarPayloadTests {

    @Test("a timed event carries its own span")
    func timedEventSpan() throws {
        let payload = try #require(CalendarPayloadBuilder.payload(for: event(duration: 45)))
        #expect(payload.start == nineAM)
        #expect(payload.end == cal.date(byAdding: .minute, value: 45, to: nineAM))
        #expect(!payload.isAllDay)
        #expect(payload.title == "Lunch with Sam")
    }

    /// A reminder is a point in time and has no length to carry over. Zero is
    /// legal in EventKit and renders as a hairline nobody can see, so it gets a
    /// short real span instead.
    @Test("a reminder gets a visible span rather than a zero-length one")
    func reminderSpan() throws {
        let payload = try #require(CalendarPayloadBuilder.payload(for: event(kind: .reminder, duration: nil)))
        #expect(payload.end > payload.start)
        let minutes = cal.dateComponents([.minute], from: payload.start, to: payload.end).minute
        #expect(minutes == CalendarPayloadBuilder.reminderSpanMinutes)
    }

    /// The end of a one-day all-day event is the *start of the next day*. Same
    /// day at both ends is a zero-length all-day event, which some calendars
    /// drop entirely.
    @Test("a day with no time becomes an all-day event ending the next morning")
    func allDaySpansToNextDay() throws {
        let payload = try #require(CalendarPayloadBuilder.payload(for: event(time: nil, duration: nil)))
        #expect(payload.isAllDay)
        #expect(payload.start == cal.startOfDay(for: day))
        #expect(payload.end == cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day)))
    }

    /// Nil is the signal the push path reads as "take this back out of the
    /// calendar". If an ineligible item ever produced a payload, an item edited
    /// into a to-do would silently stay in the user's calendar forever.
    @Test("an ineligible item has no payload at all")
    func ineligibleHasNoPayload() {
        #expect(CalendarPayloadBuilder.payload(for: event(kind: .todo, time: nil, duration: nil)) == nil)
        #expect(CalendarPayloadBuilder.payload(for: event(date: nil, time: nil)) == nil)
        #expect(CalendarPayloadBuilder.payload(for: event(recurrence: .everyDay)) == nil)
    }

    @Test("the revision is stable across identical items")
    func revisionIsStable() throws {
        let first = try #require(CalendarPayloadBuilder.payload(for: event()))
        let second = try #require(CalendarPayloadBuilder.payload(for: event()))
        #expect(first.revision == second.revision)
    }

    @Test("the revision moves when anything a calendar shows moves")
    func revisionTracksContent() throws {
        let base = try #require(CalendarPayloadBuilder.payload(for: event()))

        let renamed = try #require(CalendarPayloadBuilder.payload(for: event(title: "Lunch with Alex")))
        #expect(renamed.revision != base.revision)

        let moved = try #require(
            CalendarPayloadBuilder.payload(for: event(time: cal.date(byAdding: .hour, value: 1, to: nineAM)))
        )
        #expect(moved.revision != base.revision)

        let longer = try #require(CalendarPayloadBuilder.payload(for: event(duration: 90)))
        #expect(longer.revision != base.revision)
    }
}

// MARK: - Plan

private func snapshot(
    _ id: UUID = UUID(),
    provider: CalendarProvider? = .apple,
    state: CalendarLinkState = .linked,
    externalID: String? = "remote-1",
    revision: String? = "rev-1"
) -> CalendarLinkSnapshot {
    CalendarLinkSnapshot(
        linkID: id,
        provider: provider,
        state: state,
        ref: externalID.map { CalendarEventRef(externalID: $0) },
        pushedRevision: revision
    )
}

@Suite("Calendar link plan")
struct CalendarLinkPlanTests {

    @Test("a wanted provider with no link is created")
    func createsWhenAbsent() {
        let plan = CalendarLinkPlan.plan(existing: [], desired: [.apple], revision: "rev-1")
        #expect(plan == [.create(provider: .apple)])
    }

    /// The dedup that matters most in practice. Re-saving an item nobody
    /// changed must not touch the calendar at all — not "update it to the same
    /// thing", and certainly not "add it again".
    @Test("an unchanged item produces no provider call")
    func noOpWhenNothingChanged() {
        let plan = CalendarLinkPlan.plan(
            existing: [snapshot(revision: "rev-1")],
            desired: [.apple],
            revision: "rev-1"
        )
        #expect(plan.isEmpty)
    }

    @Test("a changed item updates the event it already has")
    func updatesWhenChanged() {
        let id = UUID()
        let plan = CalendarLinkPlan.plan(
            existing: [snapshot(id, revision: "rev-1")],
            desired: [.apple],
            revision: "rev-2"
        )
        #expect(plan == [.update(linkID: id, provider: .apple, ref: CalendarEventRef(externalID: "remote-1"))])
    }

    @Test("deselecting a provider removes its event")
    func removesWhenDeselected() {
        let id = UUID()
        let plan = CalendarLinkPlan.plan(
            existing: [snapshot(id)],
            desired: [],
            revision: "rev-1"
        )
        #expect(plan == [.remove(linkID: id, provider: .apple, ref: CalendarEventRef(externalID: "remote-1"))])
    }

    /// An item that stops being calendar-eligible is expressed as an empty
    /// `desired` with a nil revision — the same shape `CalendarSync` builds
    /// when the payload comes back nil.
    @Test("an item that stopped being eligible has its event removed")
    func ineligibleRemoves() {
        let id = UUID()
        let plan = CalendarLinkPlan.plan(existing: [snapshot(id)], desired: [], revision: nil)
        #expect(plan == [.remove(linkID: id, provider: .apple, ref: CalendarEventRef(externalID: "remote-1"))])
    }

    @Test("a link with no event behind it is retried, not duplicated")
    func retriesRatherThanDuplicating() {
        let id = UUID()
        let plan = CalendarLinkPlan.plan(
            existing: [snapshot(id, state: .failed, externalID: nil, revision: nil)],
            desired: [.apple],
            revision: "rev-1"
        )
        #expect(plan == [.retry(linkID: id, provider: .apple)])
    }

    /// The subtle half of the duplicate bug. A *failed update* leaves a link
    /// that is `.failed` and still points at a live event. Reading that as
    /// "start again" would put a second copy in the calendar and strand the
    /// first, so state alone must never decide to create.
    @Test("a failed link that still points at an event is updated, not re-created")
    func failedWithRefUpdates() {
        let id = UUID()
        let plan = CalendarLinkPlan.plan(
            existing: [snapshot(id, state: .failed, revision: "rev-1")],
            desired: [.apple],
            revision: "rev-1"
        )
        #expect(plan == [.update(linkID: id, provider: .apple, ref: CalendarEventRef(externalID: "remote-1"))])
    }

    /// Two links for one provider is the state the invariant forbids. The extra
    /// must be taken out of the calendar, not merely dropped locally —
    /// forgetting a row that pointed at a real event is how litter becomes
    /// permanent.
    @Test("a duplicate link has its event removed, not just its row forgotten")
    func duplicatesAreRemovedRemotely() {
        let keep = UUID()
        let extra = UUID()
        let plan = CalendarLinkPlan.plan(
            existing: [
                snapshot(keep, revision: "rev-1"),
                snapshot(extra, externalID: "remote-2", revision: "rev-1"),
            ],
            desired: [.apple],
            revision: "rev-1"
        )
        #expect(plan == [.remove(linkID: extra, provider: .apple, ref: CalendarEventRef(externalID: "remote-2"))])
    }

    /// Position must not decide which duplicate survives: a failed row written
    /// a moment before a successful retry would otherwise shadow it, and the
    /// live event would be the one removed.
    @Test("the link that actually points at an event is the one kept")
    func canonicalPrefersTheLiveLink() {
        let broken = UUID()
        let live = UUID()
        let plan = CalendarLinkPlan.plan(
            existing: [
                snapshot(broken, state: .failed, externalID: nil, revision: nil),
                snapshot(live, state: .linked, externalID: "remote-live", revision: "rev-1"),
            ],
            desired: [.apple],
            revision: "rev-1"
        )
        // The live one is canonical and already current, so nothing is called
        // for it; the empty one is simply dropped.
        #expect(plan == [.discard(linkID: broken)])
    }

    /// A link whose provider doesn't decode can't be acted on — we don't know
    /// whose event it is, so we can neither update nor delete it. Guessing
    /// `.apple` would delete the wrong event.
    @Test("a link with an unreadable provider is discarded, never guessed at")
    func unknownProviderIsDiscarded() {
        let id = UUID()
        let plan = CalendarLinkPlan.plan(
            existing: [snapshot(id, provider: nil)],
            desired: [.apple],
            revision: "rev-1"
        )
        #expect(plan.contains(.discard(linkID: id)))
        #expect(plan.contains(.create(provider: .apple)))
    }

    @Test("removals are planned before creations")
    func removalsSortFirst() {
        let id = UUID()
        let plan = CalendarLinkPlan.plan(
            existing: [snapshot(id, provider: .google)],
            desired: [.apple],
            revision: "rev-1"
        )
        #expect(plan.count == 2)
        #expect(plan.first == .remove(linkID: id, provider: .google, ref: CalendarEventRef(externalID: "remote-1")))
        #expect(plan.last == .create(provider: .apple))
    }
}

// MARK: - The per-item switch

/// The switch under "More" is an opt-*out*, and the difference from a chooser
/// is entirely in where it starts. A chooser that defaults to off is what
/// shipped first, and it meant a connected calendar quietly received nothing.
/// These pin the starting values, since that is the whole behaviour.
@Suite("Calendar opt-out")
struct CalendarOptOutTests {

    @Test("a new draft opens already matching the setting")
    func newDraftFollowsSettings() {
        let draft = CaptureDraft(kind: .event, defaultCalendarTargets: [.apple])
        #expect(draft.calendarTargets == [.apple])
        #expect(draft.effectiveCalendarTargets == [.apple])
        // Untouched, so the collapsed summary has nothing to report.
        #expect(!draft.hasChangedCalendarTargets)
    }

    @Test("turning it off for one item takes it out of the targets")
    func optingOut() {
        let draft = CaptureDraft(kind: .event, defaultCalendarTargets: [.apple])
        draft.calendarTargets.remove(.apple)

        #expect(draft.effectiveCalendarTargets.isEmpty)
        #expect(draft.hasChangedCalendarTargets)
    }

    /// An edit must start from where the item actually *is*. Starting from the
    /// setting would push every old event into a calendar the moment somebody
    /// opened it to fix a typo.
    @Test("an edit opens from the item's own links, not from the setting")
    func editDraftFollowsLinks() {
        let item = event()
        let link = CalendarLink(provider: .apple, state: .linked, externalID: "remote-1")
        link.item = item
        item.calendarLinks.append(link)

        let draft = CaptureDraft(item: item)

        #expect(draft.calendarTargets == [.apple])
        #expect(!draft.hasChangedCalendarTargets)
    }

    @Test("an edit of an unlinked item stays unlinked until asked otherwise")
    func editOfUnlinkedItem() {
        let draft = CaptureDraft(item: event())
        #expect(draft.calendarTargets.isEmpty)
        #expect(draft.effectiveCalendarTargets.isEmpty)
    }

    /// The switches keep their state through a kind change rather than being
    /// cleared, so flipping to a to-do and back doesn't make the person answer
    /// again.
    @Test("an ineligible draft writes nowhere but remembers the answer")
    func ineligibleKeepsItsAnswer() {
        let draft = CaptureDraft(kind: .event, defaultCalendarTargets: [.apple])
        draft.kind = .todo

        #expect(draft.effectiveCalendarTargets.isEmpty)
        #expect(draft.calendarTargets == [.apple])

        draft.kind = .event
        #expect(draft.effectiveCalendarTargets == [.apple])
    }

    @Test("a repeating draft is ineligible and writes nowhere")
    func repeatingDraftWritesNowhere() {
        let draft = CaptureDraft(kind: .event, defaultCalendarTargets: [.apple])
        draft.recurrence = .everyDay
        draft.keepRecurrence = true

        #expect(draft.calendarEligibility == .repeating)
        #expect(draft.effectiveCalendarTargets.isEmpty)
    }
}

// MARK: - A fake provider

/// Stands in for EventKit. An actor, like the real target, so the suite
/// exercises the same suspension points the app does.
private actor FakeCalendarTarget: CalendarTarget {

    nonisolated let provider: CalendarProvider
    private nonisolated let fixedAccess: CalendarAccess

    private(set) var creates = 0
    private(set) var updates = 0
    private(set) var removes = 0
    private(set) var removedIDs: [String] = []
    private(set) var lastPayload: CalendarEventPayload?

    private let createError: CalendarTargetError?
    private let updateError: CalendarTargetError?
    private var nextID = 0

    init(
        provider: CalendarProvider = .apple,
        access: CalendarAccess = .full,
        createError: CalendarTargetError? = nil,
        updateError: CalendarTargetError? = nil
    ) {
        self.provider = provider
        self.fixedAccess = access
        self.createError = createError
        self.updateError = updateError
    }

    nonisolated func access() -> CalendarAccess { fixedAccess }
    func requestAccess() async -> CalendarAccess { fixedAccess }

    func create(_ payload: CalendarEventPayload) async throws -> CalendarEventRef {
        creates += 1
        lastPayload = payload
        if let createError { throw createError }
        nextID += 1
        return CalendarEventRef(
            calendarID: "fake-calendar",
            externalID: "fake-event-\(nextID)",
            externalStableID: "fake-stable-\(nextID)"
        )
    }

    func update(_ payload: CalendarEventPayload, at ref: CalendarEventRef) async throws -> CalendarEventRef {
        updates += 1
        lastPayload = payload
        if let updateError { throw updateError }
        return ref
    }

    func remove(_ ref: CalendarEventRef) async throws {
        removes += 1
        removedIDs.append(ref.externalID)
    }
}

// MARK: - End to end

/// Serialized, and each test restores the registry: `CalendarSync.registry` is
/// shared mutable state, and two tests swapping fakes in parallel would be a
/// race that fails somewhere else.
@MainActor
@Suite("Calendar sync", .serialized)
struct CalendarSyncTests {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self,
            configurations: config
        )
        return ModelContext(container)
    }

    /// Installs `fake` as the only provider for the duration of `body`.
    private func withFake<T>(
        _ fake: FakeCalendarTarget,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let saved = CalendarSync.registry
        CalendarSync.registry = [fake.provider: fake]
        defer { CalendarSync.registry = saved }
        return try await body()
    }

    @Test("a first push creates one event and one link")
    func createsOnce() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let outcome = await withFake(fake) {
            await CalendarSync.apply([.apple], to: item, in: context)
        }

        #expect(outcome.created == 1)
        #expect(!outcome.hasFailures)
        #expect(item.calendarLinks.count == 1)
        let link = try #require(item.calendarLinks.first)
        #expect(link.provider == .apple)
        #expect(link.state == .linked)
        #expect(link.externalID == "fake-event-1")
        #expect(link.externalStableID == "fake-stable-1")
        #expect(link.lastPushedAt != nil)
        let creates = await fake.creates
        #expect(creates == 1)
    }

    /// The duplicate this whole file exists to prevent, at the level a user
    /// would hit it: saving the same unchanged item twice.
    @Test("pushing an unchanged item again does nothing at all")
    func secondPushIsANoOp() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let second = await withFake(fake) {
            _ = await CalendarSync.apply([.apple], to: item, in: context)
            return await CalendarSync.apply([.apple], to: item, in: context)
        }

        #expect(second == CalendarSync.Outcome())
        #expect(item.calendarLinks.count == 1)
        let creates = await fake.creates
        let updates = await fake.updates
        #expect(creates == 1)
        #expect(updates == 0)
    }

    @Test("editing the item updates the existing event rather than adding one")
    func editUpdates() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let outcome = await withFake(fake) {
            _ = await CalendarSync.apply([.apple], to: item, in: context)
            item.title = "Lunch with Alex"
            return await CalendarSync.apply([.apple], to: item, in: context)
        }

        #expect(outcome.updated == 1)
        #expect(item.calendarLinks.count == 1)
        let creates = await fake.creates
        let updates = await fake.updates
        let lastTitle = await fake.lastPayload?.title
        #expect(creates == 1)
        #expect(updates == 1)
        #expect(lastTitle == "Lunch with Alex")
    }

    @Test("unticking a calendar takes the event back out")
    func deselectRemoves() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let outcome = await withFake(fake) {
            _ = await CalendarSync.apply([.apple], to: item, in: context)
            return await CalendarSync.apply([], to: item, in: context)
        }

        #expect(outcome.removed == 1)
        #expect(item.calendarLinks.isEmpty)
        let removedIDs = await fake.removedIDs
        #expect(removedIDs == ["fake-event-1"])
    }

    /// An item edited into something a calendar can't hold must leave the
    /// calendar, even though the user never untidied the chip.
    @Test("an item edited into a to-do leaves the calendar")
    func ineligibleEditRemoves() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let outcome = await withFake(fake) {
            _ = await CalendarSync.apply([.apple], to: item, in: context)
            item.kind = .todo
            item.startTime = nil
            // The chip is still ticked — the item simply can't be held.
            return await CalendarSync.apply([.apple], to: item, in: context)
        }

        #expect(outcome.removed == 1)
        #expect(item.calendarLinks.isEmpty)
    }

    @Test("a failed push leaves a failed link and no duplicate on retry")
    func failureIsRecordedAndRetried() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)

        let failing = FakeCalendarTarget(createError: .noWritableCalendar)
        let outcome = await withFake(failing) {
            await CalendarSync.apply([.apple], to: item, in: context)
        }

        #expect(outcome.hasFailures)
        #expect(outcome.failures[.apple] == .noWritableCalendar)
        #expect(outcome.failureMessage?.isEmpty == false)
        #expect(item.calendarLinks.count == 1)
        #expect(item.calendarLinks.first?.state == .failed)
        #expect(item.calendarLinks.first?.externalID == nil)

        // The retry reuses the row rather than adding a second one.
        let working = FakeCalendarTarget()
        let retry = await withFake(working) {
            await CalendarSync.apply([.apple], to: item, in: context)
        }

        #expect(retry.created == 1)
        #expect(item.calendarLinks.count == 1)
        #expect(item.calendarLinks.first?.state == .linked)
        let workingCreates = await working.creates
        #expect(workingCreates == 1)
    }

    @Test("a provider this build can't reach is ignored, not failed")
    func unknownProviderIsIgnored() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let outcome = await withFake(fake) {
            await CalendarSync.apply([.google], to: item, in: context)
        }

        #expect(outcome == CalendarSync.Outcome())
        #expect(item.calendarLinks.isEmpty)
        let creates = await fake.creates
        #expect(creates == 0)
    }

    /// Deletion cascades the links away, so the refs have to be lifted out
    /// first. This is the shape both delete paths in the app use.
    @Test("removals captured before a delete still reach the calendar")
    func pendingRemovalsSurviveDeletion() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let removed = await withFake(fake) {
            _ = await CalendarSync.apply([.apple], to: item, in: context)

            let removals = CalendarSync.pendingRemovals(for: item)
            #expect(removals.count == 1)

            context.delete(item)
            try? context.save()

            return await CalendarSync.remove(removals)
        }

        #expect(removed.removed == 1)
        let removedIDs = await fake.removedIDs
        #expect(removedIDs == ["fake-event-1"])
    }

    // MARK: - Automatic destinations

    /// Runs `body` with exactly these calendars switched on, then puts the
    /// preference back. `AppSettings.shared` is process-wide state; the suite
    /// is serialized so two tests can't be mid-swap at once.
    private func withDestinations<T>(
        _ destinations: Set<CalendarProvider>,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let saved = AppSettings.shared.calendarDestinations
        AppSettings.shared.calendarDestinations = destinations
        defer { AppSettings.shared.calendarDestinations = saved }
        return try await body()
    }

    /// The behaviour the whole rework is for: switch a calendar on once, and
    /// every new event goes there with nothing else to tick.
    @Test("a new item goes to whatever is switched on, with nothing asked")
    func newItemFollowsTheSetting() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let outcome = await withFake(fake) {
            await withDestinations([.apple]) {
                await CalendarSync.sync(item, isNew: true, in: context)
            }
        }

        #expect(outcome.created == 1)
        #expect(item.calendarLinks.count == 1)
        let creates = await fake.creates
        #expect(creates == 1)
    }

    @Test("a new item goes nowhere when no calendar is switched on")
    func newItemWithNoDestinations() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let outcome = await withFake(fake) {
            await withDestinations([]) {
                await CalendarSync.sync(item, isNew: true, in: context)
            }
        }

        #expect(outcome == CalendarSync.Outcome())
        #expect(item.calendarLinks.isEmpty)
    }

    /// Turning a calendar on must not empty months of existing schedule into
    /// it. Only new events follow the setting; everything already in Routly
    /// stays where it is until it's edited.
    @Test("switching a calendar on does not backfill items already in Routly")
    func existingItemIsNotBackfilled() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let outcome = await withFake(fake) {
            await withDestinations([.apple]) {
                await CalendarSync.sync(item, isNew: false, in: context)
            }
        }

        #expect(outcome == CalendarSync.Outcome())
        #expect(item.calendarLinks.isEmpty)
        let creates = await fake.creates
        #expect(creates == 0)
    }

    /// The mirror of the rule above. Switching a calendar off stops new events
    /// going across; it must not silently delete what is already there, and an
    /// existing event must keep tracking its item's edits.
    @Test("an item already in a calendar keeps syncing after the setting is off")
    func linkedItemKeepsSyncingWhenSettingOff() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        let outcome = await withFake(fake) {
            await withDestinations([.apple]) {
                _ = await CalendarSync.sync(item, isNew: true, in: context)
            }
            // The user switches Apple Calendar off, then edits the event.
            return await withDestinations([]) {
                item.title = "Lunch with Alex"
                return await CalendarSync.sync(item, isNew: false, in: context)
            }
        }

        #expect(outcome.updated == 1)
        #expect(outcome.removed == 0)
        #expect(item.calendarLinks.count == 1)
        let removes = await fake.removes
        #expect(removes == 0)
    }

    @Test("an item's current destinations are the providers it is linked to")
    func currentDestinationsReadsLinks() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        #expect(CalendarSync.currentDestinations(of: item).isEmpty)

        await withFake(fake) {
            await withDestinations([.apple]) {
                _ = await CalendarSync.sync(item, isNew: true, in: context)
            }
        }

        #expect(CalendarSync.currentDestinations(of: item) == [.apple])
    }

    @Test("links are stamped with an owner like every other row")
    func linksCarryOwnership() async throws {
        let context = try makeContext()
        let item = event()
        context.insert(item)
        let fake = FakeCalendarTarget()

        await withFake(fake) {
            _ = await CalendarSync.apply([.apple], to: item, in: context)
        }

        let link = try #require(item.calendarLinks.first)
        #expect(link.ownerID != nil)
        #expect(link.updatedAt != .distantPast)
    }
}
