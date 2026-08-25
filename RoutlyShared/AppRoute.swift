//
//  AppRoute.swift
//  RoutineOrganizerShared
//
//  How a widget tap tells the app where to go.
//
//  There is no `routly://` URL scheme, on purpose. The app's Info.plist is
//  generated (`GENERATE_INFOPLIST_FILE`), which can express scalar keys and not
//  the nested array `CFBundleURLTypes` needs — so adopting a scheme would mean
//  hand-maintaining a plist for the whole app in order to serve three widget
//  taps. App Intents open the app without one, and work identically from a
//  lock-screen accessory.
//
//  What an intent can't do is *hand* the app a destination: `openAppWhenRun`
//  launches it and nothing more. So the intent leaves a note in the shared
//  defaults and the app reads it on activation.
//
//  The note is deliberately perishable. A route that outlived its tap would fire
//  the next time the app was opened for an unrelated reason — the app would
//  start recording because of a mic button pressed yesterday. So it carries a
//  timestamp, is consumed exactly once, and expires quickly.
//

import Foundation

extension Notification.Name {
    /// Posted in the app's process when an intent has just left a route.
    ///
    /// Only useful when the intent ran in-app (which `openAppWhenRun` does); it
    /// closes the ordering gap against `scenePhase`. See `OpenRoutlyIntent`.
    static let routlyPendingRoute = Notification.Name("routly.pendingRoute")
}

enum AppRoute: String, Sendable {
    /// Bring the to-do list to the front.
    case today
    /// Open already listening — see `VoiceLaunch`.
    case voiceCapture

    /// The scheme declared in `Config/RoutineOrganizer-Info.plist`.
    static let scheme = "routly"

    /// How a widget asks for this screen when an intent cannot.
    ///
    /// A lock-screen tap never runs an `openAppWhenRun` intent: iOS launches the
    /// app and drops the `perform()`, so `PendingRoute` is never written and the
    /// app opens knowing nothing. Verified in the log — the same widget on the
    /// home screen performs the intent in the app's own process, while from the
    /// lock screen no `perform` happens at all, even though the to-do
    /// checkbox's intent (which doesn't open the app) runs there fine.
    ///
    /// A URL survives that path, because the system carries it into the launch
    /// itself rather than asking the app to run code beforehand.
    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    /// The inverse, for `onOpenURL`. Unknown hosts are ignored rather than
    /// treated as `.today`: something else claiming this scheme must not be
    /// able to re-root the app.
    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let host = url.host(percentEncoded: false),
              let route = AppRoute(rawValue: host) else { return nil }
        self = route
    }
}

enum PendingRoute {

    private static let routeKey = "pendingRoute"
    private static let stampKey = "pendingRouteStamp"

    /// How long a tap stays meaningful.
    ///
    /// Long enough to cover a cold launch on a slow device, short enough that it
    /// can't survive into a later, unrelated open. Ten seconds is far more than
    /// a launch takes and far less than a pocket.
    static let window: TimeInterval = 10

    /// Set when the intent ran in this same process, which `openAppWhenRun`
    /// makes the normal case.
    ///
    /// This exists because the shared-defaults note is not always shared. If the
    /// App Groups entitlement isn't provisioned — which is exactly the state of a
    /// device build before the capability is enabled in the portal —
    /// `AppGroup.defaults` quietly falls back to `.standard`, and `.standard`
    /// belongs to *one* process. A note written on one side of that fallback is
    /// invisible on the other, and the symptom is precisely "the app opens but
    /// doesn't start recording".
    ///
    /// An in-memory slot needs no entitlement and no container, so the route
    /// survives however the app is configured. It's `nonisolated(unsafe)` for
    /// the same reason `CurrentOwner`'s cache is: written and read on the main
    /// actor in practice, and a lock here would buy nothing.
    private nonisolated(unsafe) static var inProcess: (route: AppRoute, at: Date)?

    /// Called by the intent. With `openAppWhenRun` this runs in the *app's*
    /// process, so both channels are written: the in-memory one always works,
    /// and the defaults note covers a cold launch where this process is replaced
    /// before the app's UI exists.
    ///
    /// `defaults` and `now` are injectable so the expiry rule can be tested
    /// without waiting ten seconds or writing into the real shared suite.
    static func set(_ route: AppRoute, now: Date = Date(), defaults: UserDefaults = AppGroup.defaults) {
        inProcess = (route, now)
        defaults.set(route.rawValue, forKey: routeKey)
        defaults.set(now.timeIntervalSince1970, forKey: stampKey)
    }

    /// Called by the app when it becomes active. Returns the route once and
    /// only once; a stale or absent note reads as nil.
    ///
    /// Clearing happens whether or not the route was still fresh — an expired
    /// note has already failed at its job and should not be reconsidered on the
    /// next activation.
    static func consume(now: Date = Date(), defaults: UserDefaults = AppGroup.defaults) -> AppRoute? {
        defer { clear(defaults: defaults) }

        // The in-memory slot first: it needs no entitlement, so it's the channel
        // that works in every configuration. Same freshness rule applies — a tap
        // from ten minutes ago must not start a recording now.
        if let pending = inProcess, now.timeIntervalSince(pending.at) < window {
            return pending.route
        }

        guard let raw = defaults.string(forKey: routeKey),
              let route = AppRoute(rawValue: raw) else { return nil }

        let stamp = defaults.double(forKey: stampKey)
        guard stamp > 0 else { return nil }
        let age = now.timeIntervalSince1970 - stamp
        // A negative age means the clock moved backwards between processes;
        // treat it as fresh rather than swallowing a tap the user just made.
        guard age < window else { return nil }

        return route
    }

    static func clear(defaults: UserDefaults = AppGroup.defaults) {
        inProcess = nil
        defaults.removeObject(forKey: routeKey)
        defaults.removeObject(forKey: stampKey)
    }
}
