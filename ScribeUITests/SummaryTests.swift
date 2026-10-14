import XCTest

/// The automatic summary under the date line, folded into one "Summary" row (a DisclosureGroup) that a tap opens and
/// closes. "Budget Review" is seeded with a summary of five lines. Summary styles were tried and removed (FED-15): no
/// style anywhere, and a summary stored in a style is written again as the short one.
final class SummaryTests: ScribeUITestCase {
    /// The fake Gemma's summary (FakeTextWriter's "Summary:" line).
    static let fakeSummary = "The test checks the live transcript; new words show at once and provisional ones stay "
        + "lighter until final."

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

    /// With Gemma (`-fakeGemma`) nothing about summary styles shows: no disc right of the Stop (its hidden stand-in
    /// keeps the Stop centred), the summary is the short one, no style under it, no Styles for Tags in Settings.
    @MainActor
    func testNoStylesWithGemma() throws {
        let app = launch(["-fakeGemma", "-resetVoiceRecognition"])
        startRecording(app)
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["AddBookmark"].exists, "the bookmark left of the Stop")
        XCTAssertFalse(app.buttons["SummaryStyleControl"].exists, "no style disc")
        XCTAssertEqual(stop.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "the Stop stays centred")
        shot("Recording card", app)
        sleep(2)
        stop.tap()

        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 15), "the transcript")
        let summary = app.buttons["Summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60), "the summary")
        XCTAssertTrue(waitFor(timeout: 30) { (summary.value as? String) == Self.fakeSummary },
                      "the short summary: \(summary.value ?? "")")
        summary.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", Self.fakeSummary)).firstMatch
            .waitForExistence(timeout: 3), "open: the paragraph")
        XCTAssertFalse(app.buttons["SummaryStyle"].exists, "no style under it")
        shot("Summary open", app)
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5), "deleted")

        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Summaries"].firstMatch.tap()
        XCTAssertTrue(app.switches["Titles and Summaries"].waitForExistence(timeout: 5), "the Summaries page")
        XCTAssertFalse(app.buttons["StylesForTags"].exists, "no Styles for Tags")
    }

    /// A summary stored in a style while styles existed (`-seedOldStyledSummary`: Budget Review's Meeting lines, with
    /// Gemma's title) is written again as the short one by the launch sweep (`-fakeGemma`); the title stays.
    @MainActor
    func testStyledSummaryWrittenAgainAsBrief() throws {
        let app = launch(["-fakeGemma", "-seedOldStyledSummary"])
        open("Budget Review", in: app)
        let summary = app.buttons["Summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(timeout: 40) { (summary.value as? String) == Self.fakeSummary },
                      "written again as the short summary: \(summary.value ?? "")")
        XCTAssertTrue(app.staticTexts["PipelineStatus"].waitForNonExistence(timeout: 30), "and done")
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review", "the title stays")
        summary.tap()
        XCTAssertFalse(app.staticTexts["Decisions"].exists, "no style's heading")
        shot("Styled summary written again", app)
    }

    @MainActor
    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        return condition()
    }
}
