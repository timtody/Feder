import XCTest

/// After a new build or update the speaker model is compiled at launch (AppServices.prewarmModels, about 35 s on an
/// iPhone 17). Meanwhile the record accessory's second line says "Preparing speaker model…" and a recording stopped
/// in that time says so in its status line instead of "Refining speakers…". The simulator has no real models:
/// `-fakeSpeakerModelSeconds` pretends the preparation takes that long, `-fakeDiarizeSeconds` keeps the speakers
/// step running long enough to read the line.
final class SpeakerModelPrewarmTests: ScribeUITestCase {
    @MainActor
    func testPreparingSpeakerModelIsShown() throws {
        let app = launch(["-fakeSpeakerModelSeconds", "25", "-fakeDiarizeSeconds", "40"])
        let accessoryLine = app.staticTexts["Preparing speaker model…"].firstMatch
        XCTAssertTrue(accessoryLine.appears(timeout: 5), "the accessory says the model is being prepared")
        shot("Accessory while preparing", app)

        startRecording(app)
        sleep(3)
        app.buttons["Stop"].firstMatch.tap()
        let status = app.staticTexts["PipelineStatus"]
        XCTAssertTrue(waitFor(timeout: 15) { (status.label) == "Preparing speaker model…" }, "the status line: \(status.label)")
        shot("Status line while preparing", app)

        // Once prepared, the speakers step reads as usual.
        XCTAssertTrue(waitFor(timeout: 30) { status.label == "Refining speakers…" || status.label == "Identifying speakers…" },
                      "back to the speakers step: \(status.label)")
    }

}
