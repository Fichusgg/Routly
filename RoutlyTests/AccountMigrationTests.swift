//
//  AccountMigrationTests.swift
//  RoutineOrganizerTests
//
//  Covers the two pieces of the account layer that must not be wrong: who owns
//  a row after a backfill or a claim, and which branch a first sign-in takes.
//  Both are pure functions over models, so none of this needs a server.
//

import Testing
import Foundation
import SwiftData
@testable import Routly

private let cal = Calendar(identifier: .gregorian)

private let reference: Date = {
    var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 20; c.hour = 8
    return cal.date(from: c)!
}()

private let guestOwner = "local:TEST-DEVICE"
private let accountID = "9f1c1e2a-0000-4000-8000-000000000001"

// MARK: - Ownership

@Suite("Data ownership")
struct DataOwnershipTests {

    @Test("backfill stamps unowned rows with the guest owner")
    func backfillStampsOwner() {
        let item = ScheduleItem(title: "Gym", createdAt: reference)
        #expect(item.ownerID == nil)

        let summary = DataOwnership.backfill(items: [item], completions: [], owner: guestOwner)

        #expect(item.ownerID == guestOwner)
        #expect(summary.items == 1)
    }

    @Test("backfill repairs updatedAt from createdAt rather than now")
    func backfillUsesCreatedAt() {
        // Stamping `now` would make a months-old routine look freshly edited to
        // the future sync layer, which is exactly the kind of quiet wrongness
        // that produces a bad merge later.
        let item = ScheduleItem(title: "Read", createdAt: reference)
        #expect(item.updatedAt == .distantPast)

        DataOwnership.backfill(items: [item], completions: [], owner: guestOwner)

        #expect(item.updatedAt == reference)
    }

    @Test("backfill is idempotent")
    func backfillIdempotent() {
        let item = ScheduleItem(title: "Walk", createdAt: reference)
        DataOwnership.backfill(items: [item], completions: [], owner: guestOwner)

        let second = DataOwnership.backfill(items: [item], completions: [], owner: guestOwner)

        #expect(second.isEmpty)
        #expect(item.ownerID == guestOwner)
    }

    @Test("backfill leaves an already-owned row alone")
    func backfillPreservesOwner() {
        let item = ScheduleItem(title: "Standup", createdAt: reference)
        item.ownerID = accountID

        DataOwnership.backfill(items: [item], completions: [], owner: guestOwner)

        #expect(item.ownerID == accountID)
    }

    @Test("claim moves guest rows to the account and marks them dirty")
    func claimMovesGuestRows() {
        let item = ScheduleItem(title: "Dentist", createdAt: reference)
        item.ownerID = guestOwner
        item.syncedAt = reference
        let completion = Completion(occurrenceDate: reference, status: .done)
        completion.ownerID = guestOwner

        let summary = DataOwnership.claim(
            items: [item],
            completions: [completion],
            from: guestOwner,
            to: accountID,
            now: reference
        )

        #expect(item.ownerID == accountID)
        #expect(completion.ownerID == accountID)
        // Dirty, so the sync layer picks them up as pending uploads for free.
        #expect(item.syncedAt == nil)
        #expect(item.updatedAt == reference)
        #expect(summary.items == 1)
        #expect(summary.completions == 1)
    }

    /// Links have to move with the items they belong to. Left behind, they'd be
    /// rows stamped with a guest owner hanging off items stamped with an
    /// account — the mislabelling `DataOwnership` exists to prevent, and one
    /// the sync layer would later have to guess its way out of.
    @Test("claim moves calendar links along with their items")
    func claimMovesLinks() {
        let item = ScheduleItem(title: "Dentist", createdAt: reference)
        item.ownerID = guestOwner
        let link = CalendarLink(provider: .apple, state: .linked, externalID: "remote-1")
        link.ownerID = guestOwner
        link.syncedAt = reference

        let summary = DataOwnership.claim(
            items: [item],
            completions: [],
            links: [link],
            from: guestOwner,
            to: accountID,
            now: reference
        )

        #expect(link.ownerID == accountID)
        #expect(link.syncedAt == nil)
        #expect(link.updatedAt == reference)
        #expect(summary.links == 1)
        #expect(!summary.isEmpty)
    }

    @Test("backfill stamps an unowned link and dates it from its last push")
    func backfillStampsLinks() {
        let pushed = CalendarLink(provider: .apple, state: .linked, externalID: "remote-1")
        pushed.lastPushedAt = reference
        let neverPushed = CalendarLink(provider: .apple)

        let summary = DataOwnership.backfill(
            items: [],
            completions: [],
            links: [pushed, neverPushed],
            owner: guestOwner,
            now: reference
        )

        #expect(pushed.ownerID == guestOwner)
        // Its own push time, not `now` — the same reasoning as an item being
        // dated from `createdAt` rather than looking freshly edited.
        #expect(pushed.updatedAt == reference)
        #expect(neverPushed.ownerID == guestOwner)
        #expect(summary.links == 2)
    }

    /// A count of links has no place in a sentence about the user's own data:
    /// a link is Routly's bookkeeping about an event, not something the person
    /// put in the app and would recognise in a total.
    @Test("the phrase counts items and check-offs, never links")
    func phraseIgnoresLinks() {
        let summary = DataOwnership.Summary(items: 2, completions: 0, links: 5)
        #expect(!summary.phrase.contains("5"))
    }

