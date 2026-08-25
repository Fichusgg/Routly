//
//  GoalEntrySheet.swift
//  RoutineOrganizer
//
//  The deliberate entry point into planning: when someone knows they want to turn
//  an ambition into a routine, they can state it here rather than relying on the
//  mic's auto-detection. A single field, a few example prompts, and one button
//  that hands the goal to the planner — the result still lands in the same
//  review-before-commit screen.
//

import SwiftUI

struct GoalEntrySheet: View {
    var onBuild: (String) -> Void
    var onCancel: () -> Void

    @State private var goal = ""
    @FocusState private var focused: Bool

    private let examples = [
        "Get back into shape",
        "Learn Spanish this quarter",
        "Launch my side project",
        "Read more this month",
    ]

    private var isValid: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What do you want to achieve?")
                                .font(Theme.Typography.title())
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Text("Say it broadly — I'll turn it into a few routines and first steps you can adjust.")
                                .font(Theme.Typography.body())
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        TextField("e.g. get back into shape", text: $goal, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.itemTitle())
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .tint(Theme.Colors.accent)
                            .lineLimit(1...4)
                            .focused($focused)
                            .submitLabel(.go)
                            .onSubmit { if isValid { onBuild(goal) } }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Theme.Colors.surfaceSunken)
                            )

                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Try")
                            FlowTags(spacing: 8) {
                                ForEach(examples, id: \.self) { example in
                                    Button { goal = example } label: {
                                        Text(example)
                                            .font(Theme.Typography.caption())
                                            .foregroundStyle(Theme.Colors.accent)
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(Capsule().fill(Theme.Colors.accentSoft))
                                    }
                                    .buttonStyle(.pressable)
                                }
                            }
                        }

                        buildButton
                    }
                    .padding(Theme.Metrics.screenPadding)
                }
            }
            .navigationTitle("Plan a goal")
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
        .onAppear { focused = true }
    }

    private var buildButton: some View {
        Button { onBuild(goal) } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Build my plan")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.Colors.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isValid ? Theme.Colors.accent : Theme.Colors.textFaint)
            )
        }
        .buttonStyle(.pressable)
        .disabled(!isValid)
    }
}
