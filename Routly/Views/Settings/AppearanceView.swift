//
//  AppearanceView.swift
//  RoutineOrganizer
//
//  How the app looks and what it puts on screen: light or dark, the colours,
//  which calendar views are offered, and whether Today keeps a heading for the
//  things already finished.
//
//  These were split across the menu and a "Preferences" page, which meant
//  light/dark and the accent colour — one decision, made in one sitting — lived
//  two taps apart under different headings. They are one intent, so they are one
//  screen, and it sits low in the list because nobody reaches for it twice.
//
//  Colours stay a page of their own rather than being folded in here: that
//  screen is a live preview and three swatch grids, and it would swamp
//  everything else on this one.
//

import SwiftUI

struct AppearanceView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    themeSection
                    colourSection
                    todaySection
                    calendarSection
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
    }

    // MARK: - Theme

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Theme")

            VStack(spacing: 12) {
                AppearanceSwitcher(selection: $settings.appearance)

                Text(appearanceNote)
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .surfaceCard()
        }
    }

    private var appearanceNote: LocalizedStringKey {
        switch settings.appearance {
        case .system: return "Follows your phone's light or dark setting."
        case .light: return "Always light, whatever your phone is set to."
        case .dark: return "Always dark, whatever your phone is set to."
        }
    }

    // MARK: - Colour

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Colour")

            NavigationLink {
                ColorSettingsView()
            } label: {
                SettingsRow(
                    icon: "paintpalette.fill",
                    title: String(localized: "Colours"),
                    detail: colourDetail
                )
            }
            .buttonStyle(.plain)
            .surfaceCard(padding: 0)
        }
    }

    private var colourDetail: String {
        "\(settings.accent.name) accent · \(settings.tagDisplay.displayName) tags"
    }

    // MARK: - Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Today")

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.showsFinishedToday) {
                    Text("Finished section on Today")
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                .tint(Theme.Colors.accent)

                Text("The list of what you've already ticked off. Collapsing it on Today hides the contents; this hides the heading as well.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .surfaceCard()
        }
    }

    // MARK: - Calendar

    /// Which views the calendar offers. Someone who only ever reads an agenda
    /// shouldn't have to walk past two other modes to get to it.
    ///
    /// The last enabled mode can't be switched off — `AppSettings` refuses it —
    /// so the row stays on rather than producing a calendar with nothing in it.
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Calendar")

            VStack(spacing: 0) {
                ForEach(Array(CalendarMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    Toggle(isOn: calendarModeBinding(mode)) {
                        Label(mode.rawValue, systemImage: mode.symbolName)
                            .font(Theme.Typography.itemTitle())
                            .foregroundStyle(Theme.Colors.textPrimary)
                    }
                    .tint(Theme.Colors.accent)
                    .padding(.horizontal, Theme.Metrics.cardPadding)
                    .padding(.vertical, Theme.Metrics.rowPadding)

                    if index < CalendarMode.allCases.count - 1 {
                        Divider().padding(.leading, Theme.Metrics.cardPadding)
                    }
                }
            }
            .surfaceCard(padding: 0)

            Text("The calendar shows the views you keep here. The last one can't be switched off.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func calendarModeBinding(_ mode: CalendarMode) -> Binding<Bool> {
        Binding(
            get: { settings.isCalendarModeEnabled(mode) },
            set: { settings.setCalendarMode(mode, enabled: $0) }
        )
    }
}

#Preview {
    NavigationStack {
        AppearanceView()
    }
}
