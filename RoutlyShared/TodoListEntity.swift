//
//  TodoListEntity.swift
//  RoutineOrganizerShared
//
//  Letting the user pick which list a to-do widget shows.
//
//  Two of the same widget on one screen — "Work" and "Shopping" — is the whole
//  point of lists being an entity rather than a string, and it's the one bit of
//  configuration a to-do widget genuinely needs. Everything else about it (which
//  to-dos, in what order) is already decided by the app's own rules.
//
//  The built-in group is offered as a *named* option rather than as "None".
//  Someone opening the picker should see the same heading they see on Today —
//  their own word for it, since that heading is renameable — not a blank that
//  they have to infer means "the main one".
//

import AppIntents
import Foundation
import SwiftData

struct TodoListEntity: AppEntity, Identifiable, Hashable {

    /// Stands for the built-in group: to-dos that aren't filed under any list.
    ///
    /// A sentinel rather than nil, so the picker can show it by name alongside
    /// the real lists. Nil is still handled — a widget added before this
    /// configuration existed has no value stored — and means the same thing.
    static let defaultGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let id: UUID
    let name: String

    var isDefaultGroup: Bool { id == Self.defaultGroupID }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "List")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = TodoListQuery()
}

/// Reads the user's lists out of the shared store for the widget's edit sheet.
struct TodoListQuery: EntityQuery {

    func entities(for identifiers: [UUID]) async throws -> [TodoListEntity] {
        let all = options()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    /// What the picker shows: the built-in group first, then each list in the
    /// order the user arranged them.
    func suggestedEntities() async throws -> [TodoListEntity] {
        options()
    }

    func defaultResult() async -> TodoListEntity? {
        options().first
    }

    private func options() -> [TodoListEntity] {
        let settings = AppSettings(defaults: AppGroup.defaults)
        let group = TodoListEntity(
            id: TodoListEntity.defaultGroupID,
            name: settings.groupName(for: .today)
        )

        guard let container = SharedModelContainer.makeForWidget() else { return [group] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<TodoList>(sortBy: [SortDescriptor(\.sortIndex)])
        let lists = (try? context.fetch(descriptor)) ?? []

        return [group] + lists.map { TodoListEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - The widget's configuration

struct SelectTodoListIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource = "Choose a list"
    static var description = IntentDescription("Pick which to-dos this widget shows.")

    /// Optional so a widget placed before this existed keeps working — nil reads
    /// as the built-in group, exactly like the sentinel does.
    @Parameter(title: "List")
    var list: TodoListEntity?

    init() {}

    init(list: TodoListEntity?) {
        self.list = list
    }

    /// What the widget should actually show. nil means the built-in group.
    var selectedListID: UUID? {
        guard let list, !list.isDefaultGroup else { return nil }
        return list.id
    }

    /// The heading, which is the chosen list's name or the group's own.
    func title(settings: AppSettings) -> String {
        guard let list, !list.isDefaultGroup else {
            return settings.groupName(for: .today)
        }
        return list.name
    }
}
