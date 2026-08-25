//
//  MoveToListSheet.swift
//  RoutineOrganizer
//
//  "Put this one somewhere else" — the list picker behind a to-do's Move
//  action.
//
//  Dropping a row onto a heading has always done this, and still does. This is
//  the version that doesn't ask for a steady hand: a drag is fine for shuffling
//  three things you can see at once, and poor for filing something into a list
//  that's scrolled off the screen or collapsed.
//
//  "No list" is a row like any other, not an X in the corner. Most to-dos never
//  get filed anywhere, so taking one *out* of a list is as ordinary as putting
//  it in, and it shouldn't be the odd one out.
//

import SwiftUI
import SwiftData

/// One to-do on its way to a list, wrapped so it can be presented with
/// `.sheet(item:)`.
///
/// The id is `persistentModelID` rather than the model's `id`, for the reason
/// the rest of this screen gives: a stored property of a row that has just been
/// deleted faults on read, and the persistent id never does.
struct PendingMove: Identifiable {
    let item: ScheduleItem
    var id: PersistentIdentifier { item.persistentModelID }
}

struct MoveToListSheet: View {
    let item: ScheduleItem
    /// Called with the chosen list, or nil for "no list at all".
    let onChoose: (TodoList?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TodoList.sortIndex) private var lists: [TodoList]

    /// Which list it's in now, so the current one can be marked rather than
    /// offered as though it were a change.
    private var currentListID: PersistentIdentifier? { item.list?.persistentModelID }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                        titleCard
                        listSection
                        if lists.isEmpty { emptyNote }
                    }
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Move to list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// What is being moved, so the sheet isn't a bare list of names with no
    /// subject. `verbatim` — a user's own task title is not a catalog key.
    private var titleCard: some View {
        Text(verbatim: item.title)
            .font(Theme.Typography.itemTitle())
            .foregroundStyle(Theme.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
    }

    private var listSection: some View {
        VStack(spacing: 0) {
            row(name: String(localized: "No list"), symbol: "tray", isCurrent: currentListID == nil) {
                onChoose(nil)
            }

            ForEach(Array(lists.enumerated()), id: \.element.persistentModelID) { index, list in
                RowDivider(inset: 52)
                row(
                    name: list.name,
                    symbol: "folder.fill",
                    isCurrent: list.persistentModelID == currentListID
                ) {
                    onChoose(list)
                }
                .id(index)
            }
        }
        .surfaceCard(padding: 0)
    }

    private func row(
        name: String,
        symbol: String,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            // Choosing the list it's already in is a no-op, not a move. Still
            // dismisses, because tapping the highlighted row plainly means
            // "leave it here".
            guard !isCurrent else { dismiss(); return }
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.Colors.accent.opacity(0.12))
                    )

                Text(verbatim: name)
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(.horizontal, Theme.Metrics.cardPadding)
            .padding(.vertical, Theme.Metrics.rowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var emptyNote: some View {
        Text("You haven't made any lists yet. Add one under the + button, then this to-do can go in it.")
            .font(Theme.Typography.caption())
            .foregroundStyle(Theme.Colors.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}
