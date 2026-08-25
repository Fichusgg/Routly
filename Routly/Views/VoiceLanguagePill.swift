//
//  VoiceLanguagePill.swift
//  RoutineOrganizer
//
//  The spoken-language switch, sitting just above the mic.
//
//  It lives here rather than only in Settings because getting it wrong is
//  discovered at exactly one moment: reading back a transcript that turned your
//  sentence into nonsense. Having to leave the screen, find a settings row and
//  come back to fix that is the difference between a small correction and
//  giving up on voice capture.
//
//  Deliberately quiet — a two-letter code in secondary text. It sits next to the
//  one loud control on the screen and must not compete with it, but it is also
//  the thing you go looking for when the transcript came back wrong, so it can't
//  be hidden either.
//

import SwiftUI

struct VoiceLanguagePill: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Menu {
            Picker("Voice language", selection: $settings.voiceLanguage) {
                ForEach(VoiceLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                Text(settings.voiceLanguage.shortCode)
                    .font(Theme.Typography.caption())
                    .fontWeight(.semibold)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Theme.Colors.surfaceSunken)
            )
        }
        .onChange(of: settings.voiceLanguage) { Haptics.selection() }
        .accessibilityLabel(Text("Voice language"))
        .accessibilityValue(settings.voiceLanguage.displayName)
        .accessibilityHint(Text("The language you'll speak when recording"))
    }
}

#Preview {
    VoiceLanguagePill(settings: AppSettings.shared)
        .padding()
        .background(Theme.Colors.background)
}
