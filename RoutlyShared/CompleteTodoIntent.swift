//
//  CompleteTodoIntent.swift
//  RoutineOrganizerWidgets
//
//  Ticking a to-do off from the home screen.
//
//  This runs in the *extension's* process, not the app's — which is the whole
//  reason the SwiftData store had to move into the App Group container. Nothing
//  here reimplements completion: it finds the item and hands it to
//  `CompletionWriter`, the same type `ScheduleViewModel.toggleDone` calls. That
//  is what keeps the consistency grid and the streaks honest about work finished
//  from a widget.
//
//  One deliberate difference from the app: there is no one-second cancel window.
//  The app fills the circle and writes a moment later so a second tap can take
//  it back — a widget has no such moment to offer, because the process is torn
//  down as soon as `perform()` returns. So the write is immediate, and taking it
//  back happens in the app.
//

import AppIntents
import Foundation
import SwiftData
import WidgetKit

struct CompleteTodoIntent: AppIntent {

    static var title: LocalizedStringResource = "Complete to-do"
    static var description = IntentDescription("Marks a to-do as done from the widget.")

    /// Deliberately false. The point of this button is that finishing something
    /// costs one tap and never leaves the home screen; opening the app would
    /// make the widget a shortcut rather than a surface.
    static var openAppWhenRun: Bool = false

    /// `ScheduleItem.id` — the app's own UUID, which survives across processes
    /// and across the store being reopened, unlike a `PersistentIdentifier`.
    @Parameter(title: "To-do")
    var todoID: String

    init() {}

    init(todoID: UUID) {
        self.todoID = todoID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: todoID),
              let container = SharedModelContainer.makeForWidget() else {
            return .result()
        }

        let context = ModelContext(container)

        // Fetched by id rather than by scanning every item: the predicate keeps
        // this a single indexed lookup on a store that may hold years of rows.
        var descriptor = FetchDescriptor<ScheduleItem>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        guard let item = try? context.fetch(descriptor).first else { return .result() }

        // The same writer the app uses. `complete` is idempotent, which matters
        // here in a way it doesn't in the app: a widget can be tapped again
        // before its timeline has reloaded, and a second record would count the
        // occurrence twice in everything that reads history.
        //
        // Owner comes from the mirror the app publishes — the Keychain that
        // ultimately backs it is unreachable from this process. nil is fine and
        // gets backfilled; a guessed id would not be. See `SharedOwner`.
        CompletionWriter().complete(
            item,
            on: Date(),
            in: context,
            owner: SharedOwner.mirrored
        )

        WidgetRefresh.reload()
        return .result()
    }
}
