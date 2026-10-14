import XCTest

/// The automatic summary under the date line, folded into one "Summary" row (a DisclosureGroup) that a tap opens and
/// closes. "Budget Review" is seeded with a summary of five lines.
final class SummaryTests: ScribeUITestCase {
    static let summary = "Travel for the two customer workshops is over plan and licences are under, so part of the "
        + "licence budget moves to travel once finance agrees. The numbers go to finance by Friday, together with the "
        + "third-quarter forecast for the whole year."

    @MainActor
    func testSummaryFoldedUntilTapped() throws {
        let app = launch()
        // The list row reads "Budget Review, Yesterday at 9:41, 0:30, …" for VoiceOver: the "·" separators are hidden.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Budget Review'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("·"), "no separator in the row's label: \(row.label)")
        open("Budget Review", in: app)
        XCTAssertTrue(app.staticTexts["AI-generated content can contain mistakes."].exists,
                      "one note for everything generated, not only the summary")
        let summary = app.buttons["Summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "the summary is one row")
        XCTAssertEqual(summary.value as? String, Self.summary, "VoiceOver reads all of it, also while it is folded")
        XCTAssertGreaterThan(summary.frame.width, 300, "the whole width is the target")
        let text = app.staticTexts.matching(NSPredicate(format: "label == %@", Self.summary)).firstMatch
        XCTAssertFalse(text.exists, "folded: the text isn't shown")
        let firstName = app.buttons["SpeakerHeader.0"].frame.minY
        shot("Summary folded", app)

        summary.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 3), "a tap shows all of it")
        sleep(1)
        XCTAssertGreaterThan(app.buttons["SpeakerHeader.0"].frame.minY, firstName + 40, "the transcript moves down")
        shot("Summary open", app)

        summary.tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 3), "another tap folds it again")
    }
}
