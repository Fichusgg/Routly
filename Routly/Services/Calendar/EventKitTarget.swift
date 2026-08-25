//
//  EventKitTarget.swift
//  RoutineOrganizer
//
//  Apple Calendar, through EventKit. Entirely on-device: no account, no
//  network, no server, nothing to configure.
//
//  ── Why this asks for full access ───────────────────────────────────────
//
//  iOS 17 split the calendar grant in two, and the gentler half does less than
//  its name suggests. **Write-only is add-only.** Changing or deleting an event
//  means finding it first, and finding it is reading —
//  `EKEventStore.event(withIdentifier:)` answers nothing without full access.
//  So under a write-only grant Routly could put an event into somebody's
//  calendar and then never touch it again: an edit wouldn't follow, and a
//  delete would leave the event behind permanently, with nothing left able to
//  find it.
//
//  Since "edits and deletes propagate outward" is the whole of what this phase
//  promises, full access is what it asks for, and the purpose string says why
//  in those terms rather than asking for trust by assertion.
//
//  A write-only grant is still handled rather than treated as a denial: it can
//  happen (a grant made in a different iOS version, or narrowed in Settings),
//  and when it does, creating still works while updates and removals report
//  `.needsFullAccess` — which the UI turns into a specific sentence and an
//  escalation button, not a silent no-op.
//
//  ── Why an actor ────────────────────────────────────────────────────────
//
//  `EKEventStore.save` and `event(withIdentifier:)` are synchronous and can
//  take real time against a CalDAV-backed calendar. This app has already been
//  bitten once by synchronous work sitting on the main actor. Actor isolation
//  keeps it off by construction.
//
//  ── Why no alarms ───────────────────────────────────────────────────────
//
//  Deliberately, `apply(_:to:)` never sets `EKAlarm`. Routly already schedules
//  its own local notification for every timed item, at the lead time the user
//  chose. Adding a calendar alarm on top would nudge the same person twice for
//  the same thing — and being nudged well is the product's actual claim, so
//  doubling it is worse than a missing feature. Routly owns the nudge; the
//  calendar holds the record.
//

import Foundation
import EventKit

actor EventKitTarget: CalendarTarget {

    nonisolated let provider = CalendarProvider.apple

    /// One store for the lifetime of the app.
    ///
    /// Not one per call: constructing an `EKEventStore` is expensive, and the
    /// change notifications a later phase listens for are posted per store
    /// instance — a fresh one each time would be a fresh one nobody is
    /// listening to.
    private let store = EKEventStore()

    // MARK: - Access

    nonisolated func access() -> CalendarAccess {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarAccess {
        // The answer we want is the *status*, not this call's Bool: `false` and
        // a thrown error both just mean "not granted", and the status says
        // which flavour of not-granted it is.
        _ = try? await store.requestFullAccessToEvents()
        return Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    /// `.authorized` is deliberately absent: iOS 17 deprecated it in favour of
    /// `.fullAccess`, and the two share a raw value, so naming both is not
    /// something Swift will compile. `@unknown default` resolves to `.denied`
    /// because an unrecognised status is not a grant, and treating it as one
    /// would mean calling EventKit and failing further from the cause.
    private static func map(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .full
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    /// The grant belongs to iOS, not to Routly. See the protocol's note.
    nonisolated var canDisconnect: Bool { false }

    // MARK: - Writes

    func create(_ payload: CalendarEventPayload) async throws -> CalendarEventRef {
        guard access().canCreate else { throw CalendarTargetError.accessDenied }
        guard let calendar = writableCalendar() else {
            throw CalendarTargetError.noWritableCalendar
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        apply(payload, to: event)

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarTargetError.providerFailed(error.localizedDescription)
        }

        // Populated by `save`, not before it. Without one there is no way back
        // to this event, so the honest answer is to say the link couldn't be
        // formed rather than to record an empty id that every later lookup
        // silently misses on.
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else {
            throw CalendarTargetError.noIdentifierReturned
        }

        return ref(for: event, identifier: identifier, calendar: calendar)
    }

    func update(_ payload: CalendarEventPayload, at ref: CalendarEventRef) async throws -> CalendarEventRef {
        guard access().canCreate else { throw CalendarTargetError.accessDenied }
        guard access().canModify else { throw CalendarTargetError.needsFullAccess }
        guard let event = findEvent(ref) else {
            // Gone from the calendar. Reported rather than re-created: whether
            // a vanished event should come back is the caller's decision (and,
            // from the next phase, the user's), not something to settle by
            // quietly making a second one.
            throw CalendarTargetError.providerFailed(
                String(localized: "That event is no longer in the calendar.")
            )
        }

        apply(payload, to: event)
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarTargetError.providerFailed(error.localizedDescription)
        }

        return self.ref(
            for: event,
            identifier: event.eventIdentifier ?? ref.externalID,
            calendar: event.calendar
        )
    }

    func remove(_ ref: CalendarEventRef) async throws {
        guard access().canCreate else { throw CalendarTargetError.accessDenied }
        guard access().canModify else { throw CalendarTargetError.needsFullAccess }

        // Already gone is the outcome we wanted. See the protocol's note on
        // idempotence — erroring here would leave the link forever trying to
        // delete something nobody can find.
        guard let event = findEvent(ref) else { return }

        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarTargetError.providerFailed(error.localizedDescription)
        }
    }

    // MARK: - Plumbing

    /// Where new events go.
    ///
    /// `defaultCalendarForNewEvents` is the calendar the user's own Calendar
    /// app would pick, which is the least surprising answer and needs no
    /// picker. A subscribed or delegated calendar can be read-only, so the
    /// answer is checked rather than assumed — writing to one fails at `save`
    /// with a much less legible error.
    private func writableCalendar() -> EKCalendar? {
        guard let calendar = store.defaultCalendarForNewEvents else { return nil }
        return calendar.allowsContentModifications ? calendar : nil
    }

    /// Finds the event a link points at, primary id first, stable id second.
    ///
    /// The fallback is not belt-and-braces: `eventIdentifier` genuinely changes
    /// for CalDAV- and Exchange-backed events when the account resyncs, and
    /// without the second lookup a perfectly present event reads as deleted.
    private func findEvent(_ ref: CalendarEventRef) -> EKEvent? {
        if let event = store.event(withIdentifier: ref.externalID) { return event }
        guard let stable = ref.externalStableID, !stable.isEmpty else { return nil }
        return store.calendarItems(withExternalIdentifier: stable)
            .compactMap { $0 as? EKEvent }
            .first
    }

    private func apply(_ payload: CalendarEventPayload, to event: EKEvent) {
        event.title = payload.title
        event.notes = payload.notes
        // Set before the dates: EventKit normalises a start/end pair against
        // the all-day flag, so flipping it afterwards can shift the span.
        event.isAllDay = payload.isAllDay
        event.startDate = payload.start
        event.endDate = payload.end
    }

    private func ref(for event: EKEvent, identifier: String, calendar: EKCalendar?) -> CalendarEventRef {
        CalendarEventRef(
            calendarID: calendar?.calendarIdentifier,
            externalID: identifier,
            externalStableID: event.calendarItemExternalIdentifier,
            etag: nil,
            remoteChangedAt: event.lastModifiedDate
        )
    }
}
