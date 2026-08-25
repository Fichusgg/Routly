//
//  AccountView.swift
//  RoutineOrganizer
//
//  The account screen, and the only place sign-in is ever offered from. Its main
//  job while signed out is to be honest about where the data lives, without
//  nagging: a plain statement of fact and a button, not a pitch.
//
//  Pushed from Settings rather than presented on its own, so it inherits that
//  screen's navigation stack and doesn't need a Done button of its own.
//

import SwiftUI

struct AccountView: View {
    @Environment(AuthController.self) private var auth

    @State private var showingSignIn = false
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var auth = auth

        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Metrics.itemSpacing + 6) {
                    if let message = auth.errorMessage {
                        ErrorBanner(message: message)
                    }

                    switch auth.state {
                    case .guest:
                        guestCard
                    case .signedIn(let user):
                        signedInCard(user)
                    }

                    if let migration = auth.lastMigration {
                        migrationReceipt(migration)
                    }

                    if let backup = StoreRecovery.lastBackupURL {
                        recoveryNotice(backup)
                    }

                    if auth.state.isSignedIn {
                        dangerSection
                    }
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.vertical, 16)
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .sheet(isPresented: $showingSignIn) { SignInView() }
        // Nothing is touched until this is answered, and it can't be swiped away.
        .sheet(item: $auth.pendingMigration) { pending in
            MigrationChoiceView(
                localItems: pending.localItems,
                remoteItems: pending.remoteItems,
                onChoose: { auth.resolve($0) }
            )
        }
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { auth.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your schedule stays on this phone. You can sign back in any time.")
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { Task { await auth.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the account. Your schedule stays on this phone and the app keeps working.")
        }
    }

    // MARK: - Guest

    private var guestCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Guest")
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
            } icon: {
                Image(systemName: "iphone")
                    .foregroundStyle(Theme.Colors.accent)
            }

            Text(dataLocationLine)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if auth.isConfigured {
                Button {
                    auth.errorMessage = nil
                    showingSignIn = true
                } label: {
                    Text("Sign in")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.Colors.accent)
                        )
                        .foregroundStyle(Theme.Colors.onAccent)
                }
                .buttonStyle(.pressable)
            } else {
                Text("Accounts aren't set up in this build, so there's nothing to sign in to yet. Everything else works as normal.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private var dataLocationLine: String {
        let summary = auth.guestDataSummary
        guard !summary.isEmpty else {
            return "Everything you add stays on this phone. Sign in whenever you want a backup."
        }
        return "Your \(summary.phrase) are stored on this phone only. If you lose it, they're gone with it."
    }

    // MARK: - Signed in

    private func signedInCard(_ user: AuthUser) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.accountLabel)
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                    Text("Signed in with \(user.provider.displayName)")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                }
            } icon: {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(Theme.Colors.accent)
            }

            Divider().overlay(Theme.Colors.separator)

            // Honest about the current state: an account exists, but nothing is
            // being uploaded yet. Claiming otherwise would be the fastest way to
            // lose the trust this whole layer is meant to build.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.badge.questionmark")
                    .foregroundStyle(Theme.Colors.textFaint)
                Text("Syncing isn't switched on yet. Your schedule is still stored on this phone and hasn't been uploaded.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Sign out") { confirmingSignOut = true }
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
        .overlay(alignment: .topTrailing) {
            if auth.isBusy {
                ProgressView()
                    .tint(Theme.Colors.accent)
                    .padding(Theme.Metrics.cardPadding)
            }
        }
    }

    // MARK: - Irreversible

    /// The one action here that can't be undone, in its own block at the bottom
    /// rather than sitting under "Sign out" as a second, redder button.
    ///
    /// Two things separate it from everything above: distance — nothing else on
    /// this screen is destructive, so nothing else should share a card with it —
    /// and a footer that says what actually happens, since "delete account" in
    /// an app that stores everything locally does far less than it sounds like.
    /// The dialog says the same thing again at the moment of the tap.
    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Careful")

            Button {
                confirmingDelete = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.Colors.now)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.Colors.now.opacity(0.12))
                        )

                    Text("Delete account")
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.now)

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, Theme.Metrics.cardPadding)
                .padding(.vertical, Theme.Metrics.rowPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .surfaceCard(padding: 0)

            Text("This can't be undone. Your schedule stays on this phone and the app keeps working — it's the account itself that goes.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        // The enclosing stack is centre-aligned — every card on this screen
        // claims the full width for itself rather than inheriting it.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Notices

    private func migrationReceipt(_ summary: DataOwnership.Summary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Colors.category(.health))
            Text("\(summary.phrase) moved to your account.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Colors.category(.health).opacity(0.10))
        )
    }

    /// If a store ever had to be set aside at launch, say where it went rather
    /// than letting someone conclude their data simply vanished.
    private func recoveryNotice(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A previous database couldn't be opened")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("It was kept, not deleted — saved as \(url.lastPathComponent) in the app's folder.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Colors.surfaceSunken)
        )
    }
}

#Preview {
    NavigationStack {
        AccountView()
            .environment(AuthController())
            .modelContainer(
                for: [ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self],
                inMemory: true
            )
    }
}
