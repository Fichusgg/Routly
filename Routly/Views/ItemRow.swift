//
//  ItemRow.swift
//  RoutineOrganizer
//
//  A single schedule item as a list row. How loudly it wears its category is the
//  user's call: "Discreet" keeps the row on the plain canvas with a small colour
//  dot at the trailing edge, "Obvious" washes the whole row in the tag colour.
//  Discreet is the default and the one the rest of the design was drawn around;
//  Obvious is for people who scan by colour rather than by text.
//
//  Tapping the circle completes; the body opens edit; deleting is a swipe from
//  the trailing edge and then a confirmation — the same gesture for every kind,
//  which is the only way a row full of gestures stays predictable.
//

import SwiftUI

struct ItemRow: View {
    let item: ScheduleItem
    let isDone: Bool
    /// True while a completion tap is still inside its cancel window: the circle
    /// reads as filled although nothing has been written yet. The caller owns
    /// both the flag and the timer behind it, because completing a to-do is what
    /// removes this row — see `ScheduleView.tapCompletion`.
    var isCompleting: Bool = false
    let onToggle: () -> Void
    let onEdit: () -> Void

    private let settings = AppSettings.shared

    private var accent: Color { Theme.Colors.category(item.category) }
    private var isObvious: Bool { settings.tagDisplay == .obvious }
    private var isTodo: Bool { item.kind == .todo }

    /// What the circle shows, which runs a second ahead of what's stored.
    private var showsFilled: Bool { isDone || isCompleting }

    var body: some View {
        HStack(spacing: 12) {
            checkbox

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    // A to-do sits a step down from a scheduled item. The
                    // timed part of the day is its spine and should read as
                    // such; the checklist under it is lighter work, and giving
                    // both the same 17pt made a long list of small errands look
                    // exactly as important as the meeting at nine.
                    .font(isTodo ? Theme.Typography.body() : Theme.Typography.itemTitle())
                    .foregroundStyle(isDone ? Theme.Colors.textFaint : Theme.Colors.textPrimary)
                    .strikethrough(isDone, color: Theme.Colors.textFaint)
                    .animation(.easeInOut(duration: 0.2), value: isDone)
                    // Category is colour-only on screen, so VoiceOver gets it
                    // as a word. See `spokenSummary` for why priority is in
                    // there when nothing on the row shows it.
                    .accessibilityLabel(spokenSummary)
                    // Delete isn't mentioned: it's a swipe action, and VoiceOver
                    // announces those itself as "actions available".
                    .accessibilityHint("Double tap to edit.")

                if hasMetadata {
                    metadata
                }
            }
            // Tapping the body edits; the checkbox above claims its own hit area.
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)

            Spacer(minLength: 8)

            trailingIndicator
        }
        // Kept small on purpose: the 44pt checkbox below sets the row's real
        // height, so this is only the breathing room a wrapped title or a
        // metadata line needs. Anything more and consecutive to-dos drift
        // apart with nothing between them to justify the gap.
        .padding(.vertical, 3)
        .padding(.horizontal, isObvious ? 12 : 0)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: isObvious ? 12 : 8, style: .continuous))
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isDone)
        // Deliberately not `.accessibilityElement(children: .combine)`: that
        // would fold the checkbox into the row and leave no way to tick
        // something off with VoiceOver. The title carries the summary instead.
    }

    // MARK: - Tag presentation

    @ViewBuilder
    private var rowBackground: some View {
        if isObvious {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Colors.categoryRowFill(item.category))
                .opacity(isDone ? 0.5 : 1)
        }
    }

    /// The tag dot at the trailing edge, in a fixed 22pt slot so Discreet and
    /// Obvious rows lay out identically — Obvious washes the whole row and has no
    /// need of a dot as well.
    private var trailingIndicator: some View {
        ZStack {
            if !isObvious {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                    .opacity(isDone ? 0.35 : 0.9)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    /// The completion control. The circle stays visually small, but the tappable
    /// area is a full 44pt — the minimum that's reliably hittable — so checking
    /// something off doesn't require precision.
    ///
    /// It fills on the first tap and, where the caller asks for it, a second tap
    /// inside the following second takes that back. So the label has to say which
    /// of the two a tap would do, rather than reading "Mark done" at a circle
    /// that's already full.
    private var checkbox: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .strokeBorder(showsFilled ? accent : Theme.Colors.separator, lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                if showsFilled {
                    Circle()
                        .fill(accent)
                        .frame(width: 22, height: 22)
                        .transition(.scale.combined(with: .opacity))
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Colors.onAccent)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: showsFilled)
        .accessibilityLabel(checkboxLabel)
    }

    /// `LocalizedStringKey`, not `String`: the `String` overload of
    /// `accessibilityLabel` is the one that *doesn't* go through the catalog, so
    /// returning a plain String here would quietly speak English to everyone.
    private var checkboxLabel: LocalizedStringKey {
        if isCompleting { return "Cancel marking done" }
        return isDone ? "Mark not done" : "Mark done"
    }

    // MARK: - Metadata

    /// Whether there's anything to show beneath the title. To-dos usually have
    /// nothing, so the row is omitted entirely rather than left as a gap.
    private var hasMetadata: Bool {
        item.startTime != nil || item.durationMinutes != nil || item.recurrence != nil
    }

    /// Metadata reads as one quiet line of text with interpuncts, rather than a
    /// row of icon badges — fewer shapes, same information.
    private var metadata: some View {
        Text(metadataText)
            .font(Theme.Typography.caption())
            .foregroundStyle(Theme.Colors.textFaint)
            .lineLimit(1)
    }

    private var metadataText: String {
        var parts: [String] = []
        if let start = item.startTime {
            parts.append(start.formatted(date: .omitted, time: .shortened))
        }
        if let minutes = item.durationMinutes {
            parts.append(durationText(minutes))
        }
        if let rule = item.recurrence {
            parts.append(rule.displayDescription)
        }
        return parts.joined(separator: " · ")
    }

    private func durationText(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    /// Category is only a colour on screen, so VoiceOver gets it in words.
    ///
    /// Priority stays here even though the badge is gone, and that is not an
    /// oversight. A sighted user infers it from where the row sits in the list;
    /// someone hearing the rows one at a time gets no such cue, so dropping it
    /// would take away information the visual design still conveys.
    ///
    /// Scope is dropped, because it is about to be conveyed structurally — it
    /// becomes the group a row sits under, and a group header announces itself.
    /// Saying it per row as well would be the same fact twice.
    private var spokenSummary: String {
        var parts = [item.title, item.category.displayName]
        if isTodo {
            parts.append(String(localized: "\(item.priority.displayName) priority"))
        }
        if hasMetadata { parts.append(metadataText) }
        if isDone { parts.append(String(localized: "Done")) }
        return parts.joined(separator: ". ")
    }
}
