//
//  DataOwnership.swift
//  RoutineOrganizer
//
//  Who each row belongs to, and the two operations that change it:
//
//  • `backfill` — stamps rows created before ownership existed with this
//    device's guest id. Runs once at launch and is idempotent.
//  • `claim`    — rewrites this device's guest rows to an account id when
//    someone signs in for the first time.
//
//  Both are plain functions over arrays so they can be tested without a server,
//  and both are deliberately non-destructive: nothing here deletes anything, so
//  the worst case of a bug is a mislabelled row rather than lost data.
//

import Foundation

enum DataOwnership {

    /// What a pass actually changed, for the account screen to report honestly.
    struct Summary: Equatable, Sendable {
        var items: Int = 0
        var completions: Int = 0

        /// Calendar links moved along with their items.
        ///
        /// Counted so `isEmpty` stays honest — a pass that re-stamped links and
        /// nothing else did do something — but deliberately absent from
        /// `phrase`. "and 3 calendar links" answers a question nobody asked: a
        /// link is Routly's private bookkeeping about an event, not a thing the
        /// person put in the app and would recognise in a count of their data.
        var links: Int = 0

        var total: Int { items + completions + links }
        var isEmpty: Bool { total == 0 }

        /// "12 items and 30 check-offs" — plain counting, no rounding or spin.
        ///
        /// Both counts go through the string catalog as numbers so each language
        /// supplies its own plural forms. Building them here as "item" + "s"
        /// only ever described English.
        var phrase: String {
            let itemPart = String(localized: "\(items) items")
            guard completions > 0 else { return itemPart }
            let checkPart = String(localized: "\(completions) check-offs")
            return String(localized: "\(itemPart) and \(checkPart)")
        }
    }

    // MARK: - Backfill

    /// Gives every unowned row this device's guest identity, and repairs the
    /// `updatedAt` of rows that predate that field. Idempotent: a second run
    /// over the same data changes nothing and reports zero.
    @discardableResult
    /// `links` is defaulted rather than added to the signature outright, so
    /// every existing caller and test keeps compiling and keeps meaning what it
    /// meant. Passing none is not a special case — it's an install with no
    /// calendar links, which is most of them.
    static func backfill(
        items: [ScheduleItem],
        completions: [Completion],
        links: [CalendarLink] = [],
        owner: String,
        now: Date = Date()
    ) -> Summary {
        var summary = Summary()

        for item in items {
            var touched = false
            if item.ownerID == nil {
                item.ownerID = owner
                touched = true
            }
            if item.updatedAt == .distantPast {
                // The row's own creation date is a truer "last changed" than
                // now — stamping everything with `now` would make a year-old
                // routine look freshly edited to the future sync layer.
                item.updatedAt = item.createdAt
                touched = true
            }
            if touched { summary.items += 1 }
        }

        for completion in completions {
            var touched = false
            if completion.ownerID == nil {
                completion.ownerID = owner
                touched = true
            }
            if completion.updatedAt == .distantPast {
                completion.updatedAt = completion.completedAt ?? completion.occurrenceDate
                touched = true
            }
            if touched { summary.completions += 1 }
        }

        for link in links {
            var touched = false
            if link.ownerID == nil {
                link.ownerID = owner
                touched = true
            }
            if link.updatedAt == .distantPast {
                // A link's own push time is the truest "last changed" it has.
                // Falling back to `now` for one that was never pushed is fine:
                // an unpushed link has no history to misrepresent.
                link.updatedAt = link.lastPushedAt ?? now
                touched = true
            }
            if touched { summary.links += 1 }
        }

        return summary
    }

    // MARK: - Claim

    /// Hands this device's guest rows to a signed-in account.
    ///
    /// Only rows owned by *this device's* guest id move. Rows already belonging
    /// to an account are left alone — under the one-account-per-device rule of
    /// v1 that situation means a different account's data is present, which is
    /// the migration coordinator's problem to resolve, not something to quietly
    /// overwrite here.
    ///
    /// Claimed rows are marked dirty (`syncedAt = nil`) so that when sync ships
    /// they are picked up as pending uploads with no extra bookkeeping.
    @discardableResult
    static func claim(
        items: [ScheduleItem],
        completions: [Completion],
        links: [CalendarLink] = [],
        from guestOwner: String,
        to accountID: String,
        now: Date = Date()
    ) -> Summary {
        var summary = Summary()

        for item in items where item.ownerID == guestOwner || item.ownerID == nil {
            item.ownerID = accountID
            item.updatedAt = now
            item.syncedAt = nil
            summary.items += 1
        }

        for completion in completions where completion.ownerID == guestOwner || completion.ownerID == nil {
            completion.ownerID = accountID
            completion.updatedAt = now
            completion.syncedAt = nil
            summary.completions += 1
        }

        // Links move with the items they belong to. Left behind, they'd be rows
        // stamped with a guest owner hanging off items stamped with an account
        // — the mislabelling this whole file exists to prevent, and the kind
        // the sync layer would later have to guess its way out of.
        for link in links where link.ownerID == guestOwner || link.ownerID == nil {
            link.ownerID = accountID
            link.updatedAt = now
            link.syncedAt = nil
            summary.links += 1
        }

        return summary
    }

    // MARK: - Inspection

    /// Rows belonging to some account other than `accountID` — the signal that
    /// a different person's data is sitting on this device.
    static func foreignOwners(
        items: [ScheduleItem],
        excluding accountID: String?,
        guestOwner: String
    ) -> Set<String> {
        var owners: Set<String> = []
        for item in items {
            guard let owner = item.ownerID else { continue }
            guard owner != guestOwner, owner != accountID else { continue }
            owners.insert(owner)
        }
        return owners
    }

    /// How much guest data is sitting on this device — what a first sign-in
    /// would carry up.
    static func guestCount(items: [ScheduleItem], completions: [Completion], guestOwner: String) -> Summary {
        Summary(
            items: items.filter { $0.ownerID == guestOwner || $0.ownerID == nil }.count,
            completions: completions.filter { $0.ownerID == guestOwner || $0.ownerID == nil }.count
        )
    }
}
