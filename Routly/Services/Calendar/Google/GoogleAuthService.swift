//
//  GoogleAuthService.swift
//  RoutineOrganizer
//
//  Signing in to Google, staying signed in, and signing out.
//
//  Three pieces, deliberately separate:
//
//   • `GoogleTokenStore` — where tokens live. Keychain, never UserDefaults,
//     for the reason `KeychainStore` already states. Cached in memory the same
//     way `LocalOwner` caches the guest id, because `CalendarTarget.access()`
//     is synchronous and this app has already been bitten once by per-call file
//     I/O on the main thread.
//   • `GoogleAuthClient` — the two token endpoints, hand-rolled on URLSession
//     exactly as `SupabaseAuthClient` does GoTrue. Sendable, no UI, testable.
//   • `GoogleAuthService` — the main-actor front door that owns the browser
//     sheet and turns "I need a token" into either a token or a specific error.
//
//  The refresh rule worth naming: Google returns a refresh token **only on the
//  first consent** for a client. Every later refresh response omits it. So a
//  refresh merges over what is stored rather than replacing it — see
//  `GoogleTokens.merging(_:)`. Replacing would sign the person out an hour
//  later, silently, with nothing on screen to explain it.
//

import Foundation
import AuthenticationServices
import UIKit

// MARK: - Storage

enum GoogleTokenStore {

    private static let key = "google-calendar-tokens"

    /// Cached so the synchronous `access()` path doesn't hit the Keychain on
    /// every read. Same pattern, and same reasoning, as `LocalOwner.cached`.
    private nonisolated(unsafe) static var cached: GoogleTokens?
    private nonisolated(unsafe) static var didLoad = false

    static var current: GoogleTokens? {
        if didLoad { return cached }
        cached = KeychainStore.value(GoogleTokens.self, for: key)
        didLoad = true
        return cached
    }

    /// True when Routly holds a refresh token, whether or not the access token
    /// has gone stale. A stale access token is a round trip away from working;
    /// no refresh token means genuinely signed out.
    static var isSignedIn: Bool { current?.refreshToken != nil }

    static func save(_ tokens: GoogleTokens) {
        cached = tokens
        didLoad = true
        KeychainStore.store(tokens, for: key)
    }

    static func clear() {
        cached = nil
        didLoad = true
        KeychainStore.remove(key)
    }

    /// Test seam, mirroring `LocalOwner.resetCacheForTesting`.
    static func resetCacheForTesting() {
        cached = nil
        didLoad = false
    }
}

// MARK: - Network

struct GoogleAuthClient: Sendable {

    var session: URLSession = .shared

