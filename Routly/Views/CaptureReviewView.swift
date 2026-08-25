//
//  CaptureReviewView.swift
//  RoutineOrganizer
//
//  The confirm-before-commit screen for voice capture. Everything the parser
//  pulled out of the transcript is listed as an editable item you can keep,
//  tweak, or drop — nothing is added silently.
//

import SwiftUI

struct CaptureReviewView: View {
    @Bindable var review: VoiceReview
    var onCommit: () -> Void
    var onCancel: () -> Void
    /// Optional escape hatch when the capture actually reads like a goal: re-run
    /// it through the planner instead. nil hides the affordance.
    var onPlanInstead: (() -> Void)? = nil

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
                        transcriptEcho
                        VStack(spacing: 0) {
                            ForEach(Array(review.items.enumerated()), id: \.element.id) { index, item in
                                ReviewItemRow(item: item) { editing = item }
                                if index < review.items.count - 1 {
                                    RowDivider(inset: 33)
                                }
                            }
                        }
                        if let onPlanInstead {
                            switchToPlan(onPlanInstead)
                        }
                    }
                    .padding(Theme.Metrics.screenPadding)
                }
            }
            // The count interpolates as a number so the string catalog can hold
            // real plural forms. Building the plural here — "item" + "s" — only
            // ever worked for English, and left no way to express languages with
            // a different set of forms.
            .navigationTitle(String(localized: "Review \(review.items.count) items"))
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
        review.keepCount <= 1 ? "Add" : "Add \(review.keepCount)"
    }

    /// Explains when results came from the offline stub rather than the AI, so a
    /// silent fallback never looks like "the AI is just bad at this".
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

    /// The language switch sits here, beside the transcript, because this is the
    /// exact moment its being wrong is discovered — reading back a sentence that
    /// came out as nonsense. It used to sit above the mic on Today, which meant
    /// the corner carried two stacked controls and the switch was nowhere near
    /// the evidence that you needed it.
    ///
    /// It changes the language for the *next* recording; it can't re-transcribe
    /// audio that has already been turned into text and thrown away.
    private var transcriptEcho: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("You said")
                Spacer(minLength: 8)
                VoiceLanguagePill(settings: AppSettings.shared)
            }
            Text("“\(review.transcript)”")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .italic()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "This is really a goal" — hands the same transcript to the planner.
    private func switchToPlan(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Text("This is a goal — build a plan instead")
                    .font(Theme.Typography.caption())
            }
            .foregroundStyle(Theme.Colors.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Colors.accentSoft)
            )
        }
        .buttonStyle(.pressable)
        .padding(.top, 4)
    }
}
