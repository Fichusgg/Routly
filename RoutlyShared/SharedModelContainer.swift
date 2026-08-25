//
//  SharedModelContainer.swift
//  RoutineOrganizerShared
//
//  One store, opened the same way by both processes.
//
//  The app and the widget extension each build their own `ModelContainer`, but
//  they must agree exactly on the schema and the file on disk — so both go
//  through here rather than each spelling it out. A disagreement about either
//  would not be an error; it would be two processes quietly using two stores,
//  which looks like "the widget is always stale".
//

import Foundation
import SwiftData

enum SharedModelContainer {

    /// Every entity in the store. The widget only reads three of them, but a
    /// container must be told about the whole schema — a partial schema opens a
    /// store it can't fully decode.
    /// `CalendarLink` is listed even though the widget never reads one, for the
    /// reason stated above: a container must be told about the whole schema.
    /// Both targets compile this file, so the two processes cannot disagree —
    /// which is the failure this enum exists to make impossible.
    static var schema: Schema {
        Schema([
            ScheduleItem.self,
            Completion.self,
            TodoList.self,
            CalendarLink.self,
        ])
    }

    /// The store location both processes use.
    ///
    /// Falls back to SwiftData's own default when the App Group entitlement
    /// isn't present. That fallback keeps the app working — and unit tests
    /// running — on a build without the capability; the only casualty is that
    /// the widget then reads an empty store of its own, which is a quiet
    /// degrade rather than a crash.
    static var configuration: ModelConfiguration {
        if let url = SharedStore.sharedURL {
            return ModelConfiguration(schema: schema, url: url)
        }
        return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    }

    /// The app's configuration, having moved an existing store into the shared
    /// container if this is the first launch since widgets arrived.
    ///
    /// Separate from `configuration` because only the app may do this. The widget
    /// extension must never reach into the app's private sandbox — it opens the
    /// shared location and nothing else.
    ///
    /// The URL comes back from the migration rather than being assumed, because
    /// a migration that failed verification deliberately answers "keep using the
    /// old one". See `StoreMigration`.
    static func appConfiguration() -> ModelConfiguration {
        guard let url = StoreMigration.resolvedStoreURL() else {
            return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }
        return ModelConfiguration(schema: schema, url: url)
    }

    /// A container for the widget extension.
    ///
    /// Read-mostly: the completion intent writes through it, everything else
    /// only fetches. Returns nil rather than trapping, because a widget that
    /// can't open the store should render its empty state, not crash the
    /// extension — a crashed widget shows the system's "unable to load" tile,
    /// which is the worst possible answer to "what's on my list".
    static func makeForWidget() -> ModelContainer? {
        try? ModelContainer(for: schema, configurations: [configuration])
    }
}
