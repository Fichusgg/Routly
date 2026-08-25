# iOS Routine & Schedule Organizer — App Development Prompt (v2)

Use this as a prompt to hand to an AI coding tool (Claude Code, etc.), a designer, or a dev team to kick off design and development.

---

## Prompt

You are an expert iOS product designer and engineer. Design an iPhone app that solves one specific problem: **most people already know what they should be doing — what fails them is a reliable, low-friction way to capture it, track it, and actually get nudged through it, day after day, without the tool itself becoming a chore.** This is not a feature-rich productivity suite. Its entire reason to exist is to become a seamless, dependable daily presence in someone's life.

### North Star — everything below serves these two things
1. **Seamless integration into how the person already lives.** Capturing and reviewing tasks must require near-zero deliberate effort, and must meet the person in moments that already exist in their day — walking to class, right after a meeting ends, putting the kids to bed — rather than requiring them to context-switch into "now I'm managing my schedule" mode. If using the app ever *feels* like using an app, that's a design failure.
2. **Consistent, dependable help — not just a good first week.** The value isn't a slick onboarding or a nice UI on day one; it's that the app is still meaningfully, correctly, helpfully present in week 12. It shows up at the right moments, adapts when life changes, never buries the person in stale clutter, and earns enough trust that they start relying on it the way they'd rely on a competent assistant — not something they have to remember to check.

If a proposed feature doesn't clearly serve one of these two things, cut it or deprioritize it. Favor doing a small number of things dependably over a large feature set that's impressive in a demo and abandoned in three weeks.

### Core Problem to Solve
Traditional calendar/task apps require the user to stop what they're doing, open the app, and manually type structured entries. That friction is why people stop using them within days. The app must remove that friction almost entirely, and — just as important — must keep proving its value every day so the person has a reason to keep it in their life past the novelty phase.

### Target Users
- **Students** juggling classes, assignments, and study routines
- **Working professionals** balancing meetings, deep work, and personal tasks
- **Parents** managing family logistics alongside their own schedule
- **Routine-builders**: people whose primary goal is establishing and sticking to daily habits and recurring routines, not just tracking one-off events

Design for the common thread: they want to *finish what they set out to do each day*, not just log it. Consistency of follow-through is the product, not the calendar itself.

### What "Seamless" and "Consistent" Actually Mean (concrete, not abstract)
Translate these two words into things you can literally build and test:
- **Seamless = capture works from wherever the person already is.** Lock screen, widget, voice, share sheet from any app — never "open this app first."
- **Seamless = the app interprets messy human input**, not the person adapting to the app's structure. "gym 3x this week" is a valid input, not an error state.
- **Consistent = the app initiates contact at well-timed moments**, not just waits to be opened. But "consistent" is not "frequent" — one well-placed nudge beats five ignorable ones.
- **Consistent = missed items are handled gracefully and automatically**, not left to pile up as guilt-inducing clutter the person has to manually clean up.
- **Consistent = the system remembers across weeks and months**, not just today — it should recognize "this always slips near month-end" or "routines hold on weekdays but fall apart on weekends," and adjust accordingly.
- **Trustworthy = the person always understands why the app did something.** Silent reorganization erodes trust fast; a short, plain-language reason ("You've moved this three times, so I nudged it to Thursday") builds it.

### Feature Requirements

**1. Frictionless Capture Layer**
- Natural-language input everywhere: type or speak a messy sentence ("remind me to call mom tomorrow evening" or "gym 3x this week") and the AI parses it into a structured item.
- Multiple low-friction entry points: home screen widget, lock screen widget, Siri/Shortcuts integration, Dynamic Island / Live Activity quick-add, Apple Watch complication, and a share-sheet extension so capture works from *any* app on the phone.
- Voice-first option for hands-busy moments (parents, commuters, gym).

**2. AI Intelligence Layer**
- Parses freeform captures into structured tasks/events (time, duration estimate, category, recurrence).
- Detects behavioral patterns (when things actually get done vs. when scheduled, which routines stick vs. get skipped, energy/focus patterns across the day and across weeks).
- Proactively suggests schedule adjustments, always with a plain-language reason attached.
- Auto-resolves conflicts and proposes placement for new items based on existing commitments and historical behavior.

**3. Onboarding That Builds a Living Profile**
- Conversational onboarding (chat or guided voice) that learns goals, existing routines, work/school schedule, energy patterns, and priorities — not just static form fields.
- Builds an initial personalized schedule from this conversation, which then keeps adapting as real usage data comes in. Onboarding is the *start* of the relationship, not a one-time setup step that's forgotten afterward.

