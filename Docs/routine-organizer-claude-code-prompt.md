# Claude Code Build Prompt — Routine & Schedule Organizer (iOS)

Paste this as your opening message to Claude Code in a fresh project folder. It's written as instructions to an engineer, with phased scope so Claude Code builds incrementally instead of trying to do everything at once.

---

## Prompt

You are building the first working version of an iOS app. Read the full brief below, then propose a phased implementation plan before writing code, and confirm the plan with me before starting Phase 1.

### What We're Building
An iPhone routine and schedule organizer whose core differentiator is **near-zero-friction capture** plus **consistent, dependable daily help** — not just a nice UI on day one, but an app still meaningfully useful in week 12. The target users are students, working professionals, and parents who want to actually *finish* their daily tasks and routines, not just log them. Full product context is in the attached brief (`routine-organizer-app-prompt.md` — I'll paste it in next, or you can ask me for it).

**Success bar for every phase below:** before marking any phase "done," check it against two questions — (1) did this reduce friction in how the item got captured or reviewed, and (2) does this make the app more likely to still be genuinely useful to the person a month from now, not just on day one? If a phase's output doesn't clearly serve one of those two things, flag it to me rather than building it as scoped.

### Constraints & Stack
- **Platform:** iOS 17+, SwiftUI, Swift 5.9+.
- **Architecture:** MVVM, with a clear separation between the UI layer, a `ScheduleEngine`/`AIParsingService` layer, and persistence.
- **Persistence:** SwiftData (native, avoids Core Data boilerplate) unless you have a strong reason to prefer Core Data — tell me why if so.
- **AI parsing:** Build the `AIParsingService` behind a protocol from day one, with a mock/stub implementation that does simple rule-based parsing (e.g. regex/keyword extraction for dates, times, recurrence). This lets the app run and be testable without a live API key. Wire in a real LLM call (Anthropic API) as a later phase, behind the same protocol.
- **Reality check:** you can generate and edit all Swift files and the project structure, but I'll need Xcode on a Mac to actually build, run in the simulator, and test on a device. Set the project up so it opens cleanly in Xcode (standard `.xcodeproj` or Swift Package structure — tell me which you recommend and why).
- **Tests:** Write unit tests for the parsing/scheduling logic as you build it, not just at the end.
- **Visual direction:** Follow the "Visual Direction (Look & Feel)" section in `docs/routine-organizer-app-prompt.md` from Phase 1 onward — dark-mode-first, bold oversized day headers, card-based modularity, warm accent color, dot-grid streak visualization. Don't default to standard iOS list/form styling and leave the "real" design for a later polish pass; build the visual language in from the first screen.

### Phased Scope

**Phase 0 — Project Setup**
- Scaffold the Xcode project, folder structure, and SwiftData models for `RoutineItem`/`TaskItem` (title, time, duration estimate, recurrence rule, category, completion state, source-of-truth notes).
- Set up the MVVM skeleton and the `AIParsingService` protocol + stub implementation.
- Confirm the project builds and runs on the simulator before moving on.

**Phase 1 — Core Capture & Schedule View (MVP)**
- A single-screen quick-capture entry point (text field) that runs input through the stub `AIParsingService` and creates a structured item.
- A basic daily/weekly schedule view showing captured items.
- Manual edit/complete/delete on items, so the app is usable end-to-end even before any real AI or widgets exist.

**Phase 2 — Real AI Parsing**
- Swap the stub for a real call to the Anthropic API to parse freeform natural-language input into structured items (date, time, duration, recurrence, category).
- Handle ambiguous input gracefully (ask a clarifying follow-up rather than guessing silently).

**Phase 3 — Ambient Capture Surfaces**
- Home screen widget for quick-add.
- Siri Shortcuts / App Intents integration for voice capture.
- Share-sheet extension so text can be captured from any app.

**Phase 4 — Consistency & Trust Layer (don't skip or fold this into Phase 3/5 as an afterthought — it's the core differentiator)**
- Well-timed proactive surfaces (e.g., one morning day-ahead surface, one light evening check-in) instead of frequent, ignorable notifications.
- Graceful auto-rescheduling of missed items, always with a short, visible reason shown to the user — never a silent change and never a guilt-inducing overdue pile.
- Track completion vs. scheduled time to detect patterns (recurring tasks that consistently get pushed or skipped, weekday-vs-weekend adherence, month-end drop-off, etc.).
- Simple rule-based suggestions first (e.g., "you've moved this 3 times — reschedule permanently?") before anything more sophisticated — but every suggestion must show its reasoning.

**Phase 5 — Longer-Horizon Adaptive Layer**
- Extend pattern detection across weeks/months, not just recent days.
- More sophisticated scheduling suggestions once the rule-based version from Phase 4 is proven out.

**Phase 6 — Onboarding**
- Build the conversational onboarding flow that gathers goals/routines and generates an initial schedule, once the underlying data model and scheduling logic are proven out in Phases 1–4.

### How I Want You to Work
- Propose the Phase 0/1 plan and folder structure first — don't start writing large amounts of code until I confirm.
- After each phase, stop, summarize what was built, and let me test it before moving to the next phase.
- Flag any architectural decision with real trade-offs (e.g., SwiftData vs. Core Data, on-device vs. cloud parsing) instead of silently picking one.
- Ask me clarifying questions if requirements are ambiguous rather than guessing on things that are expensive to change later (data model shape, especially).

---

### Notes for you (not part of the prompt above)
- Paste in the earlier product brief (`routine-organizer-app-prompt.md`) alongside this one, or just reference it — Claude Code will likely ask for the fuller context anyway.
- If you already have a repo/Xcode project started, mention that up front so it doesn't try to scaffold a new one.
- Given Claude Code needs a Mac with Xcode to actually build and run iOS projects, make sure you're running it in that environment.
