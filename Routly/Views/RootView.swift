//
//  RootView.swift
//  RoutineOrganizer
//
//  The app shell. Today *is* the app: one screen, with the calendar a push away
//  and everything else behind the gear.
//
//  There was briefly a tab bar here. It was removed again on purpose — three
//  tabs for a single-purpose app spent a permanent strip of screen advertising
//  places you rarely go, and the two you do go to are reachable from Today
//  itself: the calendar by tapping the day, the rest by the gear. What's left is
//  the day, which is the only thing this screen is for.
//
//  The mic stays inside Today's content rather than here, so the voice review
//  sheets, the consent alert and the processing overlay stay attached to the
//  screen that owns them.
//
//  Note: the notification permission request lives here so it still runs exactly
//  once at launch, wherever the user goes afterwards.
//
//  This is also the single place the light/dark preference is applied. Every
//  colour token resolves per trait collection, so setting the scheme once here
//  flips the entire app — no screen reads the setting itself.
//
//  It reads that preference from the shared `AppSettings` rather than its own
//  `@AppStorage`. Two views each holding a private `@AppStorage` for the same
//  key is what made a theme change look like it needed a relaunch; one
//  observable object shared by writer and reader has no such gap.
//

import SwiftUI

struct RootView: View {
    private let settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Bumped when a widget asks for a screen, which re-roots the navigation
    /// stack. See `applyWidgetRoute`.
    @State private var stackGeneration = 0

    /// Non-nil when this launch came from the mic widget. Handed to
    /// `ScheduleView`, which starts listening the moment it appears.
    @State private var voiceLaunch: UUID?

    var body: some View {
        NavigationStack {
            ScheduleView(voiceLaunch: voiceLaunch)
        }
        // Deliberate, and the opposite of the note below about colours.
        //
        // Re-rooting is the whole content of "take me to my to-dos": a tap on
        // the widget has to land on Today whether the user left the app on the
        // calendar, inside settings, or three sheets deep. Without a value-based
        // navigation path there is nothing to pop, and adding one would mean
        // rewriting every push in the app for the sake of three taps.
        //
        // The cost is honest and small: a screen the user wandered off to
        // minutes ago is rebuilt. That is what they asked for by tapping a
        // widget rather than the app icon.
        .id(stackGeneration)
        .tint(Theme.Colors.accent)
        // Deliberately *not* `.id(settings.paletteRevision)`. Keying the shell
        // on the revision does repaint the whole app on a colour change — and
        // also tears down the navigation stack the user is standing in. Colours
        // are picked from the settings sheet, and the screen underneath
        // re-renders when it closes, so the repaint happens anyway at the only
        // moment it's visible.
        .preferredColorScheme(settings.appearance.colorScheme)
        // `preferredColorScheme` covers this window's own hierarchy. Sheets and
        // alerts are presented in their own containers, so the style is pushed
        // onto the window itself too — that's what makes the change reach a
        // sheet the user is standing in when they make it.
        .onChange(of: settings.appearance) { _, new in
            WindowStyle.apply(new)
        }
        .task {
            WindowStyle.apply(settings.appearance)
            // Read before the permission prompt, so a mic tap isn't left waiting
            // behind a dialog on the very first launch.
            applyWidgetRoute()
            await NotificationService.requestAuthorization()
        }
        // A widget tap on a *running* app never re-runs `.task`, so activation
        // is the other half of this. Both call the same consume-once read.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            applyWidgetRoute()
        }
        // The third read, for the case the other two can't cover: an intent that
        // runs in this process *after* activation has already been handled.
        // `consume` is once-only, so whichever of the three gets there first
        // wins and the others find nothing.
        .onReceive(NotificationCenter.default.publisher(for: .routlyPendingRoute)) { _ in
            applyWidgetRoute()
        }
        // The lock screen's only working channel. A widget there cannot run an
        // app-opening intent — iOS launches the app and drops the `perform()` —
        // so the capture widget hands over a `routly://` URL instead, which the
        // system carries into the launch. Same destinations, same handler.
        .onOpenURL { url in
            guard let route = AppRoute(url: url) else { return }
            apply(route)
        }
    }

    /// Acts on a note left by a widget, if there is a fresh one.
    ///
    /// `PendingRoute.consume` returns a route at most once and expires anything
    /// older than a few seconds, so an app opened normally never inherits a tap
    /// from earlier — which would otherwise show up as the app mysteriously
    /// starting to record.
    private func applyWidgetRoute() {
        guard let route = PendingRoute.consume() else { return }
        apply(route)
    }

    /// One destination handler, whichever channel carried the request.
    private func apply(_ route: AppRoute) {
        switch route {
        case .today:
            voiceLaunch = nil
            stackGeneration += 1
        case .voiceCapture:
            // A fresh token every time: two mic taps in a row must both start a
            // session, and an unchanged value would be indistinguishable from no
            // new request.
            voiceLaunch = UUID()
            stackGeneration += 1
        }
    }
}

/// Applies the appearance choice to every window the app owns.
///
/// `preferredColorScheme` alone leaves anything presented outside the view's
/// own container — sheets, alerts, action sheets, the keyboard — resolving
/// against the system trait instead of the user's choice. Setting
/// `overrideUserInterfaceStyle` on the window closes that gap, so "Dark" means
/// dark on every surface rather than dark on most of them.
enum WindowStyle {
    @MainActor
    static func apply(_ appearance: AppearanceSetting) {
        let style: UIUserInterfaceStyle
        switch appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

#Preview {
    RootView()
        .modelContainer(
            for: [ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self],
            inMemory: true
        )
        .environment(AuthController())
}
