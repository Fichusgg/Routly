//
//  VoiceCaptureWidget.swift
//  RoutineOrganizerWidgets
//
//  A mic on the home screen — the app's core thesis, one tap from anywhere.
//
//  **It does not record.** A widget extension has no microphone: it isn't a
//  foreground app, gets no audio session, and no entitlement exists that would
//  change that. Anyone reading this hoping to move the recording in-process
//  should stop here — the constraint is the platform's, not this code's.
//
//  What it does instead is launch the app *already listening*, by opening a
//  `routly://voiceCapture` URL that the app reads on arrival.
//
//  It used to do that through an `openAppWhenRun` App Intent, which worked on
//  the home screen and silently did nothing on the lock screen: iOS launches the
//  app for such an intent while the device is locked but never runs its
//  `perform()`, so the request was lost and the app opened having been told
//  nothing. A URL is carried into the launch itself, so it survives the same
//  path. (An intent that does *not* open the app — the to-do checkbox — runs on
//  the lock screen fine; opening is the part that breaks.)
//
//  There is no timeline to speak of: a button showing nothing but itself never
//  goes stale. It refreshes far in the future purely so WidgetKit has a policy.
//

import AppIntents
import SwiftUI
import WidgetKit

struct VoiceEntry: TimelineEntry {
    let date: Date
    let locale: Locale?
}

struct VoiceProvider: TimelineProvider {

    func placeholder(in context: Context) -> VoiceEntry {
        VoiceEntry(date: Date(), locale: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (VoiceEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceEntry>) -> Void) {
        // Nothing here changes with time. A day out is not a real refresh so
        // much as a formality — the only thing that could change is the user's
        // language, and a settings change already triggers a reload.
        let next = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry()], policy: .after(next)))
    }

    private func entry() -> VoiceEntry {
        VoiceEntry(date: Date(), locale: AppSettings(defaults: AppGroup.defaults).appLanguage.explicitLocale)
    }
}

// MARK: - Views

struct VoiceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VoiceEntry

    var body: some View {
        content
            .containerBackground(Theme.Colors.background, for: .widget)
            .environment(\.locale, entry.locale ?? .autoupdatingCurrent)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular: circular
        default: square
        }
    }

    /// The home-screen square: one accent disc, the same one Today floats at the
    /// bottom right, so the gesture reads as the same gesture in both places.
    private var square: some View {
        VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.accent)
                        .frame(width: 54, height: 54)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.Colors.onAccent)
                }
            Text("Capture")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(AppRoute.voiceCapture.url)
        .accessibilityLabel(Text("Capture by voice"))
        .accessibilityHint(Text("Opens Routly and starts recording"))
    }

    /// The lock-screen accessory. No accent fill: tinted and monochrome
    /// rendering would flatten a filled disc into an unreadable blob, so the
    /// glyph carries it against the standard translucent backing.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
        }
        .widgetURL(AppRoute.voiceCapture.url)
        .widgetAccentable()
        .accessibilityLabel(Text("Capture by voice"))
    }
}

// MARK: - Widget

struct VoiceCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RoutlyVoiceCapture", provider: VoiceProvider()) { entry in
            VoiceWidgetView(entry: entry)
        }
        .configurationDisplayName("Voice capture")
        .description("Opens Routly already listening.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    VoiceCaptureWidget()
} timeline: {
    VoiceEntry(date: .now, locale: nil)
}

#Preview("Circular", as: .accessoryCircular) {
    VoiceCaptureWidget()
} timeline: {
    VoiceEntry(date: .now, locale: nil)
}
