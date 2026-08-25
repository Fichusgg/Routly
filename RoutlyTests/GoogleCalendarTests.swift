//
//  GoogleCalendarTests.swift
//  RoutineOrganizerTests
//
//  The Google layer's failure modes are quieter than Apple's, because there is
//  a network and an account between Routly and the calendar. Three of them are
//  worth pinning here, and all three are pure functions:
//
//   • **A malformed PKCE challenge.** Sign-in just fails, with an error from
//     Google that describes nothing a reader can act on.
//   • **A refresh that erases the refresh token.** Google returns one only on
//     the first consent, so a merge that replaces rather than preserves signs
//     the person out an hour later, silently, forever.
//   • **A wrong event body.** Google accepts a surprising amount and stores it
//     wrong — a missing `reminders` block means the account's default alarm
//     fires on top of Routly's own notification, which nothing in the app would
//     ever show.
//
//  None of these needs a token, a network, or an account to test.
//

import Testing
import Foundation
@testable import Routly

private let sampleClientID = "1234567890-abcdefghijklmnop.apps.googleusercontent.com"

// MARK: - PKCE

@Suite("Google PKCE")
struct GooglePKCETests {

    /// RFC 7636's own worked example. A hand-rolled base64url or a hex digest
    /// where base64 was wanted both produce a plausible-looking string that
    /// Google rejects, so the check is against the spec's vector rather than
    /// against our own output.
    @Test("the challenge matches RFC 7636's test vector")
    func matchesSpecVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCEPair.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("a generated verifier is long enough and URL-safe")
    func verifierShape() {
        let pair = PKCEPair.make()
        // RFC 7636 puts the verifier between 43 and 128 characters.
        #expect(pair.verifier.count >= 43)
        #expect(pair.verifier.count <= 128)
        for value in [pair.verifier, pair.challenge] {
            #expect(!value.contains("+"), "base64url must not contain +: \(value)")
            #expect(!value.contains("/"), "base64url must not contain /: \(value)")
            #expect(!value.contains("="), "base64url must not be padded: \(value)")
        }
    }

    @Test("two flows never share a verifier")
    func verifiersAreUnique() {
        #expect(PKCEPair.make().verifier != PKCEPair.make().verifier)
    }

    @Test("the challenge is derived from the verifier it ships with")
    func challengeMatchesVerifier() {
        let pair = PKCEPair.make()
        #expect(pair.challenge == PKCEPair.challenge(for: pair.verifier))
    }
}

// MARK: - Config

@Suite("Google config")
struct GoogleConfigTests {

    /// The redirect URI is a rearrangement of the client ID, not a second
    /// value — so there is nothing to keep in sync and nothing to get wrong.
    @Test("the callback scheme is the client ID reversed")
    func reversesClientID() {
        #expect(
            GoogleCalendarConfig.callbackScheme(for: sampleClientID)
            == "com.googleusercontent.apps.1234567890-abcdefghijklmnop"
        )
        #expect(
            GoogleCalendarConfig.redirectURI(for: sampleClientID)
            == "com.googleusercontent.apps.1234567890-abcdefghijklmnop:/oauth2redirect"
        )
    }

    /// A web client ID, or a pasted project number, has to be refused rather
    /// than turned into a scheme that silently never receives a callback.
    @Test("anything that isn't an iOS client ID is refused")
    func rejectsMalformed() {
        #expect(GoogleCalendarConfig.callbackScheme(for: "1234567890") == nil)
        #expect(GoogleCalendarConfig.callbackScheme(for: "") == nil)
        #expect(GoogleCalendarConfig.redirectURI(for: "not-a-client-id") == nil)
    }

    /// The scope and the destination are one decision in two constants, and
    /// they are only correct together: `.dedicated` needs a scope that can
    /// create a calendar, `.primary` needs one that can write to somebody
    /// else's.
    @Test("the scope matches where events are written")
    func scopeMatchesDestination() {
        switch GoogleCalendarConfig.destination {
        case .dedicated:
            #expect(GoogleCalendarConfig.scope.hasSuffix("calendar.app.created"))
        case .primary:
            #expect(GoogleCalendarConfig.scope.hasSuffix("calendar.events"))
        }
    }
}

// MARK: - Tokens

@Suite("Google tokens")
struct GoogleTokenTests {

    private func tokens(expiresIn seconds: TimeInterval, refresh: String? = "refresh") -> GoogleTokens {
        GoogleTokens(
            accessToken: "access",
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(seconds),
            scope: nil
        )
    }

    @Test("a token near its expiry is treated as already expired")
    func expiryMargin() {
        #expect(tokens(expiresIn: 3600).isExpired() == false)
        // Inside the margin: still technically valid, but not for long enough
        // to survive the request that would use it.
        #expect(tokens(expiresIn: 30).isExpired())
        #expect(tokens(expiresIn: -1).isExpired())
    }

