//
//  Haptics.swift
//  RoutineOrganizer
//
//  A thin, opinionated wrapper over UIKit's feedback generators so calendar
//  interactions carry spatial, tactile weight — a light tick on day selection,
//  a firmer thud when a period flips, a success ripple on completion. Kept in
//  one place so the vocabulary stays consistent and calls stay one word long.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum Haptics {
    /// A light tick — day taps, cell selection, mode switches.
    static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// A soft impact — a lightweight confirmation (opening a quick-look).
    static func light() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// A firmer impact — a period flip, a committed drag.
    static func medium() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// A rigid tick — crossing a snap boundary while dragging.
    static func rigid() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }

    /// A success ripple — marking something done.
    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// The double-tap of a destructive action landing — a hold-to-delete ring
    /// closing. Deliberately not `success`: something just went away, and the
    /// hand should be told that in a different voice from "done".
    static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
