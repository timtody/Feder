import XCTest

/// The tab bar (Apple Music's layout): Settings, Transcripts and Search (at the right end) in one bar, the record
/// accessory above them; minimized: the current tab, the accessory and Search. Live Speaker Labels and People are in the
/// Settings tab; a person's transcript opens the transcript card.
final class SettingsTests: ScribeUITestCase {
    @MainActor
    func testTabBarLayout() throws {
        let app = launch()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
        let transcripts = app.buttons["Transcripts"].firstMatch, settings = app.buttons["Settings"].firstMatch
        let search = app.buttons["Search"].firstMatch, record = transcribe(app)
        for (element, name) in [(transcripts, "Transcripts"), (settings, "Settings"), (search, "Search"), (record, "Transcribe")] {
            XCTAssertTrue(element.exists, "\(name) at the bottom")
            XCTAssertGreaterThan(element.frame.minY, app.windows.firstMatch.frame.height * 0.75, "\(name) in thumb reach")
        }
        XCTAssertLessThan(record.frame.maxY, transcripts.frame.minY + 4, "the record accessory above the tabs")
        XCTAssertTrue(settings.frame.midX < transcripts.frame.midX && transcripts.frame.midX < search.frame.midX,
                      "Settings, Transcripts, Search: \(settings.frame) \(transcripts.frame) \(search.frame)")
        XCTAssertEqual(search.frame.midY, transcripts.frame.midY, accuracy: 2, "in the same bar")
        XCTAssertEqual(settings.frame.midY, transcripts.frame.midY, accuracy: 2, "in the same bar")
        XCTAssertFalse(app.switches["Live Speaker Labels"].exists, "Live Speaker Labels are in Settings")
        XCTAssertFalse(app.textFields["SearchField"].exists, "no search field until Search is chosen")
        shot("tab bar", app)
    }

    /// Scrolling down minimizes the bar to three items like Apple Music's: the current tab on the left, the record
    /// accessory in the middle and Search on the right, which stays where it was at the bar's right end (it must not
    /// jump from the middle to the right). Scrolling back up expands it again. `-seedFiller 12`: a list that scrolls.
    @MainActor
    func testTabBarMinimizesLikeMusic() throws {
        let app = launch(["-seedFiller", "12"])
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
        let search = app.buttons["Search"].firstMatch, record = transcribe(app)
        let transcripts = app.buttons["Transcripts"].firstMatch, settings = app.buttons["Settings"].firstMatch
        let width = app.windows.firstMatch.frame.width
        XCTAssertTrue(search.waitForExistence(timeout: 5) && record.exists)
        let expandedSearch = search.frame
        XCTAssertGreaterThan(expandedSearch.midX, width * 0.6, "Search at the right end: \(expandedSearch)")

        app.swipeUp()
        // While the bar collapses for the first time after launch the accessory must never run under the Search
        // circle (it did, for ~0.3 s, before the Search role was primed at launch; see MainView.isBarMinimized).
        // Sampled as fast as XCUITest reads frames (every ~0.1 s) for 1.5 s.
        var overlaps: [String] = []
        let end = Date.now.addingTimeInterval(1.5)
        while Date.now < end {
            let r = record.frame, s = search.frame
            if abs(r.midY - s.midY) < 6, r.maxX > s.minX + 1 { overlaps.append("record \(r) search \(s)") }
        }
        note("First collapse", overlaps.isEmpty ? "no overlap" : overlaps.joined(separator: "\n"))
        XCTAssertTrue(overlaps.isEmpty, "the accessory ran under the Search circle during the first collapse: \(overlaps)")
        let minimized = waitFor { record.frame.midY > expandedSearch.minY - 10 }   // the accessory moves into the bar
        note("Minimized", "search \(search.frame), record \(record.frame), transcripts \(transcripts.frame), "
             + "settings \(settings.exists ? "\(settings.frame) hittable \(settings.isHittable)" : "gone")")
        shot("Minimized", app)
        XCTAssertTrue(minimized, "the bar minimizes: record \(record.frame)")
        XCTAssertEqual(record.frame.midY, search.frame.midY, accuracy: 6, "accessory and Search in one row")
        XCTAssertLessThan(transcripts.frame.midX, record.frame.minX, "the current tab on the left")
        XCTAssertGreaterThan(search.frame.minX, record.frame.maxX - 1, "Search on the right")
        XCTAssertGreaterThan(search.frame.midX, width * 0.75, "Search still at the right end: \(search.frame)")
        XCTAssertFalse(settings.exists && settings.isHittable, "three items only")

        search.tap()                                        // Search's circle opens the Search tab
        XCTAssertTrue(app.textFields["SearchField"].waitForExistence(timeout: 5), "Search from the minimized bar")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.textFields["SearchField"].waitForNonExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(waitFor { settings.exists && settings.isHittable }, "scrolling up expands the bar again")
        shot("Expanded again", app)
    }

