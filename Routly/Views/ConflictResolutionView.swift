//
//  ConflictResolutionView.swift
//  RoutineOrganizer
//
//  Shown when a timed item would clash or overload a day. Rather than placing it
//  silently, we surface the conflict and a suggested alternative with a short
//  reason, and let the user choose — use the suggestion, place anyway, or cancel.
//

import SwiftUI

/// The data a pending conflict needs to render and resolve.
struct PendingConflict: Identifiable {
    let id = UUID()
    var draft: CaptureDraft
    var report: ConflictReport
    var alternative: AlternativeSlot?
}

struct ConflictResolutionView: View {
    let pending: PendingConflict
    var onUseSuggestion: (AlternativeSlot) -> Void
    var onPlaceAnyway: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headline
                        if !pending.report.overlaps.isEmpty { overlapSection }
                        if pending.report.isOverloaded { overloadSection }
                        if let alt = pending.alternative { suggestionSection(alt) }
                        actions
                    }
                    .padding(Theme.Metrics.screenPadding)
                }
            }
            .navigationTitle("Heads up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).tint(Theme.Colors.textSecondary)
                }
            }
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var headline: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.Colors.now)
            Text("“\(pending.draft.title)” runs into something.")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.textPrimary)
        }
    }

    // The three blocks below keep their enclosures: this screen exists to let
    // someone compare "what's already there" against "what I'd suggest", and a
    // comparison needs its sides visibly separated.
    private var overlapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Overlaps")
            ForEach(pending.report.overlaps) { item in
                HStack(spacing: 8) {
                    Circle().fill(Theme.Colors.category(item.category)).frame(width: 6, height: 6)
                    Text(item.title).font(Theme.Typography.body()).foregroundStyle(Theme.Colors.textPrimary)
                    if let start = item.startTime {
                        Text(start.formatted(date: .omitted, time: .shortened))
                            .font(Theme.Typography.caption())
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private var overloadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("A full day")
            Text("That day would have \(pending.report.timedItemCount) timed items (\(hoursText)). It might be more than fits comfortably.")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private func suggestionSection(_ alt: AlternativeSlot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Suggestion")
            Text(alt.reason)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous)
                .fill(Theme.Colors.accentSoft)
        )
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let alt = pending.alternative {
                Button { onUseSuggestion(alt) } label: {
                    Text("Use \(alt.start.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.Colors.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.pressable)
            }
            Button(action: onPlaceAnyway) {
                Text("Place anyway")
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.Colors.surfaceSunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.pressable)
        }
    }

    private var hoursText: String {
        let h = pending.report.scheduledHours
        return h == h.rounded() ? "\(Int(h))h scheduled" : String(format: "%.1fh scheduled", h)
    }
}