    @Test("claim does not touch another account's rows")
    func claimSkipsForeignRows() {
        let mine = ScheduleItem(title: "Mine", createdAt: reference)
        mine.ownerID = guestOwner
        let theirs = ScheduleItem(title: "Theirs", createdAt: reference)
        theirs.ownerID = "someone-else"

        let summary = DataOwnership.claim(
            items: [mine, theirs],
            completions: [],
            from: guestOwner,
            to: accountID
        )

        #expect(mine.ownerID == accountID)
        #expect(theirs.ownerID == "someone-else")
        #expect(summary.items == 1)
    }

    @Test("foreignOwners spots data belonging to a different account")
    func foreignOwnersDetected() {
        let mine = ScheduleItem(title: "Mine", createdAt: reference)
        mine.ownerID = guestOwner
        let theirs = ScheduleItem(title: "Theirs", createdAt: reference)
        theirs.ownerID = "other-account"

        let owners = DataOwnership.foreignOwners(
            items: [mine, theirs],
            excluding: accountID,
            guestOwner: guestOwner
        )

        #expect(owners == ["other-account"])
    }

    @Test("summary phrasing counts plainly")
    func summaryPhrasing() {
        #expect(DataOwnership.Summary(items: 1, completions: 0).phrase == "1 item")
        #expect(DataOwnership.Summary(items: 3, completions: 1).phrase == "3 items and 1 check-off")
        #expect(DataOwnership.Summary(items: 2, completions: 5).phrase == "2 items and 5 check-offs")
    }
}

// MARK: - Routing

@Suite("Migration routing")
struct MigrationPlannerTests {

    @Test("local data with an empty account claims without asking")
    func claimsLocally() {
        #expect(MigrationPlanner.route(localItems: 12, remote: .empty) == .claimLocally)
    }

    @Test("an unverified account still claims locally rather than guessing")
    func unknownRemoteClaimsLocally() {
        // `.unknown` is what the current build always reports — no probe exists
        // yet. It must never be treated as a reason to ask an unanswerable
        // question, and never as licence to overwrite anything.
        #expect(MigrationPlanner.route(localItems: 4, remote: .unknown) == .claimLocally)
    }

    @Test("nothing local means nothing to do")
    func nothingLocal() {
        #expect(MigrationPlanner.route(localItems: 0, remote: .empty) == .nothingToDo)
        #expect(MigrationPlanner.route(localItems: 0, remote: .unknown) == .nothingToDo)
    }

    @Test("a populated account with no local data needs no question")
    func remoteOnlyIsNotAFork() {
        // There's nothing to reconcile — the sync layer just pulls it down.
        #expect(MigrationPlanner.route(localItems: 0, remote: .populated(items: 20)) == .nothingToDo)
    }

    @Test("data on both sides asks before touching anything")
    func bothSidesAsks() {
        let route = MigrationPlanner.route(localItems: 7, remote: .populated(items: 20))
        #expect(route == .askUser(localItems: 7, remoteItems: 20))
    }

    @Test("merge is the recommended choice")
    func mergeIsRecommended() {
        #expect(MigrationChoice.merge.isRecommended)
        #expect(!MigrationChoice.keepLocal.isRecommended)
        #expect(!MigrationChoice.keepCloud.isRecommended)
    }

    @Test("the shipped probe reports unknown, not empty")
    func probeIsHonest() async {
        let state = await UncheckedRemoteProbe().probe(accountID: accountID)
        #expect(state == .unknown)
    }
}

// MARK: - Owner identity

@Suite("Owner identity")
struct LocalOwnerTests {

    @Test("guest ids are distinguishable from account ids")
    func guestPrefixDistinguishes() {
        #expect(LocalOwner.isGuest("local:ABC"))
        #expect(!LocalOwner.isGuest(accountID))
        // An unstamped row is guest data until proven otherwise — the safe
        // reading, since it means a first sign-in carries it up.
        #expect(LocalOwner.isGuest(nil))
    }
}

// MARK: - Apple nonce

@Suite("Apple sign-in nonce")
struct AppleSignInTests {

    @Test("nonces are the requested length and never repeat")
    func nonceShape() {
        let a = AppleSignIn.makeNonce()
        let b = AppleSignIn.makeNonce()
        #expect(a.count == 32)
        #expect(a != b)
    }

    @Test("sha256 matches the known digest")
    func hashIsCorrect() {
        // Apple compares the hash inside the signed token against the raw nonce
        // we send Supabase, so this has to be a real SHA256 and not a stand-in.
        #expect(
            AppleSignIn.sha256("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}

// MARK: - Write path

@Suite("Ownership on save")
@MainActor
struct SaveStampingTests {

    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self,
            configurations: config
        )
        return ModelContext(container)
    }

    @Test("committing an item stamps owner and updatedAt")
    func commitStamps() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = ScheduleItem(title: "Run", createdAt: reference)
        vm.commit(item)

        #expect(item.ownerID != nil)
        #expect(item.updatedAt > .distantPast)
        #expect(item.syncedAt == nil)
    }

    @Test("toggling completion stamps the new Completion record too")
    func completionStamps() throws {
        let context = try inMemoryContext()
        let vm = ScheduleViewModel()
        vm.configure(context: context)

        let item = ScheduleItem(title: "Water", kind: .todo, recurrence: .everyDay, createdAt: reference)
        vm.commit(item)
        vm.toggleDone(item, on: reference)

        let completion = try #require(item.completions.first)
        #expect(completion.ownerID != nil)
        #expect(completion.updatedAt > .distantPast)
    }
}
