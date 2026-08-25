//
//  AppSettings.swift
//  RoutineOrganizer
//
//  Every preference the app persists, in one observable place.
//
//  This replaces the scattered `@AppStorage` declarations. Two views each
//  holding their own `@AppStorage` for the same key is what made the appearance
//  setting look like it needed a relaunch: the writer updated, the reader —
//  living in a different presentation, behind a sheet — did not reliably. One
//  shared `@Observable` object has no such seam. Anything that reads
//  `settings.appearance` in its body re-renders the moment it changes.
//
//  Colour choices are mirrored into `ThemePalette` on every write, because the
//  `Theme.Colors` tokens resolve inside a UIColor trait closure that must not
//  reach into observable state.
//

import SwiftUI

@Observable
final class AppSettings {

    /// One instance for the whole app. Views hold a plain reference to it rather
    /// than taking it from the environment, so no call site — or preview — has
    /// to be wired up to get the current settings.
    @MainActor static let shared = AppSettings()

    // MARK: - Stored preferences

    var appearance: AppearanceSetting {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// The single accent, used sparingly but everywhere.
    var accent: PaletteColor {
        didSet {
            defaults.set(accent.id, forKey: Keys.accent)
            syncPalette()
        }
    }

    /// Per-category tag colours, keyed by the category's raw value.
    var categoryColors: [Category: PaletteColor] {
        didSet {
            let encoded = categoryColors.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value.id }
            defaults.set(encoded, forKey: Keys.categoryColors)
            syncPalette()
        }
    }

    /// Whether an item wears its tag colour as a full background or a small dot.
    var tagDisplay: TagDisplayStyle {
        didSet { defaults.set(tagDisplay.rawValue, forKey: Keys.tagDisplay) }
    }

    /// What the two scope headings are called.
    ///
    /// Stored rather than hardcoded because "To-dos" and "Long-term" are this
    /// app's words for the split, not the user's — someone thinking in "Now" and
    /// "Someday" shouldn't have to translate every time they look at the screen.
    /// Empty falls back to the default, so clearing the field can't produce a
    /// nameless heading.
    var todayGroupName: String {
        didSet { defaults.set(todayGroupName, forKey: Keys.todayGroupName) }
    }

    var longTermGroupName: String {
        didSet { defaults.set(longTermGroupName, forKey: Keys.longTermGroupName) }
    }

