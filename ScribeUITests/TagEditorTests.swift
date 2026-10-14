import XCTest

/// The card's tags: no tag line without tags, the bottom toolbar's Add Tag inserts it with a focused field, commas
/// turn the typed words into pills, the other transcripts' tags are suggested, and Return or leaving the field ends it
/// (the line goes away again when no tag was added). Seeded: Project Kickoff has "work" and "planning", Budget Review
/// "finance".
final class TagEditorTests: ScribeUITestCase {
    /// From one tag to none (the line goes), then Add Tag: the field, the suggestions, commas, a pill removed while
    /// adding (not suggested back), a suggestion tapped, a last word with Return; the tags are still there after the
    /// card is reopened.
    @MainActor
    func testAddTagsWithCommasAndSuggestions() throws {
        let app = launch()
        open("Budget Review", in: app)
        let field = app.textFields["Add Tag"]
        let finance = app.buttons["Remove finance"]
        XCTAssertTrue(finance.waitForExistence(timeout: 5), "the tag's pill")
        XCTAssertFalse(field.exists, "no field while not adding tags")

        finance.tap()
        XCTAssertTrue(finance.waitForNonExistence(timeout: 5), "the tag is removed")
        XCTAssertFalse(field.exists, "and with no tags left, no tag line at all")
        shot("No tags, no line", app)

        XCTAssertTrue(app.buttons["More"].isHittable, "Add Tag in the bottom toolbar's More menu")
        tapMenuItem("Add Tag", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Add Tag inserts the line with its field")
        XCTAssertTrue(waitForFocus(field), "focused, ready to type")
        let suggestions = app.buttons.matching(identifier: "TagSuggestion")
        XCTAssertTrue(suggestions.firstMatch.waitForExistence(timeout: 5), "the other transcripts' tags are suggested")
        let suggested = suggestions.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(suggested.contains("work") && suggested.contains("planning"), "Project Kickoff's tags: \(suggested)")
        XCTAssertFalse(suggested.contains("finance"), "a removed tag on no other transcript is not suggested: \(suggested)")
        shot("Adding tags", app)

        field.typeText("alpha, beta,")
        XCTAssertTrue(app.buttons["Remove alpha"].waitForExistence(timeout: 5), "a comma makes the word before it a pill")
        XCTAssertTrue(app.buttons["Remove beta"].exists)
        XCTAssertEqual(field.value as? String ?? "", "Add Tag", "the field is empty again (its placeholder)")
        XCTAssertTrue(hasFocus(field), "and still focused")
        XCTAssertLessThan(app.buttons["Remove alpha"].frame.minX, app.buttons["Remove beta"].frame.minX, "in order")

        app.buttons["Remove alpha"].tap()                                    // removed while adding
        XCTAssertTrue(app.buttons["Remove alpha"].waitForNonExistence(timeout: 5), "alpha is removed")
        XCTAssertTrue(hasFocus(field), "the field keeps the focus")
        let now = suggestions.allElementsBoundByIndex.map(\.label)
        XCTAssertFalse(now.contains("alpha"), "this transcript's own tags are not suggested back: \(now)")

        field.typeText("plan")
        let planning = suggestions.matching(NSPredicate(format: "label == 'planning'")).firstMatch
        XCTAssertTrue(planning.waitForExistence(timeout: 5), "typing filters the suggestions")
        XCTAssertFalse(suggestions.matching(NSPredicate(format: "label == 'work'")).firstMatch.exists, "work doesn't match")
        shot("Filtered suggestions", app)
        planning.tap()
        XCTAssertTrue(app.buttons["Remove planning"].waitForExistence(timeout: 5), "a tapped suggestion becomes a pill")
        XCTAssertEqual(field.value as? String ?? "", "Add Tag", "and replaces what was typed")

        field.typeText("gamma\n")
        XCTAssertTrue(app.buttons["Remove gamma"].waitForExistence(timeout: 5), "Return adds the last word")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "and ends adding: the field goes")
        XCTAssertFalse(suggestions.firstMatch.exists, "the suggestions too")
        shot("Tags added", app)

        closeCard(app)
        open("Budget Review", in: app)
        XCTAssertFalse(app.buttons["Remove alpha"].exists, "alpha stays removed")
        for tag in ["beta", "planning", "gamma"] {
            XCTAssertTrue(app.buttons["Remove \(tag)"].waitForExistence(timeout: 5), "\(tag) is kept")
        }
    }

