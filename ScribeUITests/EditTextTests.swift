import XCTest

/// Edit Text (TextCorrection): the paragraphs become fields; Done writes the change into the transcript, and a word
/// typed in place of another is offered for Your Words.
final class EditTextTests: ScribeUITestCase {
    @MainActor
    func testEditAWordAndAddItToYourWords() throws {
        // A new word each run: Your Words stays on the simulator, and a word already there isn't offered again.
        let word = "Cofin" + String((0..<4).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
        let app = launch()
        open("Budget Review", in: app)
        tapMenuItem("Edit Text", in: app)
        let field = app.textFields["ParagraphField.0"].exists ? app.textFields["ParagraphField.0"]
                                                              : app.textViews["ParagraphField.0"]
        XCTAssertTrue(field.appears(timeout: 5), "the paragraphs are fields")
        XCTAssertTrue(app.buttons["Done Editing"].exists && app.buttons["Cancel Editing"].exists, "Done and Cancel")
        // The cursor to the end: a tap right of the last line's end (⌘↓ didn't always move it once the software
        // keyboard came up, and the word went in at the start).
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.88)).tap()
        sleep(1)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "under.".count) + word + ".")
        shot("Editing", app)
        hittable(app.buttons.matching(NSPredicate(format: "label == %@", "Done Editing")), or: app.buttons["Done Editing"]).tap()
        let add = app.buttons["Add"]
        XCTAssertTrue(add.appears(timeout: 5), "the new word is offered for Your Words")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", word)).firstMatch.exists)
        add.tap()
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "licences are \(word).")).firstMatch
        XCTAssertTrue(paragraph.appears(timeout: 5), "the paragraph has the new word")
        XCTAssertFalse(app.textFields["ParagraphField.0"].exists, "back to text")

        closeCard(app)
        app.buttons["Settings"].firstMatch.tap()
        let words = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Your Words'")).firstMatch
        for _ in 0..<3 where !words.isHittable { app.swipeUp() }
        words.tap()
        XCTAssertTrue(app.staticTexts[word].appears(timeout: 5), "in Your Words")
    }

    /// Done and Cancel are in the bottom bar and, while the keyboard is up, above it: the upper one (the bottom bar's
    /// lies under the keyboard then and still counts as hittable).
    @MainActor
    private func hittable(_ query: XCUIElementQuery, or fallback: XCUIElement) -> XCUIElement {
        query.allElementsBoundByIndex.filter(\.isHittable).min { $0.frame.minY < $1.frame.minY } ?? fallback.firstMatch
    }

    /// Cancel leaves the transcript as it was.
    @MainActor
    func testCancelKeepsTheText() throws {
        let app = launch()
        open("Budget Review", in: app)
        tapMenuItem("Edit Text", in: app)
        let field = app.textFields["ParagraphField.0"].exists ? app.textFields["ParagraphField.0"]
                                                              : app.textViews["ParagraphField.0"]
        XCTAssertTrue(field.appears(timeout: 5))
        field.tap()
        field.typeText("Nonsense ")
        hittable(app.buttons.matching(NSPredicate(format: "label == %@", "Cancel Editing")), or: app.buttons["Cancel Editing"]).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH \"Let's go through\"")).firstMatch
                        .appears(timeout: 5), "unchanged")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Nonsense'")).firstMatch.exists)
    }
}
