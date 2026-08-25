//
//  AppleSignIn.swift
//  RoutineOrganizer
//
//  The nonce dance for Sign in with Apple, isolated from the UI so it can be
//  tested on its own.
//
//  ⚠️ Currently inert. Sign in with Apple needs the `com.apple.developer.applesignin`
//  entitlement, which requires a paid Apple Developer Program membership, so the
//  button is off and email is the only sign-in path. This file and
//  `AuthController.signInWithApple` are kept — and kept under test — because
//  turning Apple back on is then just the entitlement plus a `SignInWithAppleButton`
//  in SignInView, rather than rewriting the nonce handling from scratch.
//
//  How it works, since it's easy to get subtly wrong: we generate a random raw
//  nonce, hand Apple its SHA256 hash, and Apple embeds that hash in the signed
//  identity token. We then send Supabase the token *and* the raw nonce; the
//  server hashes the raw value and checks it matches what's inside the signed
//  token. An attacker who intercepts a token can't reuse it without the raw
//  nonce, which never leaves the device except in that one exchange.
//

import Foundation
import CryptoKit
import AuthenticationServices

enum AppleSignIn {

    /// A fresh cryptographically-random nonce, URL-safe.
    static func makeNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else { continue }
            // Reject values that would bias the distribution across the charset.
            guard byte < (255 - (255 % UInt8(charset.count))) else { continue }
            result.append(charset[Int(byte) % charset.count])
            remaining -= 1
        }
        return result
    }

    /// Lowercase hex SHA256 — the form Apple expects in `request.nonce`.
    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Pulls the identity token and (first-time-only) display name out of an
    /// Apple credential.
    static func extract(
        from authorization: ASAuthorization
    ) -> (idToken: String, displayName: String?)? {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            return nil
        }

        let name = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")

        return (idToken, name.isEmpty ? nil : name)
    }

    /// True when the failure is just someone backing out of the sheet, which
    /// must never be surfaced as an error.
    static func isCancellation(_ error: Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }
}
