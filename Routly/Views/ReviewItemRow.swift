//
//  ReviewItemRow.swift
//  RoutineOrganizer
//
//  One editable row in a pre-commit review — a keep/discard toggle, the item's
//  title and a compact metadata strip, any parser clarification, and an edit
//  affordance. Shared by voice capture (a list of items) and goal planning (a
//  generated plan) so both confirm screens read identically.
//

import SwiftUI

struct ReviewItemRow: View {
    @Bindable var item: ReviewItem
    var onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { item.keep.toggle() }
            } label: {
                Image(systemName: item.keep ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(item.keep ? Theme.Colors.accent : Theme.Colors.separator)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.keep ? "Don't add this" : "Add this")

            VStack(alignment: .leading, spacing: 6) {
                Text(item.draft.title.isEmpty ? "Untitled" : item.draft.title)
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(item.keep ? Theme.Colors.textPrimary : Theme.Colors.textFaint)
                    .strikethrough(!item.keep)
                    .fixedSize(horizontal: false, vertical: true)

                metadata(for: item.draft)

                if let clarification = item.clarification {
                    Label(clarification, systemImage: "questionmark.circle")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit item")
        }
        // Plain row: a review list is a list to read down, not a stack of cards
        // to look at. The keep toggle carries all the state it needs.
        .padding(.vertical, Theme.Metrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(item.keep ? 1 : 0.55)
    }

    private func metadata(for draft: CaptureDraft) -> some View {
        // Wraps to a second line rather than truncating when a routine + day + kind
        // all apply, so nothing gets clipped on a narrow phone.
        FlowTags {
            tag(draft.kind.displayName, color: Theme.Colors.accent)
            tag(draft.category.displayName, color: Theme.Colors.category(draft.category))
            if draft.kind.usesTime, draft.hasTime {
                tag(draft.time.formatted(date: .omitted, time: .shortened), color: Theme.Colors.textSecondary)
            } else if draft.hasDate {
                tag(draft.date.formatted(.dateTime.month(.abbreviated).day()), color: Theme.Colors.textSecondary)
            }
            if draft.keepRecurrence, let rule = draft.recurrence {
                tag(rule.displayDescription, color: Theme.Colors.textSecondary)
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.Typography.caption())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// A minimal wrapping row of tags — lays children left to right and drops to the
/// next line when they don't fit, so a busy metadata strip never overflows.
struct FlowTags: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
