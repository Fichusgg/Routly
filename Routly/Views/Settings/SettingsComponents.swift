//
//  SettingsComponents.swift
//  RoutineOrganizer
//
//  The row vocabulary the settings screens share: a navigable row, a row whose
//  value comes from a menu, and the three-way appearance switcher.
//
//  These were file-private inside a single 500-line SettingsView. That view is
//  now three — a Menu of pages, the working-hours page, and the preferences
//  page behind the gear — and all three draw the same rows, so the components
//  moved here rather than being duplicated or made ambiguous about which file
//  owns them.
//

import SwiftUI

// MARK: - Appearance switcher

/// A three-way segmented control on a sunken track, with the selection riding a
/// matched-geometry pill. The stock segmented control can't carry an icon and a
/// label together at this size without looking cramped.
struct AppearanceSwitcher: View {
    @Binding var selection: AppearanceSetting
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppearanceSetting.allCases) { option in
                let selected = option == selection
                Button {
                    guard option != selection else { return }
                    Haptics.selection()
                    withAnimation(Theme.Motion.snappy) { selection = option }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: option.symbolName)
                            .font(.system(size: 15, weight: .medium))
                        Text(option.displayName)
                            .font(Theme.Typography.caption())
                    }
                    .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Theme.Colors.accent)
                                .matchedGeometryEffect(id: "appearancePill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.displayName)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Colors.surfaceSunken)
        )
    }
}

// MARK: - Row

/// One navigable settings row: an icon, a name, a chevron. Lives inside a
/// grouped card, so it carries its own padding rather than the card's.
///
/// `detail` is optional and, on the settings root, unused. The rows there used
/// to carry a second line echoing the current value — "9:00 AM – 5:00 PM",
/// "10 minutes before · English" — which made every row two lines tall and the
/// screen a wall of text to scan past. A settings list is read to find a place
/// to go, and the value is on the other side of the tap. Screens deeper in
/// still pass one where the row is genuinely describing something rather than
/// naming it.
///
/// The glyph is a plain monochrome symbol rather than a tinted one on a
/// coloured tile. A column of differently-coloured squares reads as a set of
/// badges competing for attention while meaning nothing — there is no scheme
/// behind the colours, so they were decoration that looked like information.
/// There is deliberately no `tint`: a parameter that is accepted and ignored is
/// worse than none, because the next call site passes a colour and waits for
/// something to happen.
struct SettingsRow: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(width: 26, height: 26)

            if let detail {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                        .lineLimit(1)
                }
            } else {
                Text(title)
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .padding(.horizontal, Theme.Metrics.cardPadding)
        .padding(.vertical, Theme.Metrics.rowPadding + 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Menu row

/// A settings row whose value is chosen from a menu rather than by navigating.
/// Language is a short, closed list — a push transition to a screen holding
/// three items would be more ceremony than the choice deserves.
struct SettingsMenuRow<Content: View>: View {
    let icon: String
    let title: String
    let value: String
    @ViewBuilder var menu: Content

    var body: some View {
        Menu {
            menu
        } label: {
            // Matches `SettingsRow`'s metrics exactly — same glyph size, same
            // 14pt gap, same vertical padding — so a menu row and a navigable
            // row sitting in one card line up rather than nearly lining up.
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .frame(width: 26, height: 26)

                Text(title)
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(value)
                    .font(Theme.Typography.body())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textFaint)
            }
            .padding(.horizontal, Theme.Metrics.cardPadding)
            .padding(.vertical, Theme.Metrics.rowPadding + 2)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}
