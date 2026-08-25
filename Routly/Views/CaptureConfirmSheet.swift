//
//  CaptureConfirmSheet.swift
//  RoutineOrganizer
//
//  The structured Add/Edit form. The user picks a kind (Event / Reminder /
//  To-do) up front, then fills in fields with real controls — this is a
//  dedicated-organizer surface, not a chat. Typing a natural-language title and
//  tapping the wand runs the parser under the hood to prefill day/time/repeat,
//  which the user can still adjust.
//
//  Layout, not amputation, is what makes this readable: every field is still
//  here. What changed is grouping — the two or three things you always fill in
//  sit at the top with room to breathe, and the settings you touch occasionally
//  (reminder lead time, repeat, effort) fold away under "More". Nothing is
//  hidden that a first-time capture actually needs.
//

import SwiftUI
import SwiftData

struct CaptureConfirmSheet: View {
    @Bindable var draft: CaptureDraft
    var onParse: () -> Void
    var onSave: () -> Void
    var onCancel: () -> Void

    /// Advanced fields start folded. Opened automatically when the draft already
    /// carries something in there, so an edit never appears to have lost data.
    @State private var showingMore = false
    @State private var didPrimeMore = false

    private let settings = AppSettings.shared
    private let connections = CalendarConnections.shared

    private var isEditing: Bool { draft.editingItem != nil }

    /// Coarse on purpose — this is a sanity check on size, not a time sheet.
    private let effortOptions = [10, 30, 60, 120, 180]

    /// The lists available to file this to-do under. Queried here rather than
    /// passed in, so every presenter of this sheet gets it without threading.
    @Query(sort: \TodoList.sortIndex) private var lists: [TodoList]

