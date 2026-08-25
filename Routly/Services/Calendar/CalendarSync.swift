//
//  CalendarSync.swift
//  RoutineOrganizer
//
//  The one place a Routly item is pushed out to the calendars the user chose.
//
//  It follows the shape `NotificationService` already set: a stateless enum of
//  static async functions, called from the view that made the change with
//  `Task { await … }`. Side effects are orchestrated by the view rather than by
//  `ScheduleViewModel`, so the view model keeps knowing nothing about EventKit —
//  the same way it knows nothing about `UNUserNotificationCenter`.
//
//  What happens here, in order, and why the order matters:
//
//   1. Build the payload. **A nil payload means the item is no longer something
//      a calendar can hold** — switched to a to-do, given a repeat, stripped of
//      its day. That collapses `desired` to empty, which makes the plan a set
//      of removals. This is how an edit takes an event back *out* of somebody's
//      calendar, and it is why eligibility is checked here rather than at the
//      call site.
//   2. Plan against the links the item already has (`CalendarLinkPlan`).
//   3. Run the provider calls, collecting outcomes — nothing is written to the
//      store yet.
//   4. Write every outcome back in one pass, then save once.
//
//  Steps 3 and 4 are separate because step 3 suspends. While it is suspended
//  the main actor is free, and the user can delete the very item being pushed.
//  Writing back as each call returned would mean touching a model that may have
//  been deleted underneath us — a fault that kills the process rather than an
//  error anything can catch. One write-back pass, guarded once, closes that.
//

import Foundation
import SwiftData

/// A remote event to delete, captured *before* its item goes away.
///
/// Needed because deletion cascades: by the time a delete has happened, the
/// links that knew where the events were have gone with it. So the refs are
/// lifted out while the item is still safe to read, and the removal runs after.
struct CalendarRemoval: Equatable, Sendable {
    var provider: CalendarProvider
    var ref: CalendarEventRef
}

@MainActor
enum CalendarSync {

    /// What a push ended up doing, for the caller to report.
    struct Outcome: Equatable, Sendable {
        var created = 0
        var updated = 0
        var removed = 0
        /// Providers that refused, and why. At most one entry per provider.
        var failures: [CalendarProvider: CalendarTargetError] = [:]

        var hasFailures: Bool { !failures.isEmpty }

        /// The one sentence shown to the user. Named for the provider, because
        /// "couldn't sync" with two providers connected tells them nothing
        /// about which calendar to go and look at.
        var failureMessage: String? {
            guard let (provider, error) = failures.sorted(by: { $0.key.rawValue < $1.key.rawValue }).first
            else { return nil }
            return String(
                format: String(localized: "Couldn't update %@. %@"),
                provider.displayName,
                error.message
            )
        }
    }

    // MARK: - Registry

    /// The providers this build can actually talk to.
    ///
    /// A provider absent from here is absent from the UI entirely — no greyed
    /// row, no "coming soon". That follows the rule the settings menu already
    /// states: a control that opens nothing is worse than no control.
    ///
    /// Google is present only when a client ID is configured, which is the same
    /// degrade Supabase already uses for accounts: with nothing set up the
    /// feature is absent rather than broken. Apple needs no configuration and
    /// is always here.
    ///
    /// `var` so the test suite can swap in fakes. Nothing in the app writes it.
    static var registry: [CalendarProvider: any CalendarTarget] = {
        var targets: [CalendarProvider: any CalendarTarget] = [.apple: EventKitTarget()]
        if GoogleCalendarConfig.isConfigured {
            targets[.google] = GoogleCalendarTarget()
        }
        return targets
    }()

    /// Offerable providers, in a stable order.
    static var availableProviders: [CalendarProvider] {
        CalendarProvider.allCases.filter { registry[$0] != nil }
    }

    static func target(for provider: CalendarProvider) -> (any CalendarTarget)? {
        registry[provider]
    }

    // MARK: - Destinations

    /// Where a **new** item goes: whatever the user has switched on in
    /// Settings, and nothing else to decide.
    static var newItemDestinations: Set<CalendarProvider> {
        AppSettings.shared.calendarDestinations.filter { registry[$0] != nil }
    }