    func groupName(for scope: TodoScope) -> String {
        let stored = scope == .today ? todayGroupName : longTermGroupName
        let clean = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return scope.defaultGroupName }
        return clean
    }

    func setGroupName(_ name: String, for scope: TodoScope) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = clean.isEmpty ? scope.defaultGroupName : clean
        if scope == .today { todayGroupName = value } else { longTermGroupName = value }
    }

    /// Whether Today shows a "Finished today" section at all.
    ///
    /// Collapsing it hides its contents; this hides the heading too. Both exist
    /// because they answer different questions — "not right now" and "not ever"
    /// — and someone who never wants to look at what they've already done
    /// shouldn't have to keep a collapsed row on the screen to say so.
    var showsFinishedToday: Bool {
        didSet { defaults.set(showsFinishedToday, forKey: Keys.showsFinishedToday) }
    }

    /// Which sections on Today are collapsed, by their stable id.
    ///
    /// Persisted rather than session state: collapsing a section is how someone
    /// says "this isn't what I'm here for", and re-opening it on every launch
    /// would make them say it again every morning.
    private(set) var collapsedSections: Set<String> {
        didSet { defaults.set(Array(collapsedSections), forKey: Keys.collapsedSections) }
    }

    func isCollapsed(_ id: String) -> Bool { collapsedSections.contains(id) }

    func setCollapsed(_ collapsed: Bool, for id: String) {
        if collapsed { collapsedSections.insert(id) } else { collapsedSections.remove(id) }
    }

    /// Which calendar modes appear in the mode switcher.
    ///
    /// Stored as raw strings rather than the enum so a mode that is renamed or
    /// removed later degrades to "unknown, ignored" instead of failing to decode
    /// the whole set.
    ///
    /// Never allowed to end up empty — a calendar with no modes is a blank
    /// screen — so the accessor falls back to every mode when the stored set
    /// resolves to nothing.
    private(set) var calendarModeIDs: Set<String> {
        didSet { defaults.set(Array(calendarModeIDs), forKey: Keys.calendarModes) }
    }

    /// The modes to offer, in declaration order. Always at least one.
    var calendarModes: [CalendarMode] {
        let enabled = CalendarMode.allCases.filter { calendarModeIDs.contains($0.id) }
        return enabled.isEmpty ? CalendarMode.allCases : enabled
    }

    func isCalendarModeEnabled(_ mode: CalendarMode) -> Bool {
        calendarModes.contains(mode)
    }

    /// Turning the last one off is refused rather than obeyed: the alternative
    /// is a calendar tab that shows nothing and offers no way back.
    func setCalendarMode(_ mode: CalendarMode, enabled: Bool) {
        var updated = Set(calendarModes.map(\.id))
        if enabled { updated.insert(mode.id) } else { updated.remove(mode.id) }
        guard !updated.isEmpty else { return }
        calendarModeIDs = updated
    }

    /// Which external calendars new events are written to.
    ///
    /// Stored as raw provider strings rather than the enum, so a provider that
    /// is renamed or dropped later degrades to "unknown, ignored" instead of
    /// failing to decode the whole set — the same reasoning as `calendarModeIDs`
    /// above.
    ///
    /// A missing key means the user has never turned one on, and the wanted
    /// default is **none**: Routly only. Writing into somebody's calendar is
    /// not a thing to start doing because a default said so.
    private(set) var calendarDestinationIDs: Set<String> {
        didSet { defaults.set(Array(calendarDestinationIDs), forKey: Keys.calendarDestinations) }
    }

    /// The calendars new events go to, as providers this build can offer.
    ///
    /// This is the whole of the decision. There is deliberately no per-event
    /// override: the add sheet used to carry chips for it, and the result was a
    /// person who had connected a calendar in Settings, watched it say
    /// "Connected", and still had to remember to tick something on every single
    /// capture. Turning a calendar on here means events go there — that is what
    /// people expect the switch to mean, and it is now what it does.
    ///
    /// Filtered on read rather than on write, so a choice made while a provider
    /// was available survives it being temporarily unavailable — a lapsed grant
    /// shouldn't quietly erase the preference behind it.
    var calendarDestinations: Set<CalendarProvider> {
        get { Set(calendarDestinationIDs.compactMap(CalendarProvider.init(rawValue:))) }
        set { calendarDestinationIDs = Set(newValue.map(\.rawValue)) }
    }

    func setCalendarDestination(_ provider: CalendarProvider, enabled: Bool) {
        var updated = calendarDestinations
        if enabled { updated.insert(provider) } else { updated.remove(provider) }
        calendarDestinations = updated
    }

    func isCalendarDestinationEnabled(_ provider: CalendarProvider) -> Bool {
        calendarDestinations.contains(provider)
    }

    /// Set the first time the "More" section on the add sheet is opened. The
    /// nudge pointing at it is only worth showing to someone who hasn't found it.
    var hasOpenedMoreSection: Bool {
        didSet { defaults.set(hasOpenedMoreSection, forKey: Keys.hasOpenedMoreSection) }
    }

    /// The window of the day the app may plan inside. Free time, overload and
    /// every slot the app picks for the user are measured against this rather
    /// than against a 24-hour day.
    ///
    /// Normalized on write, so no caller downstream has to cope with an
    /// end-before-start pair.
    var workingHours: WorkingHours {
        didSet {
            let clean = workingHours.normalized
            // Correcting the value re-enters this `didSet`. That terminates
            // because `normalized` is idempotent: the second pass finds
            // `clean == workingHours` and falls through to the write. Storing
            // the clean value while leaving a bad one in the property would be
            // worse — the picker would keep showing what was rejected.
            if clean != workingHours {
                workingHours = clean
                return
            }
            defaults.set(clean.startMinutes, forKey: Keys.workingHoursStart)
            defaults.set(clean.endMinutes, forKey: Keys.workingHoursEnd)
        }
    }

    /// How far ahead of a timed item its reminder fires, for items the user
    /// hasn't set a lead on themselves.
    ///
    /// What this buys is saying "always warn me ten minutes early" once, instead
    /// of opening "More" on the add sheet and saying it again on every capture.
    ///
    /// Where it starts depends on who is asking, and the two cases are not the
    /// same person:
    ///
    ///  • A brand-new install starts at `ReminderLead.newInstallDefault`.
    ///  • An install that already has a schedule stays at 0 — the behaviour it
    ///    has always had — because moving it would re-time reminders that are
    ///    already set.
    ///
    /// That decision is made once, by `seedReminderLeadDefault(hasExistingItems:)`.
    /// This property is a plain stored value; it does not resolve the default
    /// itself, because a computed default would have to keep re-deciding and
    /// could not tell a deliberate 0 from an untouched one.
    ///
    /// Only ever applied to a *new* draft. Editing an existing item keeps the
    /// lead that item was saved with, because changing this setting must not
    /// quietly re-time reminders that are already set.
    var defaultReminderLeadMinutes: Int {
        didSet { defaults.set(defaultReminderLeadMinutes, forKey: Keys.defaultReminderLead) }
    }

    /// Whether captures may be sent to the configured cloud parser.
    ///
    /// On by default, because with no key configured there is nothing to send
    /// and the flag is inert — and with one configured, cloud parsing is what
    /// makes a messy sentence come back as separate, correctly-timed items.
    ///
    /// Turning it off is a real trade, not a free privacy win: the offline path
    /// is rule-based, and the settings screen says so before the switch is
    /// touched rather than letting someone discover it in worse captures.
    var cloudParsingEnabled: Bool {
        didSet { defaults.set(cloudParsingEnabled, forKey: Keys.cloudParsingEnabled) }
    }

    /// The interface language. Writing `AppleLanguages` is what iOS itself reads
    /// at launch, so this takes effect on the next start — the settings screen
    /// says so rather than pretending otherwise.
    var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            applyLanguageOverride()
        }
    }

    /// The language spoken into the mic. Separate from `appLanguage` on purpose:
    /// reading the app in one language and dictating in another is normal.
    var voiceLanguage: VoiceLanguage {
        didSet { defaults.set(voiceLanguage.rawValue, forKey: Keys.voiceLanguage) }
    }

    /// Languages the user has agreed may be transcribed by Apple's servers,
    /// because no on-device model was available for them on this device.
    ///
    /// Asked once per language and remembered. Absence means "not yet asked" —
    /// which is not the same as "no", so the two are never conflated.
    private(set) var serverSpeechApproved: Set<String> {
        didSet { defaults.set(Array(serverSpeechApproved), forKey: Keys.serverSpeechApproved) }
    }

    // MARK: - Redraw signal

    /// Bumped whenever a colour changes. `Theme.Colors` resolves through plain
    /// statics, which SwiftUI has no way to observe — so the root view keys off
    /// this to rebuild once and pick up the new palette everywhere at once.
    private(set) var paletteRevision = 0

    // MARK: - Init

    private let defaults: UserDefaults

    /// Where the interface-language override is written.
    ///
    /// Deliberately *not* `defaults`. `AppleLanguages` is read by iOS from the
    /// process's own defaults at launch; writing it into the shared App Group
    /// suite would put it somewhere nothing reads, and "Spanish" would silently
    /// stop taking effect the moment the rest of the settings moved into the
    /// group. The preference itself still lives in the shared suite — that's how
    /// the widget knows which language to render in — but the switch iOS reads
    /// stays in the app's own domain.
    private let systemDefaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults, systemDefaults: UserDefaults = .standard) {
        self.systemDefaults = systemDefaults
        self.defaults = defaults
        appearance = AppearanceSetting(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        accent = PaletteColor.named(defaults.string(forKey: Keys.accent)) ?? ThemePalette.defaultAccent
        tagDisplay = TagDisplayStyle(rawValue: defaults.string(forKey: Keys.tagDisplay) ?? "") ?? .discreet
        hasOpenedMoreSection = defaults.bool(forKey: Keys.hasOpenedMoreSection)
        calendarDestinationIDs = Set(defaults.stringArray(forKey: Keys.calendarDestinations) ?? [])
        todayGroupName = defaults.string(forKey: Keys.todayGroupName) ?? TodoScope.today.defaultGroupName
        longTermGroupName = defaults.string(forKey: Keys.longTermGroupName) ?? TodoScope.longTerm.defaultGroupName
        collapsedSections = Set(defaults.stringArray(forKey: Keys.collapsedSections) ?? [])
        // `object(forKey:)` rather than `bool(forKey:)`: a missing key reads as
        // false, and the wanted default here is on.
        showsFinishedToday = defaults.object(forKey: Keys.showsFinishedToday) as? Bool ?? true
        // A missing key means "never chosen", which is every mode — not none.
        calendarModeIDs = Set(defaults.stringArray(forKey: Keys.calendarModes)
            ?? CalendarMode.allCases.map(\.id))
        // `object(forKey:)` rather than `integer(forKey:)`: a missing key reads
        // as 0, which is a legitimate minute-of-day (midnight) and would be
        // indistinguishable from someone who genuinely set it there.
        if let start = defaults.object(forKey: Keys.workingHoursStart) as? Int,
           let end = defaults.object(forKey: Keys.workingHoursEnd) as? Int {
            workingHours = WorkingHours(startMinutes: start, endMinutes: end).normalized
        } else {
            workingHours = .default
        }
        // A missing key reads as 0, which is also the wanted default here — but
        // it's spelled out rather than relying on that, since 0 is a meaningful
        // choice ("at the start time") rather than an absence of one.
        defaultReminderLeadMinutes = defaults.object(forKey: Keys.defaultReminderLead) as? Int ?? 0
        // Missing means never chosen, and the wanted default is on.
        cloudParsingEnabled = defaults.object(forKey: Keys.cloudParsingEnabled) as? Bool ?? true
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.appLanguage) ?? "") ?? .system
        // No stored value means the user has never chosen — follow the phone
        // rather than assuming English.
        voiceLanguage = VoiceLanguage(rawValue: defaults.string(forKey: Keys.voiceLanguage) ?? "")
            ?? .systemDefault
        serverSpeechApproved = Set(defaults.stringArray(forKey: Keys.serverSpeechApproved) ?? [])

        let stored = defaults.dictionary(forKey: Keys.categoryColors) as? [String: String] ?? [:]
        var resolved = ThemePalette.defaultCategories
        for category in Category.allCases {
            if let choice = PaletteColor.named(stored[category.rawValue]) {
                resolved[category] = choice
            }
        }
        categoryColors = resolved

        // `didSet` doesn't fire during init, so the first push is explicit.
        syncPalette()
    }

    // MARK: - First-run seeding

    /// Give a brand-new install a reminder lead of ten minutes, and leave every
    /// existing install exactly as it was.
    ///
    /// The problem this solves: "never chosen" and "deliberately chose 0" look
    /// identical in `UserDefaults`, because a preference is only written when
    /// it's set. So a lead of 0 on disk can't be told from no lead at all, and
    /// seeding on absence alone would re-time the reminders of everyone already
    /// using the app — the one outcome worth avoiding here.
    ///
    /// Probing the other settings keys doesn't work either, and fails in the
    /// worst direction: every property here writes only in `didSet`, so a
    /// long-standing user who never changed a setting has no keys at all and
    /// would be read as brand new.
    ///
    /// What does separate them is whether they have a schedule. Someone using a
    /// schedule app who has never created a single item has no reminders that
    /// could be re-timed, so treating them as new is safe by construction.
    ///
    /// `Keys.reminderLeadSeeded` makes the decision exactly once. Without it,
    /// an existing user who deleted everything would look brand new on the next
    /// launch and have their lead silently moved — which is the same bug by a
    /// longer route.
    func seedReminderLeadDefault(hasExistingItems: Bool) {
        guard defaults.object(forKey: Keys.reminderLeadSeeded) == nil else { return }
        defaults.set(true, forKey: Keys.reminderLeadSeeded)

        // A value on disk means the user has already answered this — including
        // when the answer was 0. Never overrule it.
        guard defaults.object(forKey: Keys.defaultReminderLead) == nil else { return }
        guard !hasExistingItems else { return }

        defaultReminderLeadMinutes = ReminderLead.newInstallDefault
    }

    // MARK: - Working hours

    /// The working hours that apply on a given day.
    ///
    /// Today this ignores `day` and hands back the one range — the app has a
    /// single window applied across the week. Every consumer asks the question
    /// this way regardless, so splitting weekdays from weekends later is a
    /// change to this method rather than a re-thread of the planner, the
    /// conflict detector and the parser.
    func workingHours(on day: Date) -> WorkingHours {
        _ = day
        return workingHours
    }

    // MARK: - Actions

    func color(for category: Category) -> PaletteColor {
        categoryColors[category] ?? ThemePalette.defaultCategories[category] ?? .mutedBlue
    }

    func setColor(_ color: PaletteColor, for category: Category) {
        categoryColors[category] = color
    }

    /// Back to the colours the app shipped with. Appearance and tag style are
    /// left alone — this button is about colour, and silently flipping unrelated
    /// settings would be a surprise.
    func resetColors() {
        accent = ThemePalette.defaultAccent
        categoryColors = ThemePalette.defaultCategories
    }

    var usesDefaultColors: Bool {
        accent == ThemePalette.defaultAccent && categoryColors == ThemePalette.defaultCategories
    }

    // MARK: - Language

    /// Whether the user has already answered the server-transcription question
    /// for a language. Distinguishes "said no" from "never asked".
    func hasDecidedServerSpeech(for language: VoiceLanguage) -> Bool {
        defaults.object(forKey: Keys.serverSpeechAsked(language)) != nil
    }

    func allowsServerSpeech(for language: VoiceLanguage) -> Bool {
        serverSpeechApproved.contains(language.rawValue)
    }

    /// Record the user's answer. Declining is remembered too, so they are asked
    /// once and not again every time they hold the mic.
    func setServerSpeech(_ allowed: Bool, for language: VoiceLanguage) {
        defaults.set(true, forKey: Keys.serverSpeechAsked(language))
        if allowed {
            serverSpeechApproved.insert(language.rawValue)
        } else {
            serverSpeechApproved.remove(language.rawValue)
        }
    }

    /// Points `AppleLanguages` at the chosen language, or clears the override so
    /// iOS decides again.
    private func applyLanguageOverride() {
        if let identifier = appLanguage.localeIdentifier {
            systemDefaults.set([identifier], forKey: AppLanguage.appleLanguagesKey)
        } else {
            systemDefaults.removeObject(forKey: AppLanguage.appleLanguagesKey)
        }
    }

    private func syncPalette() {
        ThemePalette.accent = accent
        ThemePalette.categories = categoryColors
        paletteRevision += 1
    }
}

