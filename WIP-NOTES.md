# Shelved work — what's in `stash@{0}`, and what it was for

Reverted to `cbb3eac` on 11 Aug 2026. **Nothing was deleted.** Everything below is in
`stash@{0}` ("WIP: working-hours, 3 UX bug fixes, device-log perf fixes"), 30 modified
files + 7 untracked paths, ~4,361 insertions.

```bash
git stash list          # confirm it's there
git stash show -p stash@{0} > /tmp/wip.patch   # read it without applying
git stash apply stash@{0}                      # restore everything (keeps the stash)
git checkout stash@{0} -- <path>               # restore one file
```

Use `apply`, not `pop`, until you're sure — `pop` drops the stash on success.

> Note: `stash@{1}` is older and unrelated (the rejected hint system). Don't confuse them.

---

## Read this first — the stash is suspected of CAUSING the device bugs

**`cbb3eac` runs perfectly on the iPhone 16** (confirmed on device, 11 Aug 2026). That single
fact reframes everything below, because HEAD already contains the things the bugs were blamed
on. Verified by grep against HEAD:

| Previously blamed | Present in HEAD? | So it can't be the cause |
|---|---|---|
| Main-thread plist I/O (finding B) | **Yes** — same `NSDictionary(contentsOf:)` per lookup, same 5 reads per `make()` | works fine |
| Agenda-as-landing on the slow sweep (bug 2) | **Yes** — `CalendarMode.landing = .agenda`, un-optimized `sections()` | calendar opens fine |
| Speech rotation / `RequestHolder` / `finishContinuation` | **Yes** — same architecture | recording fine |
| Processing overlay (bug 3) | **Yes** — `processingOverlay`, `processingTranscript` | no freeze |
| Groq via `OpenAICompatibleParsingService` | **Yes** — identical factory | parsing fine |

**Conclusion: the three device bugs were almost certainly introduced by the uncommitted work
in this stash, not fixed by it.** The "fixes" in §4 were written against symptoms that the
rest of the same uncommitted pile had created. That also explains why the device log showed
findings (watchdog kill, speech hangs) that had nothing to do with any of the three fixes —
it was a log of a broken build, not of HEAD.

The delta that actually shipped the bugs is in here somewhere: **+254 lines in
`SpeechTranscriber`, +122 in `ScheduleView`**, plus working-hours, `OccurrencePlan`, and
completion-integrity.

### What this means for re-applying

**Do not `git stash apply` wholesale.** Restore one group at a time and run it on the device
after each. Prime suspects first, in this order:

1. §1 working hours — it changes the `AIParsingService.parse` protocol signature and adds a
   `@MainActor syncPreferences(for:)` on every suggestion pass. Widest blast radius.
2. §3 `OccurrencePlan` — a sweep rewrite whose `day` argument **must** be start-of-day, with
   silent wrong answers if it isn't.
3. §2 completion integrity — `CompletionHold` runs timers against rows that are being removed.
4. §4–6 the fixes themselves.
5. §7 last, and only if the watchdog kill actually reproduces on a build you trust.

Corollary worth keeping: **§4's three "fixes" may be unnecessary at HEAD.** Don't re-apply
them just because they exist — reproduce each bug on HEAD first, and if it doesn't reproduce,
drop the fix.

**Verification status of the shelved work:** the suite passed **218/218** at the end of the
first fix session. The later device-log fixes (§4) were **never executed** — three
consecutive runs died in CoreSimulator with three different errors (`never began executing`,
`DTXProxyChannel error 1`, `Mach error -308 server died`). They compile; they are not
test-verified. Re-run before trusting them.

---

## 1. Working hours *(predates the bug-fix sessions)*

One planning window that the parser, conflict detector, suggestion engine and day planner
all share, instead of each guessing.

- **New:** `Models/WorkingHours.swift`, `RoutineOrganizerTests/WorkingHoursTests.swift`
- **Changed:** `AppSettings`, `SettingsView`, `ParsingContract.systemPrompt(now:workingHours:)`,
  `AIParsingService.parse(_:now:workingHours:)` (protocol signature), `ConflictDetector`,
  `SuggestionEngine`, `DayPlanner`, `ScheduleViewModel.syncPreferences(for:)`
- **Why it's threaded rather than read from settings:** the services are `Sendable` and run
  off the main actor; `AppSettings` is main-actor isolated. Passing a value avoids a hop and
  can't go stale the way a snapshot taken at init would.

