//
//  OptimizeDayView.swift
//  RoutineOrganizer
//
//  "Optimize my day" — the day planner's answer, laid out in the order a person
//  actually needs it: how much time is really left, what to do with it and why,
//  then an honest list of what won't fit, and only then the housekeeping.
//
//  The "won't fit" section is deliberately not hidden away. Being told a task
//  isn't happening today is more useful than being handed a plan that quietly
//  assumes a 25-hour day.
//
//  Every suggestion here is applied only after an explicit confirmation in the
//  caller, never on tap alone.
//

import SwiftUI

struct OptimizeDayView: View {
    let plan: DayPlan
    let suggestions: [ScheduleSuggestion]
    var onApply: (ScheduleSuggestion) -> Void
    var onDismissSuggestion: (ScheduleSuggestion) -> Void
    var onClose: () -> Void

    /// Locally hidden rows, so dismissing one updates this list immediately.
    @State private var hidden: Set<String> = []

    private var visible: [ScheduleSuggestion] {
        suggestions.filter { !hidden.contains($0.id) }
    }

    private var recommendations: [ScheduleSuggestion] {
        visible.filter { $0.kind == .recommendation }
    }
    private var wontFit: [ScheduleSuggestion] {
        visible.filter { $0.kind == .wontFit }
    }
    /// A wall of warnings stops being information and starts being noise, so
    /// only the most pressing few get a row — but the count is never hidden.
    private var wontFitShown: [ScheduleSuggestion] { Array(wontFit.prefix(4)) }
    private var wontFitOverflow: Int { max(wontFit.count - wontFitShown.count, 0) }
    /// Crowding, stale to-dos — the ambient nudges, below the plan itself.
    private var housekeeping: [ScheduleSuggestion] {
        visible.filter { $0.kind != .recommendation && $0.kind != .wontFit }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()

                if visible.isEmpty {
                    allClear
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                            timeBudget

                            if !recommendations.isEmpty {
                                group("What I'd do") {
                                    rows(recommendations)
                                }
                            }

                            if !wontFit.isEmpty {
                                group("Won't fit today") {
                                    rows(wontFitShown)
                                    if wontFitOverflow > 0 {
                                        Text("…and \(wontFitOverflow) more that won't fit today.")
                                            .font(Theme.Typography.caption())
                                            .foregroundStyle(Theme.Colors.textFaint)
                                            .padding(.top, 8)
                                    }
                                }
                            }

                            if !housekeeping.isEmpty {
                                group("Also worth a look") {
                                    VStack(spacing: Theme.Metrics.itemSpacing) {
                                        ForEach(housekeeping) { suggestion in
                                            SuggestionCard(
                                                suggestion: suggestion,
                                                onApply: suggestion.action == nil ? nil : { onApply(suggestion) },
                                                onDismiss: { dismiss(suggestion) }
                                            )
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                        .padding(Theme.Metrics.screenPadding)
                    }
                }
            }
            .navigationTitle("Optimize my day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose).tint(Theme.Colors.accent)
                }
            }
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Pieces

    /// The honest headline: what's actually left, not what the day looked like
    /// this morning. The one stat on the screen, so it keeps an enclosure and
    /// the only large numeral.
    private var timeBudget: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(freeText)
                .font(Theme.Typography.display())
                .foregroundStyle(Theme.Colors.textPrimary)
                .contentTransition(.numericText())
            Text(headline)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subhead)
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    /// Just the number, big. The sentence beneath it carries the qualifier.
    private var freeText: String {
        plan.freeMinutes > 0 ? MinutesText.short(plan.freeMinutes) : "0m"
    }

    private var headline: String {
        let endText = plan.horizonEnd.formatted(date: .omitted, time: .shortened)
        // A finished working day and a full one both leave zero minutes, but
        // they are not the same news. At 9pm "no open time left before 5:00 PM"
        // reads like the app has lost track of the clock.
        if plan.isAfterWorkingHours { return "Your working day ended at \(endText)." }
        guard plan.freeMinutes > 0 else { return "No open time left before \(endText)." }
        return "free before \(endText)."
    }

    private var subhead: String {
        if plan.isAfterWorkingHours {
            return "Anything left is for tomorrow. You can change your working hours in Settings."
        }
        if recommendations.isEmpty && !wontFit.isEmpty {
            return "Nothing outstanding fits the time that's left — here's what that means."
        }
        if recommendations.isEmpty {
            return "Nothing outstanding needs a slot right now."
        }
        let planned = recommendations.compactMap(\.slotMinutes).reduce(0, +)
        return "\(MinutesText.short(planned)) of it planned, the rest left as breathing room."
    }

    /// A labelled group. The label sits above the content with real space, so
    /// the section reads as a heading and a list rather than a wall.
    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            content()
        }
    }

    /// Divider-separated plain rows.
    private func rows(_ suggestions: [ScheduleSuggestion]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                RecommendationRow(suggestion: suggestion) { onApply(suggestion) }
                if index < suggestions.count - 1 {
                    RowDivider(inset: 70)
                }
            }
        }
    }

    private func dismiss(_ suggestion: ScheduleSuggestion) {
        withAnimation {
            _ = hidden.insert(suggestion.id)
            onDismissSuggestion(suggestion)
        }
    }

    private var allClear: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.Colors.done)
            Text("Today looks good")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Nothing's clashing and nothing's slipping. Keep going.")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Metrics.screenPadding)
    }
}