// MARK: - Reminder lead

/// How far before a timed item its reminder fires, as offered to the user.
///
/// One list, shared by the add sheet and the settings screen, so the default
/// can only ever be a value the picker on the sheet can also show. They used to
/// be two hardcoded arrays, which is the sort of thing that stays in agreement
/// right up until it doesn't.
///
/// `label` goes through `String(localized:)` rather than returning a bare
/// literal. The add sheet's version didn't, and `Text(String)` skips the catalog
/// — so the notify picker read "At start time" in Spanish and Portuguese too.
enum ReminderLead {
    static let options = [0, 10, 30, 60, 120, 180]

    /// What a fresh install starts on.
    ///
    /// Not zero. "Notify at the start time" tells someone a thing is happening
    /// at the moment it is already happening, which is a record rather than a
    /// nudge — and being nudged *through* the day is the whole claim the app
    /// makes. Ten minutes is enough to stand up and go.
    ///
    /// Applied only by `seedReminderLeadDefault(hasExistingItems:)`, and only
    /// to installs with no schedule yet. See the note there.
    static let newInstallDefault = 10

    static func label(_ minutes: Int) -> String {
        switch minutes {
        case 0: return String(localized: "At start time")
        case ..<60: return String(localized: "\(minutes) minutes before")
        case 60: return String(localized: "1 hour before")
        default: return String(localized: "\(minutes / 60) hours before")
        }
    }

