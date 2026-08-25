//
//  GoogleOAuth.swift
//  RoutineOrganizer
//
//  The OAuth 2.0 authorization-code flow with PKCE, and the tokens it produces.
//
//  Split from the network client so the fiddly, get-it-wrong-silently parts —
//  generating a verifier, deriving its challenge, deciding whether a token has
//  expired — are pure functions with tests, rather than things you find out
//  about when a sign-in mysteriously fails.
//
//  ── Why PKCE, and why there is no secret ────────────────────────────────
//
//  A native app cannot keep a secret: anything in the binary can be read out of
//  it. So Google issues iOS clients no secret at all, and PKCE replaces it. We
//  invent a random `verifier`, send Google only its SHA256 hash (the
//  `challenge`) when starting the flow, and present the raw verifier when
//  redeeming the code. An attacker who intercepts the redirect gets a code they
//  cannot exchange, because they never saw the verifier.
//

import Foundation
import CryptoKit

// MARK: - PKCE

/// One flow's verifier and the challenge derived from it.
struct PKCEPair: Equatable, Sendable {
    let verifier: String
    let challenge: String

    /// RFC 7636 puts the verifier between 43 and 128 characters of unreserved
    /// ASCII. 32 random bytes base64url-encoded is 43 — the shortest legal
    /// value, and 256 bits of entropy.
    static func make(bytes: Int = 32) -> PKCEPair {
        let verifier = randomBase64URL(bytes: bytes)
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomBase64URL(bytes count: Int) -> String {
        var raw = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &raw) != errSecSuccess {
            // Never silently proceed with predictable bytes: a guessable
            // verifier is the one thing PKCE exists to prevent. `SystemRandom`
            // is a genuine CSPRNG, so this is a fallback, not a downgrade.
            raw = (0..<count).map { _ in UInt8.random(in: .min ... .max) }
        }
        return base64URL(Data(raw))
    }

    /// base64url without padding — the encoding RFC 7636 asks for. Plain
    /// base64's `+`, `/` and `=` are all unsafe in a query parameter.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Tokens

/// What Google hands back, plus the one thing it doesn't: when the access token
/// stops working, as an absolute time rather than a duration.
///
/// `expires_in` is a countdown from the moment of the response, which is
/// useless once stored — a token written to the Keychain with "3600 seconds
/// left" is still claiming that tomorrow. Resolving it to a date at the point
/// of decoding is what makes `isExpired` answerable at all.
struct GoogleTokens: Codable, Equatable, Sendable {
    var accessToken: String
    /// Google returns a refresh token only on the *first* consent for a client,
    /// so a refresh response carries none and must not erase the stored one.
    var refreshToken: String?
    var expiresAt: Date
    var scope: String?

    /// Treated as expired slightly early, so a token doesn't lapse between the
    /// check and the request that uses it.
    static let expiryMargin: TimeInterval = 60

    func isExpired(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) <= Self.expiryMargin
    }

    /// Merges a refresh response over the stored tokens.
    ///
    /// The refresh token is carried forward when the response omits one — which
    /// is the normal case. Overwriting it with nil would sign the person out
    /// silently, an hour later, for no reason they could see.
    func merging(_ fresh: GoogleTokens) -> GoogleTokens {
        GoogleTokens(
            accessToken: fresh.accessToken,
            refreshToken: fresh.refreshToken ?? refreshToken,
            expiresAt: fresh.expiresAt,
            scope: fresh.scope ?? scope
        )
    }
}

/// The wire shape of a token response, kept separate from `GoogleTokens` so the
/// relative-to-absolute conversion happens exactly once, at the boundary.
struct GoogleTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
    let scope: String?

    func tokens(now: Date = Date()) -> GoogleTokens {
        GoogleTokens(
            accessToken: access_token,
            refreshToken: refresh_token,
            // A response with no `expires_in` is treated as already expired
            // rather than as eternal: the next call refreshes, which costs one
            // round trip. Assuming the other way costs a silent 401 loop.
            expiresAt: now.addingTimeInterval(expires_in ?? 0),
            scope: scope
        )
    }
}

// MARK: - Errors

enum GoogleAuthError: Error, Equatable, Sendable {
    /// No client ID in Secrets.plist. Google isn't offered at all in this case,
    /// so reaching here means something bypassed the registry.
    case notConfigured
    /// The client ID isn't in the form Google issues, so no redirect URI can be
    /// derived from it.
    case malformedClientID
    /// The person closed the sign-in sheet. Not a failure worth reporting.
    case cancelled
    /// Google refused, or the redirect carried an `error` parameter.
    case denied(String)
    /// The redirect came back without a code.
    case noAuthorizationCode
    /// Signed out, or the refresh token was revoked. The person has to sign in
    /// again, and the UI says so rather than retrying forever.
    case notSignedIn
    case network(String)

    var message: String {
        switch self {
        case .notConfigured:
            return String(localized: "Google Calendar isn't set up in this build.")
        case .malformedClientID:
            return String(localized: "The Google client ID in Secrets.plist isn't in the expected form.")
        case .cancelled:
            return String(localized: "Sign-in was cancelled.")
        case .denied(let detail):
            return detail
        case .noAuthorizationCode:
            return String(localized: "Google didn't complete the sign-in.")
        case .notSignedIn:
            return String(localized: "Routly is signed out of Google. Connect it again to keep sending events.")
        case .network(let detail):
            return detail
        }
    }
}
