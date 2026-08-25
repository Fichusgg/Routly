//
//  AgendaView.swift
//  RoutineOrganizer
//
//  Fantastical's signature list: the coming days as a clean, grouped scroll.
//  Sticky-feeling day headers ("Today", "Tomorrow", then the date) introduce
//  each group, empty days fall away, and each event is a tappable card with a
//  category rail, an inline completion tick, and its time. Shared row + day
//  agenda live here so the month view and the agenda mode read identically.
//

import SwiftUI

// MARK: - Full agenda (agenda mode)

struct AgendaListView: View {
    let anchor: Date
    let items: [ScheduleItem]
    let viewModel: ScheduleViewModel
    let today: Date
    var onSelect: (ScheduleItem) -> Void
    var onToggle: (ScheduleItem, Date) -> Void

    private var sections: [DaySection] {
        viewModel.sections(from: items, now: anchor).filter { !$0.items.isEmpty }
    }

    var body: some View {
        Group {
            if sections.isEmpty {
                AgendaEmptyState()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 22, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(Array(section.items.enumerated()), id: \.element.persistentModelID) { index, item in
                                        AgendaEventRow(
                                            item: item,
                                            day: section.date,
                                            isDone: viewModel.isDone(item, on: section.date),
                                            onToggle: { onToggle(item, section.date) },
                                            onSelect: { onSelect(item) }
                                        )
                                        if index < section.items.count - 1 {
                                            RowDivider(inset: 15)
                                        }
                                    }
                                }
                                .padding(.horizontal, Theme.Metrics.screenPadding)
                            } header: {
                                dayHeader(section)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func dayHeader(_ section: DaySection) -> some View {
        let cal = Calendar(identifier: .gregorian)
        let count = section.items.count
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(relativeLabel(section.date, calendar: cal))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(cal.isDateInToday(section.date) ? Theme.Colors.accent : Theme.Colors.textPrimary)
            Text(section.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
            Spacer()
            Text("\(count)")
                .font(Theme.Typography.micro())
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.vertical, 8)
        .background(Theme.Colors.background)
    }

    private func relativeLabel(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }
}

// MARK: - Day agenda (beneath the month grid)

struct DayAgendaView: View {
    let day: Date
    let items: [ScheduleItem]
    let viewModel: ScheduleViewModel
    var onSelect: (ScheduleItem) -> Void
    var onToggle: (ScheduleItem, Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A formatted date is locale-aware already and is not a catalog key.
            SectionLabel(verbatim: day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .padding(.horizontal, Theme.Metrics.screenPadding)

            if items.isEmpty {
                emptyDay
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.persistentModelID) { index, item in
                            AgendaEventRow(
                                item: item,
                                day: day,
                                isDone: viewModel.isDone(item, on: day),
                                onToggle: { onToggle(item, day) },
                                onSelect: { onSelect(item) }
                            )
                            if index < items.count - 1 {
                                RowDivider(inset: 15)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                    .padding(.bottom, 16)
                }
                .transition(.opacity)
                .id(day)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.Motion.smooth, value: day)
    }

    private var emptyDay: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.textFaint)
            Text("Nothing scheduled")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 24)
    }
}

// MARK: - Shared row

struct AgendaEventRow: View {
    let item: ScheduleItem
    let day: Date
    let isDone: Bool
    var onToggle: () -> Void
    var onSelect: () -> Void

    private let settings = AppSettings.shared

    private var color: Color { Theme.Colors.category(item.category) }
    private var isObvious: Bool { settings.tagDisplay == .obvious }

    var body: some View {
        HStack(spacing: 12) {
            // The rail is the discreet reading of a category — in Obvious mode
            // the whole row carries the colour instead, and a rail on top of
            // that is one stripe too many.
            if !isObvious {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isDone ? color.opacity(0.35) : color)
                    .frame(width: 3, height: 34)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(isDone ? Theme.Colors.textFaint : Theme.Colors.textPrimary)
                    .strikethrough(isDone, color: Theme.Colors.textFaint)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: 10))
                    if let start = item.startTime {
                        Text(start.formatted(date: .omitted, time: .shortened))
                    } else if let rule = item.recurrence {
                        Text(rule.displayDescription)
                    } else {
                        Text(item.kind.displayName)
                    }
                }
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
            }

            Spacer(minLength: 0)

            checkButton
        }
        // A plain row: the category rail on the left is the only enclosure this
        // needs. Separation is the divider below it and the space around it.
        .padding(.vertical, Theme.Metrics.rowPadding - 2)
        .padding(.horizontal, isObvious ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isObvious ? Theme.Colors.categoryRowFill(item.category) : .clear)
                .opacity(isDone ? 0.5 : 1)
        )
        .opacity(isDone ? 0.75 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            onSelect()
        }
    }

    private var checkButton: some View {
        Button {
            Haptics.success()
            withAnimation(Theme.Motion.bouncy) { onToggle() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(isDone ? color : Theme.Colors.separator, lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                if isDone {
                    Circle().fill(color).frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Colors.onAccent)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
    }
}

// MARK: - Empty state

private struct AgendaEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.Colors.textFaint)
            Text("A clear week ahead")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Nothing scheduled in this window. Capture something from Today and it'll appear here.")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}
