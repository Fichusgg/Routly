//
//  AuthController.swift
//  RoutineOrganizer
//
//  The one object the UI talks to about accounts. Owns sign-in state, persists
//  the session to the Keychain, and runs the local→account handover.
//
//  Two rules shape everything here:
//
//  1. Guest is the default and is never a degraded mode. If Supabase isn't
//     configured, if the network is down, if sign-in fails — the app is exactly
//     the app it was before, with every feature intact.
//  2. Nothing in the UI ever awaits the network to show local data. The only
//     thing that spins is the sign-in button itself.
//
//  It follows the existing `ScheduleViewModel` pattern of taking its
//  `ModelContext` via `configure(context:)` rather than reaching for one.
//

import Foundation
import SwiftData
import AuthenticationServices

@MainActor
@Observable
final class AuthController {

    /// One account per device for v1, so this is a simple two-state machine
    /// rather than a list of identities.
    enum State: Equatable {
        case guest
        case signedIn(AuthUser)

        var user: AuthUser? {
            if case .signedIn(let user) = self { return user }
            return nil
        }

        var isSignedIn: Bool { user != nil }
    }

    /// A fork that needs the person to settle it before anything changes.
    struct PendingMigration: Identifiable, Equatable {
        let id = UUID()
        let accountID: String
        let localItems: Int
        let remoteItems: Int
    }

    private(set) var state: State = .guest
    private(set) var isBusy = false

    /// Surfaced by the account and sign-in screens. Never an error code.
    var errorMessage: String?

    /// Set after a successful handover so the account screen can say what moved.
    private(set) var lastMigration: DataOwnership.Summary?

    /// Non-nil while the merge / keep-local / keep-cloud question is open.
    var pendingMigration: PendingMigration?

    /// Shown once after a sign-up that needs an emailed confirmation link.
    var awaitingConfirmationFor: String?

    private let client: SupabaseAuthClient
    private let probe: RemoteDataProbe
    private var context: ModelContext?

    private static let sessionKey = "supabase-session"

    init(client: SupabaseAuthClient = SupabaseAuthClient(), probe: RemoteDataProbe = UncheckedRemoteProbe()) {
        self.client = client
        self.probe = probe
    }

    /// True when this build can offer accounts at all. When false the account
    /// screen says so plainly instead of showing a button that can't work.
    var isConfigured: Bool { SupabaseConfig.isConfigured }

    // MARK: - Lifecycle

    func configure(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        restoreSession()
        backfillOwnership()
    }

    /// Reads any stored session back at launch. Deliberately synchronous and
    /// offline: an expired access token still identifies the account, and the
    /// refresh can happen later without holding up launch.
    private func restoreSession() {
        guard let stored = KeychainStore.value(StoredSession.self, for: Self.sessionKey) else { return }
        state = .signedIn(stored.user)
        CurrentOwner.setAccount(stored.user.id)

        if stored.isExpired() {
            Task { await refreshIfNeeded() }
        }
    }

    /// Stamps this device's guest id onto any row that predates ownership.
    /// Cheap, idempotent, and it means a later sign-in has an unambiguous set
    /// of rows to hand over.
    private func backfillOwnership() {
        guard let context else { return }
        let owner = state.user?.id ?? LocalOwner.current
        guard let items = try? context.fetch(FetchDescriptor<ScheduleItem>()),
              let completions = try? context.fetch(FetchDescriptor<Completion>()) else { return }
        // Links are fetched separately rather than walked from `items`, so a
        // link whose item has gone is still stamped rather than skipped.
        let links = (try? context.fetch(FetchDescriptor<CalendarLink>())) ?? []

        let summary = DataOwnership.backfill(
            items: items,
            completions: completions,
            links: links,
            owner: owner
        )
        if !summary.isEmpty { try? context.save() }
    }

    // MARK: - Sign in

    /// Not reachable from the UI right now — Sign in with Apple is switched off
    /// until there's a paid Apple Developer membership to carry its entitlement.
    /// See the note in `AppleSignIn.swift`.
    func signInWithApple(_ result: Result<ASAuthorization, Error>, nonce: String) async {
        switch result {
        case .failure(let error):
            // Backing out of the sheet is not a failure worth reporting.
            guard !AppleSignIn.isCancellation(error) else { return }
            errorMessage = AuthError.appleFailed.errorDescription

        case .success(let authorization):
            guard let extracted = AppleSignIn.extract(from: authorization) else {
                errorMessage = AuthError.appleFailed.errorDescription
                return
            }
            await run {
                try await self.client.signInWithApple(
                    idToken: extracted.idToken,
                    nonce: nonce,
                    displayName: extracted.displayName
                )
            }
        }
    }

    func signIn(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        await run { try await self.client.signIn(email: email, password: password) }
    }

    func signUp(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard password.count >= 8 else {
            errorMessage = AuthError.weakPassword.errorDescription
            return
        }
        await run { try await self.client.signUp(email: email, password: password) }
    }