    /// Ending without a tag (leaving the empty field, or Return in it) takes the line away again; Add Tag pressed while
    /// the line is open keeps the field focused (when it can be reached: a software keyboard covers the toolbar); a draft wider than the line takes the line's width and stays on screen
    /// (it scrolls inside the field); text left in the field when focus moves elsewhere (here the title) becomes a tag.
    /// Dragging the transcript down into the keyboard puts it away (`scrollDismissesKeyboard(.interactively)`; swiping
    /// up does not) and ends the edit the same way: checked when a software keyboard is up (with a hardware keyboard
    /// there is nothing to drag away).
    @MainActor
    func testLeavingTheFieldEndsAdding() throws {
        let app = launch()
        open("Budget Review", in: app)
        app.buttons["Remove finance"].tap()
        let field = app.textFields["Add Tag"]
        let addTag = { self.tapMenuItem("Add Tag", in: app) }

        addTag()
        XCTAssertTrue(waitForFocus(field), "the field")
        let title = app.textFields["Title"]
        title.tap()                                                          // leaving the empty field, no tags
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "leaving the empty field takes the line away")
        title.typeText("\n")                     // the title's edit ends too (a software keyboard covers the toolbar)
        addTag()
        XCTAssertTrue(waitForFocus(field), "Add Tag again: the field, focused")
        if app.buttons["More"].isHittable {       // pressed again while it is open (not under a software keyboard)
            addTag()
            XCTAssertTrue(waitForFocus(field), "still focused")
        }
        field.typeText("\n")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Return in the empty field: the line goes again")
        XCTAssertFalse(app.buttons.matching(identifier: "TagSuggestion").firstMatch.exists, "with its suggestions")

        addTag()
        XCTAssertTrue(waitForFocus(field), "the field again")
        // About 560 pt of text: wider than the line on every iPhone (362 pt on a 402 pt one).
        let long = "quarterly planning meeting with the finance team about the travel budget overrun"
        field.typeText(long)
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(field.frame.maxX, window.maxX - 10, "a long draft stays on screen: \(field.frame)")
        XCTAssertGreaterThanOrEqual(field.frame.minX, window.minX + 10, "from the margin: \(field.frame)")
        XCTAssertEqual(field.frame.width, window.width - 40, accuracy: 4, "it takes the line's width: \(field.frame)")
        shot("Long draft", app)
        title.tap()
        XCTAssertTrue(waitForFocus(title), "focus moved to the title")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "leaving the field ends adding")
        let pill = app.buttons["Remove \(long)"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the text left in the field became a tag")
        XCTAssertLessThanOrEqual(pill.frame.maxX, window.maxX - 10, "its pill fits the line: \(pill.frame)")

        // Dragging the keyboard away with the transcript.
        title.typeText("\n")
        addTag()
        XCTAssertTrue(waitForFocus(field), "the field once more")
        field.typeText("delta")
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 2), keyboard.frame.minY < window.maxY - 10 {
            let start = app.staticTexts["Paragraph.0"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            XCTAssertTrue(field.waitForNonExistence(timeout: 5), "dragging the keyboard away ends adding")
            XCTAssertTrue(app.buttons["Remove delta"].waitForExistence(timeout: 5), "and keeps the word")
        } else {
            note("Drag-away skipped", "no software keyboard on screen (hardware keyboard)")
        }
        XCTAssertEqual(title.value as? String, "Budget Review", "the title is untouched")
    }

    /// Scrolled down into a long transcript (the header gone above the screen), Add Tag brings the tag line back into
    /// view with its field. The recorded transcript is deleted afterwards.
    @MainActor
    func testAddTagScrollsTheLineIntoView() throws {
        let app = launch(["-fakeBacklogMinutes", "3"])                      // a transcript long enough to scroll
        startRecording(app)
        app.buttons["Stop"].firstMatch.tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the transcript in the card")
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 15), "its toolbar")
        RunLoop.current.run(until: .now + 1)
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(waitUntil { !(title.exists && title.isHittable) }, "precondition: the header scrolled away")

        tapMenuItem("Add Tag", in: app)
        let field = app.textFields["Add Tag"]
        XCTAssertTrue(waitForFocus(field), "the field")
        XCTAssertTrue(waitUntil { field.isHittable }, "scrolled into view: \(field.frame)")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(field.frame.minY, window.minY + 60, "below the back button: \(field.frame)")
        XCTAssertLessThan(field.frame.maxY, window.height * 0.85, "above the toolbar: \(field.frame)")
        shot("Add Tag scrolled into view", app)

        field.typeText("\n")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        app.buttons["Delete Transcript"].tap()                               // test recordings don't pile up
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5), "deleted, the card closed")
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            RunLoop.current.run(until: .now + 0.2)
        }
        return condition()
    }

    @MainActor
    private func hasFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if element.exists && hasFocus(element) { return true }
            RunLoop.current.run(until: .now + 0.1)
        }
        return false
    }
}
