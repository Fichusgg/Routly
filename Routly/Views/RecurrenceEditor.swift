//
//  RecurrenceEditor.swift
//  RoutineOrganizer
//
//  Setting a repeat by hand.
//
//  Until now recurrence could only arrive from the parser — you had to say
//  "every Tuesday" out loud, and the add sheet showed a line of text explaining
//  that. That's fine when you're talking and useless when you're typing, which
//  is exactly when someone is filling in this form. So the rule is editable
//  here, and the parser's guess is just a starting value like every other field.
//
//  The four cadences map one-to-one onto `RecurrenceRule.Frequency` plus "not at
//  all", which keeps this a view over the model rather than a second model.
//

import SwiftUI

struct RecurrenceEditor: View {
    @Binding var recurrence: RecurrenceRule?
    @Binding var keepRecurrence: Bool
    /// The day the item is filed under — a new weekly rule starts on that
    /// weekday, because "repeat weekly" almost always means "again on this day".
    let anchorDate: Date

    private let calendar = Calendar(identifier: .gregorian)

    /// The cadences offered, in order of how often they're wanted.
    private enum Cadence: String, CaseIterable, Identifiable {
        case never = "Never"
        case daily = "Daily"
        case weekly = "Weekly"
        case timesPerWeek = "N× week"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Repeats")
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)

            cadencePicker

            if current == .weekly {
                weekdayPicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if current == .timesPerWeek {
                targetStepper
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text(summary)
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Cadence

    private var cadencePicker: some View {
        HStack(spacing: 6) {
            ForEach(Cadence.allCases) { option in
                let selected = current == option
                Button {
                    Haptics.selection()
                    withAnimation(Theme.Motion.snappy) { select(option) }
                } label: {
                    Text(option.rawValue)
                        .font(Theme.Typography.caption())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected ? Theme.Colors.accent : Theme.Colors.surfaceSunken)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    /// What the bound rule currently amounts to. `keepRecurrence` is honoured
    /// here so a parsed rule the user switched off reads as "Never" rather than
    /// showing a cadence that isn't going to be saved.
    private var current: Cadence {
        guard keepRecurrence, let rule = recurrence else { return .never }
        switch rule.frequency {
        case .daily: return .daily
        case .weekly: return .weekly
        case .timesPerWeek: return .timesPerWeek
        }
    }

    private func select(_ cadence: Cadence) {
        switch cadence {
        case .never:
            keepRecurrence = false
        case .daily:
            recurrence = .everyDay
            keepRecurrence = true
        case .weekly:
            // Keep whatever days were already chosen; otherwise start on the
            // item's own weekday.
            let existing = recurrence?.weekdays ?? []
            let days = existing.isEmpty ? [calendar.component(.weekday, from: anchorDate)] : existing
            recurrence = .weekly(on: Set(days))
            keepRecurrence = true
        case .timesPerWeek:
            recurrence = .timesPerWeek(recurrence?.targetCount ?? 3)
            keepRecurrence = true
        }
    }

    // MARK: - Weekly

    private var weekdayPicker: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { weekday in
                let selected = recurrence?.weekdays.contains(weekday) ?? false
                Button {
                    Haptics.selection()
                    toggle(weekday)
                } label: {
                    Text(narrowWeekdaySymbol(weekday))
                        .font(Theme.Typography.micro())
                        .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            Circle().fill(selected ? Theme.Colors.accent : Theme.Colors.surfaceSunken)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(RecurrenceRule.weekdaySymbol(weekday) ?? "")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    /// Turning off the last day would leave a weekly rule that never happens, so
    /// the final one can't be unchecked — use "Never" to stop it repeating.
    private func toggle(_ weekday: Int) {
        var days = recurrence?.weekdays ?? []
        if days.contains(weekday) {
            guard days.count > 1 else { return }
            days.remove(weekday)
        } else {
            days.insert(weekday)
        }
        recurrence = .weekly(on: days, interval: recurrence?.interval ?? 1)
        keepRecurrence = true
    }

    private func narrowWeekdaySymbol(_ weekday: Int) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "?"
    }

    // MARK: - Times per week

    private var targetStepper: some View {
        HStack {
            Text("Times a week")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)

            Spacer(minLength: 8)

            Stepper(
                value: Binding(
                    get: { recurrence?.targetCount ?? 3 },
                    set: {
                        recurrence = .timesPerWeek($0)
                        keepRecurrence = true
                    }
                ),
                in: 1...7
            ) {
                Text("\(recurrence?.targetCount ?? 3)")
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .monospacedDigit()
            }
            .labelsHidden()
            .tint(Theme.Colors.accent)

            Text("\(recurrence?.targetCount ?? 3)")
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
                .monospacedDigit()
                .frame(minWidth: 18)
        }
    }

    // MARK: - Summary

    private var summary: String {
        guard keepRecurrence, let rule = recurrence else {
            return "Happens once. Pick a cadence to make it a routine."
        }
        switch rule.frequency {
        case .timesPerWeek:
            return "\(rule.displayDescription) — no fixed day, so it won't be scheduled at a time or send a reminder."
        default:
            return rule.displayDescription
        }
    }
}
