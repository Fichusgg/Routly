//
//  StoreMigrationTests.swift
//  RoutineOrganizerTests
//
//  The one step in the widget work that can lose a person's data.
//
//  Everything else here is recoverable by deleting a widget. This moves the live
//  store, so each of these tests is a specific way it could destroy something,
//  written down and pinned:
//
//   • all three files move, not just the one that's easy to remember
//   • the original is *renamed*, never deleted
//   • the copy is proven to open before the original is touched at all
//   • a failed copy leaves the old store exactly where it was, still in use
//   • it runs once, and never overwrites a newer store already in the container
//
//  These run against temporary directories, so they exercise the real
//  FileManager work without going near a real App Group.
//

import Testing
import Foundation
@testable import Routly

private func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: UUID().uuidString)!
}

/// A legacy store and an empty shared directory, in a throwaway sandbox.
private struct Sandbox {
    let root: URL
    let legacy: URL
    let shared: URL

    init(legacyContents: [String: String] = [
        "": "main-store",
        "-wal": "write-ahead-log",
        "-shm": "shared-memory",
    ]) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-\(UUID().uuidString)")
        let old = root.appendingPathComponent("Application Support")
        let group = root.appendingPathComponent("AppGroup")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)

        legacy = old.appendingPathComponent("default.store")
        shared = group.appendingPathComponent("default.store")

        for (suffix, contents) in legacyContents {
            try contents.write(
                to: URL(fileURLWithPath: legacy.path + suffix),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func exists(_ url: URL, _ suffix: String = "") -> Bool {
        FileManager.default.fileExists(atPath: url.path + suffix)
    }

    func contents(_ url: URL, _ suffix: String = "") -> String? {
        try? String(contentsOf: URL(fileURLWithPath: url.path + suffix), encoding: .utf8)
    }

    /// Whatever the legacy store was renamed to, if anything.
    func setAsideFiles() -> [String] {
        let directory = legacy.deletingLastPathComponent()
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return all.filter { $0.contains(".moved-to-group-") }.sorted()
    }
}

@Suite("Store migration into the App Group")
struct StoreMigrationTests {

    // MARK: - The happy path, in detail

    @Test("all three files are copied, not just the store")
    func copiesTheWholeSet() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let outcome = StoreMigration.migrate(
            legacy: box.legacy, shared: box.shared,
            defaults: scratchDefaults(), verify: { _ in true }
        )

        #expect(outcome == .migrated)
        // The -wal is the one that matters: leaving it behind gives a store that
        // opens and is quietly missing recent writes.
        #expect(box.contents(box.shared) == "main-store")
        #expect(box.contents(box.shared, "-wal") == "write-ahead-log")
        #expect(box.contents(box.shared, "-shm") == "shared-memory")
    }

    @Test("the original is renamed, never deleted")
    func originalIsSetAside() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        StoreMigration.migrate(
            legacy: box.legacy, shared: box.shared,
            defaults: scratchDefaults(), verify: { _ in true }
        )

        // Gone from its old name...
        #expect(box.exists(box.legacy) == false)
        // ...but still on disk, recoverable by hand. Three files renamed, not
        // one: a half-renamed store is not recoverable.
        #expect(box.setAsideFiles().count == 3)
    }

    @Test("a store with no sidecar files still migrates")
    func handlesMissingSidecars() throws {
        // A cleanly-closed store may have no -wal or -shm at all. Their absence
        // is normal, not a failure.
        let box = try Sandbox(legacyContents: ["": "main-store"])
        defer { box.cleanUp() }

        let outcome = StoreMigration.migrate(
            legacy: box.legacy, shared: box.shared,
            defaults: scratchDefaults(), verify: { _ in true }
        )

        #expect(outcome == .migrated)
        #expect(box.contents(box.shared) == "main-store")
    }

    // MARK: - When the copy can't be trusted

    @Test("a copy that won't open is rolled back and the original left alone")
    func failedVerificationRollsBack() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let outcome = StoreMigration.migrate(
            legacy: box.legacy, shared: box.shared,
            defaults: scratchDefaults(), verify: { _ in false }
        )

        #expect(outcome == .failed)
        // No half-copied store left in the container to be opened later.
        #expect(box.exists(box.shared) == false)
        #expect(box.exists(box.shared, "-wal") == false)
        // And the user's data is exactly where it was, under its own name.
        #expect(box.contents(box.legacy) == "main-store")
        #expect(box.setAsideFiles().isEmpty)
    }

    @Test("a failed migration keeps the app reading the old store")
    func failureFallsBackToLegacy() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let url = StoreMigration.resolvedStoreURL(
            legacy: box.legacy, shared: box.shared,
            defaults: scratchDefaults(), verify: { _ in false }
        )

        // The whole point of returning a URL: the app must not silently open an
        // empty store while the real one sits next to it.
        #expect(url == box.legacy)
    }

    @Test("a failed migration is not marked done, so it can be retried")
    func failureIsRetryable() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let defaults = scratchDefaults()

        StoreMigration.migrate(legacy: box.legacy, shared: box.shared,
                               defaults: defaults, verify: { _ in false })
        #expect(defaults.object(forKey: StoreMigration.doneKey) == nil)

        // A later launch — or a later app version — gets another chance.
        let second = StoreMigration.migrate(legacy: box.legacy, shared: box.shared,
                                            defaults: defaults, verify: { _ in true })
        #expect(second == .migrated)
    }

    // MARK: - Running exactly once

    @Test("it runs once and doesn't re-copy on later launches")
    func runsOnce() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let defaults = scratchDefaults()

        #expect(StoreMigration.migrate(legacy: box.legacy, shared: box.shared,
                                       defaults: defaults, verify: { _ in true }) == .migrated)
        #expect(StoreMigration.migrate(legacy: box.legacy, shared: box.shared,
                                       defaults: defaults, verify: { _ in true }) == .notNeeded)
    }

    @Test("a store already in the container is never overwritten")
    func neverClobbersTheSharedStore() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try "newer-data".write(to: box.shared, atomically: true, encoding: .utf8)

        let outcome = StoreMigration.migrate(
            legacy: box.legacy, shared: box.shared,
            defaults: scratchDefaults(), verify: { _ in true }
        )

        // Copying over it would roll the user back to whatever they had before
        // the group was configured.
        #expect(outcome == .notNeeded)
        #expect(box.contents(box.shared) == "newer-data")
        #expect(box.contents(box.legacy) == "main-store")
    }

    @Test("a fresh install has nothing to move and says so")
    func freshInstall() throws {
        let box = try Sandbox(legacyContents: [:])
        defer { box.cleanUp() }
        let defaults = scratchDefaults()

        let outcome = StoreMigration.migrate(
            legacy: box.legacy, shared: box.shared,
            defaults: defaults, verify: { _ in true }
        )

        #expect(outcome == .notNeeded)
        // Marked done, so a store created later in the container is never
        // mistaken for something needing migration.
        #expect(defaults.bool(forKey: StoreMigration.doneKey))
    }

    @Test("no App Group means no migration and SwiftData's own default")
    func withoutAnAppGroup() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        // `shared: nil` is what a missing entitlement looks like.
        let url = StoreMigration.resolvedStoreURL(
            legacy: box.legacy, shared: nil,
            defaults: scratchDefaults(), verify: { _ in true }
        )

        #expect(url == nil)
        #expect(box.contents(box.legacy) == "main-store")
    }

    // MARK: - The real verifier

    @Test("the verifier rejects a file that isn't a store")
    func verifierRejectsGarbage() throws {
        let box = try Sandbox(legacyContents: [:])
        defer { box.cleanUp() }
        let junk = box.root.appendingPathComponent("not-a-store.store")
        try "this is not a SQLite database".write(to: junk, atomically: true, encoding: .utf8)

        // If this ever starts returning true, every other guarantee here rests
        // on a check that passes unconditionally.
        #expect(StoreMigration.storeOpens(junk) == false)
    }
}
