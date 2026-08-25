//
//  ConsistencyView.swift
//  RoutineOrganizer
//
//  How often you're actually finishing what you plan, as a grid of days. Each
//  column is a week, each row a weekday; the greener a cell, the more got done
//  that day. It's the one screen in the app whose whole job is to be looked at
//  rather than acted on, so it stays quiet: three numbers, a grid, and a line of
//  plain English underneath.
//
//  Deliberately not a scoreboard. Empty days are blank, not red — a day with
//  nothing planned isn't a failure, and a screen that implies otherwise is one
//  people stop opening.
//

import SwiftUI
import SwiftData

struct ConsistencyView: View {
    @Query(sort: \ScheduleItem.createdAt, order: .reverse) private var items: [ScheduleItem]

    /// Roughly four months — long enough to show a pattern, short enough that
    /// the columns stay tappable on a phone.
    private let weeks = 17

    @State private var selected: DayConsistency?

    private let engine = ConsistencyEngine()
    private var calendar: Calendar { engine.calendar }

    private var days: [DayConsistency] { engine.days(from: items, weeks: weeks) }
    private var summary: ConsistencySummary { engine.summary(for: days) }

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    stats
                    gridSection
                    if let selected { detail(for: selected) }
                    legend
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Consistency")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
    }

    // MARK: - Stats

    /// Three numbers, and the consistency record gets the big type because it's
    /// the one people actually come here for.
    ///
    /// It reads as weeks, not as a daily chain, and it carries its own best
    /// alongside it. Both choices are the same choice: this should feel like a
    /// record you're building and can see the shape of, not a fragile thing one
    /// bad Tuesday takes away.
    private var stats: some View {
        HStack(alignment: .top, spacing: 12) {
            stat(
                value: "\(summary.currentWeeks)",
                unit: summary.currentWeeks == 1 ? "week in a row" : "weeks in a row",
                label: "Consistent",
                emphasised: true,
                footnote: bestText
            )
            stat(
                value: "\(summary.totalCompleted)",
                unit: summary.totalCompleted == 1 ? "thing" : "things",
                label: "Finished"
            )
            stat(
                value: rateText,
                unit: summary.completionRate == nil ? nil : "of planned",
                label: "Follow-through"
            )
        }
    }

    private var rateText: String {
        guard let rate = summary.completionRate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }

    /// Shown only when the best run is ahead of the current one — while you're
    /// standing on your best, repeating it underneath is noise. The case this
    /// exists for is the broken run: current 0, best 6, so the screen answers
    /// "you've done this before" at the exact moment that's worth knowing.
    private var bestText: LocalizedStringKey? {
        guard summary.bestWeeks > summary.currentWeeks else { return nil }
        return "Best: \(summary.bestWeeks)"
    }

    /// `unit`, `label` and `footnote` are `LocalizedStringKey` — the `String`
    /// overload of `Text` is the one that skips the catalog, which is why this
    /// screen used to be English in every language. `value` stays a `String`
    /// and is drawn `verbatim`: it's an already-formatted number, and looking
    /// it up as a key would be meaningless.
    private func stat(
        value: String,
        unit: LocalizedStringKey?,
        label: LocalizedStringKey,
        emphasised: Bool = false,
        footnote: LocalizedStringKey? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: value)
                .font(emphasised ? Theme.Typography.display() : .system(size: 26, weight: .semibold))
                .foregroundStyle(emphasised ? Theme.Colors.done : Theme.Colors.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let unit {
                Text(unit)
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .lineLimit(1)
            }
            Text(label)
                .font(Theme.Typography.label())
                .tracking(0.8)
                .foregroundStyle(Theme.Colors.textFaint)
                .textCase(.uppercase)
                .padding(.top, 2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let footnote {
                Text(footnote)
                    .font(Theme.Typography.micro())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .padding(.top, 3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Grid

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Already resolved by `rangeLabel` itself — see the note there.
            SectionLabel(verbatim: rangeLabel)

            // The grid is the point of the screen, so it gets the one enclosure
            // here — it reads as a single object rather than loose dots.
            VStack(alignment: .leading, spacing: 8) {
                ConsistencyGrid(
                    days: days,
                    weeks: weeks,
                    calendar: calendar,
                    selected: selected
                ) { day in
                    Haptics.selection()
                    withAnimation(Theme.Motion.snappy) {
                        selected = (selected?.date == day.date) ? nil : day
                    }
                }

                monthRuler
            }
            .surfaceCard()
        }
    }

    /// Resolved to a `String` here rather than handed on as a key, because
    /// `SectionLabel` takes a `String` so it can uppercase it.
    private var rangeLabel: String {
        guard let first = days.first?.date else { return String(localized: "Recent weeks") }
        let start = first.formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "Since \(start)")
    }

    /// A sparse set of month names under the columns, so a long grid still has
    /// somewhere for the eye to land.
    private var monthRuler: some View {
        HStack(spacing: 0) {
            ForEach(monthMarkers, id: \.week) { marker in
                Text(marker.name)
                    .font(Theme.Typography.micro())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One label per month that starts within the window.
    private var monthMarkers: [(week: Int, name: String)] {
        var seen: Set<Int> = []
        var markers: [(week: Int, name: String)] = []
        for (index, day) in days.enumerated() where index % 7 == 0 {
            let month = calendar.component(.month, from: day.date)
            guard !seen.contains(month) else { continue }
            seen.insert(month)
            markers.append((index / 7, day.date.formatted(.dateTime.month(.abbreviated))))
        }
        return markers
    }

    // MARK: - Detail

    private func detail(for day: DayConsistency) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(detailText(for: day))
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous)
                .fill(Theme.Colors.surfaceSunken)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func detailText(for day: DayConsistency) -> String {
        if day.isEmpty { return String(localized: "Nothing planned.") }
        if day.isMissed { return String(localized: "\(day.scheduled) planned, none finished.") }
        if day.scheduled == 0 { return String(localized: "\(day.completed) finished.") }
        return String(localized: "\(day.completed) of \(day.scheduled) finished.")
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 8) {
            Text("Less")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ConsistencyGrid.fill(for: level))
                    .frame(width: 12, height: 12)
            }
            Text("More")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Grid

/// Columns are weeks, rows are weekdays — the shape people already know how to
/// read. Cell size is derived from the available width so it fits any phone
/// without scrolling sideways.
private struct ConsistencyGrid: View {
    let days: [DayConsistency]
    let weeks: Int
    let calendar: Calendar
    let selected: DayConsistency?
    var onSelect: (DayConsistency) -> Void

    private let spacing: CGFloat = 3
    private let labelWidth: CGFloat = 20

    /// Cells are square and share the available width evenly, so the grid fits
    /// any phone without a hard-coded size or a sideways scroll. The label
    /// column takes its row heights from the grid beside it.
    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            weekdayLabels
                .frame(width: labelWidth, alignment: .leading)

            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { weekday in
                        cellView(week: week, weekday: weekday)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var weekdayLabels: some View {
        VStack(spacing: spacing) {
            ForEach(0..<7, id: \.self) { weekday in
                Group {
                    // Only alternate rows are labelled; seven tiny letters in a
                    // column is noise, three is a guide.
                    if weekday % 2 == 1 {
                        Text(symbol(for: weekday))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.Colors.textFaint)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func symbol(for weekday: Int) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = (calendar.firstWeekday - 1 + weekday) % 7
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    @ViewBuilder
    private func cellView(week: Int, weekday: Int) -> some View {
        let index = week * 7 + weekday
        if days.indices.contains(index) {
            let day = days[index]
            let isFuture = day.date > calendar.startOfDay(for: Date())
            let isSelected = selected?.date == day.date

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isFuture ? Color.clear : Self.fill(for: day.level))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.Colors.textPrimary, lineWidth: 1.5)
                    } else if calendar.isDateInToday(day.date) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.Colors.accent, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if !isFuture { onSelect(day) } }
                .accessibilityLabel(accessibilityLabel(for: day))
        } else {
            Color.clear
        }
    }

    /// Built with `String(localized:)` rather than returned as a literal: the
    /// `String` overload of `.accessibilityLabel` skips the catalog too, so
    /// VoiceOver was reading these cells out in English whatever the language.
    private func accessibilityLabel(for day: DayConsistency) -> String {
        let date = day.date.formatted(.dateTime.month(.wide).day())
        if day.isEmpty { return String(localized: "\(date), nothing planned") }
        return String(localized: "\(date), \(day.completed) of \(day.scheduled) finished")
    }

    /// The green ramp. Level 0 is a neutral tile, not a red one — an empty day
    /// is information, not an accusation.
    static func fill(for level: Int) -> Color {
        switch level {
        case 1: return Theme.Colors.done.opacity(0.25)
        case 2: return Theme.Colors.done.opacity(0.45)
        case 3: return Theme.Colors.done.opacity(0.70)
        case 4: return Theme.Colors.done
        default: return Theme.Colors.surfaceSunken
        }
    }
}

#Preview {
    NavigationStack {
        ConsistencyView()
            .modelContainer(
                for: [ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self],
                inMemory: true
            )
    }
}
