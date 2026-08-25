//
//  DayHeader.swift
//  RoutineOrganizer
//
//  Home of the small circular progress ring — the "consistency visualized"
//  motif. Used on the Today header for at-a-glance day progress; streak and
//  adherence rings reuse this shape in the Phase 4 consistency layer.
//

import SwiftUI

struct CompletionRing: View {
    let progress: Double   // 0...1

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Colors.hairline, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(
                    Theme.Colors.accent,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
        }
    }
}