## 2. Completion integrity *(predates the bug-fix sessions)*

- **New:** `ViewModels/CompletionHold.swift` — the 1-second cancellable window so a second
  tap on a to-do is a *cancel*, not an un-tick. Lives outside the row because completing a
  to-do removes that row, and a view on its way out can't finish anything.
- **New:** `RoutineOrganizerTests/CompletionIntegrityTests.swift`
- **Changed:** `ScheduleViewModel.setDone` as the single writer (at most one record per
  occurrence), `ConsistencyEngine`, `ConsistencyView`, `ConsistencyEngineTests`

## 3. Transport safety + `OccurrencePlan` *(predates the bug-fix sessions)*

- `AnthropicConfig.isTransportSafe` — the OpenAI-compatible base URL must be `https`, or
  `http` on loopback only. A rejected URL leaves `isConfigured` false and falls back offline.
- `ScheduleEngine.OccurrencePlan` + `occurs(_:onNormalized:weekday:)` — resolves each item's
  recurrence invariants once so day sweeps stop re-deriving them per call. **Its `day` must
  already be start-of-day**, or DST-at-midnight zones silently stop matching.
- Also: `RecurrenceRule`, `StubAIParsingService`, `OptimizeDayView`, localization catalog.

## 4. The three UX bug fixes *(sessions 1–2)*

| Bug | Fix | Files |
|---|---|---|
| Recording hangs | Cap at 3 consecutive failed segments, then end and still deliver what was heard | `SpeechTranscriber` |
| ” | Bound the wait on an in-flight `start()` to 3s | `VoiceCaptureButton` |
| ” | `timeoutTask` held + `weak self` so it stops pinning the recorder for 5s after every recording | `SpeechTranscriber` |
| ” | `removeTap` unconditionally — a failed `start()` left a tap installed, and the next start's second tap on bus 0 is an uncatchable ObjC exception | `SpeechTranscriber` |
| Calendar | `ScheduleViewModel.daySummaries(for:from:)` — one pass replacing 84 sweeps + 42 sorts per redraw | `ScheduleViewModel`, `MonthGridView` |
| Freeze | `captureFailure` alert — a capture that parsed to nothing now says so and hands the words back | `ScheduleView` |

## 5. Parsing timeout *(session 3)*

- **New:** `Services/ParsingTransport.swift`, `RoutineOrganizerTests/ParsingTransportTests.swift`
- The bug: `request.timeoutInterval = 30` is a *stall* timer that every received byte resets,
  and `URLSession.shared` left `timeoutIntervalForResource` at its **7-day** default. A
  trickling connection was unbounded, behind a modal overlay.
- The fix: dedicated session with both ceilings, plus `withParsingDeadline` racing the call
  and cancelling the loser — a backstop that doesn't depend on URLSession honouring anything.
- Wired into both parsing services. **4 tests, all passing at the time.**

## 6. Speech stop-path + overlay escape *(session 3)*

- `didDeliverItself` — the silence watchdog and the give-up path handed the transcript to
  `onSilenceTimeout`, then the user's release handed the *same words* over again: two parses,
  two review sheets.
- `stopRequestedDuringStart` — releasing during the permission sheets left an **unstoppable**
  recording: `stop()` ran while status was still `.idle`, took its early return, and the
  recorder then went `.recording` with nobody holding the button.
- `ScheduleView`: "Stop waiting" escape from the processing overlay, `processingTask`
  cancellation, `CaptureFailure.emptyResult` / `.abandoned`.
- Agenda sweep moved onto `OccurrencePlan` and bound once per body (it was running twice).

## 7. Device-log fixes *(session 4 — COMPILES, NOT TEST-VERIFIED)*

Three findings from a real iPhone 16 / iOS 26 log capture.

**B — synchronous main-thread file I/O.** `AnthropicConfig` did `NSDictionary(contentsOf:)`
per lookup; `ParsingServiceFactory.make()` does five lookups; `make()` is the default arg of
`ScheduleViewModel.init`, which is a `@State` initial value. `State.init(wrappedValue:)` is
**eager, not an autoclosure**, and `NavigationLink { CalendarView() }` rebuilds it on every
`ScheduleView.body`. Result: five file reads per body evaluation. Fixed with a `static let`
cache + `preload()`, `ParsingServiceFactory.shared`, and an app-init warm-up.

