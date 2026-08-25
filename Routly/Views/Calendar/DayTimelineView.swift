//
//  DayTimelineView.swift
//  RoutineOrganizer
//
//  A single day, time-blocked. Hour rules set the vertical rhythm; timed events
//  are packed into side-by-side lanes (via EventLayout) so an overlapping morning
//  stays legible; a live "now" line tracks the current minute when the day is
//  today; and all-day items ride a horizontal shelf above the grid. Tapping any
//  block hands the item up for a quick-look. Completed occurrences read as dimmed
//  and struck through so status is visible at a glance.
//

import SwiftUI

struct DayTimelineView: View {
    let day: Date
    let items: [ScheduleItem]
    let viewModel: ScheduleViewModel
    var onSelect: (ScheduleItem) -> Void

    private let calendar = Calendar(identifier: .gregorian)
    private let hourHeight: CGFloat = 56
    private let gutter: CGFloat = 54
    private let laneGap: CGFloat = 4

    private var timed: [ScheduleItem] { items.filter { $0.startTime != nil } }
    private var allDay: [ScheduleItem] { items.filter { $0.startTime == nil } }
    private var positioned: [PositionedEvent] { EventLayout.position(timed, calendar: calendar) }

    var body: some View {
        VStack(spacing: 10) {
            if !allDay.isEmpty { allDayShelf }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            hourGrid
                            if calendar.isDateInToday(day) {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    nowIndicator(width: geo.size.width, at: context.date)
                                }
                            }
                            ForEach(positioned) { pe in
                                eventBlock(pe, totalWidth: geo.size.width)
                            }
                        }
                        .frame(width: geo.size.width, height: hourHeight * 24)
                    }
                    .frame(height: hourHeight * 24)
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: day) { _, _ in scroll(proxy) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.Motion.smooth) { proxy.scrollTo(scrollAnchorHour, anchor: .top) }
    }

    // MARK: - All-day shelf

    private var allDayShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allDay) { item in
                    allDayChip(item)
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
        }
    }

    private func allDayChip(_ item: ScheduleItem) -> some View {
        let color = Theme.Colors.category(item.category)
        let done = viewModel.isDone(item, on: day)
        return Button { onSelect(item) } label: {
            HStack(spacing: 6) {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(item.title)
                    .font(Theme.Typography.caption())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(done, color: Theme.Colors.textFaint)
                    .frame(maxWidth: 170, alignment: .leading)
            }
            .foregroundStyle(done ? Theme.Colors.textFaint : color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Theme.Colors.categoryTint(item.category, strong: !done), in: Capsule())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Hour grid

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(hourLabel(hour))
                        .font(Theme.Typography.micro())
                        .foregroundStyle(Theme.Colors.textFaint)
                        .frame(width: gutter - 10, alignment: .trailing)
                        .offset(y: -6)
                    Rectangle()
                        .fill(Theme.Colors.hairline)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
            }
        }
    }

    // MARK: - Now indicator

    private func nowIndicator(width: CGFloat, at date: Date) -> some View {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let y = CGFloat(minutes) / 60 * hourHeight
        return HStack(spacing: 0) {
            Circle()
                .fill(Theme.Colors.now)
                .frame(width: 8, height: 8)
                .offset(x: gutter - 12)
            Rectangle()
                .fill(Theme.Colors.now)
                .frame(height: 1.5)
        }
        .frame(width: width)
        .offset(y: y - 4)
        .allowsHitTesting(false)
    }

    // MARK: - Event block

    private func eventBlock(_ pe: PositionedEvent, totalWidth: CGFloat) -> some View {
        let item = pe.item
        let color = Theme.Colors.category(item.category)
        let done = viewModel.isDone(item, on: day)
        let laneArea = totalWidth - gutter
        let laneWidth = (laneArea - laneGap * CGFloat(pe.columnCount - 1)) / CGFloat(pe.columnCount)
        let x = gutter + CGFloat(pe.column) * (laneWidth + laneGap)
        let y = CGFloat(pe.startMinute) / 60 * hourHeight
        let rawHeight = CGFloat(pe.endMinute - pe.startMinute) / 60 * hourHeight
        let height = max(28, rawHeight - 2)
        let showsTime = height >= 44
        let vPad: CGFloat = height < 40 ? 4 : 7

        return VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(done ? Theme.Colors.textFaint : Theme.Colors.textPrimary)
                .strikethrough(done, color: Theme.Colors.textFaint)
                .lineLimit(showsTime ? 2 : 1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
            if showsTime, let start = item.startTime {
                Text(start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, vPad)
        .frame(width: laneWidth, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.Colors.categoryGradient(item.category, strong: !done))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(done ? color.opacity(0.4) : color)
                .frame(width: 3)
                .padding(.vertical, 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(color.opacity(done ? 0.12 : 0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(done ? 0.7 : 1)
        .offset(x: x, y: y)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            onSelect(item)
        }
    }

    // MARK: - Math & labels

    private var scrollAnchorHour: Int {
        let earliest = timed.compactMap { $0.startTime }.map {
            let c = calendar.dateComponents([.hour], from: $0)
            return c.hour ?? 7
        }.min()
        // Land a little before the first event (or 7am), never negative.
        return max(0, min(earliest ?? 7, 7) - 1)
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12 AM"
        case 12: return "12 PM"
        case let h where h < 12: return "\(h) AM"
        default: return "\(hour - 12) PM"
        }
    }
}