    /// Shared shell for every sign-in path: busy flag, error mapping, and the
    /// handover on success.
    private func run(_ operation: @escaping () async throws -> AuthOutcome) async {
        guard isConfigured else {
            errorMessage = AuthError.notConfigured.errorDescription
            return
        }

        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            switch try await operation() {
            case .confirmationRequired(let email):
                awaitingConfirmationFor = email
            case .session(let session):
                await adopt(session)
            }
        } catch let error as AuthError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = AuthError.server(error.localizedDescription).errorDescription
        }
    }

    /// Persists a new session and routes the data handover.
    private func adopt(_ session: StoredSession) async {
        KeychainStore.store(session, for: Self.sessionKey)
        state = .signedIn(session.user)

        // Read the guest count *before* switching the owner over, or new writes
        // would already be landing under the account id.
        let localItems = guestItemCount()
        CurrentOwner.setAccount(session.user.id)
        let remote = await probe.probe(accountID: session.user.id)

        switch MigrationPlanner.route(localItems: localItems, remote: remote) {
        case .nothingToDo:
            lastMigration = nil
        case .claimLocally:
            lastMigration = claimGuestData(to: session.user.id)
        case .askUser(let local, let remoteCount):
            // Nothing is touched until the person answers.
            pendingMigration = PendingMigration(
                accountID: session.user.id,
                localItems: local,
                remoteItems: remoteCount
            )
        }
    }

    // MARK: - Migration

    /// Applies the choice made in the merge / keep-local / keep-cloud sheet.
    ///
    /// Only `.merge` and `.keepLocal` can be honoured locally today — both come
    /// down to claiming this device's rows for the account, and differ only in
    /// what the *sync* layer will later do with the cloud copy. `.keepCloud`
    /// needs a download that doesn't exist yet, so it deliberately leaves local
    /// data untouched rather than clearing it and having nothing to restore.
    func resolve(_ choice: MigrationChoice) {
        guard let pending = pendingMigration else { return }
        defer { pendingMigration = nil }

        switch choice {
        case .merge, .keepLocal:
            lastMigration = claimGuestData(to: pending.accountID)
        case .keepCloud:
            lastMigration = nil
        }
    }

    private func claimGuestData(to accountID: String) -> DataOwnership.Summary? {
        guard let context,
              let items = try? context.fetch(FetchDescriptor<ScheduleItem>()),
              let completions = try? context.fetch(FetchDescriptor<Completion>()) else { return nil }
        let links = (try? context.fetch(FetchDescriptor<CalendarLink>())) ?? []

        let summary = DataOwnership.claim(
            items: items,
            completions: completions,
            links: links,
            from: LocalOwner.current,
            to: accountID
        )
        try? context.save()
        return summary.isEmpty ? nil : summary
    }

    private func guestItemCount() -> Int {
        guard let context,
              let items = try? context.fetch(FetchDescriptor<ScheduleItem>()) else { return 0 }
        return items.filter { $0.ownerID == LocalOwner.current || $0.ownerID == nil }.count
    }

    /// How much data is on this device waiting to be claimed — what the sign-in
    /// screen offers to protect.
    var guestDataSummary: DataOwnership.Summary {
        guard let context,
              let items = try? context.fetch(FetchDescriptor<ScheduleItem>()),
              let completions = try? context.fetch(FetchDescriptor<Completion>()) else {
            return DataOwnership.Summary()
        }
        return DataOwnership.guestCount(items: items, completions: completions, guestOwner: LocalOwner.current)
    }

    // MARK: - Session maintenance

    /// Refreshes an expired access token in the background. A failure is not
    /// surfaced — the person stays signed in locally and nothing they can see
    /// is broken by it, since no feature depends on the token yet.
    func refreshIfNeeded() async {
        guard isConfigured,
              let stored = KeychainStore.value(StoredSession.self, for: Self.sessionKey),
              stored.isExpired() else { return }

        guard let refreshed = try? await client.refresh(
            refreshToken: stored.refreshToken,
            provider: stored.user.provider
        ) else { return }

        KeychainStore.store(refreshed, for: Self.sessionKey)
        state = .signedIn(refreshed.user)
    }

    // MARK: - Sign out & deletion

    /// Signing out is local-only and never touches schedule data. The rows keep
    /// their account `ownerID`, so signing back into the same account picks up
    /// exactly where things left off.
    func signOut() {
        let stored = KeychainStore.value(StoredSession.self, for: Self.sessionKey)
        KeychainStore.remove(Self.sessionKey)
        state = .guest
        CurrentOwner.setAccount(nil)
        lastMigration = nil
        errorMessage = nil

        if let stored {
            Task { await client.signOut(accessToken: stored.accessToken) }
        }
    }

    /// Deletes the account server-side, then signs out. Local data is handed
    /// back to guest ownership rather than deleted — someone closing an account
    /// hasn't asked to lose their schedule, and the app still works without one.
    func deleteAccount() async {
        guard let stored = KeychainStore.value(StoredSession.self, for: Self.sessionKey) else {
            signOut()
            return
        }

        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await client.deleteAccount(accessToken: stored.accessToken)
            returnDataToGuest(from: stored.user.id)
            signOut()
        } catch let error as AuthError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = AuthError.server(error.localizedDescription).errorDescription
        }
    }

    private func returnDataToGuest(from accountID: String) {
        guard let context,
              let items = try? context.fetch(FetchDescriptor<ScheduleItem>()),
              let completions = try? context.fetch(FetchDescriptor<Completion>()) else { return }

        let guest = LocalOwner.current
        let now = Date()
        for item in items where item.ownerID == accountID {
            item.ownerID = guest
            item.updatedAt = now
            item.syncedAt = nil
        }
        for completion in completions where completion.ownerID == accountID {
            completion.ownerID = guest
            completion.updatedAt = now
            completion.syncedAt = nil
        }
        try? context.save()
    }
}
