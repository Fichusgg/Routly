//
//  VoiceReview.swift
//  RoutineOrganizer
//
//  The editable staging area between a voice transcript and saved items. Voice
//  can yield several items at once, so nothing is committed until the user has
//  confirmed, edited, or discarded each one individually.
//

import Foundation

@Observable
final class VoiceReview: Identifiable {
    let id = UUID()
    let transcript: String
    var items: [ReviewItem]

    /// `defaultLeadMinutes` rides through to each draft's reminder lead. It is
    /// threaded rather than read from `AppSettings` down in `CaptureDraft`,
    /// which is not main-actor isolated — see the note on that initializer.
    init(transcript: String, parsed: [ParsedCapture], now: Date = Date(), defaultLeadMinutes: Int = 0) {
        self.transcript = transcript
        self.items = parsed.map { ReviewItem(parsed: $0, now: now, defaultLeadMinutes: defaultLeadMinutes) }
    }

    /// Drafts the user chose to keep.
    var keptDrafts: [CaptureDraft] { items.filter(\.keep).map(\.draft) }
    var keepCount: Int { items.filter(\.keep).count }
}

/// One parsed item in the review, with a keep/discard toggle and its editable draft.
@Observable
final class ReviewItem: Identifiable {
    let id = UUID()
    var keep: Bool = true
    var draft: CaptureDraft
    /// A follow-up the parser flagged when the item was ambiguous.
    let clarification: String?

    init(parsed: ParsedCapture, now: Date = Date(), defaultLeadMinutes: Int = 0) {
        self.draft = CaptureDraft(parsed: parsed, kind: parsed.kind, now: now,
                                  defaultLeadMinutes: defaultLeadMinutes)
        self.clarification = parsed.clarificationNeeded
    }
}
