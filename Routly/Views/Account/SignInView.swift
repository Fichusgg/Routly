//
//  SignInView.swift
//  RoutineOrganizer
//
//  The sign-in sheet. Presented from the account screen — never at launch, never
//  as a wall. "Not now" carries the same visual weight as signing in, because a
//  guest declining this is a supported outcome, not a funnel someone escaped.
//
//  The pitch is safety, not features: everything in the app already works, so
//  the only honest reason to sign in is not losing it.
//
//  ⚠️ Email is currently the only sign-in method. Sign in with Apple needs a paid
//  Apple Developer Program membership for its entitlement, so it's switched off
//  rather than shipped broken. The supporting code is still in place and tested
//  (`Auth/AppleSignIn.swift`, `AuthController.signInWithApple`) — restoring it is
//  the button below plus the entitlement. See Docs/supabase-auth-setup.md.
//

import SwiftUI

struct SignInView: View {
    @Environment(AuthController.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var isCreatingAccount = false
    @State private var email = ""
    @State private var password = ""

    private var summary: DataOwnership.Summary { auth.guestDataSummary }

    var body: some View {
        @Bindable var auth = auth

        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        pitch

                        if let message = auth.errorMessage {
                            ErrorBanner(message: message)
                        }

                        if let email = auth.awaitingConfirmationFor {
                            confirmationNotice(email)
                        } else {
                            emailSection
                        }

                        notNowButton
                        reassurance
                    }
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
        .onDisappear { auth.errorMessage = nil }
        .onChange(of: auth.state) { _, newValue in
            // Leave as soon as it worked — but not while a merge question is
            // still waiting, or the sheet would take the answer with it.
            if newValue.isSignedIn && auth.pendingMigration == nil { dismiss() }
        }
    }

    // MARK: - Pitch

    private var pitch: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
                .padding(.bottom, 2)

            Text("Keep your schedule safe")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.textPrimary)
                .multilineTextAlignment(.center)

            Text(summary.isEmpty
                 ? "Sign in so your routines survive a lost or replaced phone."
                 : "Your \(summary.phrase) live only on this phone. Sign in to keep them if it's lost or replaced.")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Email

    private var emailSection: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldStyle()

            SecureField("Password", text: $password)
                .textContentType(isCreatingAccount ? .newPassword : .password)
                .fieldStyle()

            Button {
                Task {
                    if isCreatingAccount {
                        await auth.signUp(email: email, password: password)
                    } else {
                        await auth.signIn(email: email, password: password)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if auth.isBusy { ProgressView().tint(Theme.Colors.onAccent) }
                    Text(isCreatingAccount ? "Create account" : "Sign in")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.Colors.accent)
                )
                .foregroundStyle(Theme.Colors.onAccent)
            }
            .buttonStyle(.pressable)
            .disabled(!canSubmitEmail)
            .opacity(canSubmitEmail ? 1 : 0.45)

            Button(isCreatingAccount ? "I already have an account" : "Create an account instead") {
                withAnimation(Theme.Motion.snappy) {
                    isCreatingAccount.toggle()
                    auth.errorMessage = nil
                }
            }
            .font(Theme.Typography.caption())
            .foregroundStyle(Theme.Colors.accent)
        }
    }

    private var canSubmitEmail: Bool {
        !auth.isBusy && email.contains("@") && password.count >= 8
    }

    private func confirmationNotice(_ address: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 26))
                .foregroundStyle(Theme.Colors.accent)
            Text("Check your email")
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("We sent a confirmation link to \(address). Open it, then sign in.")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .surfaceCard()
    }

    // MARK: - Declining

    private var notNowButton: some View {
        // Same prominence as signing in. Guest mode is a destination, not a
        // dead end, and the UI shouldn't imply otherwise.
        Button("Not now") { dismiss() }
            .font(Theme.Typography.itemTitle())
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1)
            )
            .buttonStyle(.pressable)
    }

    private var reassurance: some View {
        Text("Everything in the app works without an account. Signing in only adds a backup of what you've already got.")
            .font(Theme.Typography.caption())
            .foregroundStyle(Theme.Colors.textFaint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}

// MARK: - Shared bits

/// A non-blocking error surface. Errors here are informational — the app is
/// still fully usable behind them — so they read as a note, not an alarm.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.Colors.now)
            Text(message)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Colors.now.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.Colors.now.opacity(0.3), lineWidth: 1)
        )
        .transition(.opacity)
    }
}

private extension View {
    func fieldStyle() -> some View {
        font(Theme.Typography.body())
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Colors.surfaceSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
            )
    }
}

#Preview {
    SignInView()
        .environment(AuthController())
}
