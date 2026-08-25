//
//  CalendarView.swift
//  RoutineOrganizer
//
//  The longer-horizon destination, rebuilt as a first-class calendar. Three ways
//  to look at a schedule — Week (a day strip over a time-blocked column with a
//  live now-line and overlap lanes), Month (a real grid with an animated day
//  agenda), and Agenda (a grouped multi-day list). The visible window flips by
//  swipe, step arrows, a "Today" pill, or hardware-keyboard shortcuts, and every
//  transition is a spring with a haptic underneath it.
//
//  On a compact width it's a single stacked column; on a regular width (iPad /
//  desktop) it splits into a sidebar mini-month + a detail pane. Tapping an event
//  opens a thumb-friendly quick-look rather than jumping straight to the editor.
//

import SwiftUI
import SwiftData

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \ScheduleItem.createdAt, order: .reverse) private var items: [ScheduleItem]

    @State private var viewModel = ScheduleViewModel()
    /// Landing on a mode the user has switched off would open the calendar on a
    /// view they can't get back to, so the stored preference decides.
    @State private var mode: CalendarMode = AppSettings.shared.calendarModes.contains(.landing)
        ? .landing
        : (AppSettings.shared.calendarModes.first ?? .landing)
    @State private var selectedDay = Calendar(identifier: .gregorian).startOfDay(for: Date())
    @State private var sheet: CalendarSheet?
    @State private var pendingDelete: PendingDeletion?
    /// A calendar push that didn't land. See the note on the same state in
    /// `ScheduleView` — an event the user asked for and didn't get must say so.
    @State private var calendarError: String?

    private let calendar = Calendar(identifier: .gregorian)
    private let today = Calendar(identifier: .gregorian).startOfDay(for: Date())

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            if sizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .background(shortcuts)
        // The bar is back, and it has to be: this is a pushed view again since
        // the tab bar went, so hiding it left the calendar with no way out —
        // only the edge-swipe, which is invisible and misses anyone who doesn't
        // already know it exists. It carries the back button and nothing else;
        // the screen draws its own "August 2026" heading below.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .task { viewModel.configure(context: modelContext) }
        .sheet(item: $sheet, content: sheetContent)
        .deleteConfirmation(
            $pendingDelete,
            oneOffTitle: "Delete this?",
            oneOffMessage: "This removes it from your calendar for good.",
            onDelete: performDelete
        )
        .alert(
            "Couldn't reach your calendar",
            isPresented: calendarErrorBinding,
            presenting: calendarError
        ) { _ in
            Button("OK", role: .cancel) { calendarError = nil }
        } message: { message in
            Text(verbatim: message)
        }
    }

    private var calendarErrorBinding: Binding<Bool> {
        Binding(get: { calendarError != nil }, set: { if !$0 { calendarError = nil } })
    }

    // MARK: - Compact (iPhone)

    private var compactLayout: some View {
        VStack(spacing: 14) {
            CalendarHeaderBar(
                mode: $mode,
                title: CalendarPeriod.title(for: selectedDay, mode: mode),
                subtitle: CalendarPeriod.subtitle(for: selectedDay, mode: mode),
                isOnToday: windowContainsToday,
                onPrev: { step(-1) },
                onNext: { step(1) },
                onToday: goToday
            )

            modeContent
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                // Week and Month page by swipe; Agenda doesn't. Agenda is
                // already a continuous scroll through the days ahead, so a
                // horizontal swipe jumped a week without anything on screen
                // moving to say it had — the arrows and the Today pill are the
                // honest controls for it.
                .simultaneousGesture(mode == .agenda ? nil : swipeGesture)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .week:
            VStack(spacing: 12) {
                WeekStripView(
                    days: viewModel.weekDays(containing: selectedDay),
                    selectedDay: $selectedDay,
                    items: items,
                    viewModel: viewModel
                )
                DayTimelineView(
                    day: selectedDay,
                    items: viewModel.items(on: selectedDay, from: items),
                    viewModel: viewModel,
                    onSelect: quickLook
                )
            }
            .transition(.opacity)
        case .month:
            VStack(spacing: 14) {
                MonthGridView(
                    days: viewModel.monthGrid(containing: selectedDay),
                    anchor: selectedDay,
                    selectedDay: $selectedDay,
                    items: items,
                    viewModel: viewModel
                )
                DayAgendaView(
                    day: selectedDay,
                    items: viewModel.items(on: selectedDay, from: items),
                    viewModel: viewModel,
                    onSelect: quickLook,
                    onToggle: toggle
                )
            }
            .transition(.opacity)
        case .agenda:
            AgendaListView(
                anchor: selectedDay,
                items: items,
                viewModel: viewModel,
                today: today,
                onSelect: quickLook,
                onToggle: toggle
            )
            .transition(.opacity)
        }
    }

    // MARK: - Regular (iPad / desktop)

    private var regularLayout: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 320)
                .background(Theme.Colors.background)
            Rectangle()
                .fill(Theme.Colors.hairline)
                .frame(width: 1)
            detailPane
                .frame(maxWidth: .infinity)
                .simultaneousGesture(swipeGesture)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CalendarPeriod.title(for: selectedDay, mode: mode))
                    .font(Theme.Typography.title())
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(CalendarPeriod.subtitle(for: selectedDay, mode: mode))
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
            }

            HStack(spacing: 6) {
                sidebarStep(system: "chevron.left") { step(-1) }
                Button(action: goToday) {
                    Text("Today")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.Colors.accentSoft))
                }
                .buttonStyle(.pressable)
                sidebarStep(system: "chevron.right") { step(1) }
            }

            MonthGridView(
                days: viewModel.monthGrid(containing: selectedDay),
                anchor: selectedDay,
                selectedDay: $selectedDay,
                items: items,
                viewModel: viewModel,
                compact: true
            )

            ModeSwitcher(mode: $mode)

            legend

            Spacer()
        }
        .padding(20)
    }

    private func sidebarStep(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(width: 40, height: 32)
                .background(Capsule().fill(Theme.Colors.surfaceSunken))
        }
        .buttonStyle(.pressable)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Categories")
            ForEach(Category.allCases) { category in
                HStack(spacing: 8) {
                    Circle().fill(Theme.Colors.category(category)).frame(width: 8, height: 8)
                    Text(category.displayName)
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch mode {
        case .week:
            VStack(spacing: 12) {
                WeekStripView(
                    days: viewModel.weekDays(containing: selectedDay),
                    selectedDay: $selectedDay,
                    items: items,
                    viewModel: viewModel
                )
                .padding(.top, 16)
                DayTimelineView(
                    day: selectedDay,
                    items: viewModel.items(on: selectedDay, from: items),
                    viewModel: viewModel,
                    onSelect: quickLook
                )
            }
        case .month:
            DayAgendaView(
                day: selectedDay,
                items: viewModel.items(on: selectedDay, from: items),
                viewModel: viewModel,
                onSelect: quickLook,
                onToggle: toggle
            )
            .padding(.top, 20)
        case .agenda:
            AgendaListView(
                anchor: selectedDay,
                items: items,
                viewModel: viewModel,
                today: today,
                onSelect: quickLook,
                onToggle: toggle
            )
            .padding(.top, 12)
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: CalendarSheet) -> some View {
        switch sheet {
        case let .quickLook(item, day):
            EventQuickLookSheet(
                item: item,
                day: day,
                isDone: viewModel.isDone(item, on: day),
                onToggle: {
                    toggle(item, day)
                    self.sheet = nil
                },
                onEdit: { self.sheet = .edit(CaptureDraft(item: item)) },
                onDelete: {
                    self.sheet = nil
                    pendingDelete = PendingDeletion(item: item, day: day)
                }
            )
        case let .edit(draft):
            CaptureConfirmSheet(
                draft: draft,
                onParse: {},
                onSave: { save(draft) },
                onCancel: { self.sheet = nil }
            )
        }
    }

    // MARK: - Actions

    private func quickLook(_ item: ScheduleItem) {
        sheet = .quickLook(item, selectedDay)
    }

    private func toggle(_ item: ScheduleItem, _ day: Date) {
        withAnimation(Theme.Motion.bouncy) { viewModel.toggleDone(item, on: day) }
    }

    private func step(_ direction: Int) {
        Haptics.medium()
        withAnimation(Theme.Motion.smooth) {
            selectedDay = CalendarPeriod.shifted(selectedDay, mode: mode, by: direction)
        }
    }

    private func goToday() {
        guard !calendar.isDate(selectedDay, inSameDayAs: today) else { return }
        Haptics.medium()
        withAnimation(Theme.Motion.smooth) { selectedDay = today }
    }

    private func setMode(_ newMode: CalendarMode) {
        guard newMode != mode else { return }
        Haptics.selection()
        withAnimation(Theme.Motion.snappy) { mode = newMode }
    }

    /// Cancels first, because a removed item can't be read back to work out
    /// which notifications were its; a trimmed one re-schedules against its
    /// shortened series so nothing fires for a day that no longer exists.
    ///
    /// Not animated, for the same reason as Today's: an outgoing row that
    /// outlives the model it renders is a hard crash, not a glitch.
    private func performDelete(_ item: ScheduleItem, _ scope: ScheduleViewModel.DeletionScope, _ day: Date) {
        NotificationService.cancel(for: item)
        // Captured before the delete cascades the links away — see the same
        // step in `ScheduleView.performDelete`.
        let removals = CalendarSync.pendingRemovals(for: item)
        let outcome = viewModel.delete(item, scope: scope, on: day)
        if outcome == .trimmed {
            Task { await NotificationService.reschedule(for: item) }
        }
        if outcome == .removed, !removals.isEmpty {
            Task {
                let result = await CalendarSync.remove(removals)
                if let message = result.failureMessage { calendarError = message }
            }
        }
    }

    private func save(_ draft: CaptureDraft) {
        if let existing = draft.editingItem {
            draft.apply(to: existing)
            viewModel.save()
            Task { await NotificationService.reschedule(for: existing) }

            // Edits made here reach the calendar the same way they do from
            // Today: through the sheet's own switches, which opened showing
            // wherever this item already is.
            let targets = draft.effectiveCalendarTargets
            if !targets.isEmpty || !existing.calendarLinks.isEmpty {
                Task {
                    let outcome = await CalendarSync.apply(targets, to: existing, in: modelContext)
                    if let message = outcome.failureMessage { calendarError = message }
                }
            }
        }
        sheet = nil
    }

    // MARK: - Derived state

    private var windowContainsToday: Bool {
        switch mode {
        case .month:
            return calendar.isDate(selectedDay, equalTo: today, toGranularity: .month)
        case .week, .agenda:
            return calendar.isDate(selectedDay, equalTo: today, toGranularity: .weekOfYear)
        }
    }

    // MARK: - Gestures & shortcuts

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 30, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                // Only a decisive, predominantly-horizontal flick flips the period,
                // so it never fights the timeline's vertical scroll.
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 55 else { return }
                step(dx < 0 ? 1 : -1)
            }
    }

    /// Hardware-keyboard power-user shortcuts (iPad / Mac): T jumps to today,
    /// arrows step the window, 1·2·3 switch modes.
    private var shortcuts: some View {
        Group {
            Button("", action: goToday).keyboardShortcut("t", modifiers: [])
            Button("", action: { step(-1) }).keyboardShortcut(.leftArrow, modifiers: [])
            Button("", action: { step(1) }).keyboardShortcut(.rightArrow, modifiers: [])
            Button("", action: { setMode(.agenda) }).keyboardShortcut("1", modifiers: [])
            Button("", action: { setMode(.week) }).keyboardShortcut("2", modifiers: [])
            Button("", action: { setMode(.month) }).keyboardShortcut("3", modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// One sheet slot so quick-look and the editor swap cleanly.
private enum CalendarSheet: Identifiable {
    case quickLook(ScheduleItem, Date)
    case edit(CaptureDraft)

    var id: String {
        switch self {
        case let .quickLook(item, _): return "ql-\(item.id)"
        case let .edit(draft): return "edit-\(draft.id)"
        }
    }
}

#Preview {
    NavigationStack {
        CalendarView()
            .modelContainer(
                for: [ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self],
                inMemory: true
            )
    }
}
