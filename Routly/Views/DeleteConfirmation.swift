//
//  DeleteConfirmation.swift
//  RoutineOrganizer
//
//  Deleting a routine is ambiguous — "gym every weekday" isn't one thing you can
//  throw away. This is the ask: one occurrence, this one and everything after,
//  or the whole series. One-off items keep the plain yes/no alert, because there
//  is nothing to disambiguate. Shared by Today and the calendar so the wording
//  and the options don't drift apart.
//

import SwiftUI

/// A delete the user has asked for but not yet confirmed. Carries the day it was
/// asked from — "this one" only means something relative to an occurrence.
struct PendingDeletion: Identifiable {
    let item: ScheduleItem
    let day: Date

    var id: String { "\(item.id)-\(day.timeIntervalSinceReferenceDate)" }
}

extension View {
    /// Confirms a pending delete, offering recurrence scopes when the item repeats.
    /// - Parameters:
    ///   - oneOffTitle/oneOffMessage: wording for the simple non-repeating case,
    ///     which each screen phrases in its own voice. `LocalizedStringKey`
    ///     rather than `String` on purpose: the `String` overloads of `.alert`
    ///     and `Text` are the ones that *don't* go through the catalog, so a
    ///     plain String here spoke English to everyone regardless of language.
    ///   - onDelete: called with the scope the user picked.
    func deleteConfirmation(
        _ pending: Binding<PendingDeletion?>,
        oneOffTitle: LocalizedStringKey,
        oneOffMessage: LocalizedStringKey,
        onDelete: @escaping (ScheduleItem, ScheduleViewModel.DeletionScope, Date) -> Void
    ) -> some View {
        modifier(DeleteConfirmationModifier(
            pending: pending,
            oneOffTitle: oneOffTitle,
            oneOffMessage: oneOffMessage,
            onDelete: onDelete
        ))
    }
}

private struct DeleteConfirmationModifier: ViewModifier {
    @Binding var pending: PendingDeletion?
    let oneOffTitle: LocalizedStringKey
    let oneOffMessage: LocalizedStringKey
    let onDelete: (ScheduleItem, ScheduleViewModel.DeletionScope, Date) -> Void

    private let calendar = Calendar(identifier: .gregorian)

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "This repeats",
                isPresented: binding(forRoutine: true),
                titleVisibility: .visible,
                presenting: pending
            ) { target in
                Button("Delete only \(dayText(target.day).lowercased())") {
                    perform(target, .occurrence)
                }
                Button("Delete this and all future") {
                    perform(target, .futureOccurrences)
                }
                Button("Delete every occurrence", role: .destructive) {
                    perform(target, .series)
                }
                Button("Keep it", role: .cancel) { pending = nil }
            } message: { target in
                Text(routineMessage(target))
            }
            .alert(
                oneOffTitle,
                isPresented: binding(forRoutine: false),
                presenting: pending
            ) { target in
                Button("Keep it", role: .cancel) { pending = nil }
                Button("Delete", role: .destructive) { perform(target, .series) }
            } message: { _ in
                Text(oneOffMessage)
            }
    }

    /// Order matters here, and it's the reason deleting used to kill the app.
    /// A presentation keeps hold of the value it was `presenting:` while it
    /// animates away, and re-reads it — so if the item is already deleted by
    /// then, `routineMessage` touches a stored property on a model whose
    /// backing data is gone, which is a hard SwiftData fault, not an exception.
    /// Letting go of the item *first* means nothing is left pointing at it.
    private func perform(_ target: PendingDeletion, _ scope: ScheduleViewModel.DeletionScope) {
        Haptics.medium()
        let item = target.item
        let day = target.day
        pending = nil
        onDelete(item, scope, day)
    }

    /// Two presentations share one optional, so each only claims the case it
    /// handles — otherwise both would try to show at once.
    private func binding(forRoutine routine: Bool) -> Binding<Bool> {
        Binding(
            get: { pending.map { $0.item.isRoutine == routine } ?? false },
            set: { if !$0 { pending = nil } }
        )
    }

    private func routineMessage(_ target: PendingDeletion) -> String {
        let cadence = target.item.recurrence?.displayDescription ?? String(localized: "Repeats")
        return String(localized: "“\(target.item.title)” — \(cadence). Deleting everything ahead stops it filling future days; deleting every occurrence also clears its history.")
    }

    /// Interpolated into the "Delete only …" button, so these have to be
    /// resolved through the catalog rather than returned as English literals —
    /// the button around them is localized and would otherwise read as a
    /// half-translated sentence.
    private func dayText(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