**A — 0x8BADF00D watchdog kill on backgrounding.** The app had **no scene-phase handling at
all**, so a live recording ran into the background and `AVAudioSession.setActive(false)` — an
unbounded XPC round trip — sat on the main actor inside the 5-second deactivate budget. Fixed
with an `AudioPlant` actor, non-blocking teardown, and `abandon()` called from
`.onChange(of: scenePhase)`.

**C — 0.41s / 0.27s speech hangs.** `SFSpeechRecognizer(locale:)` and
`supportsOnDeviceRecognition` ran on main, and the latter was re-read **per segment** — i.e.
after every pause in a capture. Fixed by building on a detached task and caching the answer.

- **New:** `RoutineOrganizerTests/MainThreadIOTests.swift`

### Two judgement calls in §7 worth revisiting before re-applying

1. **`abandon()` drops the capture.** Backgrounding mid-recording no longer parses what it
   heard — `stop()` waits up to 5s for the recognizer's tail, which is exactly the watchdog's
   budget. The transcript survives in `speech.transcript`, but this is a behaviour change.
2. **SwiftData's save path was deliberately left alone**, despite the finding-A brief asking
   for an audit. Every mutation already saves synchronously as it happens, so there are
   normally no pending changes at background time; moving `mainContext` off the main actor
   needs a `ModelActor` and a second context.

---

## Suggested order if re-applying piecemeal

1–3 first (they're the base other things build on and the protocol signature change in §1
touches every parsing service), then 4, then 5–6, then 7 last since it's the least verified.

## Still open, unrelated to any of this

`OpenAICompatibleParsingService` never overrides `plan(forGoal:)`, so on Groq
(`llama-3.3-70b-versatile`, the live provider) "Turn a goal into a plan" silently uses the
offline template planner. Only the dead Anthropic path has an LLM planner.

---

## Parked: a to-do can't hold a time, so vague-time captures lose it

**Deliberately off the bisect chain.** Found during the Step 2 device gate, 11 Aug 2026.
Recorded, not acted on.

**Symptom.** "gym Tuesday afternoon" saves as a to-do dated Tuesday with no hour, rather
than a timed afternoon item.

**Mechanism.** `ItemKind.todo.usesTime == false`, and `CaptureDraft.swift:93` reads:

```swift
hasTime = kind.usesTime && parsed.startTime != nil
```

So a parsed `startTime` on a to-do is **discarded at the draft boundary, whatever the
parser returned**. The voice path goes straight through this — `VoiceReview` builds
`CaptureDraft(parsed:kind: parsed.kind)`. `applyParsed` has the same guard.

The telling detail: the *offline stub* maps `"afternoon" → 14:00` explicitly
(`StubAIParsingService`, the time-word table). So even with no network the parser produces
14:00 for that phrase and the draft still drops it. Nothing downstream would have kept a
time, so the observation tells us nothing about whether Groq returned one.

**Predates `cbb3eac`.** Not introduced by working-hours step 1 or 2, and step 3 does not
change it. The only route by which a to-do ever gets a `startTime` is the planner's
`scheduleTodoAt` action ("Optimize my day") — and that works on *today*, so a
Tuesday-dated to-do isn't offered a slot until Tuesday, by which point the word
"afternoon" is long gone and the planner just picks any free in-window gap.

**Two possible fixes, both product decisions:**

1. **Let to-dos carry a time.** Flip `usesTime` for `.todo`, or add an explicit
   slotted-to-do concept at capture. The data model already supports it —
   `ScheduleViewModel.isSlottedToday` exists precisely to render a to-do that has a
   `startTime`, and `todayTimed` shows it. So this is a capture-path restriction, not a
   model one. Risk: the add sheet grows a time picker for to-dos, which was likely
   omitted on purpose.
2. **Steer classification.** Push the model toward `.reminder` or `.event` for phrases
   that name a part of the day, since both have `usesTime == true`. Cheaper (prompt only)
   but less reliable, and it makes "gym" an event rather than a task, which may not be
   what the user means.

For reference, the three kinds: `.event` (timed, has a span, time-blocked), `.reminder`
(point-in-time nudge, dated and timed, no block), `.todo` (rolling checklist, optional
day, no time). Placement on Today: `todayTimed` takes everything that isn't a to-do, plus
to-dos holding a `startTime` today; `activeTodos` takes the rest.

---

*This file is untracked scratch — delete it whenever.*
