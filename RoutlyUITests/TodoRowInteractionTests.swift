//
//  TodoRowInteractionTests.swift
//  RoutlyUITests
//
//  A to-do row answers to two gestures, and they must not reach into each other:
//  a tap on the circle completes — after one second in which it can be taken
//  back — and a swipe from the trailing edge deletes, after a confirmation.
//
//  These are here rather than in the unit target because both questions are
//  about touch and timing, which no amount of view-model testing can ask: is the
//  row still on screen one frame after the tap, and is a second tap inside that
//  second read as a cancel rather than as an un-tick? The window is a second
//  long, which no human-paced tooling can hit reliably — XCUITest taps land
//  milliseconds apart, so it can.
//

import XCTest

final class TodoRowInteractionTests: XCTestCase {
    /// Comfortably longer than the row's own one-second window, so "after the
    /// window closed" is never a photo finish.
    private let afterWindow: TimeInterval = 2.5

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - Completion

    /// The fill is not the write. Immediately after the tap the row is still
    /// there — an instant write would already have removed it, because a done
    /// to-do is no longer an active to-do — and it leaves once the window shuts.
    func testTapCompletesOnlyAfterTheWindowCloses() throws {
        let title = uniqueTitle("Commit")
        addTodo(title)
        let row = row(titled: title)

        circle(in: row).tap()

        XCTAssertTrue(
            row.exists,
            "the completion was written on the tap itself — there was no window to cancel in"
        )
        XCTAssertTrue(
            waitForDisappearance(of: row),
            "the to-do never left, so the completion was never written"
        )
    }

