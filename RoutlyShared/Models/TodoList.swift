//
//  TodoList.swift
//  RoutineOrganizer
//
//  A named list a to-do can belong to — "Work", "Home", "Shopping".
//
//  Deliberately its own entity rather than a string on `ScheduleItem`. A string
//  means renaming a list is a find-and-replace across every row that mentions
//  it, and two rows can disagree about capitalisation forever. A relationship
//  means the name lives in exactly one place and renaming is one write.
//
//  **The delete rule is the important part.** `items` nullifies: deleting a list
//  must never delete the to-dos in it. Someone tidying up their lists is
//  organising, not throwing work away, and a delete that silently takes the
//  contents with it is the kind of thing you only discover afterwards. The
//  to-dos simply return to having no list.
//
//  Only to-dos are ever assigned. An event belongs to a day, not to a list, and
//  nothing in the UI offers the choice for other kinds — but nothing in the
//  model enforces it either, so read `ScheduleItem.list` with that in mind.
//

import Foundation
import SwiftData

@Model
final class TodoList {
    var id: UUID
    var name: String

    /// Where it sits among the other lists. Plain `Int` because every list this
    /// app creates gets one at creation; there are no pre-existing rows to
    /// migrate, since the entity itself is new.
    var sortIndex: Int

    var createdAt: Date

    /// Nullify, not cascade — see the note above. This is the single most
    /// consequential line in the file.
    @Relationship(deleteRule: .nullify, inverse: \ScheduleItem.list)
    var items: [ScheduleItem]

    // MARK: - Sync groundwork
    //
    // Mirrors `ScheduleItem`; see the longer note there. Present from the start
    // so the sync layer is a new layer rather than another migration.

    var ownerID: String? = nil
    var updatedAt: Date = Date.distantPast
    var syncedAt: Date? = nil
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        name: String,
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.items = []
    }

    /// How many to-dos in this list are still outstanding — what the list row
    /// shows, since a count including finished work answers a question nobody
    /// asked.
    var openCount: Int {
        items.filter { $0.kind == .todo && !$0.isCompleted }.count
    }
}
