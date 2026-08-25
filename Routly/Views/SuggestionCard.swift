//
//  SuggestionCard.swift
//  RoutineOrganizer
//
//  The gentle, dismissible surface for a heuristic suggestion. Tapping one with
//  a fix attached offers to apply it — the caller is responsible for confirming
//  first, so nothing ever changes behind the user's back.
//

import SwiftUI

struct SuggestionCard: View {
    let suggestion: ScheduleSuggestion
    /// nil when the suggestion is informational only (nothing to apply).
    var onApply: (() -> Void)?
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: suggestion.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Colors.accent)

            VStack(alignment: .leading, spacing: 6) {
                Text(suggestion.message)
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle = suggestion.actionTitle, onApply != nil {
                    Text(actionTitle)
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.accent)
                }
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.textFaint)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        // One of the few things that keeps an enclosure: it interrupts the day's
        // list with something the list didn't ask for, so it has to sit apart.
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Colors.accentSoft)
        )
        .contentShape(Rectangle())
        .onTapGesture { onApply?() }
    }
}
