//
//  CaptureRoutingTests.swift
//  RoutineOrganizerTests
//
//  Does "keep captures on this phone" actually keep them on the phone?
//
//  Asserting the preference persists proves nothing about where the words go —
//  the bug worth catching is a parse path that still reaches for the configured
//  cloud parser after the switch is off. So these drive the real entry points
//  on `ScheduleViewModel` with a stand-in parser that stamps its output, and
//  check whose answer came back.
//
//  Serialized, and each test restores what it found: `activeParser` reads the
//  shared `AppSettings`, so these tests genuinely touch global state and would
//  otherwise interfere with anything running beside them.
//

import Testing
import Foundation
@testable import Routly

/// Stands in for a configured cloud provider. Every route it answers is stamped,
/// so a result carrying the stamp is proof that route went "off the phone".
private struct StampedParser: AIParsingService {
    static let stamp = "SENT-TO-CLOUD"

    func parse(
        _ text: String,
        now: Date,
        workingHours: WorkingHours,
        lists: [String]
    ) async -> [ParsedCapture] {
        [ParsedCapture(title: Self.stamp, sourceText: text)]
    }

    /// Overridden deliberately. The protocol defaults `plan` to the offline
    /// template planner, so without this the goal path would look correctly
    /// routed no matter what it did.
    func plan(forGoal goal: String, now: Date) async -> ParsedPlan {
        ParsedPlan(
            goalTitle: Self.stamp,
            summary: Self.stamp,
            horizon: nil,
            items: [],
            sourceText: goal
        )
    }
}

@MainActor
@Suite("Capture routing", .serialized)
struct CaptureRoutingTests {

    /// Runs `body` with the cloud preference forced, then puts it back however
    /// the test exits.
    private func withCloudParsing(_ enabled: Bool, _ body: () async -> Void) async {
        let settings = AppSettings.shared
        let original = settings.cloudParsingEnabled
        settings.cloudParsingEnabled = enabled
        await body()
        settings.cloudParsingEnabled = original
    }

    @Test("captures go to the configured parser while sending is on")
    func onSendsToTheConfiguredParser() async {
        let viewModel = ScheduleViewModel(parser: StampedParser())
        await withCloudParsing(true) {
            let parsed = await viewModel.parseAll("gym tuesday at 7")
            #expect(parsed.first?.title == StampedParser.stamp)
        }
    }

    /// The main event. Same view model, same configured parser, switch off.
    @Test("turning it off keeps typed captures on the phone")
    func offKeepsCapturesLocal() async {
        let viewModel = ScheduleViewModel(parser: StampedParser())
        await withCloudParsing(false) {
            let parsed = await viewModel.parseAll("gym tuesday at 7")
            #expect(!parsed.isEmpty, "the offline parser should still produce an item")
            #expect(parsed.first?.title != StampedParser.stamp)
        }
    }

    /// The wand on the edit sheet is a second, easily-forgotten route to the
    /// same provider.
    @Test("the inline autofill route respects the switch")
    func autofillRespectsTheSwitch() async {
        let viewModel = ScheduleViewModel(parser: StampedParser())
        await withCloudParsing(false) {
            let parsed = await viewModel.parseFirst("call mum tomorrow evening")
            // Asserted before the comparison below, which a nil result would
            // otherwise satisfy without proving anything about routing.
            #expect(parsed != nil, "the offline parser should still produce an item")
            #expect(parsed?.title != StampedParser.stamp)
        }
    }

    /// And so is the voice path, which goes through `interpret` rather than
    /// `parse`.
    @Test("the voice route respects the switch")
    func voiceRespectsTheSwitch() async {
        let viewModel = ScheduleViewModel(parser: StampedParser())
        await withCloudParsing(false) {
            switch await viewModel.interpret("call mum tomorrow evening") {
            case .items(let items):
                // Non-empty first: an empty list would pass the comparison
                // below while proving nothing about where the words went.
                #expect(!items.isEmpty, "the offline parser should still produce an item")
                #expect(items.first?.title != StampedParser.stamp)
            case .plan(let plan):
                #expect(plan.goalTitle != StampedParser.stamp)
            }
        }
    }

    /// "Plan a goal" sends the goal text to the provider like any other
    /// capture. Leaving this route cloud-bound would have made the switch
    /// quietly untrue for a whole flow.
    @Test("the plan-a-goal route respects the switch")
    func goalPlanningRespectsTheSwitch() async {
        let viewModel = ScheduleViewModel(parser: StampedParser())
        await withCloudParsing(false) {
            let plan = await viewModel.planForGoal("get fit this quarter")
            #expect(plan.goalTitle != StampedParser.stamp)
        }
    }

    @Test("the plan-a-goal route uses the provider while sending is on")
    func goalPlanningUsesTheProviderWhenOn() async {
        let viewModel = ScheduleViewModel(parser: StampedParser())
        await withCloudParsing(true) {
            let plan = await viewModel.planForGoal("get fit this quarter")
            #expect(plan.goalTitle == StampedParser.stamp)
        }
    }
}
