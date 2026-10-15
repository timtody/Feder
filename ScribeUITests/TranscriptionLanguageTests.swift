import XCTest

/// The record accessory, like Music's mini player: "Transcribe" over the language ("German · On device") and a
/// language button at the end ("DE ⌄") that picks the next recording's language (TranscriptionLanguage).
final class TranscriptionLanguageTests: ScribeUITestCase {
    /// The menu switches the language and the subtitle follows; switched back at the end, so no setting is left
    /// behind on the simulator.
    @MainActor
    func testLanguageMenu() throws {
        let app = launch()
        let menu = app.buttons["Language"]
        XCTAssertTrue(menu.appears(timeout: 5), "the language button in the accessory")
        XCTAssertTrue(transcribe(app).exists, "Transcribe beside it")
        let before = menu.value as? String ?? ""
        let other = before == "English" ? "German" : "English"
        shot("Accessory", app)

        menu.tap()
        let item = app.buttons[other].firstMatch
        XCTAssertTrue(item.appears(timeout: 5), "\(other) in the menu")
        shot("Language menu", app)
        item.tap()
        XCTAssertTrue(app.staticTexts["\(other) · On device"].appears(timeout: 5), "the subtitle follows")
        XCTAssertEqual(menu.value as? String, other)

        menu.tap()                                                   // back to how it was
        app.buttons[before].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["\(before) · On device"].appears(timeout: 5))
    }

    /// A recording is transcribed in the chosen language: the card's caption names it. The language comes as a launch
    /// argument here (argument values are not written to the app's settings); `-fakeSilence` makes Stop discard it.
    @MainActor
    func testRecordingUsesTheLanguage() throws {
        let app = launch(["-transcriptionLanguage", "en-US", "-fakeSilence"])
        XCTAssertTrue(app.staticTexts["English · On device"].appears(timeout: 5), "the accessory says English")
        startRecording(app)
        let caption = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'English' AND label ENDSWITH 'On device'")).firstMatch
        XCTAssertTrue(caption.appears(timeout: 10), "the live card transcribes in English")
        app.buttons["Stop"].firstMatch.tap()
    }
}
