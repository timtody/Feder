import XCTest

/// Gemma's smart corrections await the user's review in a box under the tags (CorrectionReview): one row per change
/// with a checkmark, "Apply All" and "Dismiss". On the simulator `-fakeCorrections` stands in for Gemma with a made-up
/// proposal: "quick" → "brief", "lighter" → "fainter" and a period (three turns from FakeDiarizer's 4 s speakers in a
/// 10 s recording). Corrections never move words to another speaker.
final class CorrectionReviewTests: ScribeUITestCase {
    @MainActor
    func testAcceptOneThenApplyAll() throws {
        let app = launch(["-autoRecord", "-autoStopAfter", "10", "-fakeCorrections"])
        let applyAll = app.buttons["Apply All"]
        XCTAssertTrue(applyAll.waitForExistence(timeout: 60), "the review box once the background pass has run")
        assertCard(app)
        let accept = app.descendants(matching: .any).matching(identifier: "Accept correction")
        let before = accept.count
        XCTAssertGreaterThanOrEqual(before, 2, "several suggested changes")
        shot("Corrections to review", app)

        accept.firstMatch.tap()                                  // one change taken over
        XCTAssertTrue(waitFor { accept.count == before - 1 }, "the accepted row is gone")
        let firstParagraph = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Okay'")).firstMatch
        XCTAssertTrue(firstParagraph.exists)
        XCTAssertTrue(firstParagraph.label.contains("brief"), "the first change is in the transcript: \(firstParagraph.label)")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'moved'")).firstMatch.exists,
                       "no word moves to another speaker")

        applyAll.tap()
        XCTAssertTrue(applyAll.waitForNonExistence(timeout: 5), "the review ends with Apply All")
        shot("Corrections applied", app)
    }

    @MainActor
    func testDismiss() throws {
        let app = launch(["-autoRecord", "-autoStopAfter", "6", "-fakeCorrections"])
        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 60), "the review box")
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5), "dismissed: the transcript stays as it was")
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.1))
        }
        return condition()
    }
}
