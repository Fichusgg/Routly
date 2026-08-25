//
//  WeekStripView.swift
//  RoutineOrganizer
//
//  The seven-day selector above the week timeline. The selected day rides a
//  spring-animated accent capsule (matched by geometry), today wears a ring even
//  when unselected, and each day carries up to three category dots plus a "+N"
//  when a day is busier than the dots can show.
//

import SwiftUI

struct WeekStripView: View {
    let days: [Date]
    @Binding var selectedDay: Date
    let items: [ScheduleItem]
    let viewModel: ScheduleViewModel

    @Namespace private var selection
    private let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        HStack(spacing: 5) {
            ForEach(days, id: \.self) { day in
                dayColumn(day)
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
    }

    private func dayColumn(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        return Button {
            guard !selected else { return }
            Haptics.selection()
            withAnimation(Theme.Motion.snappy) { selectedDay = day }
        } label: {
            VStack(spacing: 6) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(Theme.Typography.label())
                    .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.85) : Theme.Colors.textFaint)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textPrimary)
                    .contentTransition(.numericText())
                dots(for: day, selected: selected)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.Colors.accent)
                        .matchedGeometryEffect(id: "daySelection", in: selection)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.Colors.accent.opacity(0.5), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dots(for day: Date, selected: Bool) -> some View {
        let cats = viewModel.categoriesPresent(on: day, from: items)
        let count = viewModel.items(on: day, from: items).count
        return HStack(spacing: 3) {
            if cats.isEmpty {
                Circle().fill(.clear).frame(width: 5, height: 5)
            } else {
                ForEach(cats.prefix(3), id: \.self) { cat in
                    Circle()
                        .fill(selected ? Theme.Colors.onAccent.opacity(0.9) : Theme.Colors.category(cat))
                        .frame(width: 5, height: 5)
                }
                if count > 3 {
                    Text("+\(count - 3)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(selected ? Theme.Colors.onAccent.opacity(0.9) : Theme.Colors.textFaint)
                }
            }
        }
        .frame(height: 8)
    }
}
