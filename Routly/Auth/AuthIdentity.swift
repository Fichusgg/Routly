//
//  AuthIdentity.swift
//  RoutineOrganizer
//
//  The value types the auth layer trades in. Kept free of SwiftData, SwiftUI and
//  networking so the state machine and the migration planner stay unit-testable
//  without a store or a server.
//

import Foundation

/// How someone signed in. Sign in with Apple is the primary path; email exists
/// so the app isn't unusable for someone who'd rather not use an Apple ID.
enum AuthProvider: String, Codable, Sendable {
    case apple
    case email

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .email: return "Email"
        }
    }
}

/// The signed-in person, as far as this app is concerned.
struct AuthUser: Codable, Equatable, Sendable, Identifiable {
    /// Supabase user id (a UUID string). This becomes the `ownerID` stamped on
    /// every local row once the account claims them.
    let id: String
    let email: String?
    /// Only ever populated on the very first Sign in with Apple, and only when
    /// the person chose to share it — Apple never sends it again.
    var displayName: String?
    let provider: AuthProvider

    /// What to show in the account screen. Apple's private relay addresses are
    /// real and usable, but worth labelling so nobody thinks it's a mistake.
    var accountLabel: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let email, !email.isEmpty {
            return email.hasSuffix("@privaterelay.appleid.com") ? "\(email) (hidden)" : email
        }
        let name = provider.displayName
        return String(localized: "Signed in with \(name)")
    }
}

/// A session as persisted to the Keychain.
struct StoredSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var user: AuthUser

    /// Treated as expired a minute early so a request doesn't race the boundary.
    func isExpired(now: Date = Date()) -> Bool {
        now.addingTimeInterval(60) >= expiresAt
    }
}

/// What a sign-in attempt produced. Sign-up with email confirmation turned on
/// returns no session at all, which is a success the UI has to explain rather
/// than an error.
enum AuthOutcome: Equatable, Sendable {
    case session(StoredSession)
    case confirmationRequired(email: String)
}

/// Everything the auth layer can fail with, phrased for a person rather than a
/// log file. `cancelled` is deliberately separate: someone backing out of the
/// Apple sheet is not an error and must not surface as one.
enum AuthError: LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case offline
    case invalidCredentials
    case emailInUse
    case weakPassword
    case server(String)
    case invalidResponse
    case appleFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Accounts aren't set up in this build. Everything still works on this device.")
        case .cancelled:
            return nil
        case .offline:
            return String(localized: "Couldn't reach the server. Your data is safe on this phone.")
        case .invalidCredentials:
            return String(localized: "That email and password don't match.")
        case .emailInUse:
            return String(localized: "There's already an account with that email. Try signing in instead.")
        case .weakPassword:
            return String(localized: "Passwords need to be at least 8 characters.")
        case .server(let message):
            return message
        case .invalidResponse:
            return String(localized: "Got an unexpected reply from the server. Nothing on this phone changed.")
        case .appleFailed:
            return String(localized: "Sign in with Apple didn't complete. Nothing on this phone changed.")
        }
    }
}
