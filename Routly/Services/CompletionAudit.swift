//
//  CompletionAudit.swift
//  RoutineOrganizer
//
//  Finds the days that closed without an answer.
//
//  `Completion.Status` has three cases and, until now, only one of them was
//  ever written: every record in every store was `.done`. That makes the log a
//  record of successes rather than a record of what happened, and it quietly
//  rules out the entire pattern layer — "you've moved this three times",
//  "Thursdays are your hardest day", "this routine has settled down" are all
//  questions about the days that *didn't* close, and none of them can be
//  answered from a log that only remembers the ones that did.
//
//  It also can't be fixed later. History that was never written can't be
//  backfilled, so every day the app runs without this is a day permanently
//  missing from the record.
//
//  This engine answers one question — which past occurrences ended with no
//  record at all — and answers it as pure value-in/value-out, like the other
//  engines here, so it's testable without SwiftData. Writing the records is the
//  view model's job.
//
//  What it deliberately never reports:
//
//  - **Today.** The day isn't over. Nothing is missed until it is.
//  - **Undated to-dos.** A to-do with no day rolls forward by design; that's
//    the rolling checklist working, not a failure. Stamping those daily would
//    manufacture exactly the guilt the app's anti-goals rule out, and would
//    bury the real signal under noise. This falls out of `ScheduleEngine.occurs`
//    returning false for them rather than being a special case here — but it is
//    load-bearing, so any replacement membership rule has to preserve it.
//  - **A day that already carries any record.** Done, skipped or rescheduled,
//    the day has already been answered.
//

import Foundation

/// A past occurrence that closed with nothing recorded against it.
struct MissedOccurrence {
    let item: ScheduleItem
    /// Start of day.
    let day: Date
}

struct CompletionAudit {
    var calendar: Calendar = ScheduleEngine().calendar
    private var schedule: ScheduleEngine { ScheduleEngine(calendar: calendar) }

    /// How far back a single sweep looks.
    ///
    /// **Provisional — not a decided number.** It trades two things off against
    /// each other and there's no data yet to settle it: a longer window
    /// recovers more history for someone who's been away, and costs an
    /// occurrence check per item per day on the way back. Seven days keeps a
    /// launch sweep roughly the size of the week the schedule already computes
    /// for the Today screen.
    ///
    /// It is also a deliberate cap on returning after a long absence: someone
    /// coming back after six weeks should not have six weeks of misses written
    /// out underneath them.
    static let provisionalBackfillDays = 7

    var backfillDays: Int = CompletionAudit.provisionalBackfillDays

    /// Past occurrences with no record of any kind, oldest first.
    ///
    /// - Parameter wasOnThePlate: which items counted as being "on" a given
    ///   day. Injected rather than fixed so that the day's plate — once that
    ///   rule is settled — can replace `ScheduleEngine.occurs` here without
    ///   this engine changing. The default is the shipped occurrence rule,
    ///   which is the conservative choice: it never reports an undated to-do.
    func missedOccurrences(
        in items: [ScheduleItem],
        asOf now: Date = Date(),
        wasOnThePlate: ((ScheduleItem, Date) -> Bool)? = nil
    ) -> [MissedOccurrence] {
        guard backfillDays > 0 else { return [] }

        let membership = wasOnThePlate ?? { item, day in schedule.occurs(item, on: day) }
        let today = calendar.startOfDay(for: now)

        var result: [MissedOccurrence] = []
        // Oldest first, and today is excluded outright: `1...backfillDays` days
        // back never includes the day currently in progress.
        for back in stride(from: backfillDays, through: 1, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            for item in items {
                guard membership(item, day) else { continue }
                guard !hasRecord(item, on: day) else { continue }
                result.append(MissedOccurrence(item: item, day: day))
            }
        }
        return result
    }

    /// Any record at all, whatever its status.
    ///
    /// Checking every status rather than just `.done` is what makes a sweep
    /// idempotent — running it twice must not write the same miss twice — and
    /// it's also what stops a day the user explicitly moved something off
    /// (`.rescheduled`) being counted a second time as a silent miss. One day,
    /// one answer.
    private func hasRecord(_ item: ScheduleItem, on day: Date) -> Bool {
        item.completions.contains { calendar.isDate($0.occurrenceDate, inSameDayAs: day) }
    }
}
