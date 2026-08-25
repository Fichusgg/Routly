//
//  StoreMigration.swift
//  RoutineOrganizerShared
//
//  Moving the existing store into the App Group container, once.
//
//  **This is the one step in the widget work that can lose a person's data**, so
//  it is written to be paranoid rather than clever:
//
//   • The store is three files — `default.store`, `-wal`, `-shm`. They move as a
//     set. Copying only the first leaves behind whatever hadn't been
//     checkpointed, which looks like a successful migration and is silent,
//     partial data loss.
//   • It **copies**, verifies the copy actually opens, and only then sets the
//     original aside. Nothing is ever deleted — the old files are renamed, the
//     same way `StoreRecovery` does it, so a bad outcome stays recoverable by
//     hand.
//   • If the copy won't open, the app keeps using the **old** store for this
//     launch. The user's data is what matters; the widget reading an empty store
//     is a visible but harmless degrade, and far better than an app that appears
//     to have forgotten everything.
//
//  Nothing here runs in the widget extension. The extension only ever opens the
//  shared location, and must never touch the app's private sandbox.
//

import Foundation
import SwiftData

enum StoreMigration {

    /// Set once the copy has succeeded, so this never runs twice.
    static let doneKey = "storeMigratedToAppGroup"

    enum Outcome: Equatable {
        /// Already done, or there was never an old store to move.
        case notNeeded
        /// Copied, verified, and the original set aside.
        case migrated
        /// The copy didn't open. The old store is untouched and still in use.
        case failed
    }

    /// Where the app should open its store, having moved it if needed.
    ///
    /// Returns a URL rather than a Bool because the failure case has to change
    /// the answer: on `.failed` the honest thing is to keep reading the old
    /// location. nil means "no App Group at all" — SwiftData's default applies.
    static func resolvedStoreURL(
        legacy: URL? = SharedStore.legacyURL,
        shared: URL? = SharedStore.sharedURL,
        defaults: UserDefaults = AppGroup.defaults,
        fileManager: FileManager = .default,
        verify: (URL) -> Bool = Self.storeOpens
    ) -> URL? {
        guard let shared else { return nil }

        switch migrate(legacy: legacy, shared: shared,
                       defaults: defaults, fileManager: fileManager, verify: verify) {
        case .notNeeded, .migrated:
            return shared
        case .failed:
            // Keep the user's data reachable. The widget will read an empty
            // shared store until this is fixed, which is the lesser harm.
            return legacy
        }
    }

    /// The copy itself. Separated from `resolvedStoreURL` so it can be tested
    /// against temporary directories without touching a real container.
    @discardableResult
    static func migrate(
        legacy: URL?,
        shared: URL,
        defaults: UserDefaults = AppGroup.defaults,
        fileManager: FileManager = .default,
        verify: (URL) -> Bool = Self.storeOpens
    ) -> Outcome {
        guard defaults.object(forKey: doneKey) == nil else { return .notNeeded }

        // A store already in the shared container is authoritative. This can
        // happen if the app ran once with the group configured before this code
        // existed; overwriting it with an older copy would be a rollback of
        // whatever the user did in between.
        guard !fileManager.fileExists(atPath: shared.path) else {
            defaults.set(true, forKey: doneKey)
            return .notNeeded
        }

        guard let legacy, fileManager.fileExists(atPath: legacy.path) else {
            // A fresh install. Mark it done so this check stops running, and
            // let SwiftData create the store in the shared container itself.
            defaults.set(true, forKey: doneKey)
            return .notNeeded
        }

        // Copy the whole set. A partial copy is worse than none, so any failure
        // cleans up after itself and leaves the original alone.
        var copied: [URL] = []
        for suffix in SharedStore.fileSuffixes {
            let source = URL(fileURLWithPath: legacy.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: shared.path + suffix)
            do {
                try fileManager.createDirectory(
                    at: shared.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
                copied.append(destination)
            } catch {
                remove(copied, using: fileManager)
                return .failed
            }
        }

        // Prove it before trusting it. An unreadable copy that we'd already
        // renamed the original out from under would be unrecoverable.
        guard verify(shared) else {
            remove(copied, using: fileManager)
            return .failed
        }

        setAside(legacy, using: fileManager)
        defaults.set(true, forKey: doneKey)
        return .migrated
    }

    /// Opens the store to check it is readable. The schema has to match what the
    /// app uses, or a perfectly good copy would be judged broken.
    static func storeOpens(_ url: URL) -> Bool {
        let configuration = ModelConfiguration(schema: SharedModelContainer.schema, url: url)
        return (try? ModelContainer(for: SharedModelContainer.schema, configurations: [configuration])) != nil
    }

    /// Renames the old files out of the way. **Never deletes** — see the file
    /// note. Failure here is not fatal: the copy is already verified, so the
    /// worst case is a stale duplicate left on disk.
    private static func setAside(_ url: URL, using fileManager: FileManager) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        for suffix in SharedStore.fileSuffixes {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: url.path + ".moved-to-group-\(stamp)" + suffix)
            try? fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func remove(_ urls: [URL], using fileManager: FileManager) {
        for url in urls { try? fileManager.removeItem(at: url) }
    }
}
