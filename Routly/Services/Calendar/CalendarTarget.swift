//
//  CalendarTarget.swift
//  RoutineOrganizer
//
//  The one interface every calendar provider is reached through.
//
//  It exists so that Google is a *second conformer* rather than a second code
//  path: the planner, the push loop, the dedup rule and the UI all speak to
//  this protocol, and none of them will change when Google arrives. It is also
//  the test seam — `FakeCalendarTarget` in the suite conforms to it, so every
//  rule about what gets created, updated, removed or skipped is verifiable
//  without a permission grant, a network, or a device.
//
//  Conformers are actors, not structs. `EKEventStore`'s save and fetch calls
//  are synchronous and can take real time, and this app has already paid once
//  for synchronous work on the main actor (see the device-log findings in
//  WIP-NOTES). Actor isolation keeps that work off the main thread by
//  construction rather than by everyone remembering to wrap it.
//

import Foundation

protocol CalendarTarget: Sendable {

    /// Which provider this is. `nonisolated` on conformers — it's a constant.
    var provider: CalendarProvider { get }

    /// What the provider will currently let us do, without asking the user
    /// anything. Cheap enough to call from a view body's `task`.
    func access() -> CalendarAccess

    /// Put the permission question to the user, if it hasn't been asked.
    /// Returns the answer, whatever it is — a denial is a result, not an error.
    func requestAccess() async -> CalendarAccess

    /// Write a new event and answer with where it landed.
    func create(_ payload: CalendarEventPayload) async throws -> CalendarEventRef

    /// Rewrite the event at `ref`. Throws `.eventMissing`-shaped errors rather
    /// than silently creating a replacement: a vanished event is a fact the
    /// caller has to record, not something to paper over by making a second one.
    func update(_ payload: CalendarEventPayload, at ref: CalendarEventRef) async throws -> CalendarEventRef

    /// Delete the event at `ref`.
    ///
    /// **Idempotent by contract.** An event that is already gone is a success,
    /// not a failure — the caller's goal is "this must not be in the calendar",
    /// and it isn't. Treating it as an error would leave the link permanently
    /// stuck trying to delete something nobody can find.
    func remove(_ ref: CalendarEventRef) async throws

    /// Whether this provider's connection is Routly's to give back.
    ///
    /// The two providers differ genuinely here, and flattening the difference
    /// would produce a lie either way. Apple's grant belongs to iOS: a
    /// Routly-side "disconnect" that left the system permission in place would
    /// be a second, contradictory source of truth, so EventKit answers false
    /// and the UI points at the Settings app instead. Google's connection is a
    /// token this app holds, and holding somebody's credential with no way to
    /// hand it back is not a defensible position — so it answers true.
    var canDisconnect: Bool { get }

    /// Give the connection back. A no-op where `canDisconnect` is false.
    func disconnect() async
}

extension CalendarTarget {
    var canDisconnect: Bool { false }
    func disconnect() async {}
}
