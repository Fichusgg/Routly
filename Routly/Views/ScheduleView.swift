//
//  ScheduleView.swift
//  RoutineOrganizer
//
//  The Today home: only today, nothing else. A three-way add affordance
//  (Event / Reminder / To-do) opens a structured entry form — no chat thread.
//  Timed items sit in a fixed schedule; to-dos are a rolling checklist that
//  clears itself as things get done. A dismissible suggestion card surfaces
//  gentle nudges, and placing a timed item that clashes routes through a
//  conflict-resolution step rather than landing silently.
//

import SwiftUI
import SwiftData

/// A single sheet slot for Today, so add / conflict / voice-review swap cleanly.
private enum TodaySheet: Identifiable {
    case add(CaptureDraft)
    case conflict(PendingConflict)
    case voiceReview(VoiceReview)
    case goalEntry
    case planReview(PlanReview)
    /// The calendar's card, reused: tapping something scheduled should offer
    /// complete / edit / delete rather than dropping straight into the editor.
    case quickLook(ScheduleItem, Date)

    var id: String {
        switch self {
        case .add(let draft): return "add-\(draft.id)"
        case .conflict(let pending): return "conflict-\(pending.id)"
        case .voiceReview(let review): return "review-\(review.id)"
        case .goalEntry: return "goal-entry"
        case .planReview(let review): return "plan-\(review.id)"
        case let .quickLook(item, day): return "ql-\(item.id)-\(day.timeIntervalSinceReferenceDate)"
        }
    }
}

struct ScheduleView: View {

