//
//  NewTodoRow.swift
//  RoutineOrganizer
//
//  The one editable row in the app.
//
//  Everywhere else, editing an item means opening the add sheet — this is the
//  exception, and it exists because appending a to-do is the one action worth
//  doing without a modal. It deliberately mirrors `ItemRow`'s geometry (the same
//  44pt leading circle, the same vertical padding) so the row being typed into
//  sits exactly where the row it becomes will sit, with no jump on save.
//
//  The circle is inert. It's drawn because its absence would shift the text left
//  and make the new row look like a different kind of thing, but a to-do that
//  doesn't exist yet cannot be completed, so it is not a button.
//

import SwiftUI

struct NewTodoRow: View {
    @Binding var title: String
    /// Owned by the parent: the row is created and destroyed as the user starts
    /// and finishes, and focus has to outlive that.
    var isFocused: FocusState<Bool>.Binding
    /// Return pressed. The parent decides whether that saves or discards — this
    /// view has no opinion about persistence.
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(Theme.Colors.separator, lineWidth: 1.5)
                .frame(width: 22, height: 22)
                // Matches the checkbox's 44pt target so the text baseline lines
                // up with every other row, even though nothing here is tappable.
                .frame(width: 44, height: 44)

            TextField("New to-do", text: $title)
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .focused(isFocused)
                .onSubmit(onSubmit)

            Spacer(minLength: 8)
        }
        .padding(.vertical, 7)
        // Focus is taken here rather than by the caller at the moment it flips
        // the row on: the field has to exist before it can accept focus, and
        // setting both in one update silently loses the request.
        .onAppear { isFocused.wrappedValue = true }
        .accessibilityLabel("New to-do")
        .accessibilityHint("Type a title, then press return to add it.")
    }
}

// MARK: - Measuring the gap under the last row

/// The two markers the tap-to-add gap is sized from.
///
/// The gap has to fill whatever is left of the list, which means knowing how
/// tall the rows above it are. Measuring the gap's own offset from the top of
/// the *viewport* would seem to do it, and doesn't: that value changes as the
/// list scrolls, so the gap would resize under the user's finger mid-drag.
///
/// So two markers report their position in the same coordinate space — one
/// pinned above the first row, one at the top of the gap — and the distance
/// between them is the content height. That difference is scroll-invariant,
/// because both endpoints move together.
enum ListMetrics {
    /// Y of a zero-height marker row sitting above the first section.
    struct TopKey: PreferenceKey {
        static var defaultValue: CGFloat { 0 }
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    /// Y of the top edge of the gap row.
    struct GapKey: PreferenceKey {
        static var defaultValue: CGFloat { 0 }
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    /// Name of the coordinate space both markers report into.
    static let space = "todayList"

    /// The gap never collapses below this, so there is still somewhere to tap
    /// once the rows fill the screen and the list has started scrolling.
    static let minimumGap: CGFloat = 88
}