**4. Consistency & Trust Layer (this is the core differentiator — build it deliberately, don't let it fall out of the other layers as an afterthought)**
- A daily rhythm of contact that's well-timed rather than frequent: e.g., one grounded morning surface of the day ahead, one light evening check-in — both adapting in frequency based on whether the person actually needs the nudge.
- Graceful handling of missed tasks: auto-reschedule with a visible, short reason rather than letting things pile into an overdue list that becomes something to feel bad about and ignore.
- Longitudinal pattern memory: recognize slow-forming patterns across weeks/months, not just day-to-day misses.
- Full transparency on AI-driven changes — the person should always be able to see "why did it do that" in one glance, and easily override it.

**5. Adaptive Scheduling Engine**
- Recurring routines are first-class citizens (not just repeating events): track adherence and streaks, and adjust routine timing/structure based on what's realistically working for that specific person.

**6. Review & Organize Layer**
- A lightweight daily/weekly view that surfaces what matters without requiring manual triage.
- Gentle, non-naggy check-ins that feed the learning loop rather than functioning as guilt trips.

### iOS-Specific Integration Points
This is an iPhone app, and it should behave like one, not like a web app in an iOS wrapper. Design explicitly around: Home/Lock Screen widgets, Siri & Shortcuts / App Intents, Live Activities/Dynamic Island, push notifications with actionable quick-replies, Apple Watch app/complications, and share-sheet/system-wide quick capture. Assume SwiftUI as the primary framework unless you have a strong reason to recommend otherwise.

### Visual Direction (Look & Feel)
This isn't a generic productivity-app look. Aim for:
- **Card-based modularity.** Every distinct unit — a day, a routine, a stat — lives in its own soft-cornered, gently shadowed card, not a flat list or plain table. Each card should feel like a self-contained object you could rearrange.
- **Bold, oversized section headers against quiet body text.** Day labels (e.g. "MONDAY") in heavy, condensed, near-shouting typography, contrasted against small, restrained text for the tasks underneath. The hierarchy should be legible at a glance, not read top to bottom.
- **Dark-mode-first, premium feel.** Default to a near-black theme with high-contrast white text and a single warm accent color (think fitness-tracker-app polish), not a sterile white productivity look. Light mode should still feel warm — soft gradients, not stark white and gray.
- **The lock-screen widget is the north star visual, not an afterthought.** It should look like translucent, glass-like cards sitting directly on the wallpaper — small day-by-day cards, each with a couple of checkable tasks, soft warm gradient background. This is the "seamless" principle made visible: the schedule lives on the lock screen itself, not behind an app icon.
- **Consistency visualized as a small dot-grid, not a report.** Borrow the idea of a compact monthly dot pattern (like a minified contribution graph) to show routine adherence over time at a glance. This is the visual expression of the Consistency & Trust Layer — the person should be able to *see* "did I actually keep this up" instantly, not dig through a stats screen for it.
- **Satisfying completion micro-interactions.** Strikethrough plus a color shift on checkbox completion, circular ring indicators for streaks or daily completion percentage — small, tactile, immediate feedback rather than static checkmarks.
- **Color system:** either soft, desaturated category colors for organizing by life area (work/personal/health), or a warm gradient theme as an alternate skin — both should read as calm and premium, never corporate-SaaS or clinical.

Treat this section as binding on Phase/deliverable 5 (UX/UI direction) below — it's not decoration, it's core to the "ambient, trustworthy presence" the North Star describes.

### AI/ML Approach
Recommend an architecture balancing on-device processing (for speed, privacy, and offline capture) with cloud-based LLM calls (for natural-language parsing and longer-horizon pattern analysis). Flag privacy trade-offs clearly — this app holds sensitive personal and family schedule data, and part of "trustworthy" is handling that data responsibly.

### Tone & Feel
Calm, competent, unobtrusive — like a good personal assistant, not a productivity app shouting streaks and gamification at the user. It should feel trustworthy enough that a busy parent or overwhelmed student is willing to hand it their mental load, and reliable enough that they still trust it in month three.

### What I Want From You
1. A clear product spec: core feature set for MVP vs. later phases, explicitly noting how each MVP feature serves seamless capture or consistent help (cut anything that doesn't).
2. Proposed information architecture and key user flows (capture flow, onboarding flow, the daily/evening consistency check-ins, daily review flow).
3. A recommended tech stack for iOS (frameworks, on-device vs. cloud AI split, backend needs).
4. A data model outline for tasks, routines, and the user's learned profile — including how longitudinal pattern data (weeks/months) gets stored and used, not just today's state.
5. Key UX/UI direction (not final visuals, but structure and interaction patterns) for the ambient capture experience and for how the app surfaces itself proactively without becoming naggy.
6. Any risks or open questions I should resolve before development starts.

---

### Notes for you (not part of the prompt above)
- I wrote this so it's tool-agnostic — you can paste it into Claude Code, another AI, or share it with a designer/developer.
- The v2 changes from the original: added an explicit North Star, a section grounding "seamless" and "consistent" in concrete, testable behaviors, and a dedicated Consistency & Trust Layer feature section — since that's the actual differentiator and it's easy for a builder to quietly drop it in favor of flashier features.
