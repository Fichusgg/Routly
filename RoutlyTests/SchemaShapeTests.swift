//
//  SchemaShapeTests.swift
//  RoutineOrganizerTests
//
//  What SwiftData actually persists, asserted against the generated schema
//  rather than against how the source reads.
//
//  This exists because `var priority: Priority = .medium` shipped a launch
//  crash: it looks like a defaulted additive property and is in fact a
//  non-optional column that pre-existing rows decode as NULL, which traps
//  inside the decoder. Reading the source told me nothing; reading the schema
//  tells me everything.
//

import Testing
import Foundation
import SwiftData
@testable import Routly

@MainActor
@Suite("Persisted schema shape")
struct SchemaShapeTests {

    private var itemEntity: Schema.Entity {
        let schema = Schema([ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self])
        return schema.entities.first { $0.name == "ScheduleItem" }!
    }

    private var attributeNames: [String] {
        itemEntity.attributes.map(\.name)
    }

    /// The whole point of the fix: `priority` must be an accessor, not a column.
    /// If the macro ever starts persisting computed properties, this fails here
    /// instead of at a user's launch.
    @Test("the non-optional accessors are not persisted attributes")
    func accessorsAreNotColumns() {
        #expect(!attributeNames.contains("priority"), "priority is persisted: \(attributeNames)")
        #expect(!attributeNames.contains("todoScope"), "todoScope is persisted: \(attributeNames)")
    }

    @Test("the optional raw columns are what's persisted")
    func backingColumnsArePersisted() {
        #expect(attributeNames.contains("priorityRawValue"))
        #expect(attributeNames.contains("todoScopeRawValue"))
    }

    /// The rule that keeps a schema change survivable: anything added after the
    /// first release has to be optional, so a row that predates it decodes as
    /// nil instead of trapping. Checked against the live schema so a new
    /// non-optional column can't slip in unnoticed.
    @Test("every column added since launch is optional")
    func addedColumnsAreOptional() {
        // Columns present in the original shipped schema, which existing stores
        // already have a value for and so may legitimately be non-optional.
        let original: Set<String> = [
            "id", "title", "notes", "scheduledDate", "startTime",
            "durationMinutes", "category", "recurrence", "isCompleted",
            "createdAt", "sourceText",
        ]

        for attribute in itemEntity.attributes where !original.contains(attribute.name) {
            #expect(
                attribute.isOptional || attribute.defaultValue != nil,
                "\(attribute.name) was added after launch but is neither optional nor defaulted — a pre-existing row will decode NULL into it and trap"
            )
        }
    }
}

// MARK: - Calendar links

/// `CalendarLink` is a new entity, so strictly no row can predate any of its
/// columns and the optionality rule above doesn't bite yet. It is asserted
/// anyway, for the reason the model file states: "no row predates it" stays
/// true only until the *next* column is added, and by then the shape has to
/// already be right. Getting this wrong is a launch crash, not a bug report.
@MainActor
@Suite("Calendar link schema shape")
struct CalendarLinkSchemaTests {

    private var entity: Schema.Entity {
        let schema = Schema([ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self])
        return schema.entities.first { $0.name == "CalendarLink" }!
    }

    private var attributeNames: [String] {
        entity.attributes.map(\.name)
    }

    /// The same rule as `ScheduleItem.priority`: the enums are accessors over
    /// raw string columns, never columns themselves. A Codable enum column is
    /// what the "Could not materialize Objective-C class" faults come from.
    @Test("the enum accessors are not persisted attributes")
    func accessorsAreNotColumns() {
        #expect(!attributeNames.contains("provider"), "provider is persisted: \(attributeNames)")
        #expect(!attributeNames.contains("state"), "state is persisted: \(attributeNames)")
        #expect(!attributeNames.contains("eventRef"), "eventRef is persisted: \(attributeNames)")
    }

    @Test("the raw string columns are what's persisted")
    func backingColumnsArePersisted() {
        #expect(attributeNames.contains("providerRawValue"))
        #expect(attributeNames.contains("stateRawValue"))
    }

    @Test("every column but the identity is optional or defaulted")
    func columnsSurviveNull() {
        for attribute in entity.attributes where attribute.name != "id" {
            #expect(
                attribute.isOptional || attribute.defaultValue != nil,
                "\(attribute.name) is neither optional nor defaulted — a row that predates it will decode NULL into it and trap"
            )
        }
    }

    /// The link exists to be matched back to an item; a schema where that
    /// relationship went missing would compile and then silently orphan every
    /// link at the first fetch.
    @Test("a link is related to its item")
    func relationshipExists() {
        #expect(entity.relationships.contains { $0.name == "item" })
    }

    /// Both processes open one store and must agree on the whole schema. A
    /// container told about a subset opens a store it can't fully decode.
    @Test("the shared schema both processes use includes the link entity")
    func sharedSchemaCarriesTheEntity() {
        #expect(SharedModelContainer.schema.entities.contains { $0.name == "CalendarLink" })
    }
}
