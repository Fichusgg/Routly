//
//  PlanReviewView.swift
//  RoutineOrganizer
//
//  The confirm-before-commit screen for a goal that's been expanded into a plan.
//  It leads with the goal and the approach, then lists every generated routine
//  and first step as an editable keep/drop row — nothing reaches the calendar
//  until "Add plan" is tapped. A transparent switch lets the user reinterpret the
//  same words as a plain list of tasks if the goal reading was wrong.
//

import SwiftUI

struct PlanReviewView: View {
    @Bindable var review: PlanReview
    var onCommit: () -> Void
    var onCancel: () -> Void
    /// Reinterpret the same input as a flat list of items instead of a plan.
    var onReviewAsItems: (() -> Void)? = nil

    @State private var editing: ReviewItem?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let notice = ParsingDiagnostics.shared.offlineNotice {
                            offlineBanner(notice)
                        }
                        goalHeader
                        SectionLabel("Your plan")
                            .padding(.top, 8)
                        VStack(spacing: 0) {
                            ForEach(Array(review.items.enumerated()), id: \.element.id) { index, item in
                                ReviewItemRow(item: item) { editing = item }
                                if index < review.items.count - 1 {
                                    RowDivider(inset: 33)
                                }
                            }
                        }
                        if let onReviewAsItems {
                            switchToItems(onReviewAsItems)
                        }
                    }
                    .padding(Theme.Metrics.screenPadding)
                }
            }
            .navigationTitle("Review plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).tint(Theme.Colors.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addLabel, action: onCommit)
                        .tint(Theme.Colors.accent)
                        .disabled(review.keepCount == 0)
                }
            }
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .sheet(item: $editing) { item in
                CaptureConfirmSheet(
                    draft: item.draft,
                    onParse: {},
                    onSave: { editing = nil },
                    onCancel: { editing = nil }
                )
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var addLabel: String {
        review.keepCount <= 1 ? "Add plan" : "Add \(review.keepCount)"
    }

    private var goalHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "target")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Colors.accent)
                Text(review.goalTitle)
                    .font(Theme.Typography.title())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(review.summary)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let horizon = review.horizon {
                Label(horizon.displayName, systemImage: "calendar")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.Colors.accentSoft))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous)
                .fill(Theme.Colors.accentSoft)
        )
    }

    private func switchToItems(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 13, weight: .semibold))
                Text("Not a goal — just add these as separate tasks")
                    .font(Theme.Typography.caption())
            }
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Colors.surfaceSunken)
            )
        }
        .buttonStyle(.pressable)
        .padding(.top, 4)
    }

    private func offlineBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.Colors.now)
            Text(notice)
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Colors.surfaceSunken)
        )
    }
}