    /// The bug this prevents is a slow one: everything works for an hour, then
    /// the person is silently signed out with nothing on screen to explain it.
    @Test("a refresh response without a refresh token keeps the stored one")
    func mergePreservesRefreshToken() {
        let stored = tokens(expiresIn: -10, refresh: "the-only-one")
        let fresh = GoogleTokens(
            accessToken: "new-access",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scope: nil
        )

        let merged = stored.merging(fresh)

        #expect(merged.accessToken == "new-access")
        #expect(merged.refreshToken == "the-only-one")
        #expect(!merged.isExpired())
    }

    @Test("a refresh response that does carry one replaces it")
    func mergeTakesNewRefreshToken() {
        let merged = tokens(expiresIn: -10, refresh: "old").merging(
            GoogleTokens(accessToken: "a", refreshToken: "new", expiresAt: Date(), scope: nil)
        )
        #expect(merged.refreshToken == "new")
    }

    /// `expires_in` is a countdown from the moment of the reply and is
    /// meaningless once stored, so it is resolved to a date at the boundary.
    @Test("expires_in becomes an absolute time")
    func expiryIsAbsolute() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let response = GoogleTokenResponse(
            access_token: "a", refresh_token: "r", expires_in: 3600, scope: nil
        )
        #expect(response.tokens(now: now).expiresAt == now.addingTimeInterval(3600))
    }

    /// A reply with no expiry is treated as already stale: the next call spends
    /// one refresh. Assuming the other way spends a silent 401 loop.
    @Test("a reply with no expiry is treated as expired, not as eternal")
    func missingExpiryIsExpired() {
        let response = GoogleTokenResponse(
            access_token: "a", refresh_token: nil, expires_in: nil, scope: nil
        )
        #expect(response.tokens().isExpired())
    }
}

// MARK: - Redirect

@Suite("Google redirect")
struct GoogleRedirectTests {

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("the code is read out of the callback")
    func extractsCode() throws {
        let code = try GoogleAuthService.code(from: url("com.example:/oauth2redirect?code=abc123&scope=x"))
        #expect(code == "abc123")
    }

    /// Pressing Cancel on Google's consent screen sends `access_denied`. That
    /// is a decision, not a failure, and reporting it as an error would put an
    /// alert in front of someone who just changed their mind.
    @Test("access_denied is a cancellation, not an error")
    func deniedIsCancellation() {
        #expect(throws: GoogleAuthError.cancelled) {
            try GoogleAuthService.code(from: url("com.example:/oauth2redirect?error=access_denied"))
        }
    }

    @Test("any other error is reported as itself")
    func otherErrorsSurface() {
        #expect(throws: GoogleAuthError.denied("invalid_scope")) {
            try GoogleAuthService.code(from: url("com.example:/oauth2redirect?error=invalid_scope"))
        }
    }

    @Test("a callback with no code at all is refused")
    func noCode() {
        #expect(throws: GoogleAuthError.noAuthorizationCode) {
            try GoogleAuthService.code(from: url("com.example:/oauth2redirect"))
        }
        #expect(throws: GoogleAuthError.noAuthorizationCode) {
            try GoogleAuthService.code(from: nil)
        }
    }
}

// MARK: - Token endpoint

@Suite("Google token endpoint")
struct GoogleTokenEndpointTests {

    @Test("the form body is percent-encoded, including plus signs")
    func formEncoding() throws {
        let body = GoogleAuthClient.formBody(["code": "a+b/c", "client_id": "x y"])
        let text = try #require(String(data: body, encoding: .utf8))
        // A raw `+` in form encoding is read as a space, so it must not survive.
        #expect(!text.contains("a+b"))
        #expect(text.contains("%2B"))
        #expect(text.contains("client_id="))
    }

