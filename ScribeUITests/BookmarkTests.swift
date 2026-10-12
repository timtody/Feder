import XCTest

/// Bookmarks (FED-14): moments marked while recording show above the paragraph they fall in. The card's bookmark
/// button (left of the Stop) counts them; a start from outside while recording (the Action Button: the simulator has
/// none, so `-fakeOutsidePressAfter` asks as it does) adds one; `-seedBookmarks` gives Budget Review two, at 0:09 (Anna's
/// first turn) and 0:24 (her second). Recordings are made with `-resetVoiceRecognition`, so their fake speakers store no
/// voices, and are deleted again. The lines are found as texts: the bookmark symbol beside each is labelled
/// "Bookmark" too, and XCUITest's identifier lookup also matches labels.
final class BookmarkTests: ScribeUITestCase {
    @MainActor
    private func bookmarkButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["AddBookmark"]
    }

    @MainActor
    private func deleteTranscript(_ app: XCUIApplication) {
        app.buttons["Delete Transcript"].tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks first")
        confirm.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 5), "the card closes")
    }

    /// The card's bookmark button sits left of the Stop, the Stop still centred; each press counts (VoiceOver: "1
    /// bookmark", "2 bookmarks"), a second press within a second doesn't. After Stop the transcript shows them above
    /// their paragraphs ("Bookmark · 0:03").
    @MainActor
    func testBookmarkWhileRecording() throws {
        let app = launch(["-resetVoiceRecognition"])
        startRecording(app)
        let button = bookmarkButton(app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the bookmark button")
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertLessThan(button.frame.maxX, stop.frame.minX, "left of the Stop")
        XCTAssertEqual(stop.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "the Stop stays centred")
        sleep(3)                                            // a few words first
        button.tap()
        XCTAssertTrue(waitFor { (button.value as? String) == "1 bookmark" }, "one: \(button.value ?? "")")
        button.tap()                                        // within a second: the same moment
        sleep(1)
        XCTAssertEqual(button.value as? String, "1 bookmark", "a double press is one")
        sleep(2)
        button.tap()
        XCTAssertTrue(waitFor { (button.value as? String) == "2 bookmarks" }, "two: \(button.value ?? "")")
        shot("Recording with bookmarks", app)
        sleep(2)
        stop.tap()

        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 15), "the transcript")
        let lines = app.staticTexts.matching(identifier: "Bookmark")
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 10), "the bookmarks above their paragraphs")
        let labels = lines.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTAssertEqual(labels.components(separatedBy: ":").count - 1, 2, "both times: \(labels)")
        XCTAssertTrue(labels.contains("Bookmark"), labels)
        shot("Transcript with bookmarks", app)
        deleteTranscript(app)
    }

    /// A start from outside the app while recording (the Action Button, Control Center, Siri) adds a bookmark and
    /// leaves the recording running.
    @MainActor
    func testOutsidePressWhileRecordingAddsBookmark() throws {
        let app = launch(["-resetVoiceRecognition", "-fakeOutsidePressAfter", "16"])
        startRecording(app)
        let button = bookmarkButton(app)
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(timeout: 30) { (button.value as? String) == "1 bookmark" },
                      "the outside press set one: \(button.value ?? "")")
        XCTAssertTrue(app.buttons["Stop"].firstMatch.isHittable, "still recording")
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 15), "the transcript")
        XCTAssertTrue(app.staticTexts["Bookmark"].waitForExistence(timeout: 10), "its bookmark")
        deleteTranscript(app)
    }

    /// The Live Activity's bookmark button (expanded Dynamic Island, left next to the time, Stop on the right) adds one
    /// without opening Feder (AddBookmarkIntent in the app); back in the app the card's button counts it.
    @MainActor
    func testLiveActivityBookmark() throws {
        XCUIApplication().terminate()                       // see SystemIntegrationTests.testLiveActivityStop
        let app = launch(["-autoRecord", "-fakeSilence"])    // nothing saved
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 20), "recording")
        sleep(3)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        sleep(2)
        springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: springboard.frame.midX, dy: 24))
            .press(forDuration: 1.0)                         // expands the island
        // The island speaks the simulator's language, not the app's launch argument.
        let bookmark = springboard.buttons.matching(NSPredicate(format: "label IN {'Add Bookmark', 'Lesezeichen setzen'}"))
            .firstMatch
        let stop = springboard.buttons.matching(NSPredicate(format: "label IN {'Stop', 'Stoppen'}")).firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5), "the bookmark in the expanded island")
        XCTAssertLessThan(bookmark.frame.maxX, stop.frame.minX, "left of Stop")
        shot("Dynamic Island with bookmark", springboard)
        bookmark.tap()
        sleep(2)
        shot("Dynamic Island after bookmark", springboard)
        app.activate()
        let button = bookmarkButton(app)
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor { (button.value as? String) == "1 bookmark" }, "counted: \(button.value ?? "")")
        app.buttons["Stop"].firstMatch.tap()                 // -fakeSilence: nothing saved, the card closes
        XCTAssertTrue(app.buttons["Minimize"].waitForNonExistence(timeout: 10))
    }

    /// Budget Review's two bookmarks each sit between Anna's name row and her paragraph they fall in.
    @MainActor
    func testSeededBookmarksAboveTheirParagraphs() throws {
        let app = launch(["-seedBookmarks"])
        open("Budget Review", in: app)
        let lines = app.staticTexts.matching(identifier: "Bookmark")
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(lines.count, 2, "two lines")
        let first = lines.element(boundBy: 0), second = lines.element(boundBy: 1)
        XCTAssertEqual(first.label, "Bookmark · 0:09")
        XCTAssertEqual(second.label, "Bookmark · 0:24")
        for (line, index) in [(first, 1), (second, 3)] {
            let header = app.buttons["SpeakerHeader.\(index)"], paragraph = app.staticTexts["Paragraph.\(index)"]
            XCTAssertGreaterThanOrEqual(line.frame.minY, header.frame.maxY - 1, "under Anna's name row \(index)")
            // The paragraph's frame is its text's selection area, which reaches 16 pt above the text on iOS 27.
            XCTAssertLessThanOrEqual(line.frame.maxY, paragraph.frame.minY + 16, "above her paragraph \(index)")
        }
        shot("Seeded bookmarks", app)
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
