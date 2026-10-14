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
/// Its field is the tab bar's bottom accessory on that tab (where Transcribe is on the others); a tap on it brings up
/// the keyboard with the composer (`ChatField`) over it. `-fakeGemma` answers with a canned reply streamed word by
/// word that names the question and the count of earlier messages (FakeTextWriter.chat). Kept with Gemma's download
/// tests, so the project needs no new test file.
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
        XCTAssertFalse(app.buttons["Send"].isEnabled, "no Send without text")
        let field = compose(app)
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

        XCTAssertTrue(field.exists, "the keyboard stays up after Send, as in Messages")
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

    /// The field is the bottom accessory, where Transcribe is on the other tabs: the same place and size, one row over
    /// the tab bar (not a third). The composer grows to five lines over the keyboard; with the keyboard gone the draft
    /// rests in the accessory, which minimizes with the bar, and it survives a trip to another tab.
    @MainActor
    func testFieldIsTheAccessory() throws {
        let app = launch(["-fakeGemma"])
        let record = transcribe(app)
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        let transcribeFrame = record.frame
        app.buttons["Ask"].firstMatch.tap()
        let rest = app.buttons["ChatAccessory"]
        XCTAssertTrue(rest.waitForExistence(timeout: 5), "the field in the accessory")
        XCTAssertFalse(record.exists, "no Transcribe on the Ask tab")
        XCTAssertEqual(rest.frame.minY, transcribeFrame.minY, accuracy: 1, "where Transcribe was: \(rest.frame) \(transcribeFrame)")
        XCTAssertEqual(rest.frame.height, transcribeFrame.height, accuracy: 1, "as tall as Transcribe")
        XCTAssertLessThan(rest.frame.maxY, app.buttons["Ask"].firstMatch.frame.minY + 4, "right over the tab bar")
        XCTAssertFalse(app.textFields["ChatField"].exists, "no second field over it")

        let field = compose(app)
        let oneLine = field.frame.height
        field.typeText("One\ntwo\nthree\nfour\nfive\nsix")
        XCTAssertGreaterThan(field.frame.height, oneLine * 3.5, "grows: \(oneLine) → \(field.frame.height)")
        XCTAssertLessThan(field.frame.height, oneLine * 5.8, "up to five lines: \(field.frame.height)")
        XCTAssertLessThan(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "over the keyboard")
        XCTAssertEqual(app.buttons.matching(identifier: "Send").count, 1, "one Send while composing")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "A draft")
        dismissKeyboard(app)
        XCTAssertTrue(rest.waitForExistence(timeout: 5), "the draft back in the accessory")
        XCTAssertFalse(field.exists, "the composer went with the keyboard")
        XCTAssertEqual(rest.label, "A draft")
        XCTAssertTrue(app.buttons["Send"].isEnabled, "Send from the accessory")
        shot("Draft in the minimized accessory", app)

        app.buttons["Ask"].firstMatch.tap()                         // expands a minimized bar
        app.buttons["Transcripts"].firstMatch.tap()
        XCTAssertTrue(record.waitForExistence(timeout: 5), "Transcribe back on the Transcripts tab")
        XCTAssertFalse(rest.exists)
        app.buttons["Ask"].firstMatch.tap()
        XCTAssertTrue(rest.waitForExistence(timeout: 5))
        XCTAssertEqual(rest.label, "A draft", "the draft survives the trip")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["A draft"].waitForExistence(timeout: 3), "sent from the accessory")
    }

    /// Stop mid-answer keeps what was written so far, captioned Stopped.
    @MainActor
    func testStopKeepsPartialAnswer() throws {
        let app = launch(["-fakeGemma", "-showAsk"], waitsForList: false)      // the list is in another tab
        let field = compose(app)
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

    /// Without Gemma the tab offers its download (as Settings › Summaries does), and the accessory's field is off;
    /// once Gemma is there, the field.
    @MainActor
    func testAskOffersDownload() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeGemmaDownloadSeconds", "4", "-improvementsOnboardingShown", "YES",
                          "-showAsk"], waitsForList: false)
        XCTAssertTrue(app.staticTexts["Download Gemma to Chat"].waitForExistence(timeout: 15), "the download offer")
        let rest = app.buttons["ChatAccessory"]
        XCTAssertTrue(rest.exists && !rest.isEnabled, "the field is off before Gemma is there")
        app.buttons["Download Gemma 4 E2B (3.6 GB)"].tap()
        XCTAssertTrue(app.staticTexts["Downloading Gemma 4 E2B…"].waitForExistence(timeout: 5), "the progress")
        shot("Downloading", app)
        XCTAssertTrue(app.staticTexts["Ask Gemma"].waitForExistence(timeout: 15), "downloaded: the chat")
        XCTAssertTrue(rest.isEnabled, "and the field")
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
        XCTAssertEqual(app.buttons["ChatAccessory"].label, "Gemma fragen", "the field in German")
        shot("Ask in German", app)
    }

    /// While recording Gemma doesn't run: the recording takes the accessory on the Ask tab too (it wins over the
    /// field, as Music's mini player shows what plays), and the chat says why it pauses.
    @MainActor
    func testAskPausedWhileRecording() throws {
        let app = launch(["-fakeGemma", "-showAsk", "-autoRecord"], waitsForList: false)
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 15), "recording in the card")
        closeCard(app)
        XCTAssertTrue(app.buttons["Recording"].firstMatch.waitForExistence(timeout: 5)
                      || app.otherElements["Recording"].firstMatch.exists, "the recording in the accessory")
        XCTAssertFalse(app.buttons["ChatAccessory"].exists, "no field while recording")
        XCTAssertTrue(app.staticTexts["Gemma pauses while you record."].exists, "the chat says why")
        shot("Paused while recording", app)
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 15), "saved: the card opens on the transcript")
        closeCard(app)
        app.buttons["Ask"].firstMatch.tap()
        XCTAssertTrue(app.buttons["ChatAccessory"].waitForExistence(timeout: 5), "the field is back after Stop")
    }

    /// Taps the field in the accessory: the composer comes up with the keyboard and has the focus.
    @MainActor
    private func compose(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let rest = app.buttons["ChatAccessory"]
        XCTAssertTrue(rest.waitForExistence(timeout: 15), "the field in the accessory", file: file, line: line)
        rest.tap()
        dismissKeyboardTip(app)
        let field = app.textFields["ChatField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the composer", file: file, line: line)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard", file: file, line: line)
        return field
    }

    /// A drag from the conversation down into the keyboard puts it away (`scrollDismissesKeyboard(.interactively)`;
    /// the tab bar is under the keyboard meanwhile).
    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
                   withVelocity: .default, thenHoldForDuration: 0.1)
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }
}
