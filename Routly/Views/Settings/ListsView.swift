//
//  ListsView.swift
//  RoutineOrganizer
//
//  Where to-do lists are made and named — "Work", "Home", "Shopping".
//
//  Each row shows how many to-dos in it are still outstanding, because a count
//  that included finished work would answer a question nobody asked.
//
//  Deleting a list keeps its to-dos. That is enforced by the nullify rule on
//  `TodoList.items`, and said out loud in the confirmation, because a delete
//  that silently took the contents with it is the kind of thing you only find
//  out about afterwards.
//

import SwiftUI
import SwiftData

struct ListsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoList.sortIndex) private var stored: [TodoList]

    @State private var viewModel = ScheduleViewModel()
    @State private var newName = ""
    @FocusState private var newNameFocused: Bool
    @State private var renaming: TodoList?
    @State private var renameText = ""
    @State private var pendingDelete: TodoList?

    private var lists: [TodoList] { viewModel.lists(from: stored) }

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    if !lists.isEmpty {
                        listsSection
                    }
                    addSection
                    if lists.isEmpty { emptyNote }
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .task { viewModel.configure(context: modelContext) }
        .alert("Rename list", isPresented: renamingBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { viewModel.rename(renaming, to: renameText) }
                renaming = nil
            }
        }
        .alert(
            "Delete this list?",
            isPresented: deletingBinding,
            presenting: pendingDelete
        ) { list in
            Button("Keep it", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                let target = list
                pendingDelete = nil
                viewModel.delete(target)
            }
        } message: { _ in
            Text("The to-dos in it are kept — they just stop being filed anywhere.")
        }
    }

    // MARK: - Lists

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Your lists")

            VStack(spacing: 0) {
                ForEach(Array(lists.enumerated()), id: \.element.persistentModelID) { index, list in
                    row(list)
                    if index < lists.count - 1 {
                        Divider().padding(.leading, Theme.Metrics.cardPadding)
                    }
                }
            }
            .surfaceCard(padding: 0)
        }
    }

    private func row(_ list: TodoList) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.Colors.accent.opacity(0.12))
                )

            Text(verbatim: list.name)
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(verbatim: "\(list.openCount)")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textFaint)

            Menu {
                Button {
                    renameText = list.name
                    renaming = list
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDelete = list
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textFaint)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, Theme.Metrics.cardPadding)
        .padding(.vertical, Theme.Metrics.rowPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(list.name)
        .accessibilityValue(String(localized: "\(list.openCount) outstanding"))
    }

    // MARK: - Add

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("New list")

            HStack(spacing: 10) {
                TextField("Name", text: $newName)
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .focused($newNameFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)

                Button(action: commit) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add list")
            }
            .padding(.horizontal, Theme.Metrics.cardPadding)
            .padding(.vertical, Theme.Metrics.rowPadding)
            .surfaceCard(padding: 0)
        }
    }

    private var emptyNote: some View {
        Text("Lists are optional. A to-do doesn't need one — they're for when you have enough of them that a heading helps.")
            .font(Theme.Typography.caption())
            .foregroundStyle(Theme.Colors.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func commit() {
        guard viewModel.createList(named: newName, after: lists) != nil else { return }
        Haptics.success()
        newName = ""
        // Focus is kept: making one list usually means making three.
        newNameFocused = true
    }

    // MARK: - Alert plumbing

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

#Preview {
    NavigationStack {
        ListsView()
            .modelContainer(
                for: [ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self],
                inMemory: true
            )
    }
}
