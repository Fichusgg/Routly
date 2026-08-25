//
//  GoogleCalendarConfig.swift
//  RoutineOrganizer
//
//  Everything the Google layer needs to exist, and the one thing that decides
//  whether it exists at all.
//
//  ── No SDK, and no secret ───────────────────────────────────────────────
//
//  The plan called for the GoogleSignIn SDK. This doesn't use it, for the
//  reason `SupabaseAuthClient` already states about the Supabase SDK: it would
//  be this project's first SPM dependency and a `project.pbxproj` edit, for
//  what is a standard OAuth 2.0 authorization-code flow and three REST calls.
//  `ASWebAuthenticationSession` is in the system, does the browser half, and —
//  unlike the SDK's `openURL` round trip — intercepts its own callback, so no
//  URL scheme has to be registered in Info.plist either.
//
//  **Nothing confidential ships in the binary.** An iOS OAuth client is a
//  *public* client: Google issues it no secret, and PKCE is what proves the
//  token request came from the same app that started the flow. The client ID is
//  as public as the Supabase anon key this app already ships, and for the same
//  reason — it identifies, it doesn't authorise.
//
//  ── Where events land ───────────────────────────────────────────────────
//
//  By default Routly makes its own "Routly" calendar in the person's Google
//  account and writes only there. That is worth the extra call: nothing else
//  writes to that calendar, so dedup, deletion and (later) change detection
//  have no other author to reason about — and in Google Calendar it shows up as
//  its own toggleable, colour-coded entry rather than mixed into someone's
//  primary calendar.
//
//  It also allows the narrowest scope that can do the job:
//  `calendar.app.created` reaches only calendars this app created. If Google's
//  consent screen turns out to classify that in a way you'd rather avoid, or
//  you simply want events in the primary calendar, `destination` and `scope`
//  below are the only two lines that change — see docs/google-calendar-setup.md.
//

import Foundation

enum GoogleCalendarConfig {

    // MARK: - Credentials

    /// The iOS OAuth client ID, from the gitignored `Secrets.plist`.
    ///
    /// Read through the same helper as every other secret in the app, so there
    /// is one mechanism rather than two.
    static var clientID: String? { AnthropicConfig.secret("GoogleClientID") }

    /// True only when there is a client ID to authorise with.
    ///
    /// This is what keeps Google out of the UI entirely until it can work:
    /// `CalendarSync.registry` omits the provider when this is false, and every
    /// surface is driven off the registry. No greyed-out row, no "coming soon".
    static var isConfigured: Bool { clientID != nil }

    // MARK: - Redirect

    /// Google's iOS convention: the client ID with its parts reversed, used as
    /// a private-use URL scheme.
    ///
    /// Derived rather than configured. It is a pure rearrangement of the client
    /// ID, so asking for it separately would only create a second value that
    /// can disagree with the first.
    static func callbackScheme(for clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        return "com.googleusercontent.apps." + String(clientID.dropLast(suffix.count))
    }

    static func redirectURI(for clientID: String) -> String? {
        callbackScheme(for: clientID).map { $0 + ":/oauth2redirect" }
    }

    // MARK: - Endpoints

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let calendarAPI = URL(string: "https://www.googleapis.com/calendar/v3")!

    // MARK: - Scope and destination

    /// Where Routly writes.
    enum Destination: Equatable, Sendable {
        /// A secondary calendar Routly creates and owns, by name.
        case dedicated(named: String)
        /// The account's primary calendar. Needs the broader `calendar.events`
        /// scope — see the file note.
        case primary

        var calendarIDIfFixed: String? {
            switch self {
            case .primary: return "primary"
            case .dedicated: return nil
            }
        }
    }

    /// The default. Change this and `scope` together, never one alone.
    static let destination: Destination = .dedicated(named: "Routly")

    /// The narrowest scope that covers `destination`.
    ///
    /// `calendar.app.created` — create secondary calendars, and read/write
    /// events on the ones this app created. It cannot see anything else in the
    /// person's account, which is both the honest ask and the smaller promise
    /// to keep.
    ///
    /// For `.primary`, this must become
    /// `https://www.googleapis.com/auth/calendar.events`.
    static let scope = "https://www.googleapis.com/auth/calendar.app.created"
}