    /// Set when the app was opened by the mic widget. A widget can't record —
    /// no extension can — so it launches the app and the app starts listening
    /// here, which is what makes it one tap instead of two.
    ///
    /// A token rather than a Bool so a second tap is distinguishable from the
    /// first; nil is the ordinary launch.
    var voiceLaunch: UUID? = nil

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScheduleItem.createdAt, order: .reverse) private var items: [ScheduleItem]
    @Query(sort: \TodoList.sortIndex) private var storedLists: [TodoList]

    @State private var viewModel = ScheduleViewModel()
    @State private var speech = SpeechTranscriber()
    @Bindable private var settings = AppSettings.shared
    @State private var activeSheet: TodaySheet?
    @State private var pendingDelete: PendingDeletion?
    @State private var processingTranscript: String?
    /// A suggestion awaiting confirmation — nothing is applied until the user says so.
    @State private var pendingSuggestion: ScheduleSuggestion?
    /// A calendar push that didn't land. Held rather than logged: an event the
    /// user asked to put in their calendar and that isn't there is exactly the
    /// kind of silent failure that stops the app being trusted.
    @State private var calendarError: String?
    @State private var showingOptimizer = false
    @State private var showingSettings = false
    /// The lists editor, opened from the add menu rather than only from Settings.
    @State private var showingLists = false
    /// The to-do waiting to be filed somewhere else, for the explicit move that
    /// doesn't involve dragging anything.
    ///
    /// Wrapped rather than presented as the model itself, matching
    /// `PendingDeletion`: the id is the persistent one, which is the only thing
    /// still safe to read if the row goes away while the sheet is up.
    @State private var movingTodo: PendingMove?
    /// Which day the schedule box is showing, as an offset from today. Never
    /// negative: the box pages forward into the week ahead, not back into a past
    /// you can no longer act on.
    @State private var dayOffset = 0
    /// The to-do whose circle is filled but whose completion hasn't been written
    /// yet. Held here rather than in the row because completing a to-do is what
    /// removes that row, and a view on its way out can't be trusted to finish
    /// anything. Rows match against `persistentModelID`, which is safe to ask a
    /// deleted model for; the delete paths clear this so the timer can never
    /// write a completion to one.
    @State private var completing: ScheduleItem?
    @State private var completionTimer: Task<Void, Never>?
    /// True while a session started by the mic widget is running — the one case
    /// where no finger is holding the button down, so the tap has to mean stop.
    @State private var isHandsFree = false

    // MARK: - Inline to-do capture

    /// Which group the editable row is currently open under, if any.
    ///
    /// Was a plain Bool pinned to the "today" group, which meant adding to a
    /// list took the full sheet and three taps through More. A to-do typed
    /// under a heading now belongs to that heading — the group you tapped is
    /// the answer to "which list", so it never has to be asked.
    @State private var addingInGroup: String?
    private var isAddingTodo: Bool { addingInGroup != nil }
    /// The group whose heading is being renamed, and the text being typed.
    @State private var renamingScope: TodoScope?
    @State private var renameText = ""
    /// The group a drag is currently held over, so it can say so.
    @State private var dropTargetGroup: String?
    @State private var newTodoTitle = ""
    @FocusState private var newTodoFocused: Bool
    /// How tall the tappable gap under the last row should be. Derived from the
    /// two markers in `ListMetrics`; see the note there for why it isn't simply
    /// the gap's own offset.
    @State private var gapHeight: CGFloat = ListMetrics.minimumGap
    /// The two marker positions the gap is sized from. Held rather than derived
    /// because they arrive in separate preference callbacks.
    @State private var listTop: CGFloat = 0
    @State private var gapTop: CGFloat = 0

    @Environment(AuthController.self) private var auth

    private let today = Date()
    private let calendar = Calendar(identifier: .gregorian)

    /// One heading and the to-dos under it.
    ///
    /// Scope groups and list groups are the same shape on purpose: from the
    /// screen's side they are both "a name with tasks under it you can drag
    /// things into", and only what a drop *means* differs — a scope group
    /// changes the task's scope, a list group files it.
    private struct TodoGroup: Identifiable {
        let id: String
        let title: String
        let items: [ScheduleItem]
        let scope: TodoScope?
        let list: TodoList?
        /// Only the two built-in headings are the app's words rather than the
        /// user's, so only those offer renaming. A list is renamed where it's
        /// made.
        var isRenamable: Bool { scope != nil }
    }

    /// One heading for everything unfiled, then a heading per list.
    ///
    /// The today/long-term split is gone. It asked the user to sort every
    /// capture into one of two buckets before it counted, and the answer was
    /// almost always "today" — so it was a decision that cost something and
    /// decided nothing. Lists do the same job better, because the user names
    /// them for the distinctions they actually make.
    ///
    /// Items still carrying the old long-term scope simply appear here with
    /// everything else; the field is left on the model rather than migrated
    /// away, so nothing needs rewriting on disk to stop showing it.
    ///
    /// A to-do filed under a list appears there and only there — showing it in
    /// both would be the same task twice on one screen, which is the thing
    /// `activeTodos` already goes out of its way to avoid for slotted to-dos.
    private var todoGroups: [TodoGroup] {
        var groups: [TodoGroup] = [
            TodoGroup(
                id: "scope-today",
                title: settings.groupName(for: .today),
                items: todos.filter { $0.list == nil },
                scope: .today,
                list: nil
            )
        ]
        for list in viewModel.lists(from: storedLists) {
            groups.append(TodoGroup(
                id: "list-\(list.id.uuidString)",
                title: list.name,
                items: todos.filter { $0.list?.persistentModelID == list.persistentModelID },
                scope: nil,
                list: list
            ))
        }
        return groups
    }

    /// The day the schedule box is currently showing.
    private var scheduleDate: Date {
        calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: today)) ?? today
    }

    /// `todayTimed` is already day-agnostic — it takes the day as `now:` — so
    /// paging needs no new query, just a different date.
    private var timed: [ScheduleItem] { viewModel.todayTimed(from: items, now: scheduleDate) }
    private var todos: [ScheduleItem] { viewModel.activeTodos(from: items) }
    private var completedTodos: [ScheduleItem] { viewModel.completedTodos(from: items, now: today) }
    private var suggestions: [ScheduleSuggestion] { viewModel.suggestions(from: items, now: today) }

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            VStack(spacing: 16) {
                header
                    .padding(.bottom, 4)

                if speech.isRecording {
                    liveTranscript
                }

                if let suggestion = suggestions.first {
                    SuggestionCard(
                        suggestion: suggestion,
                        onApply: suggestion.action == nil ? nil : { pendingSuggestion = suggestion },
                        onDismiss: { withAnimation { viewModel.dismiss(suggestion) } }
                    )
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Always on screen, always the same height — a day with four
                // events and a day with none must not move everything below
                // them.
                scheduleBox

                // `isAddingTodo` keeps the list on screen while the very first
                // to-do is being typed — otherwise the row would be inside a
                // branch that isn't rendered.
                if todos.isEmpty && !isAddingTodo {
                    emptyState
                    Spacer(minLength: 0)
                } else {
                    itemList
                }
            }
            .padding(.top, 12)

            floatingRecordButton

            if let transcript = processingTranscript {
                processingOverlay(transcript)
            }
        }
        // Dismissing the keyboard abandons an unsaved row rather than leaving a
        // half-typed ghost sitting in the list. A successful save has already
        // cleared `isAddingTodo` by the time focus drops, so this doesn't fire
        // for it.
        .onChange(of: newTodoFocused) { _, focused in
            if !focused && isAddingTodo { endInlineTodo() }
        }
        .task {
            viewModel.configure(context: modelContext)
            // Restores any stored session and stamps ownership on rows that
            // predate it. Local-only and synchronous — never blocks the screen.
            auth.configure(context: modelContext)
            // Closes the books on days that ended without an answer. Writes
            // nothing any screen reads, changes nothing on this one, and is
            // idempotent — so re-appearing (coming back from the calendar, for
            // instance) re-runs it harmlessly. It's here rather than at launch
            // because it needs the queried items, and after `configure` because
            // it needs somewhere to write.
            _ = viewModel.auditPastDays(from: items)
            // Decides, once ever, whether this install is new enough to start on
            // a ten-minute reminder lead. Here for the same reason the audit is:
            // it needs the queried items, and an empty schedule is what tells a
            // brand-new install apart from someone who has been using the app
            // since before the setting existed. See the note on the method.
            settings.seedReminderLeadDefault(hasExistingItems: !items.isEmpty)
            // 15s of real silence ends the recording and goes straight to review.
            speech.onSilenceTimeout = { transcript in
                isHandsFree = false
                startVoiceReview(transcript)
            }
            // Opened from the mic widget: start listening now rather than
            // waiting for a hold the user has no reason to expect — they already
            // tapped the mic once, on the home screen.
            if voiceLaunch != nil { await beginWidgetCapture() }
        }
        .sheet(isPresented: $showingSettings) { MenuView() }
        // Its own stack and its own Done: `ListsView` is written to be pushed
        // inside Settings, so presented on its own it would have no title bar
        // and no way back.
        .sheet(isPresented: $showingLists) {
            NavigationStack {
                ListsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingLists = false }
                        }
                    }
            }
        }
        .sheet(item: $movingTodo) { pending in
            MoveToListSheet(item: pending.item) { list in
                movingTodo = nil
                withAnimation(Theme.Motion.snappy) { file(pending.item, into: list) }
            }
        }
        .alert("Rename group", isPresented: renamingBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingScope = nil }
            Button("Save") {
                if let scope = renamingScope { settings.setGroupName(renameText, for: scope) }
                renamingScope = nil
            }
        } message: {
            Text("What this group is called on Today. Leave it empty to go back to the default.")
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add(let draft):
                CaptureConfirmSheet(
                    draft: draft,
                    onParse: { parseTitle(into: draft) },
                    onSave: { attemptSave(draft) },
                    onCancel: { activeSheet = nil }
                )
            case .conflict(let pending):
                ConflictResolutionView(
                    pending: pending,
                    onUseSuggestion: { applyAlternative($0, to: pending.draft) },
                    onPlaceAnyway: { commit(pending.draft) },
                    onCancel: { activeSheet = nil }
                )
            case .voiceReview(let review):
                CaptureReviewView(
                    review: review,
                    onCommit: { commitReview(review) },
                    onCancel: { activeSheet = nil },
                    onPlanInstead: { buildPlan(from: review.transcript) }
                )
            case let .quickLook(item, day):
                EventQuickLookSheet(
                    item: item,
                    day: day,
                    isDone: viewModel.isDone(item, on: day),
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.25)) { viewModel.toggleDone(item, on: day) }
                        activeSheet = nil
                    },
                    // Always the editor from here: the card is already open, so
                    // "Edit" can only sensibly mean the form behind it.
                    onEdit: { activeSheet = .add(CaptureDraft(item: item)) },
                    onDelete: {
                        // Let go of the sheet before asking, for the same reason
                        // the delete confirmation does — a presentation that is
                        // still holding a model being deleted is a hard fault.
                        activeSheet = nil
                        pendingDelete = PendingDeletion(item: item, day: day)
                    }
                )
            case .goalEntry:
                GoalEntrySheet(
                    onBuild: { buildPlan(from: $0) },
                    onCancel: { activeSheet = nil }
                )
            case .planReview(let review):
                PlanReviewView(
                    review: review,
                    onCommit: { commitPlan(review) },
                    onCancel: { activeSheet = nil },
                    onReviewAsItems: { reviewPlanAsItems(review) }
                )
            }
        }
        .deleteConfirmation(
            $pendingDelete,
            oneOffTitle: "Delete this?",
            oneOffMessage: "This removes it from your list for good — it won't count as a missed day.",
            onDelete: performDelete
        )
        // Suggestions never apply silently — this is the confirmation step.
        .alert("Apply this change?", isPresented: suggestionAlertBinding, presenting: pendingSuggestion) { suggestion in
            Button("Not now", role: .cancel) { pendingSuggestion = nil }
            Button(suggestion.actionTitle ?? "Apply") { applySuggestion(suggestion) }
        } message: { suggestion in
            Text(confirmationText(for: suggestion))
        }
        // Asked once per language, and only when that language genuinely has no
        // on-device model here. Declining is remembered too — the point is to be
        // asked once, not every time the mic is held.
        .alert(
            "Transcribe this language online?",
            isPresented: serverConsentBinding,
            presenting: pendingConsentLanguage
        ) { language in
            Button("Allow") {
                settings.setServerSpeech(true, for: language)
                speech.acknowledgeConsentPrompt()
            }
            Button("Keep it on device", role: .cancel) {
                settings.setServerSpeech(false, for: language)
                speech.acknowledgeConsentPrompt()
            }
        } message: { language in
            Text(serverConsentMessage(for: language))
        }
        .alert(
            "Couldn't reach your calendar",
            isPresented: calendarErrorBinding,
            presenting: calendarError
        ) { _ in
            Button("OK", role: .cancel) { calendarError = nil }
        } message: { message in
            Text(verbatim: message)
        }
        .sheet(isPresented: $showingOptimizer) {
            OptimizeDayView(
                plan: viewModel.dayPlan(from: items, now: today),
                suggestions: viewModel.optimizeToday(from: items, now: today),
                onApply: { pendingSuggestion = $0; showingOptimizer = false },
                onDismissSuggestion: { viewModel.dismiss($0) },
                onClose: { showingOptimizer = false }
            )
        }
    }

    // MARK: - Header & add

    /// The one place oversized type is spent on this screen. The date beneath it
    /// stays quiet — the day label is the thing worth reading first — and the
    /// single add affordance sits opposite it.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            // The day is the way to the calendar. It reads as a heading and
            // behaves as one — no chevron, no tint — because the calendar is
            // where "and what about the rest of the week" goes, and that is the
            // question the title already asks.
            NavigationLink {
                CalendarView()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today")
                        .font(Theme.Typography.display())
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(today.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the calendar.")

            Spacer(minLength: 8)

            calendarButton
            addButton
            settingsButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.screenPadding)
    }

    /// The calendar, as a named control rather than only as a tap on the date.
    ///
    /// The day title opens the same screen, and that stays: it reads as a
    /// heading and behaves as one. This is the discoverable version of it — an
    /// icon that looks like what it opens, for anyone who never learns that the
    /// word "Today" is a button.
    ///
    /// It replaces the consistency grid that briefly sat here. `ConsistencyView`
    /// is still in the project and still builds, but nothing opens it now; the
    /// route back is one line here.
    private var calendarButton: some View {
        NavigationLink {
            CalendarView()
        } label: {
            Image(systemName: "calendar")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.Colors.textFaint)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calendar")
    }

    /// Everything that isn't the day: reminders and voice, working hours, lists,
    /// colour and account, in one sheet.
    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    /// One `+`, opening a menu of the three kinds.
    ///
    /// This replaces a full-width row of three tiles. The row cost roughly a
    /// tenth of the screen to say something the `+` says in a corner, and this
    /// screen's whole job is to show the day rather than the ways into it.
    ///
    /// The honest trade: adding an Event or Reminder is now two taps rather than
    /// one. That is acceptable because neither is the fast path — the mic is
    /// (hold, no taps), and a to-do is still one tap on the gap under the list.
    /// The tiles were the deliberate, structured route, and a menu is a fair
    /// place for it.
    ///
    /// `kind.displayName` is already resolved through the catalog by `ItemKind`,
    /// so the `StringProtocol` overload of `Label` is the correct one here — it
    /// must not be looked up a second time.
    private var addButton: some View {
        Menu {
            ForEach(ItemKind.allCases) { kind in
                Button {
                    activeSheet = .add(CaptureDraft(
                        kind: kind,
                        defaultLeadMinutes: settings.defaultReminderLeadMinutes,
                        // Opens already matching Settings, so the switch under
                        // "More" is an opt-*out* rather than a question.
                        defaultCalendarTargets: CalendarSync.newItemDestinations
                    ))
                } label: {
                    Label(kind.displayName, systemImage: kind.symbolName)
                }
            }

            // A second group for the two that hand the work to the app rather
            // than to a form: one turns a sentence into a whole plan, the other
            // rearranges what's already on the day. Both produce something to
            // review, which is what separates them from the three above.
            Section {
                Button {
                    activeSheet = .goalEntry
                } label: {
                    Label("Turn a goal into a plan", systemImage: "target")
                }

                Button {
                    showingOptimizer = true
                } label: {
                    Label("Optimize my day", systemImage: "wand.and.stars")
                }
            }

            // Third group: not a thing to add, but the place the headings those
            // things get added *under* are made. It was reachable only through
            // Settings, which is a long way round from the moment you actually
            // want it — you notice you need a list while you're filing something.
            Section {
                Button {
                    showingLists = true
                } label: {
                    Label("Configure lists", systemImage: "folder")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add")
        .accessibilityHint("Choose an event, reminder or to-do to add.")
    }

    /// The primary capture affordance: hold to record, release to finish.
    ///
    /// One control in the corner and nothing else. The language pill used to be
    /// stacked above it; it now lives beside the transcript in the review sheet,
    /// which is where being wrong about the language is actually discovered.
    ///
    /// The bottom padding is measured from the safe area, and inside a tab the
    /// safe area already excludes the bar — so this is the gap between the mic
    /// and the top of the tab bar, on every device, with no bar-height
    /// arithmetic and nothing to keep in sync. On a phone with a home indicator
    /// the indicator sits below the bar and is likewise already accounted for.
    private var floatingRecordButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VoiceCaptureButton(
                    speech: speech,
                    isHandsFree: isHandsFree,
                    onFinish: { transcript in
                        isHandsFree = false
                        startVoiceReview(transcript)
                    }
                )
                    .padding(.trailing, Self.micInsetFromEdge)
                    .padding(.bottom, Self.micGapAboveTabBar)
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    /// How far the mic floats above the tab bar, and how far in from the edge.
    ///
    /// It sat 8pt above the bar and flush with the screen padding, which read as
    /// crowded into the corner — the button is 68pt of solid accent and needs
    /// air around it to look placed rather than wedged. Both are measured from
    /// the safe area, so the bottom figure is the gap to the bar itself on every
    /// device and the home indicator is already accounted for.
    private static let micGapAboveTabBar: CGFloat = 20
    private static let micInsetFromEdge: CGFloat = Theme.Metrics.screenPadding + 6

    /// Live feedback while recording — also the quickest way to see whether the
    /// whole ramble is being captured before it ever reaches the parser.
    private var liveTranscript: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Theme.Colors.accent)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript)
                    .font(Theme.Typography.body())
                    .foregroundStyle(speech.transcript.isEmpty ? Theme.Colors.textFaint : Theme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Take your time — this ends after 15s of silence, or tap stop.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Colors.accentSoft)
        )
        .padding(.horizontal, Theme.Metrics.screenPadding)
    }

    /// Covers the screen while the transcript is being turned into items, so the
    /// wait after a long ramble isn't a dead moment where nothing appears to happen.
    private func processingOverlay(_ transcript: String) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.Colors.accent)

                Text("Working on it…")
                    .font(Theme.Typography.title())
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Turning that into your schedule.")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textSecondary)

                Text("“\(transcript)”")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .italic()
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.Colors.surfaceRaised)
            )
            .elevation(.high)
        }
        .transition(.opacity)
    }

    // MARK: - Schedule box

    /// Today's schedule, in its own fixed-height box above the to-do list.
    ///
    /// It used to be a `Section` inside the same `List` as the to-dos, and that
    /// cost two things:
    ///
    /// 1. **The box changed height as you paged.** A day with four events and a
    ///    day with none are different sizes, so swiping through the week made
    ///    everything below it jump. That was solved with a constant height and
    ///    is now solved the other way: the box fits its day exactly, and the
    ///    to-do list below simply starts lower on a busy day. Movement while
    ///    paging is the lesser problem; a day you can't fully see is the worse
    ///    one.
    /// 2. **Events couldn't be deleted.** The paging `DragGesture` was attached
    ///    to the whole section, so it swallowed the horizontal swipe that opens
    ///    the delete action. To-dos were unaffected — different section, no
    ///    gesture — which is exactly why it looked like an events-only bug.
    ///
    /// That second problem is now settled the other way round, deliberately:
    /// inside this box a horizontal swipe pages the day and nothing else, so the
    /// rows carry no trailing delete at all. Deleting something scheduled goes
    /// through the quick-look card behind the row. Paging still also lives on
    /// the header's chevrons — a gesture nobody can see is not an affordance.
    private var scheduleBox: some View {
        VStack(spacing: 0) {
            scheduleBoxHeader

            if !isCollapsed(Self.scheduleSectionID) {
                scheduleContent
                    // The rows page too, now that nothing else is listening for
                    // a horizontal drag on them.
                    .simultaneousGesture(schedulePaging)
            }
        }
    }

    /// The day's rows in a plain stack.
    ///
    /// This was a `List` with `.frame(height:)` set to `rows × 46`, and that
    /// arithmetic was a bug waiting to be seen: a row actually draws about 59pt,
    /// so from three events onward the frame was shorter than its contents and
    /// the last one was clipped. It only became visible when the internal
    /// scrolling was removed — before that you could scroll to the row that the
    /// box was cutting off, which hid the miscalculation rather than fixing it.
    ///
    /// Rather than correct the constant, the constant is gone. A `VStack` is
    /// exactly as tall as what it holds, at any Dynamic Type size and however
    /// many lines a title wraps to — which is what "resize the box to the number
    /// of events" actually means, and it cannot clip.
    ///
    /// Nothing is lost by leaving `List` behind here: this box no longer has
    /// swipe actions, no longer scrolls, and never had selection or reordering.
    /// Those were the only reasons it needed to be a list.
    private var scheduleContent: some View {
        VStack(spacing: 0) {
            if timed.isEmpty {
                emptyScheduleDay
            } else {
                // Ticking a scheduled item off leaves it in place, struck
                // through, so there's nothing to take back with a second tap.
                //
                // Completion is written against the day being *shown*: ticking
                // something off on Thursday's page must land on Thursday.
                ForEach(timed, id: \.persistentModelID) { item in
                    scheduleRow(item)
                }
            }
        }
    }

    /// One row in the box. The same `ItemRow` the lists use, with the padding
    /// `listRowInsets` used to provide applied directly — outside a `List` those
    /// modifiers are silently no-ops, which would have left every row jammed
    /// against the screen edge.
    private func scheduleRow(_ item: ScheduleItem) -> some View {
        ItemRow(
            item: item,
            isDone: viewModel.isDone(item, on: scheduleDate),
            isCompleting: completing?.persistentModelID == item.persistentModelID,
            onToggle: { tapCompletion(item, defersWrite: false, on: scheduleDate) },
            onEdit: {
                activeSheet = item.kind == .todo
                    ? .add(CaptureDraft(item: item))
                    : .quickLook(item, scheduleDate)
            }
        )
        .padding(.horizontal, Theme.Metrics.screenPadding)
    }
    static let scheduleSectionID = "section-schedule"
    static let finishedSectionID = "section-finished"

    /// Collapse state lives in settings so a section someone shut stays shut.
    private func isCollapsed(_ id: String) -> Bool { settings.isCollapsed(id) }

    private func toggleCollapsed(_ id: String) {
        Haptics.selection()
        withAnimation(Theme.Motion.snappy) {
            settings.setCollapsed(!settings.isCollapsed(id), for: id)
        }
    }

    /// A chevron that turns to face the way the section will move.
    private func collapseChevron(_ id: String) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.Colors.textFaint)
            .rotationEffect(.degrees(isCollapsed(id) ? -90 : 0))
    }

    /// The day being shown, with the two steps through the week beside it.
    private var scheduleBoxHeader: some View {
        HStack(spacing: 4) {
            NavigationLink {
                CalendarView()
            } label: {
                SectionLabel(verbatim: scheduleTitle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the calendar.")

            Button { toggleCollapsed(Self.scheduleSectionID) } label: {
                collapseChevron(Self.scheduleSectionID)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today’s schedule")
            .accessibilityHint(isCollapsed(Self.scheduleSectionID) ? "Double tap to expand." : "Double tap to collapse.")

            Spacer(minLength: 8)

            stepButton(systemImage: "chevron.left", to: dayOffset - 1)
                .disabled(dayOffset == 0)
            stepButton(systemImage: "chevron.right", to: dayOffset + 1)
                .disabled(dayOffset >= pageCount - 1)
        }
        .padding(.leading, Theme.Metrics.screenPadding)
        .padding(.trailing, Theme.Metrics.screenPadding - 6)
        .padding(.top, 14)
        .padding(.bottom, 6)
        // The drag lives here rather than on the rows, so a horizontal swipe on
        // a row still belongs to `swipeActions`.
        .contentShape(Rectangle())
        .gesture(schedulePaging)
    }

    private func stepButton(systemImage: String, to offset: Int) -> some View {
        Button {
            page(to: offset)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(offset < dayOffset ? "Previous day" : "Next day")
    }

    // MARK: - To-do list

    /// Plain rows on the canvas, with nothing ruled between them. No row has a
    /// background of its own — the list reads as a list, and the spacing alone
    /// separates one to-do from the next.
    ///
    /// Every system separator is switched off. A plain List insists on ruling
    /// under its section header and after its last row, and no line in this
    /// layout was earning its keep.
    private var itemList: some View {
        GeometryReader { viewport in
            List {
                // Zero-height, invisible, and load-bearing: the top end of the
                // measurement described in `ListMetrics`.
                marker(ListMetrics.TopKey.self)

                // One section per group: the two scope headings, then a
                // heading per list. The first also appears while empty if a
                // to-do is being typed, so the first one you ever add has a
                // home.
                ForEach(todoGroups) { group in
                    if !group.items.isEmpty || addingInGroup == group.id {
                        Section {
                            if !isCollapsed(group.id) {
                                todoRows(group)

                                if addingInGroup != group.id {
                                    addRow(group)
                                }

                                if addingInGroup == group.id {
                                    NewTodoRow(
                                        title: $newTodoTitle,
                                        isFocused: $newTodoFocused,
                                        onSubmit: commitInlineTodo
                                    )
                                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.Metrics.screenPadding, bottom: 0, trailing: Theme.Metrics.screenPadding))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    // Deliberately no swipeActions: there is
                                    // nothing to delete yet, and a half-created
                                    // row that could be swiped away is a state
                                    // with two ways out.
                                }
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }

                // Finished today. Collapsed by default: it is there to answer
                // "did I already do that?", not to be read every time the screen
                // opens, and an open list of done things competes with the one
                // that still needs doing.
                if settings.showsFinishedToday && !completedTodos.isEmpty {
                    Section {
                        if !isCollapsed(Self.finishedSectionID) {
                            rows(completedTodos, defersCompletion: false, on: today)
                        }
                    } header: {
                        completedHeader
                    }
                }

                gapRow
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .listSectionSeparator(.hidden)
            .coordinateSpace(name: ListMetrics.space)
            .onPreferenceChange(ListMetrics.TopKey.self) { top in
                recomputeGap(top: top, viewportHeight: viewport.size.height)
            }
            .onPreferenceChange(ListMetrics.GapKey.self) { gap in
                recomputeGap(gapTop: gap, viewportHeight: viewport.size.height)
            }
        }
    }

    /// A zero-height row that reports its own position and nothing else.
    private func marker<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        Color.clear
            .frame(height: 0)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: key,
                        value: proxy.frame(in: .named(ListMetrics.space)).minY
                    )
                }
            )
    }

    /// The empty space under the last row — a real, full-width target rather
    /// than a thin strip, so a tap anywhere below the list starts a to-do.
    ///
    /// It is its own list row on purpose. Being a sibling of the item rows
    /// rather than an overlay on top of them is what keeps it from stealing
    /// their taps or their trailing-edge swipes: it simply has no geometry in
    /// common with them.
    private var gapRow: some View {
        VStack(spacing: 0) {
            // No circle of its own any more: every group now ends with one, and
            // the last of them sits directly above this. Two dashed circles in a
            // column read as two empty slots rather than one. The gap stays as
            // the generous tap target it always was.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: gapHeight, alignment: .topLeading)
        // Scoped to this row on purpose. A `withAnimation` around the state
        // change would also animate the editable row's insertion into the List,
        // which the list already handles; this keeps the crossfade to the one
        // thing that was popping.
        .animation(.easeInOut(duration: 0.15), value: isAddingTodo)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // Unchanged: the hit area is still the whole gap, not the circle.
        .contentShape(Rectangle())
        .onTapGesture(perform: beginInlineTodo)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ListMetrics.GapKey.self,
                    value: proxy.frame(in: .named(ListMetrics.space)).minY
                )
            }
        )
        .accessibilityLabel("Add a to-do")
        .accessibilityHint("Double tap to start a new to-do.")
        .accessibilityAddTraits(.isButton)
    }

    /// The one visual cue that the space below the list does something: a dashed
    /// circle sitting in the same column as the completion circles above it, so
    /// it reads as the next, empty one rather than as a control of its own.
    ///
    /// Purely decorative. `allowsHitTesting(false)` matters more than it looks —
    /// without it this would punch a hole in the gap's `contentShape`, and the
    /// one spot most likely to be tapped would be the one spot that didn't
    /// respond. The whole gap stays the target; this only shows where it is.
    private var nextTodoHint: some View {
        Circle()
            .strokeBorder(
                Theme.Colors.separator,
                style: StrokeStyle(lineWidth: 1.5, dash: [2, 3])
            )
            // The same 22 as a real completion circle, and the same
            // `strokeBorder` treatment, so the two are the same mark in the same
            // column. The dashes alone carry "not yet a thing" — at full size
            // the column reads as a list with one more slot in it, which a
            // smaller circle broke.
            .frame(width: 22, height: 22)
            // The same 44pt column `ItemRow`'s checkbox occupies, inset by the
            // screen padding its row carries, so the centres line up exactly.
            .frame(width: 44, height: 44)
            .padding(.leading, Theme.Metrics.screenPadding)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Identity is `persistentModelID`, not `id`: the latter is a stored
    /// property, and anything that reads a stored property of a row that's just
    /// been deleted faults. The persistent id is held in memory and is always
    /// safe to ask for.
    /// `onMove` is taken here rather than applied by the caller because the
    /// modifier only exists on `ForEach` — a wrapper returning `some View` has
    /// no `.onMove`, which is exactly what the compiler said.
    ///
    /// Groups that don't pass one are pinned with `moveDisabled`, so entering
    /// reorder mode doesn't offer a drag handle on rows that have nowhere to go.
    private func rows(
        _ items: [ScheduleItem],
        defersCompletion: Bool,
        on day: Date,
        onMove: ((IndexSet, Int) -> Void)? = nil
    ) -> some View {
        ForEach(items, id: \.persistentModelID) { item in
            row(item, defersCompletion: defersCompletion, on: day)
                .moveDisabled(onMove == nil)
                // Only a to-do can be dropped on a day — an event already has
                // one. The payload is the id as a string rather than a custom
                // `Transferable`: the drop lands in the same view that queried
                // the item, so a reference to it would be a longer way of
                // saying the same thing.
                .draggable(item.kind == .todo ? item.id.uuidString : "")
        }
        .onMove { source, destination in onMove?(source, destination) }
    }

    /// A to-do deletes by swiping from the trailing edge and then confirming —
    /// with scopes if it repeats, a plain yes/no if it doesn't. The tap gesture
    /// on the circle is the only other thing on the row, and the two don't
    /// overlap: a swipe never starts on the 44pt checkbox, and a tap doesn't
    /// travel far enough to be read as a swipe.
    ///
    /// Only the to-do lists use this; the schedule box builds its own rows and
    /// deliberately has no trailing swipe, because there a horizontal swipe
    /// means "show me the next day".
    private func row(
        _ item: ScheduleItem,
        defersCompletion: Bool,
        on day: Date
    ) -> some View {
        ItemRow(
            item: item,
            isDone: viewModel.isDone(item, on: day),
            isCompleting: completing?.persistentModelID == item.persistentModelID,
            onToggle: { tapCompletion(item, defersWrite: defersCompletion, on: day) },
            // A to-do is a line of text — the editor is the only thing
            // behind it worth showing. Something scheduled has a when, a
            // duration and a cadence, so it gets the card.
            onEdit: {
                activeSheet = item.kind == .todo
                    ? .add(CaptureDraft(item: item))
                    : .quickLook(item, day)
            }
        )
        .listRowInsets(EdgeInsets(top: 0, leading: Theme.Metrics.screenPadding, bottom: 0, trailing: Theme.Metrics.screenPadding))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Deliberately *not* `role: .destructive`. That role tells the list
            // the row is going away the moment the button is tapped, so it plays
            // its deletion animation — the action expands and the row slides off
            // the leading edge — and then never plays it back, because nothing
            // has actually been deleted: this button only opens a question. The
            // row was left invisible, still in the list and still in the store,
            // until something rebuilt the list; answering "Keep it" looked
            // exactly like a delete. The tint carries the destructive meaning
            // that the role was never really earning.
            Button {
                // Asking to delete the row that's mid-completion takes the
                // completion back. Both gestures landing on one row would
                // otherwise race, and the confirmation would be sitting over a
                // row that had already ticked itself off and left.
                if completing?.persistentModelID == item.persistentModelID {
                    clearPendingCompletion()
                }
                pendingDelete = PendingDeletion(item: item, day: day)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(Theme.Colors.now)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // Leading edge, and only for to-dos: an event has a time rather
            // than a list, so there is nothing to file it under. Opposite the
            // delete so a mis-swipe in either direction is never destructive.
            if item.kind == .todo {
                Button {
                    movingTodo = PendingMove(item: item)
                } label: {
                    Label("Move to list", systemImage: "folder")
                }
                .tint(Theme.Colors.accent)
            }
        }
    }

    // MARK: - Schedule paging

    /// How many days ahead the box can reach. Matches
    /// `ScheduleViewModel.windowDays`, which is the horizon everything else on
    /// this screen already works to — so the dots can't promise a day the rest
    /// of the app doesn't consider.
    private var pageCount: Int { viewModel.windowDays }

    /// "Today's schedule" on the first page, then the day's own name. Resolved
    /// to a `String` because only the first is a fixed phrase.
    private var scheduleTitle: String {
        guard dayOffset > 0 else { return String(localized: "Today’s schedule") }
        if calendar.isDateInTomorrow(scheduleDate) { return String(localized: "Tomorrow") }
        return scheduleDate.formatted(.dateTime.weekday(.wide))
    }

    /// Names the day it is talking about. "Nothing scheduled." on a box that
    /// pages through the week leaves you checking the header to work out which
    /// day was empty; saying it in the sentence answers that on its own.
    private var emptyScheduleText: String {
        if dayOffset == 0 { return String(localized: "Nothing scheduled for today.") }
        if calendar.isDateInTomorrow(scheduleDate) {
            return String(localized: "Nothing scheduled for tomorrow.")
        }
        return String(localized: "Nothing scheduled for \(scheduleDate.formatted(.dateTime.weekday(.wide))).")
    }

    /// A day in the window with nothing on it. Says so quietly rather than
    /// collapsing, so the box keeps its shape while paging through the week.
    private var emptyScheduleDay: some View {
        Text(verbatim: emptyScheduleText)
            .font(Theme.Typography.caption())
            .foregroundStyle(Theme.Colors.textFaint)
            // Roughly a row's worth of height, so paging from a busy day to an
            // empty one doesn't snap the whole screen upward.
            .padding(.vertical, 18)
            .padding(.leading, Theme.Metrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Swipe left for the next day, right to come back toward today.
    ///
    /// A `DragGesture` rather than a paging `TabView`: the schedule is a section
    /// inside the same `List` as the to-dos, and the gap under that list is
    /// measured from row positions (see `ListMetrics`). Lifting the section into
    /// its own pager would need a fixed height and would break that measurement
    /// for the sake of rubber-banding.
    ///
    /// `minimumDistance` is high enough that it can't be confused with the
    /// trailing-edge swipe that deletes a row.
    private var schedulePaging: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                // Ignore anything closer to vertical than horizontal, or the
                // list's own scrolling would fight it.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < 0 {
                    page(to: dayOffset + 1)
                } else {
                    page(to: dayOffset - 1)
                }
            }
    }

    /// Clamped to the window, and never behind today — a day that has already
    /// happened isn't something this screen can help with.
    private func page(to offset: Int) {
        let target = min(max(offset, 0), pageCount - 1)
        guard target != dayOffset else { return }
        Haptics.selection()
        withAnimation(Theme.Motion.snappy) { dayOffset = target }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingScope != nil }, set: { if !$0 { renamingScope = nil } })
    }

    /// A group's heading: its name, a collapse chevron, and — for the two the
    /// app named rather than the user — a tap to rename it.
    ///
    /// The whole strip is also the group's drop target, so a task can be moved
    /// into a collapsed group without expanding it first.
    private func groupHeader(_ group: TodoGroup) -> some View {
        HStack(spacing: 6) {
            Button {
                if group.isRenamable, let scope = group.scope {
                    renameText = group.title
                    renamingScope = scope
                } else {
                    toggleCollapsed(group.id)
                }
            } label: {
                Text(verbatim: group.title.uppercased())
                    .font(Theme.Typography.label())
                    .tracking(0.8)
                    .foregroundStyle(Theme.Colors.textFaint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.title)
            .accessibilityHint(group.isRenamable ? "Double tap to rename." : "")

            Text(verbatim: "\(group.items.count)")
                .font(Theme.Typography.micro())
                .foregroundStyle(Theme.Colors.textFaint)
                .opacity(isCollapsed(group.id) ? 1 : 0)

            Button { toggleCollapsed(group.id) } label: {
                collapseChevron(group.id)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isCollapsed(group.id) ? "Double tap to expand." : "Double tap to collapse.")

            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.Metrics.screenPadding)
        .padding(.trailing, Theme.Metrics.screenPadding)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(dropTargetGroup == group.id ? Theme.Colors.accentSoft : .clear)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // Dropping on the heading puts the task at the top of that group.
        .dropDestination(for: String.self) { ids, _ in
            drop(ids, into: group, at: 0)
        } isTargeted: { targeted in
            withAnimation(Theme.Motion.snappy) {
                dropTargetGroup = targeted ? group.id : nil
            }
        }
    }

    /// A group's rows.
    ///
    /// **Reordering is `onMove`, not the drop destinations.** It used to be only
    /// the latter — every row `.draggable` and every row a `.dropDestination` —
    /// on the theory that picking a task up and dropping it on its new
    /// neighbour needed no edit mode. It didn't work, and couldn't: inside a
    /// `List`, the row-level drop target competes with the list's own drag
    /// machinery and never receives the drop, so the task lifted, moved, and
    /// went straight back where it started. Nothing was written, which is why
    /// the sort index was never the thing at fault.
    ///
    /// `ForEach.onMove` is the List's native path for the same gesture: press,
    /// hold, drag, and the rows part around it. The drop destinations stay for
    /// what they're actually good at — dragging a task onto *another group's
    /// heading* to file it there, which is a different operation and one the
    /// list has no opinion about.
    private func todoRows(_ group: TodoGroup) -> some View {
        ForEach(Array(group.items.enumerated()), id: \.element.persistentModelID) { index, item in
            row(item, defersCompletion: true, on: today)
                .draggable(item.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in
                    drop(ids, into: group, at: index)
                }
        }
        .onMove { source, destination in
            Haptics.selection()
            viewModel.reorder(group.items, from: source, to: destination)
        }
    }

    // MARK: - Filing a capture

    /// The user's list names, as the parser wants them.
    ///
    /// Read fresh at each call rather than snapshotted: a list made a minute ago
    /// should be available to file into on the very next capture.
    private var listNames: [String] { viewModel.lists(from: storedLists).map(\.name) }

    /// Turns the parser's guessed list *name* into the real `TodoList`.
    ///
    /// Case-insensitive, because a model that returns "school" for a list called
    /// "School" has understood the task perfectly and it would be silly to throw
    /// that away over a capital letter. Anything that matches nothing is simply
    /// dropped: the to-do stays unfiled and the user places it themselves, which
    /// is exactly where they'd be if the feature didn't exist.
    ///
    /// Never overrides a list the user already chose — filing is a suggestion,
    /// and a suggestion that overwrites an answer is not one.
    private func resolveSuggestedList(on draft: CaptureDraft) {
        guard draft.kind == .todo, draft.list == nil,
              let name = draft.suggestedListName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return }

        draft.list = viewModel.lists(from: storedLists).first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Files a to-do under a list — or out of every list — from the row's own
    /// menu, with no dragging involved.
    ///
    /// Dropping a row onto a heading already does this, and keeps doing it. But
    /// a drag is a gesture you have to know about, hold steady, and land: fine
    /// for reordering three things you're looking at, poor for "this belongs in
    /// Work" on a list you've scrolled. This is the same operation, said out
    /// loud, and it goes through the same `move` so a filed task also lands in a
    /// sensible position rather than keeping an index from the group it left.
    private func file(_ item: ScheduleItem, into list: TodoList?) {
        let destination = todoGroups.first { group in
            guard let list else { return group.list == nil }
            return group.list?.persistentModelID == list.persistentModelID
        }
        Haptics.selection()
        viewModel.move(
            item,
            toScope: destination?.scope,
            list: list,
            within: destination?.items ?? [],
            // Appended rather than inserted: the user said which list, not where
            // in it, and guessing a position would be inventing an answer.
            at: destination?.items.count ?? 0
        )
    }

    /// Moves the dragged task into `group` at `index`.
    ///
    /// One handler for both gestures, because there is one gesture: pick a task
    /// up, put it where it belongs. Where it lands decides what changes — a
    /// scope heading changes its scope, a list heading files it — and the
    /// position is written down either way, so a drop is also a reorder.
    private func drop(_ ids: [String], into group: TodoGroup, at index: Int) -> Bool {
        dropTargetGroup = nil

        guard let id = ids.first,
              let item = items.first(where: { $0.id.uuidString == id && $0.kind == .todo })
        else { return false }

        Haptics.selection()
        withAnimation(Theme.Motion.snappy) {
            viewModel.move(
                item,
                toScope: group.scope,
                list: group.list,
                within: group.items,
                at: index
            )
        }
        return true
    }

    /// A header that is also the disclosure control for the finished list.    /// A header that is also the disclosure control for the finished list.
    ///
    /// It carries the count, so the answer to "did I do that already?" is often
    /// visible without opening it at all.
    private var completedHeader: some View {
        Button {
            toggleCollapsed(Self.finishedSectionID)
        } label: {
            HStack(spacing: 6) {
                SectionLabel("Finished today")
                Text(verbatim: "\(completedTodos.count)")
                    .font(Theme.Typography.micro())
                    .foregroundStyle(Theme.Colors.textFaint)
                collapseChevron(Self.finishedSectionID)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Theme.Metrics.screenPadding)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Finished today")
        .accessibilityValue("\(completedTodos.count)")
        .accessibilityHint(isCollapsed(Self.finishedSectionID) ? "Double tap to expand." : "Double tap to collapse.")
    }

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        SectionLabel(text)
            .padding(.leading, Theme.Metrics.screenPadding)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// The schedule's header, whose text is a resolved day name rather than a
    /// fixed phrase — so it goes through `SectionLabel(verbatim:)`.
    private func sectionHeader(verbatim text: String) -> some View {
        SectionLabel(verbatim: text)
            .padding(.leading, Theme.Metrics.screenPadding)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("A clear day")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(speech.isRecording ? "Listening… release when you're done." : "Hold the mic and say what's on your plate.")
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Image(systemName: "arrow.down.right")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.Colors.textFaint)
                .padding(.top, 8)

            if !speech.isRecording && !speech.transcript.isEmpty {
                Text("“\(speech.transcript)”")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Colors.textFaint)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
        .padding(.horizontal, Theme.Metrics.screenPadding)
    }

    // MARK: - Completion

    /// How long a filled circle waits before the completion is written. Long
    /// enough to see it happen and change your mind, short enough that clearing
    /// four to-dos isn't four seconds of waiting.
    private static let completionWindow: Double = 1.0

    /// The circle fills at once and the write lands a second later, so a second
    /// tap inside that second is a cancel rather than an un-tick: the circle
    /// empties, the row stays, and nothing was ever marked done.
    ///
    /// `defersWrite` is false where the row survives its own completion — there
    /// the fill and the write may as well be the same moment.
    private func tapCompletion(_ item: ScheduleItem, defersWrite: Bool, on day: Date) {
        if completing?.persistentModelID == item.persistentModelID {
            cancelCompletion()
            return
        }

        // Another row tapped mid-window: as far as the person is concerned that
        // one is done and they've moved on, so it lands now instead of being
        // dropped or fighting the new one for the timer.
        commitCompletion()

        guard defersWrite else {
            withAnimation(.easeInOut(duration: 0.25)) { viewModel.toggleDone(item, on: day) }
            return
        }

        Haptics.light()
        withAnimation(Theme.Motion.bouncy) { completing = item }
        completionTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.completionWindow))
            guard !Task.isCancelled else { return }
            commitCompletion()
        }
    }

    /// Writes the pending completion, if there is one. The row leaves on the next
    /// redraw, because a done to-do is no longer an active to-do.
    private func commitCompletion() {
        guard let item = completing else {
            clearPendingCompletion()
            return
        }
        clearPendingCompletion()
        Haptics.success()
        // Always today: the deferred path is the to-do list's, and the to-do
        // list doesn't page.
        withAnimation(.easeInOut(duration: 0.25)) { viewModel.toggleDone(item, on: today) }
    }

    /// The taken-back case. Unwinds with the same animation the fill used, so it
    /// reads as the circle emptying rather than as a redraw.
    private func cancelCompletion() {
        Haptics.selection()
        withAnimation(Theme.Motion.bouncy) { clearPendingCompletion() }
    }

    /// Drops the pending completion without writing it. Silent — callers that
    /// want the person to feel something add their own feedback.
    private func clearPendingCompletion() {
        completionTimer?.cancel()
        completionTimer = nil
        completing = nil
    }

    // MARK: - Actions

    /// Cancels first, because a removed item can't be read back to work out
    /// which notifications were its; a trimmed one re-schedules against its
    /// shortened series so nothing fires for a day that no longer exists.
    ///
    /// Deliberately *not* wrapped in `withAnimation`: animating the removal
    /// keeps the outgoing row on screen past the delete, and re-reading a
    /// deleted model's title is a SwiftData fault that takes the app with it.
    /// The list still settles smoothly — the rows animate on their own.
    private func performDelete(_ item: ScheduleItem, _ scope: ScheduleViewModel.DeletionScope, _ day: Date) {
        // Last line of defence for the pending completion: a timer that fires
        // after this would write a completion onto a deleted item, which is a
        // hard SwiftData fault rather than an error anyone gets to catch.
        if completing?.persistentModelID == item.persistentModelID {
            clearPendingCompletion()
        }
        NotificationService.cancel(for: item)
        // Lifted out *before* the delete. Deleting cascades to the links, so a
        // moment from now nothing will know where those events are — and an
        // event nobody can find is litter in somebody's calendar forever.
        let removals = CalendarSync.pendingRemovals(for: item)
        let outcome = viewModel.delete(item, scope: scope, on: day)
        if outcome == .trimmed {
            Task { await NotificationService.reschedule(for: item) }
        }
        if outcome == .removed, !removals.isEmpty {
            Task {
                let result = await CalendarSync.remove(removals)
                if let message = result.failureMessage { calendarError = message }
            }
        }
    }

    private var calendarErrorBinding: Binding<Bool> {
        Binding(get: { calendarError != nil }, set: { if !$0 { calendarError = nil } })
    }

    private var suggestionAlertBinding: Binding<Bool> {
        Binding(get: { pendingSuggestion != nil }, set: { if !$0 { pendingSuggestion = nil } })
    }

    /// The language waiting on an answer about server transcription, if any.
    private var pendingConsentLanguage: VoiceLanguage? {
        if case .needsServerConsent(let language) = speech.status { return language }
        return nil
    }

    private var serverConsentBinding: Binding<Bool> {
        Binding(
            get: { pendingConsentLanguage != nil },
            set: { if !$0 { speech.acknowledgeConsentPrompt() } }
        )
    }

    private func serverConsentMessage(for language: VoiceLanguage) -> String {
        String(
            format: String(localized: "This phone has no offline model for %@, so recordings in it would be sent to Apple to be transcribed. Nothing else about your schedule leaves the device."),
            language.displayName
        )
    }

    /// What the confirmation actually says. A planner recommendation's headline
    /// is just the task name, so the reason carries the explanation — the user
    /// should be confirming a decision they understand, not a bare title.
    private func confirmationText(for suggestion: ScheduleSuggestion) -> String {
        guard let reason = suggestion.reason else { return suggestion.message }
        return "“\(suggestion.message)” — \(reason)"
    }

    /// Applies a confirmed suggestion and keeps notifications in step.
    private func applySuggestion(_ suggestion: ScheduleSuggestion) {
        guard let action = suggestion.action else { return }
        withAnimation {
            if let changed = viewModel.apply(action, among: items) {
                Task { await NotificationService.reschedule(for: changed) }
            }
            viewModel.dismiss(suggestion)
        }
        pendingSuggestion = nil
    }

    /// Runs the parser over the current title and folds the first result back
    /// into the draft — natural language, surfaced as structured fields.
    private func parseTitle(into draft: CaptureDraft) {
        let text = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            guard let parsed = await viewModel.parseFirst(text, lists: listNames) else { return }
            await MainActor.run {
                draft.applyParsed(parsed)
                resolveSuggestedList(on: draft)
            }
        }
    }

    /// Save from the add/edit sheet — routes through a conflict check first.
    private func attemptSave(_ draft: CaptureDraft) {
        if let pending = viewModel.conflict(for: draft, among: items) {
            activeSheet = .conflict(pending)
        } else {
            commit(draft)
        }
    }

    // MARK: - Inline to-do capture

    /// Sizes the gap so it takes up whatever the rows leave behind.
    ///
    /// `gapTop - listTop` is the height of everything above the gap, and both
    /// markers move together when the list scrolls, so the difference is
    /// scroll-invariant. Subtracting it from the viewport is the space left.
    private func recomputeGap(
        top: CGFloat? = nil,
        gapTop newGapTop: CGFloat? = nil,
        viewportHeight: CGFloat
    ) {
        if let top { listTop = top }
        if let newGapTop { gapTop = newGapTop }
        let contentHeight = max(0, gapTop - listTop)
        gapHeight = max(ListMetrics.minimumGap, viewportHeight - contentHeight)
    }

    /// Tapping the empty space starts a to-do at the end of the list.
    /// The add affordance at the foot of every group.
    ///
    /// This is `nextTodoHint` — the dashed circle the gap under the list has
    /// always used — rather than anything new. It was already the app's mark for
    /// "the next, empty slot": same 22pt circle, same column, same stroke as a
    /// real completion circle, with the dashes carrying "not yet a thing". The
    /// only change is that every group gets one, because the gap only ever sat
    /// under the last of them.
    ///
    /// The circle stays non-hit-testing and the whole row is the target, for the
    /// same reason it is in the gap: the spot most likely to be tapped shouldn't
    /// be the one spot that doesn't respond.
    private func addRow(_ group: TodoGroup) -> some View {
        HStack(spacing: 0) {
            nextTodoHint
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { beginInlineTodo(in: group) }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityLabel(String(localized: "Add to \(group.title)"))
        .accessibilityHint("Double tap to start a new to-do.")
        .accessibilityAddTraits(.isButton)
    }

    /// Opens the editable row under `group`, expanding it if it was collapsed —
    /// typing into a section you can't see would be a strange place to land.
    private func beginInlineTodo(in group: TodoGroup) {
        if isCollapsed(group.id) { settings.setCollapsed(false, for: group.id) }
        withAnimation(Theme.Motion.snappy) {
            addingInGroup = group.id
            newTodoTitle = ""
        }
        newTodoFocused = true
    }

    /// The tap-under-the-list gap. Opens the row in the first group, which is
    /// where a to-do with no other home belongs.
    private func beginInlineTodo() {
        guard !isAddingTodo else {
            // Already open, keyboard dismissed — a second tap asks for it back
            // rather than doing nothing.
            newTodoFocused = true
            return
        }
        guard let first = todoGroups.first else { return }
        beginInlineTodo(in: first)
    }

    /// Return was pressed. Anything with text is saved through the same path the
    /// add sheet uses; an empty row is simply abandoned.
    private func commitInlineTodo() {
        let text = newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            endInlineTodo()
            return
        }
        let draft = CaptureDraft(kind: .todo)
        draft.title = text
        // The group it was typed under answers both questions the sheet would
        // otherwise have to ask: which list, and which scope.
        if let group = todoGroups.first(where: { $0.id == addingInGroup }) {
            draft.list = group.list
            if let scope = group.scope { draft.todoScope = scope }
        }
        // Deliberately `commit` and not `attemptSave`: the conflict check that
        // one runs first is guarded on `hasTime && hasDate`, both false for a
        // bare to-do, so it could never fire. This is the same makeItem →
        // insert → save → reschedule path the sheet takes; there is no second
        // way into the store.
        commit(draft)
        endInlineTodo()
    }

    /// Drops the in-progress row without saving.
    private func endInlineTodo() {
        addingInGroup = nil
        newTodoTitle = ""
        newTodoFocused = false
    }

    private func commit(_ draft: CaptureDraft) {
        let item: ScheduleItem
        if let existing = draft.editingItem {
            draft.apply(to: existing)
            viewModel.save()
            item = existing
        } else {
            item = draft.makeItem()
            viewModel.commit(item)
        }
        Task { await NotificationService.reschedule(for: item) }
        // The sheet's own answer, not the setting: it started as the setting,
        // and the person may have turned it off for this one item.
        syncToCalendars(item, targets: draft.effectiveCalendarTargets)
        activeSheet = nil
    }

    /// Send the item to whichever calendars are switched on.
    ///
    /// Fire-and-forget by design, exactly like the notification reschedule
    /// above it: the item is already saved and already on screen, and making
    /// the sheet wait on EventKit would put a spinner between the user and a
    /// capture that has, in every sense that matters to them, already worked.
    /// A failure comes back as an alert rather than as a delay.
    ///
    /// Nothing is written back to Settings. Turning a calendar off for one
    /// event is a statement about that event, not a new default.
    private func syncToCalendars(_ item: ScheduleItem, targets: Set<CalendarProvider>) {
        // Nothing wanted and nothing linked is nothing to do — and calling in
        // would still cost a plan and a save on the common path.
        guard !targets.isEmpty || !item.calendarLinks.isEmpty else { return }
        Task {
            let outcome = await CalendarSync.apply(targets, to: item, in: modelContext)
            if let message = outcome.failureMessage { calendarError = message }
        }
    }

    /// For the capture paths that have no sheet — voice, and an expanded goal.
    /// There is no switch to read, so they follow Settings exactly.
    private func syncToCalendars(_ item: ScheduleItem) {
        Task {
            let outcome = await CalendarSync.sync(item, isNew: true, in: modelContext)
            if let message = outcome.failureMessage { calendarError = message }
        }
    }

    /// Accept a suggested alternative slot and place the item there.
    private func applyAlternative(_ alt: AlternativeSlot, to draft: CaptureDraft) {
        draft.hasDate = true
        draft.date = calendar.startOfDay(for: alt.start)
        draft.hasTime = true
        draft.time = alt.start
        commit(draft)
    }

    // MARK: - Voice

    /// Starts a session nobody is holding a finger on.
    ///
    /// The in-app mic is press-and-hold, and the release is what ends it. A
    /// launch from the widget has no held finger, so this session ends the two
    /// other ways instead: the 15 seconds of silence the transcriber already
    /// watches for, or a tap on the mic — see `VoiceCaptureButton`.
    ///
    /// Nothing here asks for permission. If the mic or speech recognition
    /// hasn't been granted yet, `start()` surfaces the system prompt and the
    /// session simply doesn't begin, which is the honest outcome — a widget
    /// cannot grant permissions on the user's behalf.
    /// A widget launch arrives before the app is usable, so this waits.
    ///
    /// Measured on a cold launch from the mic widget: `.task` runs while the
    /// scene is still `inactive`, and *nothing* the recorder needs works in that
    /// state. iOS won't put the microphone or speech-recognition prompt on
    /// screen, so the request returns `denied` outright — permanently, since a
    /// denial is remembered — and `AVAudioSession.setActive` refuses for an app
    /// that isn't foreground. Both fail silently and both look the same from the
    /// outside: the widget opened the app and nothing happened.
    ///
    /// So the launch is held until activation instead. The wait is bounded by the
    /// same window `PendingRoute` uses, for the same reason: an app that ends up
    /// activating minutes later must not suddenly start listening.
    private func beginWidgetCapture() async {
        // Waits for the app to be genuinely foreground-active, then records.
        //
        // This used to note the request and wait for a `scenePhase` change to
        // arrive. That change is not guaranteed: a widget route re-roots the
        // navigation stack, so this view is rebuilt, and if the app finished
        // activating before the new instance existed the transition it was
        // waiting for had already happened. The session then never started —
        // which is what a lock-screen tap looked like, intermittently, even
        // once the route itself was arriving.
        //
        // `UIApplication.applicationState` is read live rather than captured,
        // so it cannot go stale the way the environment value did. The wait is
        // bounded by the same window `PendingRoute` uses: an app that only
        // reaches the foreground much later must not suddenly start listening.
        var waited: TimeInterval = 0
        while UIApplication.shared.applicationState != .active, waited < PendingRoute.window {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        guard UIApplication.shared.applicationState == .active else { return }
        await startHandsFreeCapture()
    }

    private func startHandsFreeCapture() async {
        guard !speech.isRecording else { return }
        isHandsFree = true
        await speech.start()

        // Coming from the lock screen, the scene reports `.active` a moment
        // before the app may actually take the microphone: `setActive` throws,
        // the engine is torn down without ever running, and the app opens
        // having silently done nothing — which is exactly what the mic widget
        // looked like from the lock screen. Confirmed in the device log, where
        // the widget launch showed `AVAudioEngine … stop, was running 0` while
        // a press-and-hold in the same process showed `was running 1`.
        //
        // So the first failure is treated as a race and asked again, briefly.
        // Only `startFailureIsRetryable` statuses qualify — a refused
        // permission is an answer, not a timing problem.
        var attemptsLeft = 8
        while !speech.isRecording, speech.startFailureIsRetryable, attemptsLeft > 0 {
            attemptsLeft -= 1
            try? await Task.sleep(for: .milliseconds(250))
            await speech.start()
        }

        // Permission refused, no recogniser for the language, audio in use by
        // something else: the session never began, so the button must not sit
        // there offering to stop a recording that isn't running.
        if !speech.isRecording { isHandsFree = false }
    }

    /// Interpret the finished transcript: a broad goal opens a plan to review, a
    /// list of things opens the per-item review. Either way, nothing commits yet.
    private func startVoiceReview(_ transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation { processingTranscript = text }
        Task {
            let interpretation = await viewModel.interpret(text, lists: listNames)
            await MainActor.run {
                withAnimation { processingTranscript = nil }
                switch interpretation {
                case .plan(let plan):
                    activeSheet = .planReview(PlanReview(plan: plan))
                case .items(let parsed):
                    guard !parsed.isEmpty else { return }
                    let review = VoiceReview(
                        transcript: text,
                        parsed: parsed,
                        defaultLeadMinutes: settings.defaultReminderLeadMinutes
                    )
                    // Resolved before the review is shown, so a filed to-do
                    // arrives already showing which list it's going into rather
                    // than moving after the user has looked at it.
                    review.items.forEach { resolveSuggestedList(on: $0.draft) }
                    activeSheet = .voiceReview(review)
                }
            }
        }
    }

    private func commitReview(_ review: VoiceReview) {
        for draft in review.keptDrafts {
            let item = draft.makeItem()
            viewModel.commit(item)
            Task { await NotificationService.reschedule(for: item) }
            // Spoken captures reach the calendar too, following Settings —
            // otherwise "automatically" would depend on which door the item
            // came through.
            syncToCalendars(item)
        }
        activeSheet = nil
    }

    // MARK: - Goal → plan

    /// Expand a goal and open it for review. Shared by the manual "Plan a goal"
    /// sheet and the "this is a goal" switch on the item-review screen.
    private func buildPlan(from goal: String) {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        activeSheet = nil
        withAnimation { processingTranscript = text }
        Task {
            let plan = await viewModel.planForGoal(text)
            await MainActor.run {
                withAnimation { processingTranscript = nil }
                activeSheet = .planReview(PlanReview(plan: plan))
            }
        }
    }

    /// The reverse switch: reinterpret a plan's source words as separate items.
    private func reviewPlanAsItems(_ review: PlanReview) {
        let text = review.sourceText
        activeSheet = nil
        withAnimation { processingTranscript = text }
        Task {
            let parsed = await viewModel.parseAll(text, lists: listNames)
            await MainActor.run {
                withAnimation { processingTranscript = nil }
                guard !parsed.isEmpty else { return }
                let review = VoiceReview(
                    transcript: text,
                    parsed: parsed,
                    defaultLeadMinutes: settings.defaultReminderLeadMinutes
                )
                review.items.forEach { resolveSuggestedList(on: $0.draft) }
                activeSheet = .voiceReview(review)
            }
        }
    }

    private func commitPlan(_ review: PlanReview) {
        for draft in review.keptDrafts {
            let item = draft.makeItem()
            viewModel.commit(item)
            Task { await NotificationService.reschedule(for: item) }
            syncToCalendars(item)
        }
        activeSheet = nil
    }
}

#Preview {
    NavigationStack {
        ScheduleView()
            .modelContainer(
                for: [ScheduleItem.self, Completion.self, TodoList.self, CalendarLink.self],
                inMemory: true
            )
            .environment(AuthController())
    }
}
