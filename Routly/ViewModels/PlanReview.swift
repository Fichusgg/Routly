//
//  PlanReview.swift
//  RoutineOrganizer
//
//  The editable staging area between a goal and a committed plan. A goal expands
//  into several items; like voice capture, nothing lands on the calendar until
//  the user has confirmed, edited, or dropped each one — same safety pattern,
//  just for a whole plan instead of a single item. Reuses `ReviewItem` so the
//  per-item edit/keep machinery is shared with voice review.
//

import Foundation

@Observable
final class PlanReview: Identifiable {
    let id = UUID()
    let goalTitle: String
    let summary: String
    let horizon: PlanHorizon?
    /// The original spoken/typed goal, so the user can flip to item-by-item
    /// interpretation over the same input.
    let sourceText: String
    var items: [ReviewItem]

    init(plan: ParsedPlan, now: Date = Date()) {
        self.goalTitle = plan.goalTitle
        self.summary = plan.summary
        self.horizon = plan.horizon
        self.sourceText = plan.sourceText
        self.items = plan.items.map { ReviewItem(parsed: $0, now: now) }
    }

    /// Drafts the user chose to keep.
    var keptDrafts: [CaptureDraft] { items.filter(\.keep).map(\.draft) }
    var keepCount: Int { items.filter(\.keep).count }
}
