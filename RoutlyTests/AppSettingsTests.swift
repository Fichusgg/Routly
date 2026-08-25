//
//  AppSettingsTests.swift
//  RoutineOrganizerTests
//
//  The settings store, against a throwaway UserDefaults suite.
//
//  The interesting property isn't "it saves a string" — it's that a colour
//  choice reaches `ThemePalette`, because that's the handoff the `Theme.Colors`
//  tokens read and the one that silently stops working if someone adds a new
//  preference and forgets to sync it.
//

import Testing
import Foundation
@testable import Routly

/// A fresh defaults suite per test, so nothing leaks between them or into the
/// developer's own simulator preferences.
private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    UserDefaults(suiteName: name)!
}

@MainActor
@Suite("App settings")
struct AppSettingsTests {

    @Test("starts on the shipped defaults")
    func defaults() {
        let settings = AppSettings(defaults: scratchDefaults())
        #expect(settings.appearance == .system)
        #expect(settings.accent == ThemePalette.defaultAccent)
        #expect(settings.tagDisplay == .discreet)
        #expect(settings.hasOpenedMoreSection == false)
        #expect(settings.usesDefaultColors)
        // Zero is "notify at the start time", which is what every capture got
        // before this setting existed. Anything else here would silently
        // re-time the reminders of everyone already using the app.
        #expect(settings.defaultReminderLeadMinutes == 0)
    }

    /// Where new events go is off until somebody says otherwise. Pushing an
    /// event into a person's calendar because a default said so would be the
    /// wrong way round.
    @Test("no calendar is a destination on a fresh install")
    func noCalendarTargetsByDefault() {
        let settings = AppSettings(defaults: scratchDefaults())
        #expect(settings.calendarDestinations.isEmpty)
        #expect(!settings.isCalendarDestinationEnabled(.apple))
    }

    /// The regression test for the bug that shipped in the first build:
    /// Settings said "Connected" and new events still went nowhere, because
    /// granting permission and choosing a destination were two decisions and
    /// only the first had a control. This preference is now the whole of the
    /// second decision — `CalendarConnections.connect` turns it on, the
    /// Settings toggle writes it, and `CalendarSync` reads it for every new
    /// item. There is no per-event override left to disagree with it.
    @Test("turning a calendar on survives a round trip through defaults")
    func calendarTargetPersists() {
        let suite = scratchDefaults()
        let settings = AppSettings(defaults: suite)

        settings.setCalendarDestination(.apple, enabled: true)
        #expect(settings.isCalendarDestinationEnabled(.apple))
        #expect(settings.calendarDestinations == [.apple])

        // A second instance over the same suite is what the next launch sees.
        #expect(AppSettings(defaults: suite).calendarDestinations == [.apple])

        settings.setCalendarDestination(.apple, enabled: false)
        #expect(AppSettings(defaults: suite).calendarDestinations.isEmpty)
    }

    /// Stored as raw strings so a provider that is renamed or dropped later
    /// degrades to "unknown, ignored" rather than failing to decode the set and
    /// taking the real choices with it.
    @Test("an unrecognised provider is ignored, not fatal")
    func unknownProviderIsDropped() {
        let suite = scratchDefaults()
        suite.set(["apple", "carrier-pigeon"], forKey: Keys.calendarDestinations)
        #expect(AppSettings(defaults: suite).calendarDestinations == [.apple])
    }

    /// Every preference has to be in `Keys.all`, or `SettingsMigration` leaves
    /// it behind in the app's private domain when the App Group moves in — and
    /// the user finds out weeks later that a setting reverted.
    @Test("the calendar preference is carried by the settings migration")
    func calendarTargetIsMigrated() {
        #expect(Keys.all.contains(Keys.calendarDestinations))
    }

    /// The default only ever seeds a *new* draft, so it has to be a value the
    /// add sheet's picker can also show — otherwise the sheet would open on a
    /// selection that isn't in its own list and appear to have reset itself.
    @Test("the default reminder lead is offered by the picker")
    func leadDefaultIsOfferable() {
        let settings = AppSettings(defaults: scratchDefaults())
        #expect(ReminderLead.options.contains(settings.defaultReminderLeadMinutes))
    }

