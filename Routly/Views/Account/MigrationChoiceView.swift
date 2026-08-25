//
//  MigrationChoiceView.swift
//  RoutineOrganizer
//
//  Shown when data exists both on this phone and in the account being signed
//  into. Nothing has been touched at the point this appears, and nothing is
//  touched until an option is picked — the sheet cannot be swiped away, because
//  dismissing it would leave the handover half-decided.
//
//  Merge is pre-selected and labelled as recommended: it's the only option that
//  can't lose anything, and a person under time pressure should land on the safe
//  choice by default rather than the fast one.
//

import SwiftUI

struct MigrationChoiceView: View {
    let localItems: Int
    let remoteItems: Int
    let onChoose: (MigrationChoice) -> Void

    @State private var selection: MigrationChoice = .merge

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    VStack(spacing: 10) {
                        ForEach(MigrationChoice.allCases) { choice in
                            optionRow(choice)
                        }
                    }

                    confirmButton

                    Text("Nothing has changed yet. Whichever you pick, a copy of what's on this phone is kept until it's safely stored.")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Metrics.screenPadding)
            }
        }
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Two sets of data")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.textPrimary)

            Text("This phone has \(localItems) items and your account has \(remoteItems). How should they come together?")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionRow(_ choice: MigrationChoice) -> some View {
        Button {
            withAnimation(Theme.Motion.snappy) { selection = choice }
            Haptics.selection()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selection == choice ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selection == choice ? Theme.Colors.accent : Theme.Colors.textFaint)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(choice.title)
                            .font(Theme.Typography.itemTitle())
                            .foregroundStyle(Theme.Colors.textPrimary)
                        if choice.isRecommended {
                            Text("Recommended")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.Colors.accentSoft))
                        }
                    }
                    Text(choice.detail)
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Metrics.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selection == choice ? Theme.Colors.accentSoft : Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        selection == choice ? Theme.Colors.accent.opacity(0.5) : Theme.Colors.hairline,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.pressable)
    }

    private var confirmButton: some View {
        Button {
            Haptics.success()
            onChoose(selection)
        } label: {
            Text("Continue")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.Colors.accent)
                )
                .foregroundStyle(Theme.Colors.onAccent)
        }
        .buttonStyle(.pressable)
    }
}

#Preview {
    MigrationChoiceView(localItems: 14, remoteItems: 31) { _ in }
}
