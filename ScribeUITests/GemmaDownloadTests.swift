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

/// Ask (FED-17, DEBUG builds on iPhones that run Gemma): a chat with Gemma as a card that zooms out of the record
/// accessory's Ask button (`AskGemma`, where Import was): a sheet at half height that pulls up to full, Close and New Chat
/// at the top, the field (`ChatField`) at the bottom. `-fakeGemma` answers with a canned reply streamed word by word
/// that names the question and the count of earlier messages (FakeTextWriter.chat). Kept with Gemma's download tests,
/// so the project needs no new test file.
final class AskTests: ScribeUITestCase {
    /// Ask sits at the accessory's end, right of the language, and stays when the bar minimizes. A tap opens the card
    /// at half height; a question gets a streamed answer (Stop while it streams, Send again after), a follow-up carries
    /// the history, New Chat clears the conversation, Close puts the card away.
    @MainActor
    func testAskCardAnswers() throws {
        let app = launch(["-fakeGemma", "-seedFiller", "12"])
        let ask = app.buttons["AskGemma"], language = app.buttons["Language"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "Ask in the accessory")
        XCTAssertLessThan(app.buttons["ImportAudio"].frame.maxY, app.frame.height * 0.2, "Import is at the top, not here")
        XCTAssertGreaterThan(ask.frame.minX, language.frame.maxX - 1, "right of the language")
        XCTAssertLessThan(abs(ask.frame.midY - language.frame.midY), 3, "on the language's line")
        XCTAssertLessThan(ask.frame.maxY, app.buttons["Transcripts"].firstMatch.frame.minY + 4, "over the tab bar")
        XCTAssertEqual(app.tabBars.buttons.count, 3, "Settings, Transcripts, Search: no Ask tab")
        app.swipeUp()                                            // the list scrolls: the bar minimizes
        XCTAssertTrue(waitUntil { !language.isHittable }, "minimized: no language")
        XCTAssertTrue(ask.isHittable, "Ask stays")
        XCTAssertGreaterThan(ask.frame.midX, app.frame.width * 0.5, "on the right")
        shot("Minimized with Ask", app)

        ask.tap()
        let title = app.navigationBars["Ask Gemma"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the card")
        let height = app.frame.height
        XCTAssertTrue(waitUntil { abs(title.frame.minY - height * 0.5) < height * 0.12 },
                      "at half height: \(title.frame) in \(height)")
        XCTAssertTrue(app.staticTexts["Ask Gemma"].exists, "the empty chat")
        XCTAssertFalse(app.buttons["New Chat"].isEnabled, "nothing to clear yet")
        XCTAssertFalse(app.buttons["Send"].isEnabled, "no Send without text")
        let field = app.textFields["ChatField"]
        XCTAssertTrue(field.exists, "the field")
        XCTAssertGreaterThan(field.frame.minY, height * 0.8, "at the bottom: \(field.frame)")
        shot("Card at half height", app)

        field.tap()
        dismissKeyboardTip(app)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the keyboard")
        XCTAssertTrue(waitUntil { title.frame.minY < height * 0.15 }, "typing: the card goes to full height: \(title.frame)")
        XCTAssertLessThan(field.frame.maxY, keyboard.frame.minY + 1, "the field over the keyboard")
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

        XCTAssertTrue(keyboard.exists, "the keyboard stays up after Send, as in Messages")
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
        app.buttons["CloseAsk"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "Close puts the card away")
        XCTAssertTrue(ask.isHittable, "back to the accessory")
    }

    /// A transcript's More › Ask About Transcript (FED-137) opens Ask's card about it: its title under "Ask Gemma", and
    /// the answer comes from the transcript (the fake quotes its first line). Its conversation is its own: Ask from the
    /// accessory stays empty, and the transcript's comes back when it is asked about again.
    @MainActor
    func testAskAboutTranscript() throws {
        let app = launch(["-fakeGemma"])
        open("Project Kickoff", in: app)
        app.buttons["More"].tap()
        let item = app.buttons["AskAboutTranscript"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "in More")
        item.tap()
        XCTAssertTrue(app.navigationBars["Ask Gemma"].waitForExistence(timeout: 5), "the Ask card")
        XCTAssertTrue(app.staticTexts["Project Kickoff"].exists, "about Project Kickoff")
        XCTAssertTrue(app.staticTexts["Ask About This Transcript"].exists, "the empty chat says so")
        shot("Ask about a transcript", app)
        let field = app.textFields["ChatField"]
        field.tap()
        dismissKeyboardTip(app)
        field.typeText("Who owns what?")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 15) && app.buttons["Stop Answer"].waitForNonExistence(timeout: 15),
                      "answered")
        let answer = app.staticTexts["ChatAnswer"].firstMatch
        XCTAssertTrue(answer.label.contains("The transcript begins:") && answer.label.contains("Okay, let"),
                      "the transcript went along: \(answer.label)")
        shot("Answered from the transcript", app)
        app.buttons["CloseAsk"].tap()
        XCTAssertTrue(app.navigationBars["Ask Gemma"].waitForNonExistence(timeout: 5))

