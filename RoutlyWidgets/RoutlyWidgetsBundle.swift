//
//  RoutlyWidgetsBundle.swift
//  RoutineOrganizerWidgets
//
//  The extension's entry point. Three widgets, each answering one question the
//  user would otherwise have to open the app for: what's left, say something,
//  what's next.
//

import SwiftUI
import WidgetKit

@main
struct RoutlyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodosWidget()
        VoiceCaptureWidget()
        AgendaWidget()
    }
}