    /// The same lead time as the *notification* says it — a countdown rather
    /// than the picker's "before" phrasing.
    ///
    /// Split by magnitude. The notification body used to divide by 60 whatever
    /// the lead was, so the two shortest options — the default among them —
    /// arrived as "Starts in 0 hours", which tells the reader nothing about a
    /// reminder they are looking at *because* it is about to happen.
    ///
    /// Each branch is one catalog key carrying its own plural forms, and the
    /// mixed case is a single two-argument key rather than two lookups joined
    /// here: composing "1 hour" with "30 minutes" in Swift would put the join
    /// — and any language that words it differently — out of the translator's
    /// reach.
    static func countdownPhrase(_ minutes: Int) -> String {
        guard minutes > 0 else { return String(localized: "Starting now") }
        let hours = minutes / 60
        let remainder = minutes % 60
        switch (hours, remainder) {
        case (0, _): return String(localized: "In \(remainder) minutes")
        case (_, 0): return String(localized: "In \(hours) hours")
        default: return String(localized: "In \(hours) hours \(remainder) minutes")
        }
    }
}

// MARK: - Tag display

/// How loudly an item wears its category colour.
enum TagDisplayStyle: String, CaseIterable, Identifiable, Sendable {
    /// The whole row is washed in the tag colour — you see the category before
    /// you read the title.
    case obvious
    /// A neutral row with a small colour dot at the trailing edge.
    case discreet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .obvious: return String(localized: "Obvious")
        case .discreet: return String(localized: "Discreet")
        }
    }

    var detail: String {
        switch self {
        case .obvious: return String(localized: "Fills each item with its tag colour.")
        case .discreet: return String(localized: "A small colour dot at the end of each item.")
        }
    }

    var symbolName: String {
        switch self {
        case .obvious: return "rectangle.fill"
        case .discreet: return "circle.fill"
        }
    }
}

