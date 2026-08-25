//
//  MenuView.swift
//  RoutineOrganizer
//
//  The settings sheet: a list of places rather than a screen of controls.
//
//  It replaces the old SettingsView, which was one long scroll with the working
//  hours' two time pickers sitting open at the top, the appearance switcher
//  halfway down, and the genuinely navigable rows mixed in among them. Reading
//  it meant reading controls; finding anything meant scrolling past settings you
//  weren't looking for.
//
//  Every row is now an icon, a name and a chevron — nothing else. The uppercase
//  section headings are gone, and so are the second lines that echoed each
//  setting's current value ("9:00 AM – 5:00 PM", "Sent to api.groq.com"). Both
//  were defensible in isolation and made the screen worse together: seven
//  headings over seven cards is a label per thing labelled, and a value line
//  doubles every row's height to answer a question you are one tap from anyway.
//  What's left is grouped by gaps between cards, which is how the rest of iOS
//  says the same thing without spending a line on it.
//
//  The grouping, top to bottom:
//
//   1. Account on its own — who this is, and where the data lives.
//   2. The five you actually change: reminders and voice first, because capture
//      friction and the nudge are the whole product; then working hours,
//      calendars, lists, appearance.
//   3. Where your words go. Its own card because it answers a different kind of
//      question from the five above.
//   4. Language and About, which you open once.
//
//  ⚠️ One consequence of stripping the value lines, accepted deliberately: the
//  cloud-parsing disclosure no longer reads at a glance from this screen. It is
//  stated in full one tap in, on `CaptureParsingView`, which is the screen that
//  owns it.
//
//  Calendars joined the second group once there was something behind it. It
//  sits next to working hours because both are about when things happen and
//  where they're allowed to land, and because the row it replaces — the
//  reserved, deliberately absent "integrations" — was only ever going to be
//  worth adding on the rule below.
//
//  Reserved for later, deliberately absent rather than stubbed: help. It needs
//  real work behind it, and a row that opens nothing is worse than no row.
//
//  The published privacy policy and the terms follow that same rule rather than
//  breaking it: the Privacy screen is real content about the app as it stands
//  today, and links to those two documents appear inside it only once the URLs
//  are configured. See `LegalLinks`.
//

import SwiftUI

struct MenuView: View {
    @Bindable private var settings = AppSettings.shared
    @Environment(AuthController.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
        }
    }

    private var content: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    accountCard
                    settingsCard
                    privacyCard
                    appCard
                    footer
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                }
                .tint(Theme.Colors.textSecondary)
                .accessibilityLabel("Close")
            }
        }
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
    }

    // MARK: - Account

    /// Alone at the top. It's the only row whose name changes with the state of
    /// the app — "Guest" or the signed-in address — so it is also the only one
    /// still carrying information rather than just a destination.
    private var accountCard: some View {
        NavigationLink {
            AccountView()
        } label: {
            SettingsRow(
                icon: auth.state.isSignedIn ? "person.crop.circle" : "iphone",
                title: accountTitle
            )
        }
        .buttonStyle(.plain)
        .surfaceCard(padding: 0)
    }

    private var accountTitle: String {
        switch auth.state {
        case .guest: return String(localized: "Guest")
        case .signedIn(let user): return user.accountLabel
        }
    }

    // MARK: - The five you change

    private var settingsCard: some View {
        VStack(spacing: 0) {
            link(to: CaptureSettingsView(), icon: "bell", title: String(localized: "Reminders & voice"))
            RowDivider(inset: 52)
            link(to: WorkingHoursView(), icon: "clock", title: String(localized: "Working hours"))
            RowDivider(inset: 52)
            link(to: CalendarsView(), icon: "calendar.badge.plus", title: String(localized: "Calendars"))
            RowDivider(inset: 52)
            link(to: ListsView(), icon: "folder", title: String(localized: "Lists"))
            RowDivider(inset: 52)
            link(to: AppearanceView(), icon: "paintpalette", title: String(localized: "Appearance"))
        }
        .surfaceCard(padding: 0)
    }

    // MARK: - Where your words go

    private var privacyCard: some View {
        VStack(spacing: 0) {
            link(
                to: CaptureParsingView(),
                icon: "text.viewfinder",
                title: String(localized: "Reading your captures")
            )
            RowDivider(inset: 52)
            link(to: PrivacyView(), icon: "hand.raised", title: String(localized: "Privacy"))
        }
        .surfaceCard(padding: 0)
    }

    // MARK: - App

    /// Language stays a menu rather than a push: it is a closed list of four,
    /// and a whole screen to hold it would be more ceremony than the choice
    /// deserves. It keeps its value on the right because a menu row without one
    /// gives no clue what it is currently set to.
    private var appCard: some View {
        VStack(spacing: 0) {
            SettingsMenuRow(
                icon: "globe",
                title: String(localized: "Language"),
                value: appLanguageValue
            ) {
                Picker("App language", selection: $settings.appLanguage) {
                    Text(AppLanguage.system.displayName).tag(AppLanguage.system)
                    Divider()
                    ForEach(AppLanguage.shipped) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            RowDivider(inset: 52)

            link(to: AboutView(), icon: "info.circle", title: String(localized: "About"))
        }
        .surfaceCard(padding: 0)
    }

    /// "System" alone leaves the user guessing which language that actually is,
    /// so it says which one it resolved to.
    private var appLanguageValue: String {
        guard settings.appLanguage == .system else { return settings.appLanguage.displayName }
        return String(
            format: String(localized: "System (%@)"),
            AppLanguage.systemResolved.displayName
        )
    }

    // MARK: - Row

    /// Every row on this screen is the same shape, so it is written once.
    private func link(
        to destination: some View,
        icon: String,
        title: String
    ) -> some View {
        NavigationLink {
            destination
        } label: {
            SettingsRow(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        Text("Routine Organizer works fully offline. An account only adds a backup — it never gates a feature.")
            .font(Theme.Typography.caption())
            .foregroundStyle(Theme.Colors.textFaint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
    }
}

#Preview {
    NavigationStack {
        MenuView()
            .environment(AuthController())
            .modelContainer(
                for: [ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self],
                inMemory: true
            )
    }
}
