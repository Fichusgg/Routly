//
//  CalendarLink.swift
//  RoutineOrganizerShared
//
//  The mapping between one Routly item and one event in somebody else's
//  calendar.
//
//  It is a separate entity rather than three columns on `ScheduleItem` for one
//  reason: an item can go to Apple *and* Google at once, and a single
//  (provider, calendar, external id) triple can only ever hold one of them. A
//  to-many relationship is what "and/or" actually means in the data.
//
//  It is also the app's dedup mechanism. The invariant every write goes through
//  is **at most one usable link per (item, provider)** — enforced in
//  `CalendarLinkPlan`, not by a `@Attribute(.unique)`, because SwiftData's
//  unique constraints resolve a collision by *upserting*, which here would mean
//  silently overwriting the link to a real remote event and orphaning it.
//
//  ── The column shapes are not stylistic ─────────────────────────────────
//
//  Every scalar below is optional or defaulted, and the two enums are stored as
//  raw `String?` with accessors on top. That is the same rule `ScheduleItem`
//  documents at length: a non-optional column traps inside SwiftData's decoder
//  when a row that predates it decodes NULL, and the trap is un-catchable — the
//  app dies at launch.
//
//  No row can predate a brand-new entity, so strictly this file could relax the
//  rule. It doesn't, because "no row predates it" is only true until the *next*
//  column is added, and by then the habit has to already be in place. `id` is
//  the single exception, matching `ScheduleItem` and `Completion`: an entity's
//  identity is written by its own initialiser and never decodes NULL.
//

import Foundation
import SwiftData

// MARK: - Provider

/// Which calendar system a link points at.
///
/// Only providers with a registered target in `CalendarSync` are ever offered
/// to the user — so declaring `google` here does not put a dead switch in the
/// UI, it just means the identifier is stable before the provider ships.
enum CalendarProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case google

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return String(localized: "Apple Calendar")
        case .google: return String(localized: "Google Calendar")
        }
    }

    var symbolName: String {
        switch self {
        case .apple: return "calendar"
        case .google: return "globe"
        }
    }
}

// MARK: - Link state

/// How much we currently believe about the remote event.
///
/// Deliberately three states, not five. `broken` (deleted over there) and
/// `diverged` (edited over there) are read-back answers, and read-back needs a
/// pass that doesn't exist yet — a state nothing can ever set is worse than no
/// state, because the next reader assumes something produces it.
enum CalendarLinkState: String, Codable, CaseIterable, Sendable {
    /// Wanted, not yet confirmed written. Also what an undecodable value reads
    /// as: "we don't know", which is the safe thing to assume.
    case pending
    /// Written, and `externalID` refers to a real event as far as we know.
    case linked
    /// The provider refused. Kept rather than deleted so the failure is
    /// visible in Settings and retryable, instead of the event quietly never
    /// appearing.
    case failed
}

// MARK: - Model

@Model
final class CalendarLink {

    var id: UUID

    /// Backing store. Never read directly — use `provider`.
    var providerRawValue: String?

    /// Backing store. Never read directly — use `state`.
    var stateRawValue: String?

    /// The calendar within the provider that holds the event.
    var calendarID: String?

    /// The provider's id for the event. `EKEvent.eventIdentifier` on Apple.
    var externalID: String?

    /// Apple's `calendarItemExternalIdentifier`, kept as a fallback.
    ///
    /// Not redundant: `eventIdentifier` is **not permanently stable**. For a
    /// CalDAV- or Exchange-backed calendar it can change out from under us when
    /// the account resyncs, at which point a lookup by it misses and the link
    /// would look broken when the event is sitting right there.
    var externalStableID: String?

    /// Google's `etag`. Unused on Apple, which has no equivalent.
    var externalETag: String?

    /// The provider's own last-modified stamp, as of our last observation.
    var remoteChangedAt: Date?

    /// When *we* last wrote to the provider.
    var lastPushedAt: Date?

    /// The `CalendarEventPayload.revision` of what we last successfully wrote.
    ///
    /// Two jobs. Today: an edit whose revision matches what's already out there
    /// is a no-op, so re-saving an unchanged item doesn't churn the user's
    /// calendar. Later: it is the left-hand side of the echo filter — an
    /// inbound change that matches what we last pushed is our own write coming
    /// back, not somebody else's edit.
    var pushedRevision: String?

    /// The item this link belongs to. The inverse and the cascade rule live on
    /// `ScheduleItem.calendarLinks`.
    var item: ScheduleItem?

    // MARK: - Sync groundwork
    //
    // The same four columns every other row in this store carries, so the
    // future cloud-sync layer treats a link like anything else rather than
    // needing a special case. Stamped by `StoreWrite`.

    var ownerID: String? = nil
    var updatedAt: Date = Date.distantPast
    var syncedAt: Date? = nil
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        provider: CalendarProvider,
        state: CalendarLinkState = .pending,
        calendarID: String? = nil,
        externalID: String? = nil,
        externalStableID: String? = nil,
        externalETag: String? = nil,
        remoteChangedAt: Date? = nil,
        lastPushedAt: Date? = nil,
        pushedRevision: String? = nil
    ) {
        self.id = id
        self.providerRawValue = provider.rawValue
        self.stateRawValue = state.rawValue
        self.calendarID = calendarID
        self.externalID = externalID
        self.externalStableID = externalStableID
        self.externalETag = externalETag
        self.remoteChangedAt = remoteChangedAt
        self.lastPushedAt = lastPushedAt
        self.pushedRevision = pushedRevision
    }

    // MARK: - Accessors

    /// Which provider this link points at, or nil when the stored value doesn't
    /// decode.
    ///
    /// Optional, unlike `ScheduleItem.priority` — and the difference matters.
    /// Priority defaults to "nobody said", which is a real, harmless answer. A
    /// link with an unreadable provider has no harmless answer: defaulting it
    /// to `.apple` would point a Google link at EventKit and delete the wrong
    /// event. nil means unusable, and unusable links get discarded rather than
    /// guessed at.
    var provider: CalendarProvider? {
        get { providerRawValue.flatMap(CalendarProvider.init(rawValue:)) }
        set { providerRawValue = newValue?.rawValue }
    }

    /// How much we believe about the remote event. An unreadable value reads as
    /// `.pending` — "unverified" is the assumption that leads to a re-check
    /// rather than to trusting an id we can't vouch for.
    var state: CalendarLinkState {
        get { stateRawValue.flatMap(CalendarLinkState.init(rawValue:)) ?? .pending }
        set { stateRawValue = newValue.rawValue }
    }

    /// The remote event's identity as a plain value, for handing to a provider.
    /// nil when there is no event out there yet to point at.
    var eventRef: CalendarEventRef? {
        guard let externalID, !externalID.isEmpty else { return nil }
        return CalendarEventRef(
            calendarID: calendarID,
            externalID: externalID,
            externalStableID: externalStableID,
            etag: externalETag,
            remoteChangedAt: remoteChangedAt
        )
    }

    /// Copies a provider's answer back onto the link and marks it written.
    func adopt(_ ref: CalendarEventRef, revision: String, now: Date = Date()) {
        calendarID = ref.calendarID
        externalID = ref.externalID
        externalStableID = ref.externalStableID
        externalETag = ref.etag
        remoteChangedAt = ref.remoteChangedAt
        pushedRevision = revision
        lastPushedAt = now
        state = .linked
    }
}
