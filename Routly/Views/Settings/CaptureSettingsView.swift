//
//  CaptureSettingsView.swift
//  RoutineOrganizer
//
//  Everything about getting something *into* the app and being told about it
//  afterwards: how early a reminder fires, whether iOS is letting reminders
//  through at all, and what language the mic is listening in.
//
//  It sits at the top of the settings list, above working hours and well above
//  colour, because capture friction and the nudge are the two things this app
//  exists to get right. A setting that decides whether the user hears about
//  their day should not be filed below the accent colour.
//
//  The permission notice only exists when it's true. A permanent
//  "Notifications: on" row would be a line of furniture in exchange for
//  information the user already has — but a silently denied permission looks
//  exactly like an app that works and never nudges, which is the failure worth
//  spending a card on.
//

import SwiftUI
import UserNotifications

struct CaptureSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    /// Resolved off the view body — building an `SFSpeechRecognizer` is far too
    /// heavy for a body, and the answer only changes when the language does.
    @State private var voiceRunsOnDevice = true
    /// `nil` until iOS has answered. Nothing is claimed in the meantime.
    @State private var notificationStatus: UNAuthorizationStatus?

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    remindersSection
                    voiceSection
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Reminders & voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .task {
            notificationStatus = await NotificationService.authorizationStatus()
        }
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Reminders")

            SettingsMenuRow(
                icon: "bell.badge",
                title: String(localized: "Notify me"),
                value: ReminderLead.label(settings.defaultReminderLeadMinutes)
            ) {
                Picker("Notify me", selection: $settings.defaultReminderLeadMinutes) {
                    ForEach(ReminderLead.options, id: \.self) { minutes in
                        Text(verbatim: ReminderLead.label(minutes)).tag(minutes)
                    }
                }
            }
            .surfaceCard(padding: 0)

            Text("Where a new event or reminder starts out. Any one item can still be changed under “More” when you add it, and nothing already in your schedule moves when you change this.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            if notificationStatus == .denied {
                permissionCard
            }
        }
    }

    /// Shown only when iOS is actually blocking notifications. The app can't
    /// grant the permission a second time — once denied, the only way back is
    /// the system settings — so this points there rather than offering a button
    /// that would do nothing.
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Notifications are switched off")
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
            } icon: {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(Theme.Colors.now)
            }

            Text("Your reminders are still set — iOS just won't show them. You can turn them back on in the Settings app.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(Theme.Typography.body())
            .foregroundStyle(Theme.Colors.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
        .accessibilityElement(children: .contain)
    }

    // MARK: - Voice

    /// Voice sits with reminders rather than with the app's languages: this is
    /// the language you *speak into the mic*, which is part of capture, and
    /// reading the app in one language while dictating in another is a normal
    /// way to use a phone.
    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Voice")

            SettingsMenuRow(
                icon: "mic",
                title: String(localized: "Voice language"),
                value: settings.voiceLanguage.displayName
            ) {
                Picker("Voice language", selection: $settings.voiceLanguage) {
                    ForEach(VoiceLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }
            .surfaceCard(padding: 0)

            // Only shown when it's actually true of this phone and this
            // language. It is the one place the choice can be revisited, so it
            // states the trade-off rather than just offering a switch.
            if !voiceRunsOnDevice {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: onlineSpeechBinding) {
                        Text("Transcribe \(settings.voiceLanguage.displayName) online")
                            .font(Theme.Typography.itemTitle())
                            .foregroundStyle(Theme.Colors.textPrimary)
                    }
                    .tint(Theme.Colors.accent)

                    Text("This phone has no offline model for \(settings.voiceLanguage.displayName). With this off, voice capture won't work in that language.")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .surfaceCard()
            }

            Text("Voice language changes right away — you don't have to reopen the app.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .task(id: settings.voiceLanguage) {
            voiceRunsOnDevice = settings.voiceLanguage.supportsOnDeviceRecognition()
        }
    }

    private var onlineSpeechBinding: Binding<Bool> {
        Binding(
            get: { settings.allowsServerSpeech(for: settings.voiceLanguage) },
            set: { settings.setServerSpeech($0, for: settings.voiceLanguage) }
        )
    }
}

#Preview {
    NavigationStack {
        CaptureSettingsView()
    }
}