// MARK: - Keys

/// Internal rather than private so `SettingsMigration` can enumerate them.
///
/// A migration that hardcoded its own copy of this list would drift the first
/// time a preference was added — and the failure is invisible: the new setting
/// simply doesn't come across, and the user finds their accent colour reset
/// weeks later with nothing to point at. One list, read by both.
enum Keys {
    static let appearance = AppearanceSetting.storageKey
    static let accent = "accentColor"
    static let categoryColors = "categoryColors"
    static let tagDisplay = "tagDisplayStyle"
    static let calendarModes = "calendarModes"
    static let todayGroupName = "todayGroupName"
    static let longTermGroupName = "longTermGroupName"
    static let collapsedSections = "collapsedSections"
    static let showsFinishedToday = "showsFinishedToday"
    static let hasOpenedMoreSection = "hasOpenedMoreSection"
    static let workingHoursStart = "workingHoursStartMinutes"
    static let workingHoursEnd = "workingHoursEndMinutes"
    static let appLanguage = AppLanguage.storageKey
    static let voiceLanguage = VoiceLanguage.storageKey
    static let serverSpeechApproved = "serverSpeechApproved"
    static let defaultReminderLead = "defaultReminderLeadMinutes"
    static let reminderLeadSeeded = "defaultReminderLeadSeeded"
    static let cloudParsingEnabled = "cloudParsingEnabled"
    /// The stored string deliberately keeps its original name. A key is a wire
    /// format: renaming it would silently reset the preference of anyone who
    /// had already turned a calendar on.
    static let calendarDestinations = "lastCalendarTargets"

