//
//  CalendarLinkPlan.swift
//  RoutineOrganizer
//
//  Given what links an item already has and where the user now wants it, work
//  out the smallest set of provider calls that gets from one to the other.
//
//  This file is where "don't create the same event twice" actually lives. It is
//  a pure function over value types — no SwiftData, no provider, no clock — so
//  every rule below is a test rather than something you find out about from a
//  duplicated entry in somebody's calendar.
//
//  ── The invariant ───────────────────────────────────────────────────────
//
//  **At most one usable link per (item, provider).** Enforced here rather than
//  by a `@Attribute(.unique)` on the model, because SwiftData resolves a unique
//  collision by upserting — it would overwrite the link that points at the real
//  remote event, and the event it pointed at would be orphaned in the user's
//  calendar with nothing left able to find it.
//
//  Duplicates that do turn up (a crash between the provider call and the save,
//  a future store merge) are not ignored: the extras are *removed remotely*
//  when they name a real event, and only discarded locally when they don't.
//  Dropping a duplicate row that pointed at a real event is how you leave
//  litter in somebody's calendar forever.
//

import Foundation

/// One existing link, flattened to what the plan needs to reason about.
struct CalendarLinkSnapshot: Equatable, Sendable {
    var linkID: UUID
    /// nil when the stored provider didn't decode — an unusable row.
    var provider: CalendarProvider?
    var state: CalendarLinkState
    var ref: CalendarEventRef?
    var pushedRevision: String?
}

/// What to do about one link.
enum CalendarLinkAction: Equatable, Sendable {
    /// No link for a wanted provider — make the event and the link.
    case create(provider: CalendarProvider)
    /// A link row with no event behind it. Same provider call as `create`;
    /// kept distinct so the existing row is reused rather than a second one
    /// appearing beside it.
    case retry(linkID: UUID, provider: CalendarProvider)
    /// The event exists and what we last wrote no longer matches the item.
    case update(linkID: UUID, provider: CalendarProvider, ref: CalendarEventRef)
    /// The event exists and is no longer wanted — take it out of the calendar.
    case remove(linkID: UUID, provider: CalendarProvider, ref: CalendarEventRef)
    /// A link row with nothing behind it. Delete the row, call nobody.
    case discard(linkID: UUID)

    /// Sort key, so a plan is deterministic and a test can assert on it
    /// directly. Removals sort before creations: when a plan does both, the
    /// user's calendar should never briefly hold two copies.
    var order: Int {
        switch self {
        case .discard: return 0
        case .remove: return 1
        case .create: return 2
        case .retry: return 3
        case .update: return 4
        }
    }
}

enum CalendarLinkPlan {

    /// The whole rule set.
    ///
    /// - Parameters:
    ///   - existing: every link currently on the item.
    ///   - desired: the providers the user now wants. **Pass an empty set when
    ///     the item has stopped being calendar-eligible** — that is what turns
    ///     "this is a to-do now" into "take it out of the calendar".
    ///   - revision: the current `CalendarEventPayload.revision`, or nil when
    ///     there is no payload. A link whose `pushedRevision` already equals
    ///     this needs no call at all.
    static func plan(
        existing: [CalendarLinkSnapshot],
        desired: Set<CalendarProvider>,
        revision: String?
    ) -> [CalendarLinkAction] {
        var actions: [CalendarLinkAction] = []

        // A link we can't attribute to a provider can't be acted on: we don't
        // know whose event it is, so we can neither update nor delete it. The
        // row goes; nothing is called.
        let (attributed, unattributed) = existing.partitionedByProvider()
        actions += unattributed.map { .discard(linkID: $0.linkID) }

        // One canonical link per provider; the rest are duplicates to clean up.
        for (provider, links) in attributed {
            guard let canonical = canonical(among: links) else { continue }

            for extra in links where extra.linkID != canonical.linkID {
                actions.append(cleanup(extra, provider: provider))
            }

            if desired.contains(provider) {
                if let action = reconcile(canonical, provider: provider, revision: revision) {
                    actions.append(action)
                }
            } else {
                actions.append(cleanup(canonical, provider: provider))
            }
        }

        // Wanted providers with nothing there yet.
        let linked = Set(attributed.keys)
        for provider in desired.subtracting(linked) {
            actions.append(.create(provider: provider))
        }

        return actions.sorted { left, right in
            left.order == right.order
                ? left.sortName < right.sortName
                : left.order < right.order
        }
    }