    /// Where an **existing** item goes: exactly where it already is.
    ///
    /// This is the rule that keeps automatic writing predictable in both
    /// directions. Turning a calendar on does not reach back and push every
    /// item already in Routly into it — that could empty months of schedule
    /// into somebody's calendar the moment they flipped a switch. Turning one
    /// off does not reach back and delete what is already there either; an item
    /// that was written stays written, and its edits and deletes keep following.
    ///
    /// So the setting governs new events, and existing links govern themselves.
    static func currentDestinations(of item: ScheduleItem) -> Set<CalendarProvider> {
        Set(item.calendarLinks.compactMap(\.provider))
    }

    /// The one call every view makes after saving.
    ///
    /// `isNew` is the only thing a caller has to know, and it is the difference
    /// between "send this to the calendars that are switched on" and "keep the
    /// calendars this is already in up to date".
    @discardableResult
    static func sync(
        _ item: ScheduleItem,
        isNew: Bool,
        in context: ModelContext,
        now: Date = Date()
    ) async -> Outcome {
        let destinations = isNew ? newItemDestinations : currentDestinations(of: item)
        guard !destinations.isEmpty || !item.calendarLinks.isEmpty else { return Outcome() }
        return await apply(destinations, to: item, in: context, now: now)
    }

    // MARK: - Push

    /// Make the calendars match `desired` for this item.
    @discardableResult
    static func apply(
        _ desired: Set<CalendarProvider>,
        to item: ScheduleItem,
        in context: ModelContext,
        now: Date = Date()
    ) async -> Outcome {

        let payload = CalendarPayloadBuilder.payload(for: item)
        // An ineligible item wants nothing, whatever the user ticked — and a
        // provider this build can't reach is not a target, however it got into
        // the set.
        let effective: Set<CalendarProvider> = payload == nil
            ? []
            : desired.filter { registry[$0] != nil }

        let actions = CalendarLinkPlan.plan(
            existing: snapshots(of: item),
            desired: effective,
            revision: payload?.revision
        )
        guard !actions.isEmpty else { return Outcome() }

        var outcome = Outcome()
        var writebacks: [Writeback] = []

        for action in actions {
            switch action {
            case .discard(let linkID):
                writebacks.append(.delete(linkID: linkID))

            case .remove(let linkID, let provider, let ref):
                guard let target = registry[provider] else {
                    // No way to reach the provider, so no way to take the event
                    // out. The row stays and stays visible as a failure rather
                    // than disappearing and taking the only record of a real
                    // remote event with it.
                    outcome.failures[provider] = .accessDenied
                    continue
                }
                do {
                    try await target.remove(ref)
                    writebacks.append(.delete(linkID: linkID))
                    outcome.removed += 1
                } catch {
                    let failure = normalize(error)
                    outcome.failures[provider] = failure
                    writebacks.append(.fail(linkID: linkID, provider: provider, error: failure))
                }

            case .create(let provider), .retry(_, let provider):
                guard let payload, let target = registry[provider] else { continue }
                let linkID = action.linkID
                do {
                    let ref = try await target.create(payload)
                    writebacks.append(.adopt(linkID: linkID, provider: provider, ref: ref, revision: payload.revision))
                    outcome.created += 1
                } catch {
                    let failure = normalize(error)
                    outcome.failures[provider] = failure
                    writebacks.append(.fail(linkID: linkID, provider: provider, error: failure))
                }

            case .update(let linkID, let provider, let ref):
                guard let payload, let target = registry[provider] else { continue }
                do {
                    let fresh = try await target.update(payload, at: ref)
                    writebacks.append(.adopt(linkID: linkID, provider: provider, ref: fresh, revision: payload.revision))
                    outcome.updated += 1
                } catch {
                    let failure = normalize(error)
                    outcome.failures[provider] = failure
                    writebacks.append(.fail(linkID: linkID, provider: provider, error: failure))
                }
            }
        }

        // The item may have been deleted while we were suspended above. Its
        // links went with it, so there is nothing to write back — but anything
        // we just created is now an orphan in the user's calendar with no row
        // left able to find it. Take it straight back out.
        guard !item.isDeleted, item.modelContext != nil else {
            await compensate(writebacks)
            return outcome
        }

        write(writebacks, to: item, in: context, now: now)
        return outcome
    }

    // MARK: - Removal

    /// The removals an item's links imply, captured while the item is still
    /// readable. Call this **before** deleting, and hand the result to
    /// `remove(_:)` afterwards.
    static func pendingRemovals(for item: ScheduleItem) -> [CalendarRemoval] {
        item.calendarLinks.compactMap { link in
            guard let provider = link.provider, let ref = link.eventRef else { return nil }
            return CalendarRemoval(provider: provider, ref: ref)
        }
    }

