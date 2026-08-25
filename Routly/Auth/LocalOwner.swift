//
//  LocalOwner.swift
//  RoutineOrganizer
//
//  The device's guest identity.
//
//  The point of this file is small but load-bearing: a guest is not "a user with
//  no account", it's a user whose account is local. Every row carries an owner
//  from the moment it's created, so signing in later is a field rewrite rather
//  than a guess about which rows were "the old ones".
//
//  Stored in the Keychain rather than UserDefaults so the same device keeps its
//  identity across a delete-and-reinstall — someone who reinstalls before ever
//  signing in shouldn't have their remaining data orphaned under a stale owner.
//

import Foundation

enum LocalOwner {
    private static let key = "local-owner-id"

    /// Cached so the common path doesn't hit the Keychain on every save.
    private nonisolated(unsafe) static var cached: String?

    /// The guest owner id for this device, created on first access.
    static var current: String {
        if let cached { return cached }

        if let data = KeychainStore.data(for: key),
           let existing = String(data: data, encoding: .utf8),
           !existing.isEmpty {
            cached = existing
            return existing
        }

        let fresh = "local:\(UUID().uuidString)"
        if let data = fresh.data(using: .utf8) {
            KeychainStore.set(data, for: key)
        }
        cached = fresh
        return fresh
    }

    /// True when `ownerID` is this device's guest identity rather than an
    /// account. The `local:` prefix makes the two kinds impossible to confuse —
    /// a Supabase user id is a bare UUID.
    static func isGuest(_ ownerID: String?) -> Bool {
        guard let ownerID else { return true }
        return ownerID.hasPrefix("local:")
    }

    /// Test seam — resets the in-process cache so a suite can exercise the
    /// first-access path without touching the real Keychain item.
    static func resetCacheForTesting() {
        cached = nil
    }
}

/// Whoever owns rows written *right now* — the signed-in account if there is
/// one, otherwise this device's guest identity.
///
/// Exists so `ScheduleViewModel` can stamp ownership without taking a dependency
/// on `AuthController`, and without hitting the Keychain on every save.
/// `AuthController` is the only thing that sets it.
enum CurrentOwner {
    private nonisolated(unsafe) static var accountID: String?

    static var id: String {
        let resolved = accountID ?? LocalOwner.current
        // Published here rather than at each call site, because this is the one
        // point every answer passes through. The widget extension can't read the
        // Keychain this is ultimately backed by, so it reads the mirror instead
        // — see `SharedOwner`. `mirror` no-ops when nothing changed, so the
        // ordinary save path costs one defaults read.
        SharedOwner.mirror(resolved)
        return resolved
    }

    static func setAccount(_ id: String?) {
        accountID = id
        SharedOwner.mirror(id ?? LocalOwner.current)
    }
}