        closeCard(app)
        app.buttons["AskGemma"].tap()
        XCTAssertTrue(app.staticTexts["Ask Gemma"].waitForExistence(timeout: 5), "Ask's own chat is still empty")
        XCTAssertFalse(app.staticTexts["ChatAnswer"].exists)
        app.buttons["CloseAsk"].tap()
        XCTAssertTrue(app.navigationBars["Ask Gemma"].waitForNonExistence(timeout: 5))
        open("Project Kickoff", in: app)
        app.buttons["More"].tap()
        app.buttons["AskAboutTranscript"].tap()
        XCTAssertTrue(app.staticTexts["Who owns what?"].waitForExistence(timeout: 5), "the transcript's chat is kept")
    }

    /// The field grows to five lines over the keyboard; a draft survives closing the card (a swipe down) and is sent
    /// when it is opened again. Pulled up by its grabber, the card goes to full height without the keyboard.
    @MainActor
    func testFieldGrowsAndDraftSurvives() throws {
        let app = launch(["-fakeGemma"])
        let ask = app.buttons["AskGemma"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.tap()
        let title = app.navigationBars["Ask Gemma"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let height = app.frame.height
        XCTAssertTrue(waitUntil { title.frame.minY > height * 0.3 }, "half height first")
        // Pulled up from the top of the card: full height.
        let top = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        XCTAssertTrue(waitUntil { title.frame.minY < height * 0.15 }, "pulled up to full: \(title.frame)")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "no keyboard for that")
        shot("Card at full height", app)

        let field = app.textFields["ChatField"]
        field.tap()
        dismissKeyboardTip(app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let oneLine = field.frame.height
        field.typeText("One\ntwo\nthree\nfour\nfive\nsix")
        XCTAssertGreaterThan(field.frame.height, oneLine * 3.5, "grows: \(oneLine) → \(field.frame.height)")
        XCTAssertLessThan(field.frame.height, oneLine * 5.8, "up to five lines: \(field.frame.height)")
        XCTAssertLessThan(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "over the keyboard")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "A draft")
        app.buttons["CloseAsk"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "closed")
        ask.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "A draft", "the draft survives closing the card")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["A draft"].waitForExistence(timeout: 3), "sent")
        // A swipe down on the grabber closes it, as any sheet.
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "swiped away")
    }

    /// Stop mid-answer keeps what was written so far, captioned Stopped.
    @MainActor
    func testStopKeepsPartialAnswer() throws {
        let app = launch(["-fakeGemma", "-askQuestion", "Tell me something long"])
        let answer = app.staticTexts["ChatAnswer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        app.buttons["Stop Answer"].tap()
        XCTAssertTrue(app.staticTexts["Stopped"].waitForExistence(timeout: 3), "the answer is marked Stopped")
        XCTAssertTrue(app.buttons["Send"].exists, "Send again")
        XCTAssertFalse(answer.label.contains("That is all for now."), "only part of it: \(answer.label)")
        XCTAssertTrue(answer.label.hasPrefix("You asked"), answer.label)
        shot("Stopped", app)
    }

    /// Without Gemma the card offers its download (as Settings › Summaries does) and has no field; once Gemma is
    /// there, the chat and the field.
    @MainActor
    func testAskOffersDownload() throws {
        let app = launch(["-fakeGemmaDownload", "-fakeGemmaDownloadSeconds", "4", "-improvementsOnboardingShown", "YES",
                          "-showAsk"])
        XCTAssertTrue(app.staticTexts["Download Gemma to Chat"].waitForExistence(timeout: 15), "the download offer")
        XCTAssertFalse(app.textFields["ChatField"].exists, "no field before Gemma is there")
        app.buttons["Download Gemma 4 E2B (3.6 GB)"].tap()
        XCTAssertTrue(app.staticTexts["Downloading Gemma 4 E2B…"].waitForExistence(timeout: 5), "the progress")
        shot("Downloading", app)
        XCTAssertTrue(app.staticTexts["Ask Gemma"].waitForExistence(timeout: 15), "downloaded: the chat")
        XCTAssertTrue(app.textFields["ChatField"].waitForExistence(timeout: 5), "and the field")
    }

    /// German: the button and the card are "Gemma fragen", New Chat "Neuer Chat".
    @MainActor
    func testAskInGerman() throws {
        let app = launch(["-fakeGemma", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"])
        let ask = app.buttons["AskGemma"]
        XCTAssertTrue(ask.waitForExistence(timeout: 15))
        XCTAssertEqual(ask.label, "Gemma fragen", "the button in German")
        ask.tap()
        XCTAssertTrue(app.navigationBars["Gemma fragen"].waitForExistence(timeout: 5), "the card in German")
        XCTAssertTrue(app.buttons["Neuer Chat"].exists, "New Chat in German")
        shot("Ask in German", app)
    }

    /// While recording Gemma doesn't run: the accessory shows the recording, without Ask; after Stop Ask is back. A
    /// recording started from outside while the card is up (the Action Button) closes it for the recording's card.
    @MainActor
    func testNoAskWhileRecording() throws {
        let app = launch(["-fakeGemma", "-showAsk", "-fakeOutsidePressAfter", "4"])
        XCTAssertTrue(app.navigationBars["Ask Gemma"].waitForExistence(timeout: 5), "the card is up")
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 15), "the recording's card instead")
        XCTAssertFalse(app.navigationBars["Ask Gemma"].exists, "the Ask card went")
        closeCard(app)
        XCTAssertTrue(app.buttons["Recording"].firstMatch.waitForExistence(timeout: 5)
                      || app.otherElements["Recording"].firstMatch.exists, "the recording in the accessory")
        XCTAssertFalse(app.buttons["AskGemma"].exists, "no Ask while recording")
        shot("Recording without Ask", app)
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 15), "saved: the card opens on the transcript")
        closeCard(app)
        XCTAssertTrue(app.buttons["AskGemma"].waitForExistence(timeout: 5), "Ask is back after Stop")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        return condition()
    }
}
