import XCTest

/// Hand corrections of the speakers (SpeakerCorrection) from a name row's long-press menu. "Project Kickoff" has four
/// turns: Anna Schmidt, Jonas Weber, Anna Schmidt, Jonas Weber (SpeakerHeader.0-3).
final class SpeakerCorrectionTests: ScribeUITestCase {
    @MainActor
    private func names(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'SpeakerHeader.'")).allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
    }

    @MainActor
    private func menu(_ app: XCUIApplication, header: Int, _ item: String, _ choice: String) {
        app.buttons["SpeakerHeader.\(header)"].press(forDuration: 1.0)
        let submenu = app.buttons[item]
        XCTAssertTrue(submenu.waitForExistence(timeout: 5), "\(item) in the name row's menu")
        submenu.tap()
        let button = app.buttons[choice].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(choice) in \(item)")
        button.tap()
    }

    /// Jonas's first turn goes to Anna: Anna's first three turns are one; then Anna merged into Jonas (asked first):
    /// one speaker left.
    @MainActor
    func testAssignAndMerge() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        XCTAssertEqual(names(app), ["Anna Schmidt", "Jonas Weber", "Anna Schmidt", "Jonas Weber"])
        menu(app, header: 1, "Assign This Part To", "Anna Schmidt")
        XCTAssertTrue(waitFor { self.names(app) == ["Anna Schmidt", "Jonas Weber"] }, "\(names(app))")
        shot("Assigned to Anna", app)

        menu(app, header: 0, "Merge Into", "Jonas Weber")
        let merge = app.buttons["Merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5), "a merge asks first")
        merge.tap()
        XCTAssertTrue(waitFor { self.names(app) == ["Jonas Weber"] }, "\(names(app))")
        shot("Merged", app)
    }

    /// A turn to a new speaker: splitting a speaker that is two people.
    @MainActor
    func testAssignToNewSpeaker() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        menu(app, header: 2, "Assign This Part To", "New Speaker")
        XCTAssertTrue(waitFor { self.names(app) == ["Anna Schmidt", "Jonas Weber", "Speaker 3", "Jonas Weber"] },
                      "\(names(app))")
    }

    /// A merge can be undone from the toast: the four turns and both names are back.
    @MainActor
    func testUndoMerge() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        menu(app, header: 0, "Merge Into", "Jonas Weber")
        app.buttons["Merge"].tap()
        XCTAssertTrue(waitFor { self.names(app) == ["Jonas Weber"] }, "\(names(app))")
        let undo = app.buttons["UndoCorrection"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the Undo toast")
        XCTAssertTrue(app.staticTexts["Speakers Merged"].exists)
        shot("Undo toast", app)
        undo.tap()
        XCTAssertTrue(waitFor { self.names(app) == ["Anna Schmidt", "Jonas Weber", "Anna Schmidt", "Jonas Weber"] },
                      "undone: \(names(app))")
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5), "the toast goes")
    }

    /// Edit Text's speaker chip moves one paragraph: Jonas's first paragraph to Anna, so Anna's first three paragraphs
    /// are one turn; Undo brings the four turns back.
    @MainActor
    func testParagraphChipAndUndo() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        app.buttons["Edit Text"].tap()
        let chip = app.buttons["SpeakerChip.1"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "a speaker chip above each paragraph")
        XCTAssertEqual(chip.label, "Jonas Weber")
        XCTAssertTrue(app.buttons["SpeakerChip.3"].exists)
        chip.tap()
        let anna = app.buttons["Anna Schmidt"].firstMatch
        XCTAssertTrue(anna.waitForExistence(timeout: 5), "the speakers to choose from")
        XCTAssertTrue(app.buttons["New Speaker"].exists)
        anna.tap()
        XCTAssertTrue(waitFor { chip.label == "Anna Schmidt" }, "the chip shows the choice: \(chip.label)")
        shot("Speaker chip", app)
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done Editing'")).allElementsBoundByIndex
            .filter(\.isHittable).min { $0.frame.minY < $1.frame.minY } ?? app.buttons["Done Editing"].firstMatch
        done.tap()
        XCTAssertTrue(waitFor { self.names(app) == ["Anna Schmidt", "Jonas Weber"] }, "\(names(app))")
        let undo = app.buttons["UndoCorrection"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the Undo toast")
        XCTAssertTrue(app.staticTexts["Transcript Edited"].exists)
        undo.tap()
        XCTAssertTrue(waitFor { self.names(app) == ["Anna Schmidt", "Jonas Weber", "Anna Schmidt", "Jonas Weber"] },
                      "undone: \(names(app))")
    }

    /// A rename after a correction drops its Undo (undoing would throw the rename away); a Done in Edit Text that
    /// changes nothing offers no Undo.
    @MainActor
    func testRenameDropsUndoAndNoOpDoneOffersNone() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        menu(app, header: 1, "Assign This Part To", "Anna Schmidt")
        let undo = app.buttons["UndoCorrection"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        app.buttons["SpeakerHeader.1"].tap()                      // Jonas: rename him
        XCTAssertTrue(app.buttons["CancelRename"].waitForExistence(timeout: 5))
        // Back to the default name, not a new one: a new person ("Jonas W.") outlived the samples' reseeding, linked by
        // voice in other tests' recordings, and crowded testRenameSheet's list.
        app.buttons["UseDefaultName"].tap()                       // saves and closes the sheet
        XCTAssertTrue(app.buttons["CancelRename"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5), "the rename dropped the Undo")

        app.buttons["Edit Text"].tap()
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done Editing'")).allElementsBoundByIndex
            .filter(\.isHittable).min { $0.frame.minY < $1.frame.minY } ?? app.buttons["Done Editing"].firstMatch
        done.tap()
        sleep(1)
        XCTAssertFalse(undo.exists, "a Done that changed nothing offers no Undo")
    }

    /// A word added at the end of a paragraph stays with that paragraph's speaker (it used to get no time and go to
    /// the next speaker).
    @MainActor
    func testAppendedWordStaysWithItsSpeaker() throws {
        let app = launch()
        open("Project Kickoff", in: app)
        app.buttons["Edit Text"].tap()
        let field = app.textFields["ParagraphField.0"].exists ? app.textFields["ParagraphField.0"]
                                                              : app.textViews["ParagraphField.0"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.88)).tap()
        sleep(1)
        field.typeText(" Danke.")
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done Editing'")).allElementsBoundByIndex
            .filter(\.isHittable).min { $0.frame.minY < $1.frame.minY } ?? app.buttons["Done Editing"].firstMatch
        done.tap()
        let first = app.staticTexts["Paragraph.0"]
        XCTAssertTrue(waitFor { (first.label as String).hasSuffix("Danke.") }, "the word ends Anna's paragraph: \(first.label)")
        XCTAssertFalse(app.staticTexts["Paragraph.1"].label.hasPrefix("Danke"), "and doesn't start Jonas's")
        XCTAssertEqual(names(app), ["Anna Schmidt", "Jonas Weber", "Anna Schmidt", "Jonas Weber"])
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        return condition()
    }
}
