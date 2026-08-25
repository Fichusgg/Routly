//
//  EventLayout.swift
//  RoutineOrganizer
//
//  The pure geometry behind a readable day timeline. Overlapping events must not
//  stack on top of one another; they split into side-by-side lanes the way every
//  serious calendar (Fantastical, Google, Apple) lays out a busy morning.
//
//  This is deliberately UI-free and deterministic so the packing algorithm can be
//  unit-tested without SwiftData or a running view — the layout math is the part
//  most likely to be subtly wrong, so it lives where it can be pinned down.
//

import Foundation

/// One timed event resolved to a vertical span (in minutes from midnight) and a
/// horizontal lane (`column` of `columnCount`) within its overlap cluster.
struct PositionedEvent: Identifiable, Equatable {
    let item: ScheduleItem
    let startMinute: Int
    let endMinute: Int
    let column: Int
    let columnCount: Int

    var id: UUID { item.id }

    static func == (lhs: PositionedEvent, rhs: PositionedEvent) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.startMinute == rhs.startMinute &&
        lhs.endMinute == rhs.endMinute &&
        lhs.column == rhs.column &&
        lhs.columnCount == rhs.columnCount
    }
}

enum EventLayout {
    /// Packs timed items into lanes. Items without a `startTime` are ignored (they
    /// belong in the all-day row, not the grid).
    ///
    /// - `defaultDuration`: assumed length for an item with no duration.
    /// - `minDuration`: a floor so a zero/short event still reserves a tappable
    ///   span and can genuinely overlap its neighbours.
    static func position(
        _ items: [ScheduleItem],
        calendar: Calendar = Calendar(identifier: .gregorian),
        defaultDuration: Int = 30,
        minDuration: Int = 20
    ) -> [PositionedEvent] {
        // 1. Resolve each timed item to a [start, end) minute span.
        struct Span {
            let item: ScheduleItem
            let start: Int
            let end: Int
        }
        let spans: [Span] = items.compactMap { item in
            guard let start = item.startTime else { return nil }
            let comps = calendar.dateComponents([.hour, .minute], from: start)
            let startMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            let length = max(minDuration, item.durationMinutes ?? defaultDuration)
            let endMin = min(24 * 60, startMin + length)
            return Span(item: item, start: startMin, end: max(endMin, startMin + minDuration))
        }
        .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }

        guard !spans.isEmpty else { return [] }

        var result: [PositionedEvent] = []

        // 2. Walk the spans, grouping any that chain-overlap into one cluster. A
        //    cluster ends when a span starts at or after the running maximum end.
        var cluster: [Span] = []
        var clusterMaxEnd = Int.min

        func flush(_ group: [Span]) {
            guard !group.isEmpty else { return }
            // Greedy column assignment: reuse the first lane whose last event has
            // already ended; otherwise open a new lane.
            var laneEnds: [Int] = []          // end minute per open lane
            var assignedColumn: [Int] = []     // column index per span, in order
            for span in group {
                if let lane = laneEnds.firstIndex(where: { $0 <= span.start }) {
                    laneEnds[lane] = span.end
                    assignedColumn.append(lane)
                } else {
                    laneEnds.append(span.end)
                    assignedColumn.append(laneEnds.count - 1)
                }
            }
            let columnCount = laneEnds.count
            for (i, span) in group.enumerated() {
                result.append(PositionedEvent(
                    item: span.item,
                    startMinute: span.start,
                    endMinute: span.end,
                    column: assignedColumn[i],
                    columnCount: columnCount
                ))
            }
        }

        for span in spans {
            if cluster.isEmpty || span.start < clusterMaxEnd {
                cluster.append(span)
                clusterMaxEnd = max(clusterMaxEnd, span.end)
            } else {
                flush(cluster)
                cluster = [span]
                clusterMaxEnd = span.end
            }
        }
        flush(cluster)

        return result
    }
}
