//
//  Completion.swift
//  RoutineOrganizer
//
//  A per-occurrence log entry. One record captures what happened on a given
//  day for a given item: whether it was done, skipped, or rescheduled, plus
//  the scheduled-vs-actual time. Recording this from Phase 1 is what lets the
//  Phase 4/5 consistency layer show real streaks and longitudinal patterns —
//  history can't be backfilled if it was never written.
//

import Foundation
import SwiftData

@Model
final class Completion {
    enum Status: String, Codable, Sendable {
        case done
        case skipped
        case rescheduled
    }

    var id: UUID

    /// The occurrence day this record refers to (normalized to start-of-day).
    var occurrenceDate: Date

    /// When the item was scheduled for on that day, if known.
    var scheduledTime: Date?

    /// When the user actually marked it done.
    var completedAt: Date?

    var status: Status

    var item: ScheduleItem?

    // MARK: - Sync groundwork
    //
    // Mirrors the fields on `ScheduleItem`; see the longer note there. Completion
    // records are append-only and immutable in practice, so they will only ever
    // union across devices rather than genuinely conflict.

    /// Who this row belongs to — the device's local guest id, or the account id
    /// once signed in. nil means it predates the field (backfilled at launch).
    var ownerID: String? = nil

    /// Last local mutation. `.distantPast` marks a row predating the field.
    var updatedAt: Date = Date.distantPast

    /// Last confirmed push. Always nil until the sync layer ships.
    var syncedAt: Date? = nil

    /// Tombstone, unused until soft deletes arrive with the sync layer.
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        occurrenceDate: Date,
        scheduledTime: Date? = nil,
        completedAt: Date? = nil,
        status: Status = .done,
        item: ScheduleItem? = nil
    ) {
        self.id = id
        self.occurrenceDate = occurrenceDate
        self.scheduledTime = scheduledTime
        self.completedAt = completedAt
        self.status = status
        self.item = item
    }
}