    static func serverSpeechAsked(_ language: VoiceLanguage) -> String {
        "serverSpeechAsked.\(language.rawValue)"
    }

    /// The per-language consent keys share this prefix; there is one per
    /// language the user has been asked about, so they're matched rather than
    /// listed.
    static let serverSpeechAskedPrefix = "serverSpeechAsked."

    /// Every fixed key this app persists.
    ///
    /// `AppLanguage.appleLanguagesKey` is deliberately absent: it belongs to
    /// iOS, lives in the app's own domain, and means nothing in a shared suite.
    static let all: [String] = [
        appearance, accent, categoryColors, tagDisplay, calendarModes,
        todayGroupName, longTermGroupName, collapsedSections, showsFinishedToday,
        hasOpenedMoreSection, workingHoursStart, workingHoursEnd,
        appLanguage, voiceLanguage, serverSpeechApproved,
        defaultReminderLead, reminderLeadSeeded, cloudParsingEnabled,
        calendarDestinations,
    ]
}

// MARK: - Moving preferences into the App Group

/// Copies the user's settings from the app's private defaults into the shared
/// suite, once.
///
/// Needed because the widget extension can't read `UserDefaults.standard` — that
/// domain belongs to the app alone. Without this, everyone who already uses
/// Routly would get widgets rendered in the default accent, with the default
/// group name, as though they'd never chosen anything.
///
/// Deliberately called explicitly at launch rather than from `AppSettings.init`.
/// The initialiser takes an injected suite, and tests construct it against
/// throwaway suites by the dozen; migrating inside it would copy the developer's
/// real preferences into every test's scratch defaults and make those tests read
/// state they never set.
enum SettingsMigration {

    /// Set on the destination once the copy has happened.
    static let doneKey = "settingsMigratedToAppGroup"

    /// Copies each known key that the destination doesn't already have.
    ///
    /// Never overwrites: if the shared suite already holds a value, that value
    /// is newer than anything left in the old domain, and clobbering it would
    /// undo a change the user made after the move.
    static func migrateIfNeeded(
        from source: UserDefaults = .standard,
        to destination: UserDefaults = AppGroup.defaults
    ) {
        // No entitlement means `AppGroup.defaults` *is* `.standard`; there is
        // nothing to move and copying a domain onto itself is pure risk.
        guard destination != source else { return }
        guard destination.object(forKey: doneKey) == nil else { return }

        for key in Keys.all where destination.object(forKey: key) == nil {
            guard let value = source.object(forKey: key) else { continue }
            destination.set(value, forKey: key)
        }

        for (key, value) in source.dictionaryRepresentation()
        where key.hasPrefix(Keys.serverSpeechAskedPrefix) && destination.object(forKey: key) == nil {
            destination.set(value, forKey: key)
        }

        destination.set(true, forKey: doneKey)
    }
}