    /// Which list the to-do belongs to. "None" is a first-class choice, not an
    /// absence of one — most to-dos never get filed anywhere.
    private var listRow: some View {
        HStack(spacing: 12) {
            Text("List")
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)

            Spacer(minLength: 8)

            Menu {
                Button {
                    draft.list = nil
                } label: {
                    Label("None", systemImage: draft.list == nil ? "checkmark" : "")
                }
                if !lists.isEmpty { Divider() }
                ForEach(lists, id: \.persistentModelID) { list in
                    Button {
                        draft.list = list
                    } label: {
                        Label(
                            list.name,
                            systemImage: draft.list?.persistentModelID == list.persistentModelID ? "checkmark" : ""
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: draft.list?.name ?? String(localized: "None"))
                        .font(Theme.Typography.body())
                        .foregroundStyle(Theme.Colors.textFaint)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textFaint)
                }
            }
            .accessibilityLabel("List")
            .accessibilityValue(draft.list?.name ?? String(localized: "None"))
        }
        .padding(.horizontal, Theme.Metrics.cardPadding)
        .padding(.vertical, Theme.Metrics.rowPadding)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colors.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                        basics
                        when
                        more
                    }
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle(isEditing ? "Edit" : "New \(draft.kind.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .tint(Theme.Colors.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add", action: onSave)
                        .tint(Theme.Colors.accent)
                        .disabled(!draft.isValid)
                }
            }
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        }
        // One detent, deliberately. With `[.medium, .large]` iOS promotes the
        // sheet to large the moment a text field takes first responder — so
        // tapping the title to type made the whole sheet leap up the screen,
        // dragging the field out from under the thumb that was aiming at it.
        // A single detent has nothing to promote to: the keyboard slides over a
        // sheet that stays exactly where it was.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: primeMoreSection)
    }

    /// Unfolds "More" when there's already something in it worth seeing — an
    /// existing repeat rule, a stated effort, or a non-default reminder.
    private func primeMoreSection() {
        guard !didPrimeMore else { return }
        didPrimeMore = true
        showingMore = draft.recurrence != nil
            || draft.effortMinutes != nil
            || draft.reminderLeadMinutes != 0
            || draft.priority != .medium
            || draft.hasChangedCalendarTargets
        if showingMore { settings.hasOpenedMoreSection = true }
    }

    private func toggleMore() {
        withAnimation(Theme.Motion.snappy) { showingMore.toggle() }
        // The nudge has done its job the first time it's followed. It never
        // comes back, because a hint you've already acted on is just clutter.
        if showingMore { settings.hasOpenedMoreSection = true }
    }

    // MARK: - Basics

    /// What it is and what it's called. No section label — this is the top of
    /// the sheet and the navigation title already says what's happening.
    private var basics: some View {
        VStack(alignment: .leading, spacing: 18) {
            kindPicker
            titleField
            categoryPicker
        }
    }

    private var kindPicker: some View {
        Picker("Type", selection: $draft.kind) {
            ForEach(ItemKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: draft.kind) { _, newKind in
            if newKind.requiresDate { draft.hasDate = true }
            if !newKind.usesTime { draft.hasTime = false }
            if !newKind.usesDuration { draft.hasDuration = false }
        }
    }

    /// The title carries the weight here, so it gets real size and a rule under
    /// it rather than a boxed text field.
    private var titleField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField(titlePrompt, text: $draft.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .tint(Theme.Colors.accent)
                    .lineLimit(1...3)
                    .submitLabel(.done)
                    .onSubmit(onParse)

                if !isEditing {
                    Button(action: onParse) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.Colors.accent)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Autofill from text")
                }
            }

            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: 1)
        }
    }

    private var titlePrompt: String {
        switch draft.kind {
        case .event: return "e.g. lunch with Sam at noon"
        case .reminder: return "e.g. call mom tomorrow evening"
        case .todo: return "e.g. finish the report"
        }
    }

    private var categoryPicker: some View {
        HStack(spacing: 8) {
            ForEach(Category.allCases) { category in
                let selected = draft.category == category
                let color = Theme.Colors.category(category)
                Button {
                    Haptics.selection()
                    draft.category = category
                } label: {
                    Text(category.displayName)
                        .font(Theme.Typography.caption())
                        .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? color : Theme.Colors.surfaceSunken)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - When

    /// Day, start, end. The fields nearly every capture touches, grouped as one
    /// block of rows so the eye reads a single question — "when is this?" —
    /// instead of four separate labelled cells.
    private var when: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("When")

            VStack(spacing: 0) {
                dayRow

                if draft.kind.usesTime {
                    RowDivider(inset: 0)
                    timeRow
                }

                if draft.kind.usesDuration, draft.hasTime {
                    RowDivider(inset: 0)
                    endRow
                }
            }
            .surfaceCard(padding: 0)
        }
    }

    /// For a to-do the chosen day *is* the deadline — `CaptureDraft` resolves it
    /// straight into `dueDate` — so it's labelled for what it means.
    ///
    /// When the kind can't exist without a day, there's no toggle at all: a
    /// switch you aren't allowed to turn off just reads as a broken control.
    private var dayRow: some View {
        FormRow {
            if draft.kind.requiresDate {
                HStack {
                    Text(dayLabel)
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Spacer(minLength: 8)

                    DatePicker("", selection: $draft.date, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(Theme.Colors.accent)
                }
            } else {
                Toggle(dayLabel, isOn: $draft.hasDate)
                    .tint(Theme.Colors.accent)
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)

                if draft.hasDate {
                    DatePicker("", selection: $draft.date, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(Theme.Colors.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var dayLabel: String {
        draft.kind == .todo ? "Due" : "Day"
    }

    private var timeRow: some View {
        FormRow {
            Toggle(draft.kind.usesDuration ? "Starts" : "Time", isOn: $draft.hasTime)
                .tint(Theme.Colors.accent)
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
                .onChange(of: draft.hasTime) { _, on in
                    // Opening a time on an event should present a real span.
                    if on { draft.normalizeEndTime() }
                }

            if draft.hasTime {
                DatePicker("", selection: $draft.time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Theme.Colors.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Moving the start carries the end along, so the length the
                    // user set is preserved rather than silently reshaped.
                    .onChange(of: draft.time) { old, new in
                        if draft.kind.usesDuration {
                            draft.endTime = draft.endTime.addingTimeInterval(new.timeIntervalSince(old))
                        }
                    }
            }
        }
    }

    /// The end-time picker for events. Duration isn't typed — it's shown here as
    /// the result of start…end, and the end is kept after the start.
    private var endRow: some View {
        FormRow {
            HStack {
                Text("Ends")
                    .font(Theme.Typography.itemTitle())
                    .foregroundStyle(Theme.Colors.textPrimary)

                Spacer(minLength: 8)

                DatePicker("", selection: $draft.endTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Theme.Colors.accent)
                    .onChange(of: draft.endTime) { _, _ in draft.normalizeEndTime() }
            }

            Text("Duration \(draft.durationDisplay)")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
        }
    }

    // MARK: - More

    /// Everything that's genuinely optional, folded away by default. It's all
    /// still here — one tap, not one fewer feature.
    private var more: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggleMore) {
                HStack(spacing: 6) {
                    SectionLabel("More")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Colors.textFaint)
                        .rotationEffect(.degrees(showingMore ? 0 : -90))
                    Spacer()
                    if !showingMore, let summary = moreSummary {
                        Text(summary)
                            .font(Theme.Typography.caption())
                            .foregroundStyle(Theme.Colors.textFaint)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showingMore ? "Hide more options" : "Show more options")

            if showsMoreHint {
                moreHint
            }

            if showingMore {
                VStack(spacing: 0) {
                    if draft.kind == .todo {
                        listRow
                        RowDivider(inset: 0)
                        priorityRow
                        RowDivider(inset: 0)
                        // Only to-dos carry an effort estimate: an event's
                        // length is already the span you set above.
                        effortRow
                        RowDivider(inset: 0)
                    }

                    if draft.kind.usesTime, draft.hasTime {
                        notifyRow
                        RowDivider(inset: 0)
                    }

                    recurrenceRow

                    if !connectedCalendars.isEmpty {
                        RowDivider(inset: 0)
                        calendarRow
                    }
                }
                .surfaceCard(padding: 0)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// A folded section is easy to never notice — people assume a collapsed
    /// header is a header, not a door. This points at it once, says what's
    /// actually behind it (a list beats "more options"), and never returns after
    /// it's been opened.
    private var showsMoreHint: Bool {
        !showingMore && !settings.hasOpenedMoreSection
    }

    private var moreHint: some View {
        Button(action: toggleMore) {
            HStack(spacing: 8) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.accent)

                Text("Add repeat, priority, and a time estimate")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Colors.textFaint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    // Dismissing is its own action: tapping the note opens the
                    // section, tapping the × just makes the note go away.
                    .onTapGesture { dismissMoreHint() }
            }
            .padding(.leading, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.Colors.accentSoft)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityHint("Opens the more options section.")
    }

    private func dismissMoreHint() {
        withAnimation(Theme.Motion.snappy) { settings.hasOpenedMoreSection = true }
    }

    /// Priority, as three chips rather than a menu — the whole point is that
    /// it's one tap away once you've found this section.
    private var priorityRow: some View {
        FormRow {
            Text("Priority")
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)

            HStack(spacing: 6) {
                ForEach(Priority.allCases) { level in
                    let selected = draft.priority == level
                    Button {
                        Haptics.selection()
                        draft.priority = level
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: level.symbolName)
                                .font(.system(size: 9, weight: .bold))
                            Text(level.displayName)
                                .font(Theme.Typography.caption())
                        }
                        .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected ? Theme.Colors.accent : Theme.Colors.surfaceSunken)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Today versus the long game. Worded as a question because "Scope" on its
    /// own means nothing to anyone who didn't write the data model.
    private var scopeRow: some View {
        FormRow {
            Text("When does this matter?")
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)

            HStack(spacing: 6) {
                ForEach(TodoScope.allCases) { option in
                    let selected = draft.todoScope == option
                    Button {
                        Haptics.selection()
                        draft.todoScope = option
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: option.symbolName)
                                .font(.system(size: 10, weight: .medium))
                            Text(option.displayName)
                                .font(Theme.Typography.caption())
                        }
                        .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected ? Theme.Colors.accent : Theme.Colors.surfaceSunken)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(draft.todoScope == .today
                 ? "Sits at the top of your list until it's done."
                 : "Real, but not today's problem — it sinks below today's work.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A one-line read of what's folded away, so collapsing never hides a
    /// setting the user can't tell is set.
    private var moreSummary: String? {
        var parts: [String] = []
        if draft.kind == .todo {
            // Only what's been deliberately changed — echoing the defaults back
            // would make every collapsed section look like it holds settings.
            if draft.priority != .medium { parts.append(draft.priority.displayName) }
            if draft.todoScope != .today { parts.append(draft.todoScope.displayName) }
            if let minutes = draft.effortMinutes { parts.append(durationLabel(minutes)) }
        }
        // Compared against the user's default rather than against zero: someone
        // who has set "10 minutes before" as their default hasn't deliberately
        // changed anything by leaving it there, and echoing it back would put a
        // value in the summary of every capture they ever make.
        if draft.kind.usesTime, draft.hasTime,
           draft.reminderLeadMinutes != settings.defaultReminderLeadMinutes {
            parts.append(ReminderLead.label(draft.reminderLeadMinutes))
        }
        if let rule = draft.recurrence, draft.keepRecurrence {
            parts.append(rule.displayDescription)
        }
        if let calendar = calendarSummary { parts.append(calendar) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the collapsed section should say about calendars — which is
    /// nothing at all in the ordinary case.
    ///
    /// Two situations earn a line, and both are ones where the person would
    /// otherwise be surprised later:
    ///
    ///  • They deliberately steered this item away from the calendars their
    ///    setting sends things to. Folding "More" must not hide that.
    ///  • The item is something a calendar can't hold, while a calendar is
    ///    switched on and expecting it. This is the only place that now says
    ///    so, since nothing about calendars appears at the top of the sheet —
    ///    and a repeating event silently not arriving is exactly the kind of
    ///    quiet failure this feature keeps producing.
    private var calendarSummary: String? {
        guard !connectedCalendars.isEmpty else { return nil }

        if !draft.calendarEligibility.isEligible {
            // Only worth saying when something was expecting it. A to-do was
            // never going to a calendar and nobody thought it was.
            guard draft.kind != .todo, !settings.calendarDestinations.isEmpty else { return nil }
            return String(localized: "Not on a calendar")
        }

        guard draft.hasChangedCalendarTargets else { return nil }
        let dropped = draft.initialCalendarTargets.subtracting(draft.calendarTargets)
        guard let provider = dropped.sorted(by: { $0.rawValue < $1.rawValue }).first else {
            return String(localized: "On a calendar")
        }
        return String(format: String(localized: "Not in %@"), provider.displayName)
    }

    /// Size of the job, for the day planner. Genuinely optional: skipping it
    /// costs nothing, and tapping the selected chip again clears it. Left blank,
    /// the planner estimates and says so — better than making every capture pay
    /// a tax to serve one screen.
    private var effortRow: some View {
        FormRow {
            Text("How long will it take?")
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)

            HStack(spacing: 6) {
                ForEach(effortOptions, id: \.self) { minutes in
                    let selected = draft.effortMinutes == minutes
                    Button {
                        draft.effortMinutes = selected ? nil : minutes
                        Haptics.selection()
                    } label: {
                        Text(durationLabel(minutes))
                            .font(Theme.Typography.caption())
                            .foregroundStyle(selected ? Theme.Colors.onAccent : Theme.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(selected ? Theme.Colors.accent : Theme.Colors.surfaceSunken)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(draft.effortMinutes == nil
                 ? "Tell me and “Optimize my day” can fit this into a gap that's actually big enough. Skip it and I'll estimate instead."
                 : "Used to fit this into a gap that's actually big enough.")
                .font(Theme.Typography.caption())
                .foregroundStyle(Theme.Colors.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The chosen lead is drawn as an explicit label rather than left to
    /// `.pickerStyle(.menu)`.
    ///
    /// A menu picker renders its own label in the *system* body font, which
    /// follows the text-size setting. Every other string in this sheet is a fixed
    /// Theme size, so at the larger settings this one control kept growing while
    /// "Notify" stayed at 17pt — "10 minutes before" wrapped onto two lines and
    /// swamped the row. Same shape as `SettingsMenuRow`, which draws its value
    /// the same way and never had the problem.
    private var notifyRow: some View {
        FormRow {
            Menu {
                Picker("Notify", selection: $draft.reminderLeadMinutes) {
                    ForEach(ReminderLead.options, id: \.self) { minutes in
                        Text(verbatim: ReminderLead.label(minutes)).tag(minutes)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Notify")
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    // Scales down before it truncates: the longest option in
                    // Spanish ("10 minutos antes") is wider than anything
                    // English asks for, and half a word is worse than 90% type.
                    Text(verbatim: ReminderLead.label(draft.reminderLeadMinutes))
                        .font(Theme.Typography.body())
                        .foregroundStyle(Theme.Colors.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Notify"))
            .accessibilityValue(Text(verbatim: ReminderLead.label(draft.reminderLeadMinutes)))
        }
    }

    /// Calendars this build can reach and the person has connected. Anything
    /// else has nothing to toggle.
    private var connectedCalendars: [CalendarProvider] {
        connections.providers.filter { connections.canCreate($0) }
    }

    /// The escape hatch, and deliberately nothing more.
    ///
    /// Where events go is settled once in Settings → Calendars, and the switch
    /// here opens already matching it — so the ordinary capture needs no
    /// thought and no tap. This exists for the exception: the one event you
    /// would rather your calendar didn't have. That is the whole reason it sits
    /// folded under "More" instead of in front of every capture, which is where
    /// two earlier attempts put it and where it was in the way.
    ///
    /// When the item is something a calendar can't hold, the switches are off
    /// and disabled with the reason underneath, rather than absent — a control
    /// that vanishes leaves the person wondering whether they imagined it.
    private var calendarRow: some View {
        FormRow {
            ForEach(connectedCalendars) { provider in
                Toggle(isOn: calendarBinding(provider)) {
                    Text(verbatim: provider.displayName)
                        .font(Theme.Typography.itemTitle())
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                .tint(Theme.Colors.accent)
                .disabled(!draft.calendarEligibility.isEligible)
            }

            if let reason = draft.calendarEligibility.reason {
                Text(verbatim: reason)
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func calendarBinding(_ provider: CalendarProvider) -> Binding<Bool> {
        Binding(
            get: { draft.calendarTargets.contains(provider) },
            set: { on in
                Haptics.selection()
                if on {
                    draft.calendarTargets.insert(provider)
                } else {
                    draft.calendarTargets.remove(provider)
                }
            }
        )
    }

    private var recurrenceRow: some View {
        FormRow {
            RecurrenceEditor(
                recurrence: $draft.recurrence,
                keepRecurrence: $draft.keepRecurrence,
                anchorDate: draft.hasDate ? draft.date : Date()
            )
        }
    }

    // MARK: - Formatting

    private func durationLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Form row

/// One row inside a grouped block: consistent padding, contents stacked. Keeps
/// every field in the sheet on the same rhythm without each one re-deciding its
/// own spacing.
private struct FormRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.cardPadding)
        .padding(.vertical, 13)
    }
}