    @Test("a chosen reminder lead survives a relaunch")
    func leadPersistence() {
        let defaults = scratchDefaults()

        let first = AppSettings(defaults: defaults)
        first.defaultReminderLeadMinutes = 10

        #expect(AppSettings(defaults: defaults).defaultReminderLeadMinutes == 10)
    }

    // MARK: - New install vs. existing install

    /// The whole point of the seed: someone opening the app for the first time
    /// gets warned ten minutes early rather than at the moment the thing starts.
    @Test("a brand-new install starts on a ten-minute lead")
    func seedGivesNewInstallsALead() {
        let settings = AppSettings(defaults: scratchDefaults())
        settings.seedReminderLeadDefault(hasExistingItems: false)
        #expect(settings.defaultReminderLeadMinutes == ReminderLead.newInstallDefault)
    }

    /// The regression this feature exists to avoid. Someone already using the
    /// app has reminders set against "at start time"; moving that under them is
    /// a silent change to when their phone goes off.
    @Test("an existing install is left at zero")
    func seedLeavesExistingInstallsAlone() {
        let defaults = scratchDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.seedReminderLeadDefault(hasExistingItems: true)

        #expect(settings.defaultReminderLeadMinutes == 0)
        // Nothing written, so a later read still resolves to the old behaviour.
        #expect(defaults.object(forKey: "defaultReminderLeadMinutes") == nil)
        #expect(AppSettings(defaults: defaults).defaultReminderLeadMinutes == 0)
    }

    /// A deliberate 0 and a never-set 0 read identically off disk, so the seed
    /// has to consult the marker rather than the value. If it didn't, choosing
    /// "at start time" on a fresh install would be undone on the next launch.
    @Test("a deliberate choice of zero is never overruled")
    func seedRespectsADeliberateZero() {
        let defaults = scratchDefaults()

        let first = AppSettings(defaults: defaults)
        first.defaultReminderLeadMinutes = 10
        first.defaultReminderLeadMinutes = 0

        let second = AppSettings(defaults: defaults)
        second.seedReminderLeadDefault(hasExistingItems: false)
        #expect(second.defaultReminderLeadMinutes == 0)
    }

    @Test("a chosen lead survives the seed")
    func seedRespectsAChosenLead() {
        let defaults = scratchDefaults()

        let first = AppSettings(defaults: defaults)
        first.defaultReminderLeadMinutes = 30

        let second = AppSettings(defaults: defaults)
        second.seedReminderLeadDefault(hasExistingItems: false)
        #expect(second.defaultReminderLeadMinutes == 30)
    }

    /// The delete-everything hole. Without the marker, an existing user who
    /// cleared their schedule would look brand new on the next launch and have
    /// their lead moved — the same bug the seed was written to prevent, just
    /// arriving a week later.
    @Test("clearing the schedule can't re-trigger the seed")
    func seedRunsOnceEvenIfTheScheduleEmpties() {
        let defaults = scratchDefaults()

        AppSettings(defaults: defaults).seedReminderLeadDefault(hasExistingItems: true)

        let afterDeletingEverything = AppSettings(defaults: defaults)
        afterDeletingEverything.seedReminderLeadDefault(hasExistingItems: false)
        #expect(afterDeletingEverything.defaultReminderLeadMinutes == 0)
    }

    /// `ScheduleView.task` re-runs on every appearance, so the seed is called
    /// far more than once per install.
    @Test("the seed is idempotent across repeated launches")
    func seedIsIdempotent() {
        let defaults = scratchDefaults()

        let first = AppSettings(defaults: defaults)
        first.seedReminderLeadDefault(hasExistingItems: false)
        first.defaultReminderLeadMinutes = 60

        let second = AppSettings(defaults: defaults)
        second.seedReminderLeadDefault(hasExistingItems: false)
        #expect(second.defaultReminderLeadMinutes == 60)
    }

    /// The seeded value has to be one the add sheet's picker can show, or a new
    /// user's first capture opens on a selection missing from its own list.
    @Test("the seeded lead is offered by the picker")
    func seededLeadIsOfferable() {
        #expect(ReminderLead.options.contains(ReminderLead.newInstallDefault))
    }

