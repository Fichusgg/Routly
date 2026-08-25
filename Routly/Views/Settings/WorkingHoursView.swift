//
//  WorkingHoursView.swift
//  RoutineOrganizer
//
//  "Your day" — the window everything else is measured against: free time, what
//  counts as an overloaded day, and every slot the app picks on the user's
//  behalf.
//
//  It used to sit open at the top of the settings list, two time pickers deep,
//  which put the single setting that changes what the app *does* in the same
//  visual register as the ones that change how it looks. It is a page you open
//  now, which is also what lets the menu in front of it stay a list of names.
//
//  Two plain time pickers rather than a preset list ("9–5", "8–6", …) — the
//  whole point is that the shipped assumption was wrong for this person, so
//  offering them a different set of assumptions would miss it.
//

import SwiftUI

struct WorkingHoursView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 0) {
                        DatePicker(
                            "Starts",
                            selection: workingHoursBinding(\.startMinutes),
                            displayedComponents: .hourAndMinute
                        )
                        .padding(.horizontal, Theme.Metrics.cardPadding)
                        .padding(.vertical, Theme.Metrics.rowPadding)

                        Divider().padding(.leading, Theme.Metrics.cardPadding)

                        DatePicker(
                            "Ends",
                            selection: workingHoursBinding(\.endMinutes),
                            displayedComponents: .hourAndMinute
                        )
                        .padding(.horizontal, Theme.Metrics.cardPadding)
                        .padding(.vertical, Theme.Metrics.rowPadding)
                    }
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .tint(Theme.Colors.accent)
                    .surfaceCard(padding: 0)

                    Text("\(settings.workingHours.rangeText()) · \(MinutesText.short(settings.workingHours.durationMinutes))")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(.horizontal, 4)

                    Text("Free time and overloaded days are measured against these hours, and “optimize my day” won't suggest a slot outside them. Times you set yourself are always kept.")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Your day")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
    }

    /// Bridges a minutes-from-midnight field to the `Date` a `DatePicker` wants.
    ///
    /// The setter pushes the whole range back through `AppSettings`, whose
    /// `normalized` keeps end after start — so dragging the start past the end
    /// shunts the end along rather than producing an inside-out day. That's why
    /// this reads and writes the pair instead of the single field.
    private func workingHoursBinding(_ field: WritableKeyPath<WorkingHours, Int>) -> Binding<Date> {
        let calendar = Calendar.current
        return Binding(
            get: {
                let midnight = calendar.startOfDay(for: Date())
                return calendar.date(
                    byAdding: .minute,
                    value: settings.workingHours[keyPath: field],
                    to: midnight
                ) ?? midnight
            },
            set: { newValue in
                let comps = calendar.dateComponents([.hour, .minute], from: newValue)
                var updated = settings.workingHours
                updated[keyPath: field] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                // Dragging the start forward past the end should carry the end
                // with it, not silently refuse the gesture.
                if field == \WorkingHours.startMinutes, updated.endMinutes <= updated.startMinutes {
                    updated.endMinutes = updated.startMinutes + WorkingHours.minimumWindowMinutes
                }
                settings.workingHours = updated
            }
        )
    }
}

#Preview {
    NavigationStack {
        WorkingHoursView()
    }
}
