import XCTest

/// Gemma's download (BetterSummaries, GemmaDownload). The simulator can't run MLX and the tests must not fetch 3.6 GB:
/// `-fakeGemmaDownload` offers Gemma as if on an 8 GB iPhone and stands in for the background transfer
/// (`-fakeGemmaDownloadSeconds`, from 0 to 100 %), `-fakeNoWiFi` keeps it waiting for Wi-Fi.
/// `-improvementsOnboardingShown YES` keeps the onboarding sheet away (it has its own test).
final class GemmaDownloadTests: ScribeUITestCase {
    @MainActor
    func testDownloadInSettings() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeGemmaDownloadSeconds", "12", "-improvementsOnboardingShown", "YES"])
        app.buttons["Settings"].firstMatch.tap()
        let row = app.buttons["Summaries"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Not downloaded"), row.label)
        row.tap()
        let download = app.buttons["Download Gemma 4 E2B (3.6 GB)"]
        XCTAssertTrue(download.waitForExistence(timeout: 5), "the download names the model and its size")
        download.tap()
        XCTAssertTrue(app.staticTexts["Downloading Gemma 4 E2B…"].waitForExistence(timeout: 5), "the progress row")
        XCTAssertTrue(app.buttons["Cancel Download"].exists, "a running download can be cancelled")
        shot("Downloading", app)
        XCTAssertTrue(app.switches["Titles and Summaries"].waitForExistence(timeout: 20), "ready: the on/off switch")
        XCTAssertFalse(app.buttons["Cancel Download"].exists)
        shot("Downloaded", app)
    }

    @MainActor
    func testWaitsForWiFiAndCancels() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeNoWiFi", "-improvementsOnboardingShown", "YES"])
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Summaries"].firstMatch.tap()
        let download = app.buttons["Download Gemma 4 E2B (3.6 GB)"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi…"].waitForExistence(timeout: 5), "no Wi-Fi: it waits")
        shot("Waiting for Wi-Fi", app)
        app.buttons["Cancel Download"].tap()
        XCTAssertTrue(download.waitForExistence(timeout: 5), "cancelled: the Download button again")
    }
}