    // MARK: - Cloud parsing

    @Test("captures may be sent by default, and the choice persists")
    func cloudParsingPreference() {
        let defaults = scratchDefaults()
        #expect(AppSettings(defaults: defaults).cloudParsingEnabled)

        let first = AppSettings(defaults: defaults)
        first.cloudParsingEnabled = false
        #expect(AppSettings(defaults: defaults).cloudParsingEnabled == false)
    }

    /// A fresh draft opens on the user's default; a draft made from an item
    /// already saved keeps that item's own lead. The second half is the one
    /// worth pinning: without it, opening an old event to fix its title would
    /// quietly re-time its reminder.
    @Test("the default seeds new drafts only")
    func leadSeedsNewDraftsOnly() {
        let fresh = CaptureDraft(kind: .event, defaultLeadMinutes: 30)
        #expect(fresh.reminderLeadMinutes == 30)

        let saved = ScheduleItem(title: "Standup", kind: .event, category: .work)
        saved.reminderLeadMinutes = nil
        #expect(CaptureDraft(item: saved).reminderLeadMinutes == 0)

        saved.reminderLeadMinutes = 60
        #expect(CaptureDraft(item: saved).reminderLeadMinutes == 60)
    }

    @Test("preferences survive a relaunch")
    func persistence() {
        let defaults = scratchDefaults()

        let first = AppSettings(defaults: defaults)
        first.appearance = .dark
        first.accent = .vividOrange
        first.tagDisplay = .obvious
        first.hasOpenedMoreSection = true
        first.setColor(.vividYellow, for: .work)

        let second = AppSettings(defaults: defaults)
        #expect(second.appearance == .dark)
        #expect(second.accent == .vividOrange)
        #expect(second.tagDisplay == .obvious)
        #expect(second.hasOpenedMoreSection)
        #expect(second.color(for: .work) == .vividYellow)
        // Untouched categories keep their shipped colour.
        #expect(second.color(for: .health) == ThemePalette.defaultCategories[.health])
    }

    /// The link the whole colour feature hangs on: `Theme.Colors` resolves
    /// through `ThemePalette`, so a choice that doesn't land there changes
    /// nothing on screen no matter how well it persists.
    @Test("choosing a colour pushes it into the live palette")
    func paletteSync() {
        let settings = AppSettings(defaults: scratchDefaults())

        settings.accent = .mutedGreen
        #expect(ThemePalette.accent == .mutedGreen)

        settings.setColor(.vividPink, for: .personal)
        #expect(ThemePalette.color(for: .personal) == .vividPink)

        settings.resetColors()
        #expect(ThemePalette.accent == ThemePalette.defaultAccent)
        #expect(ThemePalette.color(for: .personal) == ThemePalette.defaultCategories[.personal])
    }

    @Test("constructing a store publishes its stored colours immediately")
    func paletteSyncOnInit() {
        let defaults = scratchDefaults()
        AppSettings(defaults: defaults).accent = .graphite

        // A relaunch reads from disk in `init`, where `didSet` never fires — so
        // the push has to be explicit there or the app starts on the wrong hue.
        _ = AppSettings(defaults: defaults)
        #expect(ThemePalette.accent == .graphite)
    }