    /// Which of several links for one provider is the real one.
    ///
    /// A link that actually points at an event wins over one that doesn't,
    /// regardless of position. Taking "the first" instead would mean a failed
    /// row written a moment before a successful retry could shadow the
    /// successful one — and the event the successful one points at would then
    /// be removed as a duplicate, which is the exact litter this file exists to
    /// prevent. The relationship array's order is not guaranteed either, so
    /// "first" was never a stable choice to begin with.
    private static func canonical(among links: [CalendarLinkSnapshot]) -> CalendarLinkSnapshot? {
        links.first { $0.state == .linked && $0.ref != nil } ?? links.first
    }

    /// A link the user still wants. Three cases, and the middle one is the
    /// dedup that matters most in practice: an item re-saved without any change
    /// a calendar would notice produces **no provider call at all**.
    private static func reconcile(
        _ link: CalendarLinkSnapshot,
        provider: CalendarProvider,
        revision: String?
    ) -> CalendarLinkAction? {
        guard let ref = link.ref else {
            // Nothing behind it — pending, or a create that failed, or a write
            // the provider accepted without returning an id. Reuse the row;
            // make the event.
            return .retry(linkID: link.linkID, provider: provider)
        }
        guard let revision else {
            // Wanted, but there is nothing to write. Only reachable if a caller
            // passes a non-empty `desired` with no payload, which is a caller
            // bug — answering "do nothing" is the safe reading, since the
            // alternative is deleting a real event on the strength of a nil.
            return nil
        }
        // **A link that points at a real event is updated, whatever state it is
        // in.** Reading `.failed` as "start again" would be the subtle version
        // of the duplicate bug this file exists to prevent: an update that
        // failed leaves a link that is `.failed` *and* still points at a live
        // event, so re-creating would put a second copy in the calendar and
        // orphan the first. State decides whether to retry; only the absence of
        // a ref decides whether to create.
        guard link.state == .failed || link.pushedRevision != revision else { return nil }
        return .update(linkID: link.linkID, provider: provider, ref: ref)
    }

    /// Getting rid of a link. Removes the remote event when there is one;
    /// otherwise just drops the row.
    private static func cleanup(
        _ link: CalendarLinkSnapshot,
        provider: CalendarProvider
    ) -> CalendarLinkAction {
        guard let ref = link.ref else { return .discard(linkID: link.linkID) }
        return .remove(linkID: link.linkID, provider: provider, ref: ref)
    }
}

// MARK: - Helpers

private extension Array where Element == CalendarLinkSnapshot {

    /// Splits links into "we know whose these are", grouped by provider and
    /// keeping their original order, and "we don't".
    func partitionedByProvider() -> ([CalendarProvider: [CalendarLinkSnapshot]], [CalendarLinkSnapshot]) {
        var grouped: [CalendarProvider: [CalendarLinkSnapshot]] = [:]
        var orphans: [CalendarLinkSnapshot] = []
        for link in self {
            guard let provider = link.provider else {
                orphans.append(link)
                continue
            }
            grouped[provider, default: []].append(link)
        }
        return (grouped, orphans)
    }
}

private extension CalendarLinkAction {
    /// Secondary sort key, so two actions of the same kind order stably.
    var sortName: String {
        switch self {
        case .create(let provider): return provider.rawValue
        case .retry(let linkID, let provider): return provider.rawValue + linkID.uuidString
        case .update(let linkID, let provider, _): return provider.rawValue + linkID.uuidString
        case .remove(let linkID, let provider, _): return provider.rawValue + linkID.uuidString
        case .discard(let linkID): return linkID.uuidString
        }
    }
}
