//
//  OpenRoutlyIntent.swift
//  RoutineOrganizerShared
//
//  The two taps that open the app: the to-do widget's body, and the mic.
//
//  One intent with a destination rather than two nearly identical ones, so the
//  perishable-note mechanism in `PendingRoute` has exactly one writer.
//
//  **This file must be in the shared folder, not the widget's.** `openAppWhenRun`
//  works by launching the app and having *the app* perform the intent, so the
//  app's own App Intents metadata has to contain it. With the file compiled only
//  into the extension, the app bundle gets no `Metadata.appintents` at all, the
//  system has nothing to launch into, and tapping the mic does nothing
//  whatsoever — no app, no error, no clue. Verified on the simulator: that is
//  exactly what happened before it moved here.
//

import AppIntents
import Foundation

struct OpenRoutlyIntent: AppIntent {

    static var title: LocalizedStringResource = "Open Routly"

    /// The whole point: this intent exists to launch the app.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Destination")
    var route: String

    init() {
        self.route = AppRoute.today.rawValue
    }

    init(_ route: AppRoute) {
        self.route = route.rawValue
    }

    func perform() async throws -> some IntentResult {
        PendingRoute.set(AppRoute(rawValue: route) ?? .today)

        // Two channels, because the ordering between this `perform()` and the
        // app's own activation is not specified. The note above is the durable
        // one and survives a cold launch; this notification covers the case
        // where the app was already alive and had its `scenePhase` change *fire
        // before* the route was written, which would otherwise mean a tap that
        // opened the app and then did nothing. Whichever arrives second finds
        // the note already consumed and no-ops.
        await MainActor.run {
            NotificationCenter.default.post(name: .routlyPendingRoute, object: nil)
        }
        return .result()
    }
}