    /// Redeems the authorization code. The verifier is what proves this is the
    /// same app that started the flow; there is no client secret to send.
    func exchange(code: String, verifier: String, clientID: String, redirectURI: String) async throws -> GoogleTokens {
        try await token(form: [
            "code": code,
            "code_verifier": verifier,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
    }

    func refresh(refreshToken: String, clientID: String) async throws -> GoogleTokens {
        try await token(form: [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "grant_type": "refresh_token",
        ])
    }

    /// Best-effort server-side revocation, in the same spirit as
    /// `SupabaseAuthClient.signOut`: the local tokens are cleared either way,
    /// so a failure here is not worth blocking a sign-out on.
    func revoke(token: String) async {
        var request = URLRequest(url: GoogleCalendarConfig.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["token": token])
        _ = try? await session.data(for: request)
    }

    private func token(form: [String: String]) async throws -> GoogleTokens {
        var request = URLRequest(url: GoogleCalendarConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GoogleAuthError.network(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Self.failure(status: status, data: data)
        }
        guard let decoded = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else {
            throw GoogleAuthError.network(String(localized: "Google's reply couldn't be read."))
        }
        return decoded.tokens()
    }

    /// Maps Google's error body onto something a person can act on.
    ///
    /// `invalid_grant` is the one that matters: it means the refresh token is
    /// dead — revoked in the Google account, or expired while the app was in
    /// testing mode. Retrying can never fix it, so it becomes `.notSignedIn`
    /// and the UI asks for a fresh sign-in instead of failing forever.
    static func failure(status: Int, data: Data) -> GoogleAuthError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = body?["error"] as? String
        if code == "invalid_grant" { return .notSignedIn }
        let description = body?["error_description"] as? String ?? code
        return .denied(description ?? String(localized: "Google refused the request (\(status))."))
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        // `+` is a legal query character that form-encoding reads as a space,
        // so it has to be escaped here even though URLComponents leaves it.
        let encoded = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        return Data(encoded.utf8)
    }
}

// MARK: - Front door

@MainActor
final class GoogleAuthService {

    static let shared = GoogleAuthService()

    private let client: GoogleAuthClient
    /// Held for the sheet's lifetime — a session that goes out of scope is
    /// dismissed, and the callback never fires.
    private var pendingSession: ASWebAuthenticationSession?
    private let anchors = PresentationAnchors()

    init(client: GoogleAuthClient = GoogleAuthClient()) {
        self.client = client
    }

    var isSignedIn: Bool { GoogleTokenStore.isSignedIn }

    // MARK: Sign in

    func signIn() async throws {
        guard let clientID = GoogleCalendarConfig.clientID else {
            throw GoogleAuthError.notConfigured
        }
        guard let redirectURI = GoogleCalendarConfig.redirectURI(for: clientID),
              let scheme = GoogleCalendarConfig.callbackScheme(for: clientID) else {
            throw GoogleAuthError.malformedClientID
        }

        let pkce = PKCEPair.make()
        let code = try await authorize(clientID: clientID, redirectURI: redirectURI, scheme: scheme, pkce: pkce)
        let tokens = try await client.exchange(
            code: code,
            verifier: pkce.verifier,
            clientID: clientID,
            redirectURI: redirectURI
        )
        GoogleTokenStore.save(tokens)
    }

    func signOut() async {
        if let token = GoogleTokenStore.current?.refreshToken {
            await client.revoke(token: token)
        }
        GoogleTokenStore.clear()
        GoogleCalendarDirectory.forgetCalendarID()
    }

    // MARK: Tokens

    /// A usable access token, refreshing first if the stored one has gone
    /// stale. Throws `.notSignedIn` when there is nothing left to refresh with,
    /// which is the signal the UI turns into "connect again".
    func accessToken() async throws -> String {
        guard let stored = GoogleTokenStore.current else { throw GoogleAuthError.notSignedIn }
        if !stored.isExpired() { return stored.accessToken }

        guard let refreshToken = stored.refreshToken else { throw GoogleAuthError.notSignedIn }
        guard let clientID = GoogleCalendarConfig.clientID else { throw GoogleAuthError.notConfigured }

        do {
            let fresh = try await client.refresh(refreshToken: refreshToken, clientID: clientID)
            let merged = stored.merging(fresh)
            GoogleTokenStore.save(merged)
            return merged.accessToken
        } catch GoogleAuthError.notSignedIn {
            // The refresh token is dead. Clearing it is what stops every later
            // call retrying against a credential that can never work again.
            GoogleTokenStore.clear()
            throw GoogleAuthError.notSignedIn
        }
    }

    // MARK: Browser

    private func authorize(
        clientID: String,
        redirectURI: String,
        scheme: String,
        pkce: PKCEPair
    ) async throws -> String {
        var components = URLComponents(url: GoogleCalendarConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleCalendarConfig.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Both are required to be issued a refresh token at all. Without
            // them Routly would stop working an hour after sign-in.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else { throw GoogleAuthError.malformedClientID }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                self.pendingSession = nil
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled
                        ? GoogleAuthError.cancelled
                        : GoogleAuthError.denied(error.localizedDescription))
                    return
                }
                do {
                    continuation.resume(returning: try Self.code(from: callbackURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            session.presentationContextProvider = anchors
            // Deliberately not ephemeral: someone already signed into Google in
            // Safari should not have to type a password again to connect a
            // calendar.
            session.prefersEphemeralWebBrowserSession = false
            pendingSession = session

            guard session.start() else {
                pendingSession = nil
                continuation.resume(throwing: GoogleAuthError.denied(
                    String(localized: "Routly couldn't open the Google sign-in page.")
                ))
                return
            }
        }
    }

    /// Pulls the code out of the redirect, or the reason there isn't one.
    ///
    /// `error=access_denied` is what Google sends when someone presses Cancel
    /// on the consent screen — a decision, not a failure, so it maps to
    /// `.cancelled` and is never reported as something going wrong.
    nonisolated static func code(from url: URL?) throws -> String {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GoogleAuthError.noAuthorizationCode
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? GoogleAuthError.cancelled : GoogleAuthError.denied(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw GoogleAuthError.noAuthorizationCode
        }
        return code
    }
}

// MARK: - Presentation

/// Where the sign-in sheet hangs from. Retained by the service, because
/// `presentationContextProvider` is a weak reference and a provider that has
/// been deallocated makes the session fail to present with no error worth
/// reading.
@MainActor
private final class PresentationAnchors: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
