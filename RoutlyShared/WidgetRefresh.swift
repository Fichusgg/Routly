//
//  WidgetRefresh.swift
//  RoutineOrganizerShared
//
//  Asking the widgets to redraw.
//
//  Hung off the app's single save funnel rather than sprinkled over the call
//  sites that "obviously" change what a widget shows. The sprinkled version is
//  the one that goes stale: someone adds a mutation months later, doesn't think
//  of the widget, and the home screen quietly disagrees with the app until the
//  next scheduled reload. One call in `save()` cannot be forgotten.
//
//  This is *not* the same budget as timeline refreshes the widget schedules for
//  itself. A reload the app requests while the user is actually using it is the
//  cheap, intended path; the scheduled entries in each provider are what has to
//  stay frugal, and those are computed around real event times rather than a
//  fixed interval.
//

import Foundation
import WidgetKit

enum WidgetRefresh {

    /// Redraw every Routly widget on the home and lock screens.
    ///
    /// Deliberately all-kinds rather than per-kind: the three widgets read
    /// overlapping slices of the same day, and a mutation that changes one
    /// usually changes another (completing a slotted to-do moves it out of the
    /// checklist *and* strikes it through on the agenda). Reloading one and
    /// leaving the others is how two widgets on the same screen end up
    /// disagreeing.
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
