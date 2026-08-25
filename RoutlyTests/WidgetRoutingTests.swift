//
//  WidgetRoutingTests.swift
//  RoutineOrganizerTests
//
//  The note a widget leaves for the app, and the settings that had to move so
//  the widget could read them.
//
//  The route's expiry is the interesting one. Without it, a mic tap that failed
//  to launch would sit in the shared defaults and fire the next time the app was
//  opened for an unrelated reason — the app would start recording out of
//  nowhere, hours later, with nothing on screen to explain why.
//

import Testing
import Foundation
@testable import Routly

/// A throwaway suite per test, so nothing here touches the real shared defaults
/// or leaks into the next test.
private func scratch() -> UserDefaults {
    UserDefaults(suiteName: UUID().uuidString)!
}

/// `.serialized`, and every route test clears first.
///
/// `PendingRoute` keeps an in-process slot as well as the defaults note (see the
/// note there — it's what makes the route work without an App Group). That slot
/// is static, and Swift Testing runs tests in parallel by default, so without
/// serialising, one test's `set` could satisfy another's `consume` and the suite
/// would fail intermittently in a way that looks like a bug in the code.
@Suite("Widget routing", .serialized)
struct WidgetRoutingTests {

    // MARK: - The URL channel

    /// The lock screen's only working channel, and the reason it exists.
    ///
    /// A widget on the lock screen cannot reach the app through an
    /// `openAppWhenRun` intent: iOS launches the app and never runs the
    /// intent's `perform()`, so `PendingRoute` stays empty and the app opens
    /// having been told nothing. Confirmed in the device log — the same widget
    /// on the home screen performs the intent in the app's own process, while
    /// from the lock screen no `perform` happens at all. A URL is carried into
    /// the launch itself and survives that path.
    @Test("every route survives a round trip through its URL")
    func urlRoundTrip() throws {
        for route in [AppRoute.today, .voiceCapture] {
            let url = route.url
            #expect(url.scheme == "routly")
            #expect(AppRoute(url: url) == route, "\(route.rawValue) didn't come back")
        }
    }

    /// The scheme is declared in the app's Info.plist, so the string it is built
    /// from is not free to drift.
    @Test("the capture URL is the one the widget hands to the system")
    func captureURLIsStable() {
        #expect(AppRoute.voiceCapture.url.absoluteString == "routly://voiceCapture")
        #expect(AppRoute.today.url.absoluteString == "routly://today")
    }

    /// Anything else is ignored rather than treated as a default destination.
    /// Another app can claim the same scheme, and a stray open must not be able
    /// to re-root this one — still less start it recording.
    @Test("a foreign or malformed URL yields no route")
    func foreignURLsAreIgnored() throws {
        let rejected = [
            "https://routly.app/voiceCapture",   // right host, wrong scheme
            "routly://somethingElse",            // right scheme, unknown host
            "routly://",                         // no host at all
            "todos://voiceCapture",              // another app's scheme
        ]
        for string in rejected {
            let url = try #require(URL(string: string))
            #expect(AppRoute(url: url) == nil, "\(string) should not route")
        }
    }

    // MARK: - Settings reaching the widget

    @Test("settings are copied into the shared suite so the widget can read them")
    func migrationCopies() {
        let source = scratch()
        let destination = scratch()
        source.set("vividGreen", forKey: Keys.accent)
        source.set("Chores", forKey: Keys.todayGroupName)

        SettingsMigration.migrateIfNeeded(from: source, to: destination)

        #expect(destination.string(forKey: Keys.accent) == "vividGreen")
        #expect(destination.string(forKey: Keys.todayGroupName) == "Chores")
    }

    @Test("a value already in the shared suite is never overwritten")
    func migrationDoesNotClobber() {
        let source = scratch()
        let destination = scratch()
        source.set("vividGreen", forKey: Keys.accent)
        // Newer: set after the move, in the domain that is now authoritative.
        destination.set("vividPurple", forKey: Keys.accent)

        SettingsMigration.migrateIfNeeded(from: source, to: destination)

        #expect(destination.string(forKey: Keys.accent) == "vividPurple")
    }

    @Test("the copy happens once, so later changes aren't undone")
    func migrationRunsOnce() {
        let source = scratch()
        let destination = scratch()
        source.set("Chores", forKey: Keys.todayGroupName)

        SettingsMigration.migrateIfNeeded(from: source, to: destination)
        // The user renames the group in the app, which now writes to the shared
        // suite. A second migration must not drag the stale name back.
        destination.set("Errands", forKey: Keys.todayGroupName)
        source.set("Chores", forKey: Keys.todayGroupName)
        SettingsMigration.migrateIfNeeded(from: source, to: destination)

        #expect(destination.string(forKey: Keys.todayGroupName) == "Errands")
    }

    @Test("migrating a domain onto itself is refused")
    func migrationRefusesSameDomain() {
        // What happens with no App Group entitlement: `AppGroup.defaults` falls
        // back to `.standard`, and copying a domain onto itself is pure risk.
        let same = scratch()
        same.set("vividGreen", forKey: Keys.accent)

        SettingsMigration.migrateIfNeeded(from: same, to: same)

        #expect(same.object(forKey: SettingsMigration.doneKey) == nil)
    }