    /// Take events out of their calendars. Used by the delete path, where the
    /// links are already gone and there is nothing to write back.
    @discardableResult
    static func remove(_ removals: [CalendarRemoval]) async -> Outcome {
        var outcome = Outcome()
        for removal in removals {
            guard let target = registry[removal.provider] else { continue }
            do {
                try await target.remove(removal.ref)
                outcome.removed += 1
            } catch {
                outcome.failures[removal.provider] = normalize(error)
            }
        }
        return outcome
    }

    // MARK: - Store

    static func snapshots(of item: ScheduleItem) -> [CalendarLinkSnapshot] {
        item.calendarLinks.map { link in
            CalendarLinkSnapshot(
                linkID: link.id,
                provider: link.provider,
                state: link.state,
                ref: link.eventRef,
                pushedRevision: link.pushedRevision
            )
        }
    }

    /// What one provider call decided should happen to the store.
    private enum Writeback {
        case adopt(linkID: UUID?, provider: CalendarProvider, ref: CalendarEventRef, revision: String)
        case fail(linkID: UUID?, provider: CalendarProvider, error: CalendarTargetError)
        case delete(linkID: UUID)
    }

    private static func write(
        _ writebacks: [Writeback],
        to item: ScheduleItem,
        in context: ModelContext,
        now: Date
    ) {
        guard !writebacks.isEmpty else { return }

        // Built by hand rather than with `Dictionary(uniqueKeysWithValues:)`,
        // which *traps* on a repeated key. Two rows sharing an id should be
        // impossible, and a trap is an un-catchable process kill — not a price
        // worth paying to find that out.
        var byID: [UUID: CalendarLink] = [:]
        for link in item.calendarLinks where byID[link.id] == nil {
            byID[link.id] = link
        }

        for writeback in writebacks {
            switch writeback {
            case .delete(let linkID):
                guard let link = byID.removeValue(forKey: linkID) else { continue }
                item.calendarLinks.removeAll { $0.id == linkID }
                context.delete(link)

            case .adopt(let linkID, let provider, let ref, let revision):
                let link = existing(linkID, in: byID) ?? insert(provider: provider, on: item, in: context, into: &byID)
                link.provider = provider
                link.adopt(ref, revision: revision, now: now)

            case .fail(let linkID, let provider, _):
                let link = existing(linkID, in: byID) ?? insert(provider: provider, on: item, in: context, into: &byID)
                link.provider = provider
                link.state = .failed
            }
        }

        // Through the same funnel as every other write in the app, so links get
        // their owner and merge clock without this file knowing how that works.
        StoreWrite.save(context, owner: CurrentOwner.id)
        WidgetRefresh.reload()
    }

    private static func existing(_ linkID: UUID?, in byID: [UUID: CalendarLink]) -> CalendarLink? {
        guard let linkID else { return nil }
        return byID[linkID]
    }

    private static func insert(
        provider: CalendarProvider,
        on item: ScheduleItem,
        in context: ModelContext,
        into byID: inout [UUID: CalendarLink]
    ) -> CalendarLink {
        // Attached in the same order `CompletionWriter.complete` attaches a
        // `Completion`: the to-one side is set while the object is still
        // outside the context, then it's appended, then inserted. Doing it the
        // other way round — insert first, then assign — lets SwiftData's own
        // inverse maintenance append it as well, and the item ends up holding
        // the same link twice.
        let link = CalendarLink(provider: provider)
        link.item = item
        item.calendarLinks.append(link)
        context.insert(link)
        byID[link.id] = link
        return link
    }

    /// Undo creations whose item disappeared mid-push. Best effort by nature —
    /// if this fails too, the event stays, and there is nothing left that knows
    /// about it. Worth attempting precisely because nothing else can.
    private static func compensate(_ writebacks: [Writeback]) async {
        for writeback in writebacks {
            guard case .adopt(_, let provider, let ref, _) = writeback,
                  let target = registry[provider] else { continue }
            try? await target.remove(ref)
        }
    }

    private static func normalize(_ error: Error) -> CalendarTargetError {
        (error as? CalendarTargetError) ?? .providerFailed(error.localizedDescription)
    }
}

// MARK: - Action helpers

private extension CalendarLinkAction {
    /// The link this action already has a row for, if any. `.create` is the
    /// only case without one.
    var linkID: UUID? {
        switch self {
        case .create: return nil
        case .retry(let id, _), .update(let id, _, _), .remove(let id, _, _): return id
        case .discard(let id): return id
        }
    }
}
