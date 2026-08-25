//
//  WidgetStore.swift
//  RoutineOrganizerShared
//
//  The widget's one read of the world.
//
//  Everything a timeline provider needs — the items, the user's preferences, and
//  the accent pushed into `ThemePalette` — comes from here in a single call, so
//  no provider has to remember the order those things have to happen in.
//
//  Failure is a first-class outcome rather than a thrown error: a widget whose
//  extension crashes shows the system's "Unable to Load" tile, which is the
//  worst possible answer to "what's on my list today". Every path below degrades
//  to an empty, honest snapshot instead.
//

import Foundation
import SwiftData

struct WidgetStore {

    /// Everything one timeline build needs.
    struct Reading {
        let items: [ScheduleItem]
        /// The user's lists, needed to tell "this list is empty" from "this list
        /// was deleted" when a widget is configured for one.
        let lists: [TodoList]
        let settings: AppSettings
        /// False when the store couldn't be opened at all — no App Group
        /// entitlement, or a store that won't migrate. The views treat it the
        /// same as "nothing to show", because from the user's side it is.
        let storeAvailable: Bool

        var knownListIDs: Set<UUID> { Set(lists.map(\.id)) }
    }

    /// Opens the shared store, reads every item, and applies the user's palette.
    ///
    /// The palette push matters: `Theme.Colors.accent` resolves through
    /// `ThemePalette`'s statics at draw time, and in a fresh extension process
    /// those statics start at the shipped default. Without this, every widget
    /// would render in stock blue no matter what the user chose.
    static func read() -> Reading {
        let settings = AppSettings(defaults: AppGroup.defaults)

        guard let container = SharedModelContainer.makeForWidget() else {
            return Reading(items: [], lists: [], settings: settings, storeAvailable: false)
        }

        let context = ModelContext(container)
        // Sorted by creation like the app's own query, so anything downstream
        // that falls back to insertion order agrees with the app.
        let descriptor = FetchDescriptor<ScheduleItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let items = (try? context.fetch(descriptor)) ?? []
        let lists = (try? context.fetch(
            FetchDescriptor<TodoList>(sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? []
        return Reading(items: items, lists: lists, settings: settings, storeAvailable: true)
    }
}
