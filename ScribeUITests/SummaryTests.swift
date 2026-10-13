import XCTest

/// The automatic summary under the date line, folded into one "Summary" row (a DisclosureGroup) that a tap opens and
/// closes. "Budget Review" is seeded with a summary of five lines. Its styles (FED-15): the menu under the open summary,
/// the disc while recording, Styles for Tags, and none of it without Gemma.
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
        XCTAssertFalse(app.buttons["SummaryStyle"].exists, "no styles without Gemma")
    }

    // MARK: Summary styles (FED-15)

    /// Budget Review's summary in the Meeting style (`-seedStyledSummary`, marked described, so `-fakeGemma`'s sweep
    /// leaves it): headings and bullets in the open row, its style in the menu under it. Choosing Bullet Points writes
    /// it again (the fake Gemma's Budget Review answer after 3 s): the old text stays meanwhile and the menu's place
    /// says "Writing summary…", the row stays open, the title stays. The choice is kept with the transcript; Brief
    /// brings a paragraph back.
    @MainActor
    func testStyleRewritesSummary() throws {
        let app = launch(["-fakeGemma", "-seedStyledSummary", "-interactionTrace"])   // the "style" press's log line
        open("Budget Review", in: app)
        let summary = app.buttons["Summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue((summary.value as? String ?? "").hasPrefix("Decisions\n• Part of the licence budget"),
                      "the Meeting summary: \(summary.value ?? "")")
        summary.tap()
        let picker = styleMenu(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "the style under the open summary")
        XCTAssertTrue(app.staticTexts["To-dos"].exists, "Meeting's headings")
        XCTAssertTrue(app.staticTexts["Anna Schmidt sends the numbers to finance by Friday."].exists, "a bullet's text")
        XCTAssertTrue((picker.value as? String) == "Meeting",
                      "Meeting chosen: \(picker.label) \(picker.value ?? "")")
        shot("Meeting summary", app)

        choose("Bullet Points", in: picker, app)
        XCTAssertTrue(app.staticTexts["SummaryRewriting"].waitForExistence(timeout: 2), "Writing summary… in its place")
        XCTAssertTrue(app.staticTexts["To-dos"].exists, "the old text stays meanwhile")
        shot("Rewriting", app)
        XCTAssertTrue(waitFor(timeout: 15) { (summary.value as? String ?? "").hasPrefix("• Travel is over plan") },
                      "written as bullet points: \(summary.value ?? "")")
        XCTAssertTrue(app.staticTexts["SummaryRewriting"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "the row stays open")
        XCTAssertFalse(app.staticTexts["To-dos"].exists, "no headings any more")
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review", "the title stays")
        shot("Bullet points summary", app)

        closeCard(app)
        open("Budget Review", in: app)
        summary.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue((picker.value as? String) == "Bullet Points",
                      "the choice is kept: \(picker.label) \(picker.value ?? "")")

        choose("Brief", in: picker, app)
        XCTAssertTrue(waitFor(timeout: 15) {
            let value = summary.value as? String ?? ""
            return !value.isEmpty && !value.contains("•") && !value.contains("\n")
        }, "a paragraph again: \(summary.value ?? "")")
    }

    /// A rewrite stopped by leaving the app (iOS takes the GPU away: BetterSummaries cancels Gemma's request) keeps
    /// the old summary and says it isn't finished, also with the card still open; Try Again writes it.
    @MainActor
    func testStoppedRewriteSaysNotFinished() throws {
        let app = launch(["-fakeGemma", "-seedStyledSummary"])
        open("Budget Review", in: app)
        let summary = app.buttons["Summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        let picker = styleMenu(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        choose("Interview", in: picker, app)
        XCTAssertTrue(app.staticTexts["SummaryRewriting"].waitForExistence(timeout: 2), "writing")
        XCUIDevice.shared.press(.home)                      // the fake Gemma's answer takes 3 s: stopped before it
        sleep(2)
        app.activate()
        let notFinished = app.staticTexts["Not Finished"]
        XCTAssertTrue(notFinished.waitForExistence(timeout: 5), "not finished")
        XCTAssertTrue((summary.value as? String ?? "").hasPrefix("Decisions"), "the Meeting summary stays")
        XCTAssertEqual(picker.value as? String, "Interview", "the chosen style stays")
        shot("Not finished", app)
        app.buttons["Try Again"].tap()
        XCTAssertTrue(waitFor(timeout: 15) { (summary.value as? String ?? "").hasPrefix("Q: Why is travel over plan?") },
                      "written as an interview: \(summary.value ?? "")")
        XCTAssertFalse(notFinished.exists)
    }

    /// While recording, a disc right of the Stop (the bookmark stays left, the Stop centred) opens the styles' menu;
    /// the transcript's summary is then written in the chosen style (the fake Gemma's lines) and the open summary shows
    /// that style.
    @MainActor
    func testStyleChosenWhileRecording() throws {
        let app = launch(["-fakeGemma", "-resetVoiceRecognition"])
        startRecording(app)
        let control = app.buttons["SummaryStyleControl"]
        XCTAssertTrue(control.waitForExistence(timeout: 10), "the style disc")
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertGreaterThan(control.frame.minX, stop.frame.maxX, "right of the Stop")
        XCTAssertLessThan(app.buttons["AddBookmark"].frame.maxX, stop.frame.minX, "the bookmark left of it")
        XCTAssertEqual(stop.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "the Stop stays centred")
        XCTAssertEqual(control.value as? String, "Brief")
        control.tap()
        let option = app.buttons["Bullet Points"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3), "the styles' menu")
        shot("Style menu while recording", app)
        option.tap()
        XCTAssertTrue(waitFor { (control.value as? String) == "Bullet Points" }, "chosen: \(control.value ?? "")")
        sleep(2)
        stop.tap()

        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 15), "the transcript")
        let summary = app.buttons["Summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60), "the summary")
        XCTAssertTrue((summary.value as? String ?? "").hasPrefix("• The test checks the live transcript."),
                      "written as bullet points: \(summary.value ?? "")")
        summary.tap()
        let picker = styleMenu(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue((picker.value as? String) == "Bullet Points",
                      "its style: \(picker.label) \(picker.value ?? "")")
        shot("Summary written as bullet points", app)
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5), "deleted")
    }

    /// Without Gemma (the simulator without `-fakeGemma`, or Gemma offered but not downloaded) nothing about styles
    /// shows: no disc while recording (its stand-in keeps the Stop centred), no style under the summary, no Styles
    /// for Tags in Settings.
    @MainActor
    func testNoStylesWithoutGemma() throws {
        var app = launch(["-resetVoiceRecognition"])
        startRecording(app)
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["SummaryStyleControl"].exists, "no style disc")
        XCTAssertEqual(stop.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "the Stop stays centred")
        app.buttons["Minimize"].tap()                       // recording goes on in the accessory
        app.terminate()                                     // nothing saved: a recording ended by a kill is lost

        app = launch(["-fakeGemmaDownload"])
        open("Budget Review", in: app)
        app.buttons["Summary"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", Self.summary)).firstMatch
            .waitForExistence(timeout: 3), "the summary")
        XCTAssertFalse(app.buttons["SummaryStyle"].exists, "no style before Gemma is downloaded")
        closeCard(app)
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Summaries"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Download Gemma 4 E2B (3.6 GB)"].firstMatch.waitForExistence(timeout: 5)
                      || app.staticTexts["Titles and Summaries"].waitForExistence(timeout: 5), "the Summaries page")
        XCTAssertFalse(app.buttons["StylesForTags"].exists, "no Styles for Tags")
    }

    /// Settings › Summaries › Styles for Tags lists the tags in use; "work" gets Meeting. Adding "work" to Budget
    /// Review (whose style was never chosen) writes its summary again as a meeting; a tag without a style ("planning")
    /// rewrites nothing.
    @MainActor
    func testTagStyle() throws {
        let app = launch(["-fakeGemma"])
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Summaries"].firstMatch.tap()
        let stylesRow = app.buttons["StylesForTags"]
        XCTAssertTrue(stylesRow.waitForExistence(timeout: 5), "Styles for Tags")
        stylesRow.tap()
        let work = app.buttons["TagStyle.work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5), "the tags in use")
        XCTAssertTrue(app.buttons["TagStyle.finance"].exists && app.buttons["TagStyle.planning"].exists,
                      "finance and planning too")
        work.tap()
        let meeting = app.buttons["Meeting"].firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 3), "the styles' menu")
        meeting.tap()
        XCTAssertTrue(waitFor { (work.value as? String) == "Meeting" }, "work: Meeting (\(work.value ?? ""))")
        shot("Styles for Tags", app)
        app.navigationBars.buttons.firstMatch.tap()        // back to Summaries
        XCTAssertTrue(waitFor { app.staticTexts["1"].exists }, "one tag with a style")

        app.buttons["Transcripts"].firstMatch.tap()
        open("Budget Review", in: app)
        let summary = app.buttons["Summary"]
        // -fakeGemma's sweep writes the seeded summary again first (Brief: the fake's paragraph).
        XCTAssertTrue(waitFor(timeout: 20) { (summary.value as? String ?? "").hasPrefix("The test checks") },
                      "the swept summary: \(summary.value ?? "")")
        addTag("work", app)
        XCTAssertTrue(waitFor(timeout: 15) { (summary.value as? String ?? "").contains("Anna Schmidt sends the numbers") },
                      "written again as a meeting: \(summary.value ?? "")")
        XCTAssertTrue((summary.value as? String ?? "").hasPrefix("Decisions"))

        summary.tap()
        let picker = styleMenu(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        choose("Brief", in: picker, app)
        XCTAssertTrue(waitFor(timeout: 15) { (summary.value as? String ?? "").hasPrefix("The test checks") }, "Brief")
        addTag("planning", app)
        sleep(4)
        XCTAssertTrue((summary.value as? String ?? "").hasPrefix("The test checks"), "no rewrite for a tag without a style")
        XCTAssertFalse(app.staticTexts["SummaryRewriting"].exists)
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

    /// The open summary's style menu.
    @MainActor
    private func styleMenu(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["SummaryStyle"].firstMatch
    }

    /// Opens a style menu and picks `style`.
    @MainActor
    private func choose(_ style: String, in menu: XCUIElement, _ app: XCUIApplication) {
        menu.tap()
        let option = app.buttons[style].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3), "the menu offers \(style)")
        option.tap()
    }

    /// The bottom toolbar's Add Tag, then `tag` and Return.
    @MainActor
    private func addTag(_ tag: String, _ app: XCUIApplication) {
        app.buttons["Add Tag"].tap()
        let field = app.textFields["Add Tag"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(tag + "\n")
    }
}