    /// The one error worth telling apart. `invalid_grant` means the refresh
    /// token is dead — revoked, or expired in testing mode — and no amount of
    /// retrying fixes it, so it has to end in "sign in again" rather than in a
    /// loop.
    @Test("invalid_grant means signed out, not a transient failure")
    func invalidGrantIsSignedOut() {
        let data = Data(#"{"error":"invalid_grant"}"#.utf8)
        #expect(GoogleAuthClient.failure(status: 400, data: data) == .notSignedIn)
    }

    @Test("other errors carry Google's own description through")
    func descriptionSurvives() {
        let data = Data(#"{"error":"invalid_scope","error_description":"Bad scope"}"#.utf8)
        #expect(GoogleAuthClient.failure(status: 400, data: data) == .denied("Bad scope"))
    }
}

// MARK: - Event body

@Suite("Google event body")
struct GoogleEventBodyTests {

    private let timeZone = TimeZone(identifier: "Europe/Madrid")!

    private func payload(isAllDay: Bool = false, notes: String? = nil) -> CalendarEventPayload {
        let start = Date(timeIntervalSince1970: 1_757_840_400)
        return CalendarEventPayload(
            title: "Lunch with Sam",
            notes: notes,
            start: start,
            end: start.addingTimeInterval(2700),
            isAllDay: isAllDay
        )
    }

    @Test("a timed event carries dateTime and a zone")
    func timedBounds() throws {
        let body = GoogleEventBody.json(for: payload(), timeZone: timeZone)
        let start = try #require(body["start"] as? [String: Any])
        #expect(start["dateTime"] is String)
        #expect(start["timeZone"] as? String == "Europe/Madrid")
        #expect(start["date"] == nil)
        #expect(body["summary"] as? String == "Lunch with Sam")
    }

    @Test("an all-day event carries a plain date instead")
    func allDayBounds() throws {
        let body = GoogleEventBody.json(for: payload(isAllDay: true), timeZone: timeZone)
        let start = try #require(body["start"] as? [String: Any])
        #expect(start["dateTime"] == nil)
        let date = try #require(start["date"] as? String)
        #expect(date.count == 10, "expected yyyy-MM-dd, got \(date)")
    }

    /// Left unspecified, Google applies the account's default alarm — so the
    /// person would be told twice about the same thing, once by Routly and once
    /// by Google. Silence here is a choice, and it's the wrong one.
    @Test("reminders are explicitly turned off, never left to the default")
    func remindersAreSilenced() throws {
        let reminders = try #require(GoogleEventBody.json(for: payload())["reminders"] as? [String: Any])
        #expect(reminders["useDefault"] as? Bool == false)
        #expect((reminders["overrides"] as? [Any])?.isEmpty == true)
    }

    @Test("notes become a description only when there are any")
    func notesAreOptional() {
        #expect(GoogleEventBody.json(for: payload())["description"] == nil)
        #expect(GoogleEventBody.json(for: payload(notes: ""))["description"] == nil)
        #expect(GoogleEventBody.json(for: payload(notes: "Bring the report"))["description"] as? String == "Bring the report")
    }

    /// The day string is a wire format, so it is built with a fixed locale and
    /// calendar. A Buddhist or Persian calendar locale would otherwise produce
    /// a year Google rejects — on the devices of the people least likely to
    /// report it.
    @Test("the day string is Gregorian whatever the device's calendar is")
    func dayStringIsGregorian() {
        let date = Date(timeIntervalSince1970: 1_757_840_400)
        let string = GoogleEventBody.dayString(date, timeZone: timeZone)
        #expect(string.hasPrefix("2025-") || string.hasPrefix("2026-"), "got \(string)")
        #expect(string.count == 10)
    }

    @Test("Google's updated stamp parses with or without milliseconds")
    func timestampParsing() {
        #expect(GoogleEventBody.parseTimestamp("2026-09-14T09:00:00.123Z") != nil)
        #expect(GoogleEventBody.parseTimestamp("2026-09-14T09:00:00Z") != nil)
        #expect(GoogleEventBody.parseTimestamp("not a date") == nil)
    }
}

// MARK: - API errors

@Suite("Google API errors")
struct GoogleAPIErrorTests {

    /// The token was refreshed a moment before the call, so a 401 here means
    /// the grant itself is gone rather than that the token was stale. Retrying
    /// can't fix it; asking for a fresh sign-in can.
    @Test("401 and 403 mean the connection is gone, not that a retry would help")
    func unauthorizedIsSignedOut() {
        let expected = CalendarTargetError.providerFailed(GoogleAuthError.notSignedIn.message)
        #expect(GoogleCalendarTarget.failure(status: 401, data: Data()) == expected)
        #expect(GoogleCalendarTarget.failure(status: 403, data: Data()) == expected)
    }

    @Test("Google's own message is carried through when it has one")
    func messageSurvives() {
        let data = Data(#"{"error":{"message":"Calendar usage limits exceeded."}}"#.utf8)
        #expect(
            GoogleCalendarTarget.failure(status: 429, data: data)
            == .providerFailed("Calendar usage limits exceeded.")
        )
    }
}

// MARK: - Registry

@MainActor
@Suite("Google registration")
struct GoogleRegistrationTests {

    /// With no client ID there is nothing Google can do, so it is absent rather
    /// than present-and-broken — no row in Settings, no line on the add sheet,
    /// no button that fails when pressed. Same degrade as Supabase accounts.
    @Test("Google is offered only when a client ID is configured")
    func presenceFollowsConfiguration() {
        let offered = CalendarSync.availableProviders.contains(.google)
        #expect(offered == GoogleCalendarConfig.isConfigured)
    }

    /// Apple needs no configuration and must never drop out of the registry.
    @Test("Apple is always available")
    func appleIsAlwaysThere() {
        #expect(CalendarSync.availableProviders.contains(.apple))
    }
}
