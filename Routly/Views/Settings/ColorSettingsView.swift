//
//  ColorSettingsView.swift
//  RoutineOrganizer
//
//  Colour, made the user's. Two things are adjustable: the single accent the
//  app spends on selection and emphasis, and the colour each tag/category wears.
//
//  Every swatch is a light/dark *pair*, not a hex — that's what keeps the app
//  legible when the appearance flips, and it's why this is a picker over a
//  curated set rather than a colour wheel. A free wheel would let someone pick
//  a pale yellow accent and discover that every button label went invisible.
//
//  The preview at the top is the point of the screen: you change a swatch and
//  watch a real row change, rather than guessing from a dot.
//

import SwiftUI

struct ColorSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    previewSection
                    accentSection
                    categorySection
                    tagStyleSection
                    resetSection
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Colours")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        // The shell's `.tint` was resolved before this screen appeared, so
        // without re-applying it here the back button keeps wearing the accent
        // you just changed away from — on the one screen where that's the thing
        // being demonstrated. This body re-runs on every accent tap, so the
        // token is re-read each time.
        .tint(Theme.Colors.accent)
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Preview")

            VStack(spacing: 0) {
                ForEach(Array(Category.allCases.enumerated()), id: \.element) { index, category in
                    SampleRow(category: category, title: sampleTitle(category))
                    if index < Category.allCases.count - 1 {
                        RowDivider(inset: 0)
                    }
                }
            }
            .surfaceCard(padding: 12)
            // The row fills resolve through `ThemePalette`, which isn't
            // observable — without this the preview keeps painting the colour
            // you just changed away from, which is the one thing this screen
            // must not do.
            .id(settings.paletteRevision)
        }
    }

    private func sampleTitle(_ category: Category) -> String {
        switch category {
        case .work: return "Finish the quarterly report"
        case .personal: return "Call mum"
        case .health: return "Evening walk"
        }
    }

    // MARK: - Accent

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Accent")

            VStack(alignment: .leading, spacing: 12) {
                SwatchGrid(selection: settings.accent) { choice in
                    Haptics.selection()
                    withAnimation(Theme.Motion.snappy) { settings.accent = choice }
                }

                Text("Used for selection, links, and the checkmark on anything you tick off.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .surfaceCard()
        }
    }

    // MARK: - Categories

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Tag colours")

            VStack(spacing: 0) {
                ForEach(Array(Category.allCases.enumerated()), id: \.element) { index, category in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Theme.Colors.category(category))
                                .frame(width: 10, height: 10)
                            Text(category.displayName)
                                .font(Theme.Typography.itemTitle())
                                .foregroundStyle(Theme.Colors.textPrimary)
                        }

                        SwatchGrid(selection: settings.color(for: category)) { choice in
                            Haptics.selection()
                            withAnimation(Theme.Motion.snappy) {
                                settings.setColor(choice, for: category)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Metrics.cardPadding)
                    .padding(.vertical, 14)

                    if index < Category.allCases.count - 1 {
                        RowDivider(inset: 0)
                    }
                }
            }
            .surfaceCard(padding: 0)
        }
    }

    // MARK: - Tag style

    private var tagStyleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Tag display")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(TagDisplayStyle.allCases) { style in
                        let selected = settings.tagDisplay == style
                        Button {
                            guard !selected else { return }
                            Haptics.selection()
                            withAnimation(Theme.Motion.snappy) { settings.tagDisplay = style }
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: style.symbolName)
                                    .font(.system(size: 14, weight: .medium))
                                Text(style.displayName)
                                    .font(Theme.Typography.caption())
                            }
                            .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(selected ? Theme.Colors.accent : Theme.Colors.surfaceSunken)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.displayName)
                        .accessibilityHint(style.detail)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }

                Text(settings.tagDisplay.detail)
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .surfaceCard()
        }
    }

    // MARK: - Reset

    @ViewBuilder
    private var resetSection: some View {
        if !settings.usesDefaultColors {
            Button {
                Haptics.medium()
                withAnimation(Theme.Motion.snappy) { settings.resetColors() }
            } label: {
                Text("Reset to default colours")
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        }
    }
}

// MARK: - Swatches

/// The colour choices as filled circles, the selected one ringed. A ring rather
/// than a checkmark: at this size a glyph inside the swatch fights the colour
/// it's meant to be showing.
///
/// Grouped by tier, one labelled row each, and — because every tier holds the
/// same seven hues in the same order — a fixed seven-column grid rather than an
/// adaptive one. That keeps a hue in the same column across all three rows, so
/// the set reads as a grid of variants instead of a bag of colours.
private struct SwatchGrid: View {
    let selection: PaletteColor
    let onSelect: (PaletteColor) -> Void

    /// Seven fixed columns, tight spacing. On a 375pt screen that leaves each
    /// swatch about 38pt wide — under the 44pt ideal, but the cell is a full
    /// 44pt tall and keeping a hue in one column across all three tiers is worth
    /// more here than the last six points of width.
    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 30), spacing: 6),
        count: 7
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(PaletteTier.allCases) { tier in
                VStack(alignment: .leading, spacing: 7) {
                    Text(tier.displayName)
                        .font(Theme.Typography.micro())
                        .foregroundStyle(Theme.Colors.textFaint)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(PaletteColor.tier(tier)) { choice in
                            swatch(choice)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(tier.displayName)
            }
        }
    }

    private func swatch(_ choice: PaletteColor) -> some View {
        let selected = choice == selection
        return Button {
            onSelect(choice)
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        selected ? Theme.Colors.textPrimary.opacity(0.55) : .clear,
                        lineWidth: 2
                    )
                    .frame(width: 34, height: 34)

                Circle()
                    .fill(swatchColor(choice))
                    // A pale swatch on a pale card has almost no edge of its
                    // own, so the whole pastel row would read as ghosted
                    // without this. Hairline-weight, so it never becomes a
                    // border in its own right on the darker swatches.
                    .overlay(Circle().strokeBorder(Theme.Colors.separator, lineWidth: 0.5))
                    .frame(width: 26, height: 26)
            }
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Swatches resolve their own pair rather than going through `ThemePalette`,
    /// since the whole point is to show what you'd be switching *to*.
    private func swatchColor(_ choice: PaletteColor) -> Color {
        Color(UIColor { traits in
            UIColor(hex: choice.hex(dark: traits.userInterfaceStyle == .dark))
        })
    }
}

// MARK: - Sample row

/// A stand-in for a real item, so both the tag colour and the Obvious/Discreet
/// setting can be judged on something that looks like the thing it affects.
private struct SampleRow: View {
    let category: Category
    let title: String

    private let settings = AppSettings.shared

    var body: some View {
        let obvious = settings.tagDisplay == .obvious

        return HStack(spacing: 12) {
            Circle()
                .strokeBorder(Theme.Colors.separator, lineWidth: 1.5)
                .frame(width: 20, height: 20)

            Text(title)
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !obvious {
                Circle()
                    .fill(Theme.Colors.category(category))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, obvious ? 12 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(obvious ? Theme.Colors.categoryRowFill(category) : .clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(category.displayName).")
    }
}

#Preview {
    NavigationStack {
        ColorSettingsView()
    }
}
