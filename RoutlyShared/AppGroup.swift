//
//  AppGroup.swift
//  RoutineOrganizerShared
//
//  The seam between the app and its widgets.
//
//  Two processes, one set of data. Everything the widget extension needs to read
//  — the schedule itself, and the handful of preferences that decide how it
//  looks — has to live somewhere both processes can reach, which on iOS means an
//  App Group container. This file is the single place that container is named.
//
//  Nothing here is optional-by-design: if the entitlement is missing, the group
//  URL comes back nil and the callers below fall back to the app's own sandbox.
//  That fallback exists so the app still runs (and tests still pass) without the
//  capability configured — the widget simply sees an empty store, which is a
//  quiet degrade rather than a crash.
//

import Foundation

enum AppGroup {

    /// The shared container both targets are entitled to.
    ///
    /// Must match the `com.apple.security.application-groups` entry in *both*
    /// entitlements files. A typo here is silent: the URL just comes back nil.
    static let identifier = "group.com.FilipOscar.Routly"

    /// The group container on disk, or nil when the entitlement isn't present.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Preferences both processes read. The app writes; the widget only reads.
    ///
    /// `UserDefaults(suiteName:)` returns nil for an unknown suite, so the
    /// fallback keeps every call site non-optional.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// True when the app is actually running with the group entitlement. Used to
    /// decide whether the store lives in the shared container or the app's own
    /// sandbox — never to gate features, since the app works either way.
    static var isAvailable: Bool { containerURL != nil }
}

// MARK: - Store location

/// Where the SwiftData store lives.
///
/// The store used to sit at SwiftData's default location inside the app's own
/// sandbox, which no extension can open. Moving it into the App Group container
/// is what makes the widget's completion button possible at all: an interactive
/// widget runs its `AppIntent` in the *extension's* process, so that process has
/// to be able to write the real store, not a copy of it.
enum SharedStore {

    /// The store file's name. Kept explicit rather than letting SwiftData pick,
    /// because the migration has to name the same file on both sides.
    static let filename = "default.store"

    /// The store URL inside the shared container, or nil without the entitlement.
    static var sharedURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(filename)
    }

    /// Where SwiftData would have put the store on its own — the pre-App-Group
    /// location, and the source the one-time migration copies from.
    static var legacyURL: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        .appendingPathComponent(filename)
    }

    /// The three files that together *are* the store.
    ///
    /// Copying only `default.store` and leaving the write-ahead log behind gives
    /// you a store that opens and is missing whatever hadn't been checkpointed —
    /// silent, partial data loss that looks like a successful migration. They
    /// move as a set or not at all.
    static let fileSuffixes = ["", "-wal", "-shm"]
}