    /// The cancel. Two taps milliseconds apart: the second one lands well inside
    /// the window, so nothing is written and the row stays exactly as it was.
    ///
    /// Both taps are delivered by coordinate, off a single resolution of the
    /// circle's frame. Asking the accessibility tree for the element a second
    /// time can take longer than the whole one-second window — this test failed
    /// that way once, and what it was measuring then was its own query speed,
    /// not the app. Coordinates make the interval between the taps the only
    /// thing that varies.
    func testSecondTapInsideTheWindowCancels() throws {
        let title = uniqueTitle("Cancel")
        addTodo(title)
        let row = row(titled: title)

        let checkbox = circle(in: row)
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5), "never found the circle to tap")
        let centre = checkbox.frame
        let tapPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: centre.midX, dy: centre.midY))

        tapPoint.tap()
        tapPoint.tap()

        // Long enough that a window which hadn't been cancelled would have
        // fired by now, twice over.
        Thread.sleep(forTimeInterval: afterWindow)

        XCTAssertTrue(row.exists, "the cancelled to-do disappeared anyway")
        XCTAssertEqual(
            circle(in: row).label,
            "Mark done",
            "the circle didn't empty — the row still reads as done or as mid-completion"
        )
    }

    // MARK: - Deletion

    /// The standard pattern, which to-dos are back on: swipe, then confirm. The
    /// confirmation matters as much as the swipe — a swipe that deleted outright
    /// is a different, worse interaction.
    func testSwipeDeletesAfterConfirming() throws {
        let title = uniqueTitle("Swipe")
        addTodo(title)
        let row = row(titled: title)

        row.swipeLeft()

        let deleteAction = app.buttons["Delete"].firstMatch
        XCTAssertTrue(
            deleteAction.waitForExistence(timeout: 3),
            "swiping a to-do revealed no Delete action"
        )
        deleteAction.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: 3),
            "the swipe deleted without asking"
        )
        // The row is still there, and that's load-bearing: the confirmation is
        // raised a turn of the loop after the swipe action's handler returns, so
        // the row closes first and is drawn normally underneath. Raising it from
        // inside the handler used to leave the row translated off the leading
        // edge — present in the list and the store, but invisible.
        XCTAssertTrue(row.exists, "the row went before the confirmation was answered")

        alert.buttons["Delete"].tap()
        XCTAssertTrue(waitForDisappearance(of: row), "confirming the delete didn't remove the row")
    }

    /// Backing out of the confirmation keeps the to-do, and — the part that used
    /// to be broken — leaves it *visible*. The row stayed translated off the
    /// leading edge after a cancelled swipe-delete, so a kept item looked exactly
    /// like a deleted one until the app was relaunched. No relaunch here on
    /// purpose: that would hide the very thing being checked.
    func testKeepingItLeavesTheRowUntouched() throws {
        let title = uniqueTitle("Keep")
        addTodo(title)
        let row = row(titled: title)

        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Keep it"].tap()

        Thread.sleep(forTimeInterval: afterWindow)

        XCTAssertTrue(row.exists, "the kept to-do is gone from the list")
        XCTAssertTrue(row.isHittable, "the kept to-do is in the list but not drawn")
        XCTAssertEqual(
            circle(in: row).label,
            "Mark done",
            "the swipe left the row part-completed"
        )
    }

    // MARK: - The two together

    /// The interference test, in both directions on one row: a swipe must not
    /// complete anything, and a tap must not reveal a delete.
    func testTheTwoGesturesStayOutOfEachOthersWay() throws {
        let title = uniqueTitle("Both")
        addTodo(title)
        let row = row(titled: title)

        // Swipe, then put it back. Nothing about the circle should have moved.
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].firstMatch.waitForExistence(timeout: 3))
        row.swipeRight()
        XCTAssertEqual(
            circle(in: row).label,
            "Mark done",
            "swiping the row started a completion"
        )

        // And the other way: a tap on the circle opens no delete affordance.
        // Tap, then cancel immediately, and only then ask about the delete
        // action — a query between the two taps can outlast the one-second
        // window, and then the row commits and leaves mid-test.
        let checkbox = circle(in: row)
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5), "never found the circle to tap")
        let centre = checkbox.frame
        let tapPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: centre.midX, dy: centre.midY))

        tapPoint.tap()
        tapPoint.tap()

        XCTAssertFalse(
            app.buttons["Delete"].firstMatch.exists,
            "tapping the circle revealed the delete action"
        )

        Thread.sleep(forTimeInterval: afterWindow)
        XCTAssertTrue(row.exists)
    }

    // MARK: - Reaching the row

    /// Unique per run: these tests add real rows to a real store, and a title
    /// left over from a previous run would otherwise be picked up as this one's.
    private func uniqueTitle(_ prefix: String) -> String {
        "\(prefix) \(UUID().uuidString.prefix(4))"
    }

    /// Adds a to-do through the add sheet. There's no test seam into the store,
    /// and this is the path a person takes anyway.
    private func addTodo(_ title: String) {
        app.buttons["To-do"].firstMatch.tap()

        let field = titleField()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the add sheet never showed a title field")
        focus(field)
        field.typeText(title)

        app.buttons["Add"].firstMatch.tap()

        XCTAssertTrue(
            row(titled: title).waitForExistence(timeout: 5),
            "“\(title)” was never added, so there's nothing to test against"
        )
    }

    /// Tapping a text field returns before the keyboard is up, and `typeText`
    /// into a field that hasn't taken focus yet throws rather than waiting for
    /// it — which shows up in the log as a failure inside whichever test was
    /// unlucky, reading like a product bug. So tap until the keyboard is
    /// actually there.
    private func focus(_ field: XCUIElement) {
        for _ in 0..<3 {
            field.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) { return }
        }
        XCTFail("the keyboard never came up for the title field")
    }

    /// `axis: .vertical` makes SwiftUI report the field as a text view on some
    /// releases and a text field on others, so take whichever one is there.
    private func titleField() -> XCUIElement {
        let textField = app.textFields.firstMatch
        return textField.exists ? textField : app.textViews.firstMatch
    }

    /// The row's spoken label leads with the title and then adds category,
    /// priority and scope, so the title is a prefix of it and not the whole.
    private func row(titled title: String) -> XCUIElement {
        app.cells
            .containing(NSPredicate(format: "label BEGINSWITH %@", title))
            .firstMatch
    }

    /// The checkbox, found by elimination. Not by its own label, because that's
    /// the thing under test — it becomes "Cancel marking done" mid-window, so
    /// querying by it would stop finding the button at exactly the wrong moment.
    /// And not simply the row's first button either: a swiped-open row also
    /// carries its Delete action, which must not be mistaken for the circle.
    private func circle(in row: XCUIElement) -> XCUIElement {
        row.buttons
            .matching(NSPredicate(format: "label != %@", "Delete"))
            .firstMatch
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }
}
