//
//  EventQuickLookSheet.swift
//  RoutineOrganizer
//
//  Tapping an event shouldn't dump you into a full editor — it should give you a
//  glanceable, thumb-friendly card. This is that quick-look: a category-tinted
//  header, the essential facts (when, how long, how often, notes), and three
//  fat, reachable actions — complete, edit, delete. It rides a medium detent so
//  the calendar stays visible behind it.
//

import SwiftUI

struct EventQuickLookSheet: View {
    let item: ScheduleItem
    let day: Date
    let isDone: Bool
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var color: Color { Theme.Colors.category(item.category) }
    private let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header
                Divider().overlay(Theme.Colors.hairline)
                ScrollView(showsIndicators: false) {
                    details
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                actions
            }
            .padding(24)
        }
        .presentationDetents([.height(360), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.Colors.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4, height: 46)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(Theme.Typography.title())
                    .foregroundStyle(isDone ? Theme.Colors.textFaint : Theme.Colors.textPrimary)
                    .strikethrough(isDone, color: Theme.Colors.textFaint)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    kindBadge
                    categoryBadge
                }
            }
        }
    }

    private var kindBadge: some View {
        Label(item.kind.displayName, systemImage: item.kind.symbolName)
            .font(Theme.Typography.caption())
            .foregroundStyle(Theme.Colors.textFaint)
    }

    private var categoryBadge: some View {
        Text(item.category.displayName)
            .font(Theme.Typography.caption())
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Theme.Colors.categoryTint(item.category)))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let start = item.startTime {
                detailRow(icon: "clock", text: whenText(start))
            } else {
                detailRow(icon: "calendar", text: dayText)
            }
            if let minutes = item.durationMinutes {
                detailRow(icon: "hourglass", text: durationText(minutes))
            }
            if let rule = item.recurrence {
                detailRow(icon: "repeat", text: recurrenceText(rule))
            }
            if item.kind == .todo {
                // Only to-dos carry these, and only they're worth a line here —
                // an event happens when it happens, whatever you think of it.
                detailRow(
                    icon: item.priority.symbolName,
                    text: "\(item.priority.displayName) priority · \(item.todoScope.displayName)"
                )
                if let effort = item.effortMinutes {
                    detailRow(icon: "timer", text: "About \(durationText(effort)) of work")
                }
            }
            if let notes = item.notes, !notes.isEmpty {
                detailRow(icon: "text.alignleft", text: notes)
            }
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Colors.textFaint)
                .frame(width: 20)
            Text(text)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            actionButton(
                title: isDone ? "Done" : "Complete",
                icon: isDone ? "checkmark.circle.fill" : "checkmark.circle",
                tint: color,
                filled: isDone
            ) {
                Haptics.success()
                onToggle()
            }
            actionButton(title: "Edit", icon: "pencil", tint: Theme.Colors.accent, filled: false) {
                Haptics.light()
                onEdit()
            }
            actionButton(title: "Delete", icon: "trash", tint: Theme.Colors.now, filled: false) {
                Haptics.medium()
                onDelete()
            }
        }
    }

    private func actionButton(title: String, icon: String, tint: Color, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(Theme.Typography.caption())
            }
            .foregroundStyle(filled ? Theme.Colors.onAccent : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(filled ? tint : tint.opacity(0.10))
            )
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Text

    private func whenText(_ start: Date) -> String {
        let startText = start.formatted(date: .omitted, time: .shortened)
        // Show the full span for events with a length; a point in time otherwise.
        if let minutes = item.durationMinutes, minutes > 0,
           let end = calendar.date(byAdding: .minute, value: minutes, to: start) {
            let endText = end.formatted(date: .omitted, time: .shortened)
            return "\(dayText) · \(startText) – \(endText)"
        }
        return "\(dayText) · \(startText)"
    }

    private var dayText: String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// A routine the user has stopped shouldn't still claim it runs forever.
    private func recurrenceText(_ rule: RecurrenceRule) -> String {
        guard let end = item.recurrenceEndDate else { return rule.displayDescription }
        let until = end.formatted(.dateTime.month(.abbreviated).day())
        return "\(rule.displayDescription) · until \(until)"
    }

    private func durationText(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes) min"
    }
}
