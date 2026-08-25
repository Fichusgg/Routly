//
//  CaptureParsingView.swift
//  RoutineOrganizer
//
//  Where the words you capture are actually read, said plainly and without
//  jargon, plus the switch that keeps them on the phone.
//
//  This screen exists because the app was quietly wrong by omission. With a
//  provider configured, every typed and spoken capture is sent to that provider
//  to be interpreted — and nothing anywhere in the app said so. The one privacy
//  sentence on the About screen covers speech only. For an app asking a parent
//  or a student to hand over their family's schedule, "we never mentioned it"
//  is not a position worth defending.
//
//  Two rules the copy here follows:
//
//   • Name the real destination. "api.groq.com" is something a person can look
//     up; "a cloud service" asks them to take it on trust, which is the
//     opposite of what this screen is for. The host is read from the same
//     configuration the parser uses, so it can't drift out of date.
//   • Never oversell the offline path. Turning the switch off does not hand
//     the work to a clever on-device model — there isn't one. It hands it to
//     regex and keyword matching, which merges tasks and gets titles wrong.
//     That is said *before* the switch, not discovered afterwards in bad
//     captures.
//

import SwiftUI

struct CaptureParsingView: View {
    @Bindable private var settings = AppSettings.shared

    /// Resolved once: this is build configuration, not state, and it cannot
    /// change while the screen is open.
    private let cloudHost = ParsingServiceFactory.cloudHost

    /// Whether captures are, right now, actually being sent anywhere.
    private var sendsToCloud: Bool {
        cloudHost != nil && settings.cloudParsingEnabled
    }

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    statusSection
                    if cloudHost != nil {
                        switchSection
                    }
                    voiceNote
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Reading your captures")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
    }

    // MARK: - Where

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Where")

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(sendsToCloud ? "Sent to be read" : "Read on this phone")
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)
                } icon: {
                    Image(systemName: sendsToCloud ? "arrow.up.forward.app" : "iphone")
                        .foregroundStyle(sendsToCloud ? Theme.Colors.accent : Theme.Colors.category(.health))
                }

                Text(statusExplanation)
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()

            // Verified against what `makeRequest` actually puts in the body:
            // the system prompt (today's date and the working-hours window) and
            // the capture text. Nothing else — no identity, no other items.
            //
            // Deliberately silent on what the provider does with it afterwards.
            // Retention is their policy, not something this app can see, and a
            // reassuring sentence about it would be a guess dressed as a fact
            // on the one screen that exists to not do that.
            //
            // Removed from the layout rather than faded out: nothing is being
            // sent, so a paragraph's worth of reserved space would sit there
            // holding a gap for a sentence that no longer applies.
            if sendsToCloud {
                Text("What's sent is the words you captured, today's date, and the hours you've said you're available — nothing else. Not your name, and not the rest of your schedule.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
    }

    /// Three genuinely different situations, and none of them may be described
    /// with another's words.
    private var statusExplanation: String {
        guard let cloudHost else {
            return String(localized: "This build has no reading service set up, so your captures never leave the phone. They're read here by simple pattern-matching, which can merge two tasks into one or get a title wrong.")
        }
        if settings.cloudParsingEnabled {
            return String(
                format: String(localized: "When you type or speak a capture, those words are sent to %@ to be turned into a dated, timed item. It's what lets “gym tuesday and thursday at 7” become two entries instead of one line of text."),
                cloudHost
            )
        }
        return String(localized: "Your captures stay on this phone. They're read here by simple pattern-matching, which can merge two tasks into one or get a title wrong.")
    }

    // MARK: - The switch

    private var switchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Choice")

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.cloudParsingEnabled) {
                    Text("Send captures to be read")
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                .tint(Theme.Colors.accent)

                Text("Turning this off keeps every capture on the phone. It also makes them rougher — the offline reading is pattern-matching, not understanding, so expect to fix more of what it guesses.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .surfaceCard()

            Text("This takes effect on your next capture. Everything already in your schedule stays exactly as it is.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Voice

    /// Voice is a separate journey off the phone and would be misleading to
    /// fold into the section above: speech becomes text through Apple, and only
    /// then is the text read like any other capture.
    private var voiceNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Speaking")

            Text("Holding the mic turns speech into words on the phone itself wherever your language allows it. If it can't, Routine Organizer asks you first — that choice lives under Reminders & voice.")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceCard()
        }
    }
}

#Preview {
    NavigationStack {
        CaptureParsingView()
    }
}
