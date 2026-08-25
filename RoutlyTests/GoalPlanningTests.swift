//
//  GoalPlanningTests.swift
//  RoutineOrganizerTests
//
//  The goal-to-plan routing and the template planner are pure and offline, so
//  they're pinned down here: goals must be told apart from lists of errands, and
//  a goal must expand into a small, sane plan rather than one vague to-do.
//

import Testing
import Foundation
@testable import Routly

struct GoalDetectionTests {
    @Test func aspirationsReadAsGoals() {
        #expect(GoalDetector.looksLikeGoal("I want to get back into shape"))
        #expect(GoalDetector.looksLikeGoal("I want to launch my startup this quarter"))
        #expect(GoalDetector.looksLikeGoal("I'd like to learn Spanish"))
        #expect(GoalDetector.looksLikeGoal("get in shape"))
    }

    @Test func listsOfErrandsDoNotReadAsGoals() {
        #expect(!GoalDetector.looksLikeGoal("call mom at 6, pick up dry cleaning, gym three times this week"))
        #expect(!GoalDetector.looksLikeGoal("buy milk and call the dentist"))
        #expect(!GoalDetector.looksLikeGoal("remind me to email Sam tomorrow"))
    }

    @Test func trivialInputIsNotAGoal() {
        #expect(!GoalDetector.looksLikeGoal(""))
        #expect(!GoalDetector.looksLikeGoal("hi"))
    }
}

struct PlanTemplateTests {
    private let now = Date()

    @Test func fitnessGoalExpandsToASmallHealthPlan() {
        let plan = PlanTemplates.plan(for: "I want to get back into shape", now: now)
        #expect(plan.goalTitle == "Get back into shape")
        #expect(!plan.items.isEmpty)
        #expect(plan.items.count <= PlanTemplates.maxItems)
        #expect(plan.items.contains { $0.category == .health })
        #expect(plan.items.contains { $0.recurrence != nil })
    }

    @Test func planIsNeverOverwhelming() {
        for goal in ["learn to code", "launch my business", "save more money", "I want to sleep better", "become a better writer"] {
            let plan = PlanTemplates.plan(for: goal, now: now)
            #expect(plan.items.count >= 1)
            #expect(plan.items.count <= PlanTemplates.maxItems)
        }
    }

    @Test func statedHorizonIsCaptured() {
        let plan = PlanTemplates.plan(for: "learn Spanish this quarter", now: now)
        #expect(plan.horizon == .thisQuarter)
    }

    @Test func goalTitleStripsLeadingIntent() {
        #expect(PlanTemplates.cleanGoalTitle("I want to run a marathon") == "Run a marathon")
        #expect(PlanTemplates.cleanGoalTitle("my goal is to read more") == "Read more")
    }

    @Test func planItemsCarryTheGoalAsSource() {
        let plan = PlanTemplates.plan(for: "launch my side project", now: now)
        #expect(plan.items.allSatisfy { $0.sourceText == "launch my side project" })
    }
}

struct InterpretRoutingTests {
    @Test func stubRoutesGoalsToPlansAndListsToItems() async {
        let stub = StubAIParsingService()

        let goal = await stub.interpret("I want to get back into shape")
        if case .plan(let plan) = goal {
            #expect(!plan.items.isEmpty)
        } else {
            Issue.record("Expected a goal to interpret as a plan")
        }

        let list = await stub.interpret("buy milk and call the dentist")
        if case .items = list {
            // expected
        } else {
            Issue.record("Expected a list of errands to interpret as items")
        }
    }
}
