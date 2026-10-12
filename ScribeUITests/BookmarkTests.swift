import XCTest

/// Bookmarks (FED-14): moments marked while recording. The transcript highlights each one's sentence and lists them
/// in a folded "Bookmarks" row under the summary (time and sentence; a tap scrolls there). The card's
/// bookmark button (left of the Stop) counts them; a start from outside while recording (the Action Button: the
/// simulator has none, so `-fakeOutsidePressAfter` asks as it does) adds one; `-seedBookmarks` gives Budget Review
/// four on three sentences (9.6 s and 10.5 s on one, 17 s, 25.5 s). Recordings are made with `-resetVoiceRecognition`,
/// so their fake speakers store no voices, and are deleted again.
final class BookmarkTests: ScribeUITestCase {
    @MainActor
    private func bookmarkButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["AddBookmark"]
    }

    /// The folded Bookmarks row, opened; its rows' labels (time, sentence).
    @MainActor
    private func openBookmarks(_ app: XCUIApplication, count: Int, file: StaticString = #filePath,
                               line: UInt = #line) -> [String] {
        let row = app.buttons["Bookmarks"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Bookmarks row", file: file, line: line)
        XCTAssertEqual(row.value as? String, "\(count)", "its count", file: file, line: line)
        row.tap()
        XCTAssertTrue(app.buttons["BookmarkRow.\(count - 1)"].waitForExistence(timeout: 5), "opened", file: file, line: line)
        return (0..<count).map { app.buttons["BookmarkRow.\($0)"].label }
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
    /// bookmark", "2 bookmarks"), a second press within a second doesn't. After Stop no Bookmarks row while the words
    /// and speakers are still being found (FED-73: placed only on the final paragraphs; the vocabulary check after them
    /// keeps the sentences); then it lists both, each with its time and sentence, also once the fake Gemma
    /// (`-fakeGemma`) has written the summary.
    @MainActor
    func testBookmarkWhileRecording() throws {
        let app = launch(["-resetVoiceRecognition", "-fakeGemma"])
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
        XCTAssertFalse(app.staticTexts["Bookmark"].exists, "no line above the paragraph any more")
        // While the steps after Stop still rewrite the paragraphs, no Bookmarks row (FED-73: it jumped from pass to
        // pass); it comes once they are final, during the vocabulary check at the latest.
        let status = app.staticTexts["PipelineStatus"]
        let textSteps: Set<String> = ["Transcribing…", "Identifying speakers…", "Refining speakers…",
                                      "Preparing speaker model…"]
        var textStepSeen = false, bookmarksDuringText = false
        let end = Date.now.addingTimeInterval(60)
        while !app.buttons["Summary"].exists, Date.now < end {
            if let line = try? status.snapshot(), textSteps.contains(line.label) {
                textStepSeen = true
                if app.buttons["Bookmarks"].exists { bookmarksDuringText = true }
            }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        XCTAssertTrue(textStepSeen, "the steps after Stop were seen")
        XCTAssertFalse(bookmarksDuringText, "no Bookmarks row while the paragraphs are being found")
        XCTAssertTrue(app.buttons["Summary"].exists, "the summary")
        let rows = openBookmarks(app, count: 2)
        XCTAssertTrue(rows.allSatisfy { $0.contains("0:") }, "with their times: \(rows)")
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
        _ = openBookmarks(app, count: 1)
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

    /// Budget Review's four bookmarks (`-seedBookmarks`, no Gemma: no titles): two on one sentence are one row, at the
    /// first one's time, with a small ×2 (FED-73); each row has its time and the sentence at the press; the one 0.7 s
    /// into Lena's reply has the sentence that had just ended (Anna's, across the speaker change). A tap scrolls; the
    /// highlighted sentences, each with one bookmark, are seen in the screenshot.
    @MainActor
    func testSeededBookmarksList() throws {
        let app = launch(["-seedBookmarks"])
        open("Budget Review", in: app)
        XCTAssertFalse(app.staticTexts["Bookmark"].exists, "no line above the paragraph")
        let rows = openBookmarks(app, count: 3)
        XCTAssertTrue(rows[0].contains("0:10") && rows[0].contains("The travel overrun comes from the two customer workshops."),
                      "one row for the two on this sentence, at the first: \(rows[0])")
        XCTAssertTrue(rows[0].contains("2 bookmarks"), "its small ×2 says so: \(rows[0])")
        XCTAssertFalse(rows[1].contains("bookmarks"), "one bookmark: no ×: \(rows[1])")
        XCTAssertTrue(rows[1].contains("0:17") && rows[1].contains("I'd move part of the licence budget to cover it."),
                      "the sentence that just ended: \(rows[1])")
        XCTAssertTrue(rows[2].contains("0:26") && rows[2].contains("I'll also add the forecast"), rows[2])
        note("Paragraph 1", app.staticTexts["Paragraph.1"].label)
        shot("Seeded bookmarks", app)
        app.buttons["BookmarkRow.2"].tap()
        XCTAssertTrue(app.staticTexts["Paragraph.3"].isHittable, "scrolled to it")
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
