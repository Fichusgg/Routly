//
//  MonthGridView.swift
//  RoutineOrganizer
//
//  A real 6×7 month grid. The selected day rides a spring-animated accent field
//  (matched by geometry), today keeps a ring, adjacent-month days fade back, and
//  each day carries a compact row of category bars with a "+N" overflow. Doubles
//  as the iPad sidebar's mini-month via the `compact` flag, which trims the cell
//  down to just the number and a dot.
//

import SwiftUI

struct MonthGridView: View {
    let days: [Date]
    let anchor: Date
    @Binding var selectedDay: Date
    let items: [ScheduleItem]
    let viewModel: ScheduleViewModel
    var compact: Bool = false

    @Namespace private var selection
    @State private var hoveredDay: Date?
    private let calendar = Calendar(identifier: .gregorian)
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: compact ? 2 : 5), count: 7)
    }

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            HStack(spacing: compact ? 2 : 5) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(Theme.Typography.label())
                        .tracking(0.5)
                        .foregroundStyle(Theme.Colors.textFaint)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: compact ? 2 : 5) {
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
        .padding(.horizontal, compact ? 0 : Theme.Metrics.screenPadding)
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: anchor, toGranularity: .month)
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        let hovered = hoveredDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        // Only today-and-selected gets a solid accent fill; a plain selection is
        // a soft wash, which keeps a light month grid from turning into a
        // checkerboard of saturated tiles.
        let filled = selected && isToday

        return Button {
            guard !selected else { return }
            Haptics.selection()
            withAnimation(Theme.Motion.snappy) { selectedDay = day }
        } label: {
            VStack(spacing: compact ? 2 : 5) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: compact ? 12 : 14, weight: isToday ? .bold : .regular))
                    .foregroundStyle(dayColor(isToday: isToday, filled: filled))
                if compact {
                    Circle()
                        .fill(hasItems(day) ? Theme.Colors.accent : .clear)
                        .frame(width: 4, height: 4)
                } else {
                    eventBars(day, filled: filled)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 32 : 46)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: compact ? 8 : 11, style: .continuous)
                        .fill(filled ? Theme.Colors.accent : Theme.Colors.accentSoft)
                        .matchedGeometryEffect(id: "monthSelection", in: selection)
                } else if isToday {
                    RoundedRectangle(cornerRadius: compact ? 8 : 11, style: .continuous)
                        .strokeBorder(Theme.Colors.accent.opacity(0.5), lineWidth: 1.5)
                } else if hovered {
                    RoundedRectangle(cornerRadius: compact ? 8 : 11, style: .continuous)
                        .fill(Theme.Colors.surfaceSunken)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(inMonth ? 1 : 0.32)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredDay = inside ? day : nil
            }
        }
    }

    private func dayColor(isToday: Bool, filled: Bool) -> Color {
        if filled { return Theme.Colors.onAccent }
        if isToday { return Theme.Colors.accent }
        return Theme.Colors.textPrimary
    }

    private func hasItems(_ day: Date) -> Bool {
        !viewModel.categoriesPresent(on: day, from: items).isEmpty
    }

    private func eventBars(_ day: Date, filled: Bool) -> some View {
        let cats = viewModel.categoriesPresent(on: day, from: items)
        let count = viewModel.items(on: day, from: items).count
        return HStack(spacing: 3) {
            if cats.isEmpty {
                Capsule().fill(.clear).frame(width: 10, height: 3)
            } else {
                ForEach(cats.prefix(3), id: \.self) { cat in
                    Capsule()
                        .fill(filled ? Theme.Colors.onAccent.opacity(0.9) : Theme.Colors.category(cat))
                        .frame(width: 10, height: 3)
                }
                if count > 3 {
                    Text("+\(count - 3)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(filled ? Theme.Colors.onAccent.opacity(0.9) : Theme.Colors.textFaint)
                }
            }
        }
        .frame(height: 6)
    }

    private var weekdaySymbols: [String] {
        calendar.veryShortStandaloneWeekdaySymbols
    }
}
