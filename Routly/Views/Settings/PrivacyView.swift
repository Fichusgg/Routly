//
//  PrivacyView.swift
//  RoutineOrganizer
//
//  What the app holds, where it holds it, and the two occasions something
//  leaves the phone.
//
//  Everything on this screen is true of the app as it stands today — it is not
//  a placeholder waiting for legal text. The published policy and the terms are
//  separate documents and are linked *when they exist*: `LegalLinks` reads them
//  from Info.plist, and each row renders only when its URL is actually set.
//  That's the structure ready for them without a row that opens nothing, which
//  is worse than no row at all.
//

import SwiftUI

struct PrivacyView: View {

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    storageSection
                    leavingSection
                    if LegalLinks.hasAny {
                        documentsSection
                    }
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
    }

    // MARK: - Where it lives

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Where your schedule lives")

            Text("On this phone. Your items, routines and history are stored in the app's own database and are not uploaded anywhere. You don't need an account to use any part of Routine Organizer, and making one adds a backup rather than switching anything on.")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceCard()
        }
    }

    // MARK: - What leaves

    /// The two journeys off the phone, each pointing at the screen that owns
    /// the choice rather than repeating a switch here. Both are stated even
    /// when they're currently inactive — "it depends how you've set it up" is
    /// the honest shape of the answer.
    private var leavingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("What leaves the phone")

            VStack(spacing: 0) {
                NavigationLink {
                    CaptureParsingView()
                } label: {
                    SettingsRow(
                        icon: "text.viewfinder",
                        title: String(localized: "Reading your captures"),
                        detail: captureDetail
                    )
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 52)

                NavigationLink {
                    CaptureSettingsView()
                } label: {
                    SettingsRow(
                        icon: "mic",
                        title: String(localized: "Speaking to it"),
                        // `SettingsRow` gives the detail one line; the longer
                        // phrasing lost its end to an ellipsis at 375pt.
                        detail: String(localized: "Where your language allows")
                    )
                }
                .buttonStyle(.plain)
            }
            .surfaceCard(padding: 0)

            Text("Nothing else is sent anywhere. There's no analytics, no advertising, and no tracking in this app.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var captureDetail: String {
        guard let host = ParsingServiceFactory.cloudHost else {
            return String(localized: "On this phone")
        }
        guard AppSettings.shared.cloudParsingEnabled else {
            return String(localized: "On this phone")
        }
        return host
    }

    // MARK: - Documents

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Documents")

            VStack(spacing: 0) {
                if let policy = LegalLinks.privacyPolicy {
                    Link(destination: policy) {
                        SettingsRow(
                            icon: "hand.raised.fill",
                            title: String(localized: "Privacy policy"),
                            detail: String(localized: "Opens in your browser")
                        )
                    }
                    .buttonStyle(.plain)
                }

                if LegalLinks.privacyPolicy != nil && LegalLinks.terms != nil {
                    Divider().padding(.leading, 52)
                }

                if let terms = LegalLinks.terms {
                    Link(destination: terms) {
                        SettingsRow(
                            icon: "doc.text.fill",
                            title: String(localized: "Terms & Conditions"),
                            detail: String(localized: "Opens in your browser")
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .surfaceCard(padding: 0)
        }
    }
}

// MARK: - Legal links

/// The published privacy policy and terms, when they exist.
///
/// Read from Info.plist rather than hardcoded so publishing them is a
/// configuration change rather than a code change — and, more to the point, so
/// the rows for them are *absent* until there is something at the other end.
/// A "Terms & Conditions" row that opens a 404 is worse than no row, which is
/// the standard the rest of this settings tree already holds itself to.
enum LegalLinks {
    static var privacyPolicy: URL? { url(forKey: "PrivacyPolicyURL") }
    static var terms: URL? { url(forKey: "TermsURL") }

    static var hasAny: Bool { privacyPolicy != nil || terms != nil }

    private static func url(forKey key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(string: raw)
    }
}

#Preview {
    NavigationStack {
        PrivacyView()
    }
}
