//
//  RoutlyApp.swift
//  RoutineOrganizer
//
//  Created by Filip Jaern on 20/07/2026.
//

import SwiftUI
import SwiftData

@main
struct RoutlyApp: App {

    init() {
        // Before anything reads a preference. `AppSettings.shared` is created
        // lazily on first touch, and that first touch happens inside the scene
        // below — so this is the last moment the old values can be moved across
        // without the settings object having already read an empty suite.
        SettingsMigration.migrateIfNeeded()
    }

    let modelContainer: ModelContainer = {
        let schema = SharedModelContainer.schema
        // Bound to the App Group container, so the widget extension opens the
        // same file. See `SharedModelContainer` — both processes go through it
        // precisely so they can't drift apart on schema or location.
        //
        // `appConfiguration()` also performs the one-time move of an existing
        // store into that container, and answers with the *old* location if that
        // move couldn't be verified. See `StoreMigration` for why that fallback
        // matters more than the widget working.
        let configuration = SharedModelContainer.appConfiguration()
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A store from an older shape can fail to migrate. This used to wipe
            // the store outright, which is untenable now that accounts exist: the
            // data being destroyed is exactly the data a first sign-in is meant to
            // rescue. Instead the old store is moved aside, so the app still
            // launches and nothing is unrecoverable.
            //
            // Note: "additive with a default" is NOT automatically safe, and
            // this recovery path cannot save you from the unsafe version.
            // Adding `var priority: Priority = .medium` — non-optional, custom
            // type, defaulted — shipped a launch crash: pre-existing rows decode
            // NULL for the new column and SwiftData *traps* ("Passed nil for a
            // non-optional keypath") inside the decoder, which is below this
            // `catch` and takes the process with it.
            //
            // The rule that actually holds: a new property must be an OPTIONAL
            // primitive, with a non-optional computed accessor supplying the
            // default (see `ScheduleItem.priority`).
            //
            // TODO: anything beyond that — renaming, retyping, or removing a
            // property — needs a real VersionedSchema + SchemaMigrationPlan.
            StoreRecovery.setAside(storeAt: configuration.url)
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Could not create ModelContainer after setting the old store aside: \(error)")
            }
        }
    }()

    /// Owns sign-in state and the local↔account data handover. Created here so a
    /// single instance spans the app; guest is the default and needs no setup.
    @State private var auth = AuthController()

    /// Present only to pin the app to portrait — see AppDelegate.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            // The colour scheme is owned by RootView, which reads the user's
            // appearance setting. Nothing is forced here.
            RootView()
                .environment(auth)
        }
        .modelContainer(modelContainer)
    }
}

/// Non-destructive handling of a store that refuses to open.
enum StoreRecovery {
    /// Set when a store had to be moved aside during launch, so the account
    /// screen can tell the user where their old data went instead of leaving
    /// them to assume it evaporated.
    private(set) nonisolated(unsafe) static var lastBackupURL: URL?

    /// Renames the SwiftData store and its sidecar files (-wal, -shm) rather than
    /// deleting them. Recoverable by hand, and never a silent data loss.
    static func setAside(storeAt url: URL) {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp)")

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: backup.path + suffix)
            do {
                try fm.moveItem(at: source, to: destination)
            } catch {
                // Only if the move itself fails is removal the lesser evil —
                // otherwise the app can never launch again.
                try? fm.removeItem(at: source)
            }
        }
        lastBackupURL = backup
    }
}
