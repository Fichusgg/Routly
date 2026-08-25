//
//  RecommendationRow.swift
//  RoutineOrganizer
//
//  One line of the day plan: when, what, how long, and — the part that earns
//  the user's trust — why. The reason is not decoration; a recommendation the
//  person can't argue with is one they can't correct.
//
//  Tapping accepts, which routes through the same confirmation the rest of the
//  app uses. Nothing here applies on tap alone.
//

import SwiftUI

struct RecommendationRow: View {
    let suggestion: ScheduleSuggestion
    var onAccept: () -> Void

    private var isWontFit: Bool { suggestion.kind == .wontFit }
    private var tint: Color { isWontFit ? Theme.Colors.textSecondary : Theme.Colors.accent }

    var body: some View {
        Button(action: onAccept) {
            HStack(alignment: .top, spacing: 12) {
                timeColumn

                VStack(alignment: .leading, spacing: 5) {
                    Text(suggestion.message)
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    if let reason = suggestion.reason {
                        Text(reason)
                            .font(Theme.Typography.caption())
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }

                    if let actionTitle = suggestion.actionTitle {
                        Text(actionTitle)
                            .font(Theme.Typography.caption())
                            .foregroundStyle(tint)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 0)

                if suggestion.action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Colors.textFaint)
                        .padding(.top, 4)
                }
            }
            // Plain row. The time column on the left already separates one
            // recommendation from the next; a box around each just adds noise
            // to a screen that's meant to feel decisive.
            .padding(.vertical, Theme.Metrics.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isWontFit ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // Informational rows aren't actionable — don't offer a tap that does nothing.
        .disabled(suggestion.action == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(suggestion.action == nil ? "" : "Double tap to schedule this")
    }

    /// The slot, or the size when there's no slot to show.
    private var timeColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let start = suggestion.slotStart {
                // A time is a key number — one of the few things that earns
                // real weight on this screen.
                Text(start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                Image(systemName: suggestion.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
            }

            if let minutes = suggestion.slotMinutes {
                Text(MinutesText.short(minutes))
                    .font(Theme.Typography.micro())
                    .foregroundStyle(Theme.Colors.textFaint)
                if suggestion.effortIsGuess {
                    // Say when a number is ours, so it's obvious what to correct.
                    Text("est.")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Theme.Colors.textFaint)
                }
            }
        }
        .frame(width: 58, alignment: .leading)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let start = suggestion.slotStart {
            parts.append(start.formatted(date: .omitted, time: .shortened))
        }
        parts.append(suggestion.message)
        if let minutes = suggestion.slotMinutes {
            parts.append(suggestion.effortIsGuess
                         ? "about \(MinutesText.short(minutes)), estimated"
                         : MinutesText.short(minutes))
        }
        if let reason = suggestion.reason { parts.append(reason) }
        return parts.joined(separator: ". ")
    }
}
