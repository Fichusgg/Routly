//
//  CalendarHeaderBar.swift
//  RoutineOrganizer
//
//  The top chrome for the calendar: a bold period title with the concrete range
//  beneath it, step arrows, a "Today" pill that only appears when you've wandered
//  off, and a custom segmented switcher whose selection is a single sliding pill
//  (matchedGeometryEffect) rather than the stock control. Every control is
//  tactile and every change is a spring — this is the surface the eye lands on
//  first, so it sets the bar for the rest.
//

import SwiftUI

struct CalendarHeaderBar: View {
    @Binding var mode: CalendarMode
    let title: String
    let subtitle: String
    /// True when the visible window already contains today — hides the jump pill.
    let isOnToday: Bool
    var onPrev: () -> Void
    var onNext: () -> Void
    var onToday: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.display())
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text(subtitle)
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                        .contentTransition(.numericText())
                }

                Spacer(minLength: 8)

                if !isOnToday {
                    Button(action: onToday) {
                        Text("Today")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Colors.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Theme.Colors.accentSoft))
                    }
                    .buttonStyle(.pressable)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }

                stepper
            }

            ModeSwitcher(mode: $mode)
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .animation(Theme.Motion.snappy, value: isOnToday)
    }

    private var stepper: some View {
        HStack(spacing: 2) {
            stepButton(system: "chevron.left", action: onPrev)
            stepButton(system: "chevron.right", action: onNext)
        }
        .padding(3)
        .background(Capsule().fill(Theme.Colors.surfaceSunken))
    }

    private func stepButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

/// The Week / Month / Agenda selector — a sliding accent pill under an animated
/// label+icon, matched by geometry so the selection glides instead of snapping.
struct ModeSwitcher: View {
    @Binding var mode: CalendarMode
    @Namespace private var pill

    /// Only the modes the user kept. Reading the settings here rather than
    /// taking them as a parameter keeps every calendar surface in step without
    /// threading the list through the header's callers.
    private var options: [CalendarMode] { AppSettings.shared.calendarModes }

    var body: some View {
        HStack(spacing: 4) {
            // A single remaining mode has nothing to switch between, so the
            // switcher steps out of the way rather than drawing a control with
            // one option in it.
            ForEach(options.count > 1 ? options : []) { option in
                let selected = option == mode
                Button {
                    guard option != mode else { return }
                    Haptics.selection()
                    withAnimation(Theme.Motion.snappy) { mode = option }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.symbolName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(option.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(selected ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Theme.Colors.surface)
                                .elevation(.low)
                                .matchedGeometryEffect(id: "modePill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Colors.surfaceSunken)
        )
    }
}