/// The Ask tab (FED-17, DEBUG builds on iPhones that run Gemma): a chat with Gemma, between Transcripts and Search.
/// `-fakeGemma` answers with a canned reply streamed word by word that names the question and the count of earlier
/// messages (FakeTextWriter.chat). Kept with Gemma's download tests, so the project needs no new test file.
final class AskTests: ScribeUITestCase {
    /// The tab sits between Transcripts and Search; a question gets a streamed answer (Stop while it streams, Send
    /// again after), a follow-up carries the history, and New Chat clears the conversation.
    @MainActor
    func testAskTabAnswers() throws {
        let app = launch(["-fakeGemma"])
        let transcripts = app.buttons["Transcripts"].firstMatch, ask = app.buttons["Ask"].firstMatch
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "the Ask tab with Gemma")
        XCTAssertTrue(transcripts.frame.midX < ask.frame.midX && ask.frame.midX < search.frame.midX,
                      "Transcripts, Ask, Search: \(transcripts.frame) \(ask.frame) \(search.frame)")
        XCTAssertEqual(ask.frame.midY, search.frame.midY, accuracy: 2, "in the same bar")
        ask.tap()
        XCTAssertTrue(app.staticTexts["Ask Gemma"].waitForExistence(timeout: 5), "the empty chat")
        XCTAssertFalse(app.buttons["New Chat"].isEnabled, "nothing to clear yet")
        let field = app.textFields["ChatField"]
        XCTAssertTrue(field.exists)
        XCTAssertFalse(app.buttons["Send"].isEnabled, "no Send without text")
        field.tap()
        dismissKeyboardTip(app)
        field.typeText("What can you do?")
        shot("Typed", app)
        app.buttons["Send"].tap()
        // Stop first: the fake answer is done in about 3.5 s, and with the keyboard up each query takes a while.
        XCTAssertTrue(app.buttons["Stop Answer"].waitForExistence(timeout: 3), "Send turns into Stop")
        XCTAssertTrue(app.staticTexts["What can you do?"].exists, "the question in its bubble")
        let answer = app.staticTexts["ChatAnswer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "the answer streams in")
        shot("Streaming", app)
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 15), "Stop turns back into Send")
        XCTAssertTrue(answer.label.contains("You asked: \u{201C}What can you do?\u{201D}"), answer.label)
        XCTAssertTrue(answer.label.contains("Earlier messages: 0."), answer.label)

        field.typeText("And then?")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Stop Answer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 15))
        let second = app.staticTexts.matching(identifier: "ChatAnswer").element(boundBy: 1)
        XCTAssertTrue(second.label.contains("Earlier messages: 2."), "the history went along: \(second.label)")
        shot("Two answers", app)

        app.buttons["New Chat"].tap()
        XCTAssertTrue(app.staticTexts["Ask Gemma"].waitForExistence(timeout: 5), "New Chat clears the conversation")
        XCTAssertFalse(app.staticTexts["ChatAnswer"].exists)
    }

    /// Stop mid-answer keeps what was written so far, captioned Stopped.
    @MainActor
    func testStopKeepsPartialAnswer() throws {
        let app = launch(["-fakeGemma", "-showAsk"], waitsForList: false)      // the list is in another tab
        let field = app.textFields["ChatField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        dismissKeyboardTip(app)
        field.typeText("Tell me something long")
        app.buttons["Send"].tap()
        let answer = app.staticTexts["ChatAnswer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        app.buttons["Stop Answer"].tap()
        XCTAssertTrue(app.staticTexts["Stopped"].waitForExistence(timeout: 3), "the answer is marked Stopped")
        XCTAssertTrue(app.buttons["Send"].exists, "Send again")
        XCTAssertFalse(answer.label.contains("That is all for now."), "only part of it: \(answer.label)")
        XCTAssertTrue(answer.label.hasPrefix("You asked"), answer.label)
        shot("Stopped", app)
    }

    /// Without Gemma the tab offers its download (as Settings › Summaries does); once it is there, the field.
    @MainActor
    func testAskOffersDownload() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeGemmaDownloadSeconds", "4", "-improvementsOnboardingShown", "YES",
                          "-showAsk"], waitsForList: false)
        XCTAssertTrue(app.staticTexts["Download Gemma to Chat"].waitForExistence(timeout: 15), "the download offer")
        XCTAssertFalse(app.textFields["ChatField"].exists, "no field before Gemma is there")
        app.buttons["Download Gemma 4 E2B (3.6 GB)"].tap()
        XCTAssertTrue(app.staticTexts["Downloading Gemma 4 E2B…"].waitForExistence(timeout: 5), "the progress")
        shot("Downloading", app)
        XCTAssertTrue(app.textFields["ChatField"].waitForExistence(timeout: 15), "downloaded: the chat")
        XCTAssertTrue(app.staticTexts["Ask Gemma"].exists)
    }

    /// German: the tab is "Fragen", the empty chat "Gemma fragen".
    @MainActor
    func testAskInGerman() throws {
        let app = launch(["-fakeGemma", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"], waitsForList: false)
        let ask = app.buttons["Fragen"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 15), "the tab in German")
        ask.tap()
        XCTAssertTrue(app.staticTexts["Gemma fragen"].waitForExistence(timeout: 5), "the empty chat in German")
        XCTAssertTrue(app.buttons["Neuer Chat"].exists, "New Chat in German")
        shot("Ask in German", app)
    }

    /// While recording Gemma doesn't run: the field is off and says why.
    @MainActor
    func testAskPausedWhileRecording() throws {
        let app = launch(["-fakeGemma", "-showAsk", "-autoRecord"], waitsForList: false)
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 15), "recording in the card")
        closeCard(app)
        let field = app.textFields["ChatField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(field.isEnabled, "no questions while recording")
        XCTAssertEqual(field.placeholderValue, "Gemma pauses while you record.")
        shot("Paused while recording", app)
    }
}
