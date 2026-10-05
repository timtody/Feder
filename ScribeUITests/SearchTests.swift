import XCTest

/// The Search tab, tapped like a user: its bar at the top of the screen (like Apple Music's), suggestions, tokens under
/// the field, results (scrolling them dismisses the keyboard at once), the result's card with its highlights and the hit
/// navigator in its bottom bar, the field's focus per tap on Search, and the record accessory around searching.
final class SearchTests: ScribeUITestCase {

    /// The Search tab opens its field at the top with the close button beside it; a person suggestion becomes a token
    /// chip under the field that filters the list; the result opens at that person's first turn (marked) with "1 of 2",
    /// and Next steps to the second.
    @MainActor
    func testPersonSuggestionTokenAndResult() throws {
        let app = launch()
        let field = openSearch(app)
        assertAtTop(field, app)
        app.typeText("Jo")
        let suggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Jonas Weber'")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "Jonas Weber is suggested")
        XCTAssertTrue(app.staticTexts["Budget Review"].exists || app.staticTexts["Project Kickoff"].exists,
                      "results stay visible below the suggestions")
        shot("Person suggestion", app)
        suggestion.tap()

        XCTAssertTrue(app.staticTexts["Budget Review"].waitForNonExistence(timeout: 5), "the token filters the list")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists)
        // The token is a chip floating under the field; the typed fragment that became the token is gone from it.
        let token = app.buttons["Remove Jonas Weber"]
        XCTAssertTrue(token.exists, "the person token is a chip")
        XCTAssertGreaterThanOrEqual(token.frame.minY, field.frame.maxY, "under the field: \(token.frame) \(field.frame)")
        XCTAssertEqual(app.buttons.matching(identifier: "SearchToken").count, 1, "one token chip")
        let value = field.value as? String ?? ""
        XCTAssertFalse(value.hasPrefix("Jo"), "the typed fragment became the token: \(value)")
        shot("Token and results", app)