    /// Anything offered as an accent has `onAccent` text sitting directly on it.
    /// That ink is now derived per swatch instead of being a fixed white, so the
    /// invariant is no longer "white works on everything" — it's that whichever
    /// ink a swatch picks actually clears 4.5:1 on it, in both themes. This is
    /// what lets the picker stay a curated list instead of a colour wheel.
    @Test("every swatch clears 4.5:1 against its own ink, both themes")
    func swatchesCarryTheirInk() {
        for choice in PaletteColor.all {
            for dark in [false, true] {
                let ratio = contrast(choice.hex(dark: dark), choice.ink(dark: dark))
                #expect(
                    ratio >= 4.5,
                    "\(choice.name) \(dark ? "dark" : "light") is \(ratio) against its ink"
                )
            }
        }
    }

    /// "Obvious" mode washes a whole row in the tag colour and leaves the title
    /// on the normal text ink, so every swatch has to survive that composite —
    /// including the pastels, which fill almost opaquely in light mode. AA is
    /// 4.5:1; this holds a much higher line because body text on a coloured row
    /// is the least forgiving thing in the app.
    @Test("every tag colour keeps row text legible in Obvious mode")
    func rowFillsStayLegible() {
        // The canvas each fill composites over, and the ink that lands on top.
        let canvas: [Bool: UInt] = [false: 0xF5F4F1, true: 0x16161A]
        let text: [Bool: UInt] = [false: 0x1C1B19, true: 0xF2F1EE]

        for choice in PaletteColor.all {
            for dark in [false, true] {
                let filled = blend(
                    choice.hex(dark: dark),
                    alpha: choice.rowFillAlpha(dark: dark),
                    over: canvas[dark]!
                )
                let ratio = contrast(filled, text[dark]!)
                #expect(
                    ratio >= 7,
                    "\(choice.name) \(dark ? "dark" : "light") row fill is \(ratio) against body text"
                )
            }
        }
    }

    /// A stored id from the palette that shipped before the three-tier set has
    /// to keep resolving, or every existing user silently reverts to defaults on
    /// update. `graphite` is the one id that survived unchanged.
    @Test("colours chosen under the old palette still resolve")
    func legacyIDsMigrate() {
        #expect(PaletteColor.named("inkBlue") == .vividBlue)
        #expect(PaletteColor.named("slate") == .mutedBlue)
        #expect(PaletteColor.named("forest") == .vividGreen)
        #expect(PaletteColor.named("blush") == .pastelRed)
        #expect(PaletteColor.named("graphite") == .graphite)
        #expect(PaletteColor.named("nonsense") == nil)

        // And the migration has to survive the round trip through defaults,
        // which is where it actually matters.
        let defaults = scratchDefaults()
        defaults.set("plum", forKey: "accentColor")
        #expect(AppSettings(defaults: defaults).accent == .vividPurple)
    }

    /// The tiers are meant to be variants of one hue set, which only holds if
    /// they stay the same length and order. A hue added to one tier and
    /// forgotten in another would break the picker's column alignment.
    @Test("every hue tier covers the same seven hues")
    func tiersAreParallel() {
        let hueTiers = [PaletteColor.pastels, PaletteColor.vivids, PaletteColor.muteds]
        for tier in hueTiers {
            #expect(tier.count == 7)
        }
        #expect(Set(PaletteColor.all.map(\.id)).count == PaletteColor.all.count)
        // `all` must be exactly the tiers, or the picker would silently drop a
        // swatch that only exists in one of the two lists.
        #expect(PaletteColor.all.count == PaletteTier.allCases.reduce(0) { $0 + PaletteColor.tier($1).count })
    }

    @Test("reset only touches colour, not appearance or tag style")
    func resetIsNarrow() {
        let settings = AppSettings(defaults: scratchDefaults())
        settings.appearance = .dark
        settings.tagDisplay = .obvious
        settings.accent = .vividPurple

        settings.resetColors()

        #expect(settings.appearance == .dark)
        #expect(settings.tagDisplay == .obvious)
        #expect(settings.accent == ThemePalette.defaultAccent)
    }
}

/// Flatten a translucent fill onto an opaque background, the way the row wash
/// actually lands on screen. Straight `source-over` in sRGB, which is what
/// UIColor does — contrast has to be measured against the *result*, not against
/// the colour the alpha was applied to.
///
/// `contrast` and `relativeLuminance` come from the app module; there used to be
/// a second copy of them here, which is exactly how a test starts agreeing with
/// itself instead of with the code.
private func blend(_ fill: UInt, alpha: Double, over background: UInt) -> UInt {
    var out: UInt = 0
    for shift: UInt in [16, 8, 0] {
        let f = Double((fill >> shift) & 0xFF)
        let b = Double((background >> shift) & 0xFF)
        let mixed = UInt((alpha * f + (1 - alpha) * b).rounded())
        out |= min(255, mixed) << shift
    }
    return out
}
