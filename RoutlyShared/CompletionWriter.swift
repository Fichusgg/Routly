//
//  CompletionWriter.swift
//  RoutineOrganizerShared
//
//  The one place a completion is written, for both processes.
//
//  This is lifted verbatim out of `ScheduleViewModel` rather than reimplemented,
//  and that matters more than it looks. A widget that wrote its own version of
//  "mark this done" would be a second definition of what completion *means* —
//  and the first time the two disagreed, the damage would show up in the
//  consistency grid and the streaks weeks later, as history that can't be
//  reconstructed. The rules encoded below (one record per occurrence, `.done`
//  removal narrowed to `.done`, `isCompleted` only for one-offs) are the same
//  rules the app has always followed; the widget now follows them by calling the
//  same code rather than by agreeing to.
//
//  Deliberately a plain struct over a `ModelContext`, with no view-model
//  dependencies: the widget extension has no parser, no engines, and no
//  `@Observable` graph to hang them from.
//

import Foundation
import SwiftData

struct CompletionWriter {

    let calendar: Calendar

    init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    // MARK: - Reading

    /// Whether this item counts as done on `day`.
    ///
    /// A one-off carries a single flag; a routine is done per-occurrence, which
    /// only the completion records know. Same distinction the app has always
    /// drawn — see the note on `ScheduleViewModel.completedTodos` for why a flag
    /// alone can't answer "was it done *today*".
    func isDone(_ item: ScheduleItem, on day: Date) -> Bool {
        if item.recurrence == nil { return item.isCompleted }
        return item.completions.contains {
            $0.status == .done && calendar.isDate($0.occurrenceDate, inSameDayAs: day)
        }
    }

    // MARK: - Writing

    /// Ticks an item on or off for `day`.
    ///
    /// The app's path: tapping a filled circle takes the completion back.
    func toggle(_ item: ScheduleItem, on day: Date, in context: ModelContext, owner: String?) {
        if isDone(item, on: day) {
            uncomplete(item, on: day, in: context, owner: owner)
        } else {
            complete(item, on: day, in: context, owner: owner)
        }
    }

    /// Marks done, and does nothing if it already is.
    ///
    /// Idempotent on purpose — this is the widget's entry point. A widget can be
    /// tapped again before its timeline has reloaded, and the honest response to
    /// "complete something already complete" is silence, not a second record
    /// that would count twice in every statistic that reads occurrences.
    func complete(_ item: ScheduleItem, on day: Date, in context: ModelContext, owner: String?) {
        guard !isDone(item, on: day) else { return }
        let dayStart = calendar.startOfDay(for: day)
        let completion = Completion(
            occurrenceDate: dayStart,
            scheduledTime: item.startTime,
            completedAt: Date(),
            status: .done,
            item: item
        )
        item.completions.append(completion)
        context.insert(completion)
        if item.recurrence == nil { item.isCompleted = true }
        save(context, owner: owner)
    }

    /// Takes a completion back.
    func uncomplete(_ item: ScheduleItem, on day: Date, in context: ModelContext, owner: String?) {
        let dayStart = calendar.startOfDay(for: day)
        removeCompletion(item, on: dayStart, in: context)
        if item.recurrence == nil { item.isCompleted = false }
        save(context, owner: owner)
    }

    /// Removes records for one day, narrowed to the statuses named.
    ///
    /// The `.done`-only default is load-bearing and is carried over unchanged
    /// from the view model: un-ticking something is the user taking back a
    /// completion, and says nothing about a reschedule or a skip that may also
    /// have happened that day. Widening it would be silent data loss.
    func removeCompletion(
        _ item: ScheduleItem,
        on dayStart: Date,
        in context: ModelContext,
        statuses: Set<Completion.Status> = [.done]
    ) {
        let matches = item.completions.filter {
            statuses.contains($0.status) && calendar.isDate($0.occurrenceDate, inSameDayAs: dayStart)
        }
        for match in matches {
            item.completions.removeAll { $0.id == match.id }
            context.delete(match)
        }
    }

    private func save(_ context: ModelContext, owner: String?) {
        StoreWrite.save(context, owner: owner)
    }
}

// MARK: - Ownership

/// Stamps and saves. The single funnel every write in either process goes
/// through, so ownership and the merge clock can't be forgotten by a new caller.
///
/// `owner` is passed in rather than resolved here because the two processes
/// learn it differently: the app reads the Keychain (via `CurrentOwner`), while
/// the extension — which has no access to that Keychain item — reads the value
/// the app mirrored into the shared defaults. A nil owner is a legitimate
/// answer, not a failure: it means "unknown here", and the app's launch backfill
/// fills it in. Guessing an id in the extension would be worse than leaving it
/// blank, because a wrong owner is indistinguishable from another device's.
enum StoreWrite {
    static func save(_ context: ModelContext, owner: String?) {
        stampOwnership(context, owner: owner)
        try? context.save()
    }

    static func stampOwnership(_ context: ModelContext, owner: String?) {
        guard context.hasChanges else { return }
        let now = Date()

        for model in context.insertedModelsArray + context.changedModelsArray {
            switch model {
            case let item as ScheduleItem:
                if item.ownerID == nil { item.ownerID = owner }
                item.updatedAt = now
                item.syncedAt = nil
            case let completion as Completion:
                if completion.ownerID == nil { completion.ownerID = owner }
                completion.updatedAt = now
                completion.syncedAt = nil
            case let link as CalendarLink:
                if link.ownerID == nil { link.ownerID = owner }
                link.updatedAt = now
                link.syncedAt = nil
            default:
                break
            }
        }
    }
}