    /// The October 2026 cleanup: no font choice, Smart Corrections or Developer section. Transcription is Apple Speech by
    /// default, and Parakeet is an optional download named with its size (not tapped: it would fetch 610 MB), not in
    /// the picker until it is there. The Consulting & Banking Terms toggle is on the main page only, not under Your Words.
    @MainActor
    func testSettingsAfterCleanup() throws {
        let app = launch()
        app.buttons["Settings"].firstMatch.tap()
        let transcription = app.buttons["Transcription"].firstMatch
        XCTAssertTrue(transcription.waitForExistence(timeout: 5), "the Transcription row")
        for gone in ["Smart Corrections", "Reading", "Developer", "New York", "Libron", "Local Model"] {
            XCTAssertFalse(app.descendants(matching: .any)[gone].exists, "\(gone) is gone")
        }
        XCTAssertTrue(transcription.label.contains("Apple Speech"), "Apple Speech by default: \(transcription.label)")
        XCTAssertTrue(app.switches["Consulting & Banking Terms"].exists, "the built-in terms toggle on the main page")
        shot("Settings", app)

        transcription.tap()
        let apple = app.buttons["Apple Speech"]
        XCTAssertTrue(apple.waitForExistence(timeout: 5) && apple.isSelected, "Apple Speech chosen")
        XCTAssertFalse(app.buttons["Parakeet"].exists, "Parakeet is not in the picker before it is downloaded")
        XCTAssertTrue(app.buttons["Download Parakeet (610 MB)"].exists, "the download names the model and its size")
        shot("Transcription", app)
        app.navigationBars.buttons.firstMatch.tap()

        let yourWords = app.staticTexts["Your Words"].firstMatch   // the row is a link, not a button
        for _ in 0..<3 where !yourWords.isHittable { app.swipeUp() }
        yourWords.tap()
        XCTAssertTrue(app.textFields["Add a word or name"].waitForExistence(timeout: 5), "the Your Words page")
        XCTAssertFalse(app.switches["Consulting & Banking Terms"].exists, "not repeated under Your Words")
        shot("Your Words", app)
    }

    /// Settings › After Recording › Summaries: only Gemma writes titles and summaries. Without it (the simulator has no
    /// MLX GPU) the row says "Not available" and the page explains that it needs an 8 GB iPhone; with `-fakeGemma` the
    /// row names Gemma and the page has the switch.
    @MainActor
    func testSummariesSectionInSettings() throws {
        var app = launch()
        app.buttons["Settings"].firstMatch.tap()
        var row = app.buttons["Summaries"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the Summaries row under After Recording")
        XCTAssertTrue(row.label.contains("Not available"), "no Gemma on the simulator: \(row.label)")
        row.tap()
        let footer = app.staticTexts["Automatic titles and summaries need an iPhone with 8 GB of memory (iPhone 17 or later)."]
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "the page's footer without Gemma")
        XCTAssertTrue(app.staticTexts["Titles and Summaries"].exists, "the section header")
        shot("Summaries without Gemma", app)

        app.terminate()
        app = launch(["-fakeGemma"])
        app.buttons["Settings"].firstMatch.tap()
        row = app.buttons["Summaries"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Gemma 4 E2B"), "Gemma there: \(row.label)")
        row.tap()
        XCTAssertTrue(app.switches["Titles and Summaries"].waitForExistence(timeout: 5), "the on/off switch")
        shot("Summaries with Gemma", app)
    }

    @MainActor
    func testPeopleAndLiveLabelsInSettings() throws {
        let app = launch()
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Live Speaker Labels"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Live Speaker Labels toggle in Settings")
        let before = toggle.value as? String
        let knob = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))   // the switch at the row's end
        knob.tap()
        XCTAssertNotEqual(toggle.value as? String, before, "the toggle switches")
        knob.tap()                                          // back to how it was
        XCTAssertEqual(toggle.value as? String, before)

        app.buttons["People"].tap()
        XCTAssertTrue(app.navigationBars["People"].waitForExistence(timeout: 5), "People pushed inside Settings")
        let anna = app.staticTexts["Anna Schmidt"]
        XCTAssertTrue(anna.waitForExistence(timeout: 5), "seeded person listed")
        shot("people in settings", app)
        anna.tap()
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 5), "person view")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists && app.staticTexts["Budget Review"].exists,
                      "Anna's transcripts are listed")
        shot("person in settings", app)

        // A transcript of hers opens the transcript card (no push inside Settings); its grabber goes back to her.
        app.staticTexts["Budget Review"].tap()
        assertCard(app)
        XCTAssertEqual(app.textFields["Title"].value as? String, "Budget Review")
        XCTAssertTrue(app.buttons["SpeakerHeader.0"].exists, "the transcript")
        shot("card from a person", app)
        closeCard(app)
        XCTAssertTrue(app.navigationBars["Anna Schmidt"].waitForExistence(timeout: 5), "back at the person")
    }

    @MainActor
    func testSearchFieldOnlyWhileOpen() throws {
        let app = launch()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["SearchField"].exists)
        app.buttons["Search"].firstMatch.tap()
        let field = app.textFields["SearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search shows the field")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "focused, keyboard up")
        dismissKeyboardTip(app)
        shot("search open", app)
        XCTAssertTrue(app.buttons["Close"].firstMatch.exists, "search has a close button")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5), "back to the Transcripts tab")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "keyboard gone")
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 4) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        return condition()
    }
}
