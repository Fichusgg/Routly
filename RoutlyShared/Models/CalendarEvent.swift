//
//  CalendarEvent.swift
//  RoutineOrganizerShared
//
//  The value types that cross the boundary between Routly and a calendar
//  provider.
//
//  Nothing here knows about SwiftData, EventKit or Google, and that is the
//  whole point. A provider is handed a `CalendarEventPayload` and answers with
//  a `CalendarEventRef`; it never sees a `ScheduleItem`. So the two pieces most
//  likely to be wrong — deciding *what* to send, and matching a reply back to
//  the right row — are plain functions over plain structs, testable without a
//  calendar, a permission grant, or a device.
//
//  These live in Shared rather than beside the EventKit code because
//  `CalendarLink` (a model both processes compile) refers to them. The widget
//  extension compiles them and uses none of them; it must never touch a
//  calendar, having neither the entitlement nor any business asking for one.
//

import Foundation

// MARK: - Payload

/// Everything a provider writes for one event.
struct CalendarEventPayload: Equatable, Sendable {
    var title: String
    var notes: String?
    var start: Date
    var end: Date
    var isAllDay: Bool

    /// A fingerprint of every field above.
    ///
    /// Used to answer "has anything a calendar would care about actually
    /// changed?" without diffing field by field at each call site. Re-saving an
    /// item whose title and time are untouched must not churn the user's
    /// calendar, and a `pushedRevision` that still matches is how we know to do
    /// nothing.
    ///
    /// Deliberately built from the fields rather than from `updatedAt`: Routly
    /// stamps `updatedAt` on every save, including ones that changed only a
    /// to-do's sort index, and a clock is not a statement about content.
    var revision: String {
        let stamp = { (date: Date) in String(Int(date.timeIntervalSince1970)) }
        return [
            title,
            notes ?? "",
            stamp(start),
            stamp(end),
            isAllDay ? "1" : "0",
        ].joined(separator: "\u{1F}")
    }
}

// MARK: - Reference

/// A provider's identity for an event it holds.
struct CalendarEventRef: Equatable, Sendable {
    /// Which calendar within the provider holds it.
    var calendarID: String?
    /// The provider's primary id.
    var externalID: String
    /// Apple's `calendarItemExternalIdentifier` — see the note in `CalendarLink`.
    var externalStableID: String?
    /// Google's etag. Always nil on Apple.
    var etag: String?
    /// The provider's own last-modified stamp.
    var remoteChangedAt: Date?

    init(
        calendarID: String? = nil,
        externalID: String,
        externalStableID: String? = nil,
        etag: String? = nil,
        remoteChangedAt: Date? = nil
    ) {
        self.calendarID = calendarID
        self.externalID = externalID
        self.externalStableID = externalStableID
        self.etag = etag
        self.remoteChangedAt = remoteChangedAt
    }
}

// MARK: - Access

/// What a provider will currently let us do.
///
/// The two computed properties are the load-bearing part of this file, and
/// `canModify` is the one that shaped the whole phase:
///
/// **iOS 17's write-only calendar grant is add-only in the strictest sense.**
/// Updating or removing an event means finding it first, and finding it is
/// reading — `EKEventStore.event(withIdentifier:)` returns nothing without full
/// access. So a write-only grant can create an event and can then never touch
/// it again: no edit propagation, no delete propagation, no cleanup. That is
/// why Routly asks for full access, and why a write-only grant is a degraded
/// state the UI has to name out loud rather than a lighter equivalent.
enum CalendarAccess: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case full

    /// Can we put a new event into the calendar?
    var canCreate: Bool {
        self == .writeOnly || self == .full
    }

    /// Can we change or delete an event that is already there?
    var canModify: Bool { self == .full }

    /// Is there any point offering the user a connect button, or is this a
    /// state only the Settings app can change?
    var isAskable: Bool { self == .notDetermined }
}

// MARK: - Errors

/// Why a push didn't happen. Every case maps to something a person can act on;
/// there is deliberately no `.unknown`.
enum CalendarTargetError: Error, Equatable, Sendable {
    /// No grant at all.
    case accessDenied
    /// A write-only grant met an update or a remove. See `CalendarAccess`.
    case needsFullAccess
    /// The grant is fine but the provider offers nowhere to write.
    case noWritableCalendar
    /// The provider accepted the write and then declined to say what it wrote.
    case noIdentifierReturned
    /// The provider's own failure, carried verbatim for the log.
    case providerFailed(String)

    /// What the person is told. Never an error code, and never "an error
    /// occurred" — each of these has a specific next step.
    var message: String {
        switch self {
        case .accessDenied:
            return String(localized: "Routly doesn't have permission to use this calendar.")
        case .needsFullAccess:
            return String(localized: "Routly can add to this calendar but can't change or remove what it added. Full calendar access is needed for that.")
        case .noWritableCalendar:
            return String(localized: "There's no calendar available to write to.")
        case .noIdentifierReturned:
            return String(localized: "The event was added but the calendar didn't say where, so Routly can't keep it in step.")
        case .providerFailed(let detail):
            return detail
        }
    }
}
