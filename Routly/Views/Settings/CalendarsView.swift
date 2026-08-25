//
//  CalendarsView.swift
//  RoutineOrganizer
//
//  Which calendars Routly can write to, what it's currently allowed to do, and
//  what that actually means.
//
//  It fills the slot `MenuView` reserved and deliberately left empty —
//  integrations — on the rule stated there: a row that opens nothing is worse
//  than no row. So this screen only exists now that there is something behind
//  it, and it only lists providers this build can genuinely reach. Google is
//  absent rather than greyed out until a client ID is configured — see
//  `GoogleCalendarConfig` and docs/google-calendar-setup.md.
//
//  Two things this screen refuses to do:
//
//   • **Pretend a limited grant is a working one.** iOS 17's write-only access
//     lets Routly add an event and then never touch it again — no edit
//     following, no delete following. That reads as "connected" and behaves
//     like a slow leak, so it gets its own status word and its own sentence.
//   • **Offer a connect button it can't honour.** Once someone has said no, only
//     the Settings app can change that; a button here would just fail silently.
//     The row says where to go instead.
//
//  The toggle is the point of the screen, and it is now the *only* place the
//  question is asked. The add sheet used to carry chips for it, which meant a
//  person who had connected a calendar here still had to remember to tick
//  something on every single capture — and, since the chips defaulted to off, a
//  calendar could be connected, allowed, and receiving nothing. Where events go
//  is one decision, made once, here.
//
//  Disconnect appears only where the connection is Routly's to hand back.
//  Google's is a token this app holds, and holding somebody's credential with
//  no way to return it is not defensible — so Google gets a button, and pressing
//  it revokes the token, forgets the calendar, and switches the destination off.
//  Apple's grant belongs to iOS: a Routly-side "disconnect" that left the system
//  permission in place would be a second, contradictory source of truth, so
//  there is no button and the row points at the Settings app instead.
//
//  Turning the toggle off stops *new* events going across. It deliberately does
//  not reach back and delete what is already there — see
//  `CalendarSync.currentDestinations(of:)`. An item that was written stays
//  written, and its edits and deletes keep following.
//

import SwiftUI
import SwiftData

struct CalendarsView: View {

    private let connections = CalendarConnections.shared
    @Bindable private var settings = AppSettings.shared

    /// Links whose last push failed, so this screen can say so rather than
    /// leaving the user to notice an absence in their calendar.
    @Query private var links: [CalendarLink]

    @Environment(\.scenePhase) private var scenePhase

    private var providers: [CalendarProvider] { connections.providers }

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    ForEach(providers) { provider in
                        providerSection(provider)
                    }
                    if failedCount > 0 {
                        troubleSection
                    }
                    explainer
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .onAppear { connections.refresh() }
        // The grant can be changed in the Settings app while Routly sits in the
        // background, so coming back is the one moment this screen is certain
        // to be out of date.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connections.refresh() }
        }
    }

    // MARK: - One provider

    private func providerSection(_ provider: CalendarProvider) -> some View {
        let access = connections.access(for: provider)

        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(verbatim: provider.displayName)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: provider.symbolName)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(statusColor(access))
                        .frame(width: 26, height: 26)

                    Text(verbatim: connections.statusLabel(for: provider))
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Spacer(minLength: 8)

                    if access.isAskable {
                        Button("Connect") {
                            Task { await connections.connect(provider) }
                        }
                        .font(Theme.Typography.body())
                        .tint(Theme.Colors.accent)
                    } else if connections.canDisconnect(provider) {
                        // Only where the connection is actually Routly's to
                        // give back. Apple's grant belongs to iOS and the row
                        // points at the Settings app instead — see
                        // `CalendarTarget.canDisconnect`.
                        Button("Disconnect", role: .destructive) {
                            Task { await connections.disconnect(provider) }
                        }
                        .font(Theme.Typography.body())
                        .tint(Theme.Colors.now)
                    }
                }

                // The whole decision, in one switch. Granting permission and
                // choosing a destination are two different things, and the
                // screen used to offer only the first while looking like it
                // had settled both.
                if access.canCreate {
                    RowDivider(inset: 0)
                    Toggle(isOn: defaultBinding(provider)) {
                        Text("Add new events here")
                            .font(Theme.Typography.itemTitle())
                            .foregroundStyle(Theme.Colors.textPrimary)
                    }
                    .tint(Theme.Colors.accent)
                }

                if let detail = connections.statusDetail(for: provider) {
                    Text(verbatim: detail)
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Says the quiet part: connected, allowed, and nothing has
                // actually gone across. Without it, "Connected" with an empty
                // calendar leaves someone with nothing to check.
                if access.canCreate, linkedCount(provider) == nil {
                    Text("Nothing has been added here yet.")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                }

                if let count = linkedCount(provider) {
                    Text("\(count) items are in this calendar.")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
        }
    }

    /// Green for a grant that does everything, the live/careful red for one
    /// that does nothing, and the accent for the middle state — which is not a
    /// failure and shouldn't be coloured like one, but is not finished either.
    private func statusColor(_ access: CalendarAccess) -> Color {
        switch access {
        case .full: return Theme.Colors.done
        case .writeOnly: return Theme.Colors.accent
        case .denied, .restricted: return Theme.Colors.now
        case .notDetermined: return Theme.Colors.textFaint
        }
    }

    // MARK: - Trouble

    private var troubleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Not added")

            VStack(alignment: .leading, spacing: 8) {
                Text("\(failedCount) items couldn't be added to a calendar.")
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Open one and save it again to retry. Routly keeps the item either way — nothing has been lost.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
        }
    }

    // MARK: - What this does

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("What goes across")

            VStack(alignment: .leading, spacing: 12) {
                Text("Events and reminders with a day on them. When you change or delete one in Routly, the calendar follows.")
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("To-dos and repeating items stay in Routly. Nothing comes the other way yet — events you create in a calendar app don't appear here.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                // Said here because it's the promise the nudge depends on, and
                // because someone seeing an event in two apps will reasonably
                // wonder whether they're about to be told about it twice.
                Text("Routly still sends its own reminder. It doesn't add a second alert to the calendar, so nothing tells you twice.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
        }
    }

    /// Writes through `AppSettings` rather than holding its own copy, so the
    /// add sheet's chips and this toggle can't disagree about where new events
    /// go.
    private func defaultBinding(_ provider: CalendarProvider) -> Binding<Bool> {
        Binding(
            get: { settings.isCalendarDestinationEnabled(provider) },
            set: { settings.setCalendarDestination(provider, enabled: $0) }
        )
    }

    // MARK: - Counts

    private var failedCount: Int {
        links.filter { $0.state == .failed }.count
    }

    /// nil rather than 0 when there's nothing to say, so the row is absent
    /// instead of announcing an empty count.
    private func linkedCount(_ provider: CalendarProvider) -> Int? {
        let count = links.filter { $0.provider == provider && $0.state == .linked }.count
        return count > 0 ? count : nil
    }
}

#Preview {
    NavigationStack {
        CalendarsView()
            .modelContainer(
                for: [ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self],
                inMemory: true
            )
    }
}
