//
//  CalendarConnections.swift
//  RoutineOrganizer
//
//  What the UI knows about calendar permissions.
//
//  A thin observable cache over `CalendarTarget.access()`. It exists because
//  three separate surfaces — the add sheet's chips, the Settings screen, and
//  the reason line under the chips — all need the same answer, and asking
//  EventKit from inside a view body would be both a main-thread call and a
//  value SwiftUI has no way to observe changing.
//
//  Follows the `AppSettings.shared` pattern: one instance, referenced directly
//  rather than passed through the environment, so no call site or preview has
//  to be wired up to get it.
//

import Foundation

@MainActor
@Observable
final class CalendarConnections {

    static let shared = CalendarConnections()

    /// Last known answer per provider. Absent means never asked EventKit —
    /// which is not the same as `.notDetermined` (never asked *the user*), so
    /// the two are kept distinct rather than conflated.
    private(set) var access: [CalendarProvider: CalendarAccess] = [:]

    /// Providers this build can offer at all.
    var providers: [CalendarProvider] { CalendarSync.availableProviders }

    init() {
        refresh()
    }

    /// Re-reads every provider's status. Cheap — `EKEventStore` answers this
    /// from a static without touching the store — so it's fine to call on
    /// appear, and it must be, since the user can change the grant in Settings
    /// while the app is backgrounded.
    func refresh() {
        var updated: [CalendarProvider: CalendarAccess] = [:]
        for provider in providers {
            updated[provider] = CalendarSync.target(for: provider)?.access() ?? .denied
        }
        access = updated
    }

    func access(for provider: CalendarProvider) -> CalendarAccess {
        access[provider] ?? .notDetermined
    }

    /// True when Routly can put events into this calendar right now.
    func canCreate(_ provider: CalendarProvider) -> Bool {
        access(for: provider).canCreate
    }

    /// True when Routly can also change and remove what it put there. The
    /// difference between this and `canCreate` is the whole of the write-only
    /// story — see `CalendarAccess`.
    func canModify(_ provider: CalendarProvider) -> Bool {
        access(for: provider).canModify
    }

    /// Put the permission question to the user and record the answer.
    ///
    /// Returns the resulting access so a caller can act on the answer in the
    /// same breath — the add sheet ticks its chip only if the grant arrived.
    ///
    /// **A successful grant also makes this calendar a destination for new
    /// events.** That is not a convenience, it is the fix for a real bug: the
    /// Settings screen used to grant permission and change nothing else, so it
    /// said "Connected" while every event still went only to Routly. Going to
    /// Settings and connecting a calendar is about as clear as someone can be
    /// that they want their events in it; a status word that means "we asked
    /// iOS a question once" is not what they were reading. The toggle on that
    /// screen is how they take it back — and it is the only place the question
    /// is asked, since the add sheet no longer carries a per-event chooser.
    @discardableResult
    func connect(_ provider: CalendarProvider) async -> CalendarAccess {
        guard let target = CalendarSync.target(for: provider) else { return .denied }
        let result = await target.requestAccess()
        access[provider] = result
        if result.canCreate {
            AppSettings.shared.setCalendarDestination(provider, enabled: true)
        }
        return result
    }

    /// True when this connection is Routly's to hand back — Google's is, the
    /// system calendar grant isn't. See `CalendarTarget.canDisconnect`.
    func canDisconnect(_ provider: CalendarProvider) -> Bool {
        CalendarSync.target(for: provider)?.canDisconnect ?? false
    }

    /// Hand the connection back and stop sending new events there.
    ///
    /// The destination switch goes off with it. Leaving it on would mean a
    /// disconnected calendar still described as somewhere events go, and the
    /// next sign-in would silently resume writing to it.
    func disconnect(_ provider: CalendarProvider) async {
        guard let target = CalendarSync.target(for: provider) else { return }
        await target.disconnect()
        AppSettings.shared.setCalendarDestination(provider, enabled: false)
        refresh()
    }

    /// What the Settings row says on the right.
    func statusLabel(for provider: CalendarProvider) -> String {
        switch access(for: provider) {
        case .notDetermined: return String(localized: "Not connected")
        case .denied: return String(localized: "Denied")
        case .restricted: return String(localized: "Unavailable")
        case .writeOnly: return String(localized: "Limited")
        case .full: return String(localized: "Connected")
        }
    }

    /// The sentence under a provider's row.
    ///
    /// A connected calendar used to return nil here, on the theory that
    /// "Connected" speaks for itself. It doesn't: it says a permission was
    /// granted, and people read it as "my events go here now" — which is a
    /// different claim, and was the one thing the screen wasn't saying. So the
    /// connected state now describes what actually happens to new events, and
    /// the answer depends on the toggle rather than on the grant.
    func statusDetail(for provider: CalendarProvider) -> String? {
        switch access(for: provider) {
        case .full:
            return AppSettings.shared.isCalendarDestinationEnabled(provider)
                ? String(localized: "Every new event with a day on it goes here automatically.")
                : String(localized: "Routly can add events here. Turn on “Add new events here” and every new event will go automatically.")
        case .notDetermined:
            return provider == .google
                ? String(localized: "Connect your Google account to send events there.")
                : String(localized: "Routly will ask for permission the first time you add an event here.")
        case .denied:
            // Only Apple can land here: a Google refusal leaves the state
            // unchanged rather than recording a denial, because backing out of
            // a sign-in sheet is not the same as saying no.
            return String(localized: "Turn Calendars on for Routly in the Settings app to add events here.")
        case .restricted:
            // For Google this means no client ID in the build rather than a
            // device restriction, and the two need different sentences — the
            // first is something the developer fixes, the second something
            // nobody can.
            return provider == .google
                ? String(localized: "Google Calendar isn't set up in this build.")
                : String(localized: "This device doesn't allow calendar access.")
        case .writeOnly:
            // The honest description of add-only. Worth its own sentence rather
            // than being rounded to "connected": events already added will
            // silently stop matching what Routly shows, and the person deserves
            // to know that before it happens rather than after.
            return String(localized: "Routly can add events here but can't change or remove them. Allow full access in the Settings app to keep them in step.")
        }
    }
}