        open("Project Kickoff", in: app)                    // the card, not a push
        let count = app.staticTexts["Match 1 of 2"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), "n of m")
        assertHitNavigatorInBottomBar(app)
        XCTAssertEqual(app.staticTexts["Paragraph.1"].value as? String, "Current match", "Jonas's first turn is marked")
        // That turn is on screen already: the card stays at its top, the title clear of the back button (centring
        // the hit pulled the title up under it).
        XCTAssertGreaterThan(app.textFields["Title"].frame.minY, app.buttons["Minimize"].frame.maxY + 4,
                             "the title below the back button: \(app.textFields["Title"].frame)")
        shot("Result opened", app)
        app.buttons["Next Match"].tap()
        XCTAssertTrue(app.staticTexts["Match 2 of 2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["Paragraph.3"].value as? String, "Current match")
        shot("Next match", app)
        app.buttons["Previous Match"].tap()
        XCTAssertTrue(app.staticTexts["Match 1 of 2"].waitForExistence(timeout: 5), "Previous steps back")

        closeCard(app)                                      // back to the results, the search as it was
        XCTAssertTrue(field.exists, "back in Search")
        XCTAssertTrue(app.buttons["Remove Jonas Weber"].exists, "with the token")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists)
    }

    /// The hit navigator ("n of m", Previous Match, Next Match) is in the card's bottom toolbar between the More menu
    /// (Share, Add Tag and Speakers: seven items fit no iPhone's bar) and Delete, all reachable (not in an overflow
    /// menu).
    @MainActor
    private func assertHitNavigatorInBottomBar(_ app: XCUIApplication) {
        let height = app.windows.firstMatch.frame.height
        let count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Match '")).firstMatch
        let more = app.buttons["More"]
        let items = [("n of m", count), ("Previous Match", app.buttons["Previous Match"]),
                     ("Next Match", app.buttons["Next Match"]), ("More", more),
                     ("Delete", app.buttons["Delete Transcript"])]
        for (name, element) in items {
            XCTAssertTrue(element.waitForExistence(timeout: 5), name)
            XCTAssertGreaterThan(element.frame.minY, height * 0.85, "\(name) in the bottom bar: \(element.frame)")
            if name != "n of m" { XCTAssertTrue(element.isHittable, "\(name) is reachable") }
        }
        XCTAssertLessThan(more.frame.minX, app.buttons["Previous Match"].frame.minX, "More on the left")
        XCTAssertLessThan(app.buttons["Previous Match"].frame.minX, app.buttons["Next Match"].frame.minX)
        XCTAssertLessThan(app.buttons["Next Match"].frame.minX, app.buttons["Delete Transcript"].frame.minX,
                          "Delete stays outermost")
    }

    /// Every tap on Search focuses the field (keyboard up), and leaving the Search tab puts the keyboard away: it must
    /// not stay up over the Transcripts list. The test simulator has a hardware keyboard (the software keyboard is
    /// off screen but still in the tree while a field is first responder), so the field's focus is checked as well.
    @MainActor
    func testSearchTabFocusAndKeyboardLeaveWithTab() throws {
        let app = launch()
        let field = openSearch(app)
        XCTAssertTrue(hasFocus(field), "tapping Search focuses the field")

        app.buttons["Transcripts"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard went with the Search tab")
        XCTAssertTrue(app.cells.firstMatch.isHittable, "the Transcripts list")
        shot("Transcripts after Search", app)

        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "back in Search: keyboard up again")
        XCTAssertTrue(waitFor { self.hasFocus(field) }, "and the field focused")

        // Unfocused within Search (Return ends editing; the hardware keyboard sends it), a tap on the selected Search
        // tab focuses the field again.
        app.typeText("a")
        waitForResults(app)
        app.typeText("\n")
        guard waitFor({ !self.hasFocus(field) }) else {
            throw XCTSkip("Return did not end editing: no unfocused field to tap Search on")
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard went with the focus")
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(waitFor { self.hasFocus(field) }, "a tap on the selected Search tab focuses the field again")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard up")
        XCTAssertEqual(field.value as? String, "a", "the text stays")
        shot("Search tapped again", app)
    }

    /// "a" matches every transcript: the search has run once the result count is shown. (Not "Budget Review": with
    /// transcripts recorded on the simulator before, newer than it, it is below the screen and not in the tree.)
    @MainActor
    private func waitForResults(_ app: XCUIApplication) {
        let count = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+ Transcripts?'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "the results are shown")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists, "the newest result")
    }

    @MainActor
    private func hasFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
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

    /// Typed words: the matching transcript only, and its paragraphs with the word are stepped through.
    @MainActor
    func testWordResultHighlights() throws {
        let app = launch()
        _ = openSearch(app)
        app.typeText("budget")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForNonExistence(timeout: 5))
        let result = app.staticTexts["Budget Review"]
        XCTAssertTrue(result.exists)
        shot("Word results", app)
        open("Budget Review", in: app)
        XCTAssertTrue(app.staticTexts["Match 1 of 2"].waitForExistence(timeout: 5))
        assertHitNavigatorInBottomBar(app)
        XCTAssertEqual(app.staticTexts["Paragraph.0"].value as? String, "Current match")
        shot("Word result opened", app)

        // Share, Add Tag and Speakers are in the More menu meanwhile, and Add Tag works from there.
        app.buttons["More"].tap()
        for label in ["Share Transcript", "Add Tag", "Speakers"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "\(label) in the More menu")
        }
        shot("More menu with the hit navigator", app)
        app.buttons["Add Tag"].tap()
        let tagField = app.textFields["Add Tag"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 5), "Add Tag from the menu inserts the tag line")
        XCTAssertTrue(app.buttons["Remove finance"].exists, "after the transcript's tag")
        // Focused although the menu was still closing, and it stays (a lost focus would end the edit at once).
        XCTAssertTrue(waitFor { self.hasFocus(tagField) }, "the tag field is focused")
        RunLoop.current.run(until: .now + 1)
        XCTAssertTrue(tagField.exists && hasFocus(tagField), "and stays focused")
    }

    /// While searching, the last result is not covered by the tab bar, the record accessory or the keyboard once the
    /// results are scrolled to the end; the record accessory is there after closing search.
    @MainActor
    func testResultsNotCoveredWhileSearching() throws {
        let app = launch()
        XCTAssertTrue(transcribe(app).waitForExistence(timeout: 5))
        _ = openSearch(app)
        app.typeText("a")
        waitForResults(app)
        for _ in 0..<3 { app.swipeUp() }                    // to the end (also with more transcripts in the store)
        RunLoop.current.run(until: .now.addingTimeInterval(1))
        let last = app.cells.allElementsBoundByIndex.last { $0.frame.height > 40 }   // a result, not a caption row
        let record = transcribe(app).frame, tabBar = app.tabBars.firstMatch.frame
        let keyboard = app.keyboards.firstMatch
        var edge = min(record.minY, tabBar.minY)
        if keyboard.exists { edge = min(edge, keyboard.frame.minY) }
        shot("Searching, scrolled to the end", app)
        note("Last result", "last \(last?.frame ?? .null), record \(record), tab bar \(tabBar)")
        XCTAssertNotNil(last)
        XCTAssertLessThanOrEqual(last?.frame.maxY ?? .infinity, edge + 1, "the last result is not covered")
        closeSearch(app)
        XCTAssertTrue(transcribe(app).waitForExistence(timeout: 5), "the record accessory after search")
        XCTAssertTrue(transcribe(app).isHittable)
    }

    /// Pulling the list down far past its top and letting go there opens search with the keyboard; shorter pulls
    /// (also held for a while: the finger lifting decides, not the list springing back) do not.
    @MainActor
    func testPullDownOpensSearch() throws {
        let app = launch()
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let field = app.textFields["SearchField"]

        pull(row, by: 25)
        XCTAssertFalse(field.waitForExistence(timeout: 2), "a short pull just bounces")
        pull(row, by: 120, hold: 1)
        XCTAssertFalse(field.waitForExistence(timeout: 2), "a medium pull, held, is still below the threshold")

        pull(row, by: 330, hold: 1)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "a long pull opens search")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "with the keyboard up")
        assertAtTop(field, app)
        shot("Pulled to search", app)

        closeSearch(app)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5), "back to the list")
        shot("Closed after pull (no pull ring left)", app)
    }

    /// Scrolling the results puts the keyboard away (like Music); the field keeps its text. Needs the software
    /// keyboard on screen: with the simulator's hardware keyboard connected (Simulator: I/O > Keyboard) it is off
    /// screen, there is nothing to dismiss and the test is skipped.
    @MainActor
    func testScrollingResultsDismissesKeyboard() throws {
        let app = launch()
        let field = openSearch(app)
        app.typeText("a")
        waitForResults(app)
        let window = app.windows.firstMatch
        let keyboard = app.keyboards.firstMatch
        shot("Typed", app)
        guard keyboard.frame.minY < window.frame.maxY - 1 else {
            throw XCTSkip("the software keyboard is off screen (hardware keyboard connected): \(keyboard.frame)")
        }
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                    withVelocity: .default, thenHoldForDuration: 0)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "scrolling put the keyboard away")
        XCTAssertTrue(field.exists, "the field stays")
        XCTAssertEqual(field.value as? String, "a", "with its text")
        shot("Scrolled", app)
    }

    /// Fast typing keeps every character (the search runs after the pause, not per keystroke), and the results follow.
    @MainActor
    func testTypingIsDebounced() throws {
        let app = launch()
        let field = openSearch(app)
        app.typeText("budget review")
        XCTAssertEqual(field.value as? String, "budget review", "no keystroke is lost")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForNonExistence(timeout: 5), "results after the pause")
        XCTAssertTrue(app.staticTexts["Budget Review"].exists)
        // Clearing applies at once: the whole list is back.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "budget review".count))
        XCTAssertTrue(app.staticTexts["Project Kickoff"].waitForExistence(timeout: 2))
    }

    /// The search field is at the top of the screen, right under the status bar (Apple Music), the close button
    /// beside it on the right.
    @MainActor
    private func assertAtTop(_ field: XCUIElement, _ app: XCUIApplication) {
        XCTAssertLessThan(field.frame.minY, 120, "the search field is at the top: \(field.frame)")
        XCTAssertGreaterThan(field.frame.minY, 40, "below the status bar: \(field.frame)")
        let close = app.buttons["Close"].firstMatch.frame
        XCTAssertLessThan(abs(close.midY - field.frame.midY), 8, "the close button is beside the field")
        XCTAssertGreaterThan(close.minX, field.frame.maxX, "to its right")
    }

    /// Drags `element` straight down by `distance` points, optionally holding before letting go.
    @MainActor
    private func pull(_ element: XCUIElement, by distance: CGFloat, hold: TimeInterval = 0) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                    withVelocity: .slow, thenHoldForDuration: hold)
    }

    /// Chooses the Search tab; returns its search field once the keyboard is up.
    @MainActor
    private func openSearch(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up")
        dismissKeyboardTip(app)
        let field = app.textFields["SearchField"]
        XCTAssertTrue(field.exists)
        return field
    }

    /// The close button beside the search field: back to the Transcripts tab.
    @MainActor
    private func closeSearch(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.exists, "a button closes the search")
        close.tap()
    }
}