    @Test("every key the app persists is in the migration list")
    func migrationListIsComplete() {
        // The list and the keys live in the same file precisely so this can be
        // checked; a preference missing here comes across as "reset itself".
        #expect(Keys.all.contains(Keys.accent))
        #expect(Keys.all.contains(Keys.todayGroupName))
        #expect(Keys.all.contains(Keys.workingHoursStart))
        #expect(Keys.all.contains(Keys.appLanguage))
        #expect(Keys.all.count == Set(Keys.all).count, "duplicate key in the migration list")
        // AppleLanguages belongs to iOS and to the app's own domain — moving it
        // into a shared suite would put it where nothing reads it.
        #expect(!Keys.all.contains(AppLanguage.appleLanguagesKey))
    }

    // MARK: - The note a widget leaves

    /// Clears both channels — the defaults note and the in-process slot.
    private func freshRoute() -> UserDefaults {
        let defaults = scratch()
        PendingRoute.clear(defaults: defaults)
        return defaults
    }

    @Test("a fresh tap is delivered once and then gone")
    func consumedExactlyOnce() {
        let defaults = freshRoute()
        PendingRoute.set(.voiceCapture, defaults: defaults)

        #expect(PendingRoute.consume(defaults: defaults) == .voiceCapture)
        // A second activation must not start recording all over again.
        #expect(PendingRoute.consume(defaults: defaults) == nil)
    }

    @Test("a stale tap is dropped rather than fired late")
    func staleRouteIsDropped() {
        let defaults = freshRoute()
        let tappedAt = Date()
        PendingRoute.set(.voiceCapture, now: tappedAt, defaults: defaults)

        // The app opens an hour later, for its own reasons. Firing here would
        // start recording with nothing on screen to explain it.
        let muchLater = tappedAt.addingTimeInterval(PendingRoute.window + 3600)
        #expect(PendingRoute.consume(now: muchLater, defaults: defaults) == nil)
    }

    @Test("an expired tap is cleared, not left to fire on the next launch")
    func staleRouteIsCleared() {
        let defaults = freshRoute()
        let tappedAt = Date()
        PendingRoute.set(.today, now: tappedAt, defaults: defaults)

        _ = PendingRoute.consume(now: tappedAt.addingTimeInterval(PendingRoute.window + 1), defaults: defaults)
        // Even asked at a plausible time afterwards, it's gone.
        #expect(PendingRoute.consume(now: tappedAt, defaults: defaults) == nil)
    }

    @Test("no note reads as no route")
    func absentRoute() {
        #expect(PendingRoute.consume(defaults: freshRoute()) == nil)
    }

    @Test("a tap just inside the window still counts")
    func freshEnough() {
        let defaults = freshRoute()
        let tappedAt = Date()
        PendingRoute.set(.today, now: tappedAt, defaults: defaults)

        let duringLaunch = tappedAt.addingTimeInterval(PendingRoute.window - 1)
        #expect(PendingRoute.consume(now: duringLaunch, defaults: defaults) == .today)
    }

    @Test("the route survives when the defaults note isn't shared at all")
    func routeSurvivesUnsharedDefaults() {
        _ = freshRoute()
        // The device symptom this fixes: with App Groups not yet provisioned,
        // `AppGroup.defaults` falls back to `.standard`, which is per-process —
        // so a note written on one side is invisible on the other. Two different
        // suites stand in for those two domains.
        let writerDomain = scratch()
        let readerDomain = scratch()

        PendingRoute.set(.voiceCapture, defaults: writerDomain)

        // The reader's own domain has nothing, yet the tap still arrives, because
        // `openAppWhenRun` performed the intent in this same process.
        #expect(readerDomain.string(forKey: "pendingRoute") == nil)
        #expect(PendingRoute.consume(defaults: readerDomain) == .voiceCapture)
    }

    @Test("the in-process route expires too, and is consumed once")
    func inProcessRouteIsPerishable() {
        _ = freshRoute()
        let writerDomain = scratch()
        let readerDomain = scratch()
        let tappedAt = Date()

        PendingRoute.set(.voiceCapture, now: tappedAt, defaults: writerDomain)

        // A stale in-memory tap must be no more able to start a recording than a
        // stale note — otherwise the fallback reintroduces the bug the window
        // exists to prevent.
        let muchLater = tappedAt.addingTimeInterval(PendingRoute.window + 60)
        #expect(PendingRoute.consume(now: muchLater, defaults: readerDomain) == nil)

        PendingRoute.set(.today, now: tappedAt, defaults: writerDomain)
        #expect(PendingRoute.consume(now: tappedAt, defaults: readerDomain) == .today)
        #expect(PendingRoute.consume(now: tappedAt, defaults: readerDomain) == nil)
    }

    // MARK: - The language the widget renders in

    @Test("an explicit language resolves to a locale, System to none")
    func explicitLocale() {
        // The widget is a separate process and never sees the app's
        // AppleLanguages, so it pushes this into the environment instead.
        #expect(AppLanguage.spanish.explicitLocale?.identifier == "es")
        #expect(AppLanguage.portuguese.explicitLocale?.identifier == "pt-BR")
        #expect(AppLanguage.system.explicitLocale == nil)
    }
}
